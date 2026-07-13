
# DDCS Test, Verification, Troubleshooting, and Benchmarks

Operational detail for validating a DDCS deployment. SKILL.md keeps Steps 1–6 + 8 (install/teardown) inline; this file holds the optional proof-of-life test, the post-deploy verification checks, the troubleshooting matrix, and the reference benchmark data.

## Step 7 — Proof-of-life test (optional)

Only when `ENABLE_TEST=true` or `--test` flag is passed. This deploys a Kit pod (Isaac Sim) that connects to DDCS and validates the shader cache pipeline.

**Critical: GKE NVIDIA lib path fix.** On GKE Container-Optimized OS, NVIDIA libs are at `/usr/local/nvidia/lib64/` but not in the `ldconfig` cache. Kit's `startup.sh` checks `ldconfig -p | grep libGLX_nvidia.so.0` and fails without this fix:

```bash
echo "/usr/local/nvidia/lib64" > /etc/ld.so.conf.d/nvidia-gke.conf
ldconfig
```

This requires `runAsUser: 0` and `OMNI_KIT_ALLOW_ROOT=1`.

**Kit launch command (warmup mode):**

The preferred Kit invocation uses `kit/kit` directly with `warmupMode=1` instead of `isaac-sim.sh`. This forces the extension warmup pipeline (shader compilation) without needing an external USD scene, and `fastShutdown=1` prevents Kit from hanging during shutdown.

```bash
cd /isaac-sim
export OMNI_KIT_ALLOW_ROOT=1
./kit/kit ./apps/isaacsim.exp.base.kit \
  --no-window \
  --/app/warmupMode=1 \
  --/app/quitAfter=300 \
  --/app/fastShutdown=1 \
  --/app/content/emptyStageOnStart=1 \
  --/rtx/materialDb/syncLoads=1 \
  --/omni.kit.plugin/syncUsdLoads=1 \
  --/rtx/hydra/materialSyncLoads=1 \
  --/app/asyncRendering=0 \
  --ext-folder ./exts --ext-folder ./apps \
  --enable omni.ujitso.default \
  --/drivercachewrapper/enableByProtocol=grpcdns://${DDCS_ENDPOINT} \
  --/drivercachewrapper/grpcDnsName=${DDCS_ENDPOINT} \
  --/drivercachewrapper/grpcUseTLS=false \
  --/UJITSO/datastore/GRPCDataStore/useTLS=false \
  --/UJITSO/datastore/GRPCDataStore/selfFile/enabled=false \
  --/UJITSO/datastore/GRPCDataStore/tenantID=${TENANT_ID} \
  --/UJITSO/datastore/GRPCDnsName=${DDCS_ENDPOINT} \
  --/log/outputStreamLevel=verbose \
  --/log/channels/omni.datastore=verbose \
  --/log/channels/gpu.foundation.plugin=verbose
```

Note: `warmupMode=1` is an application-level hint for asset pre-loading by extensions and does NOT bypass the `DriverShaderCacheManager`'s routing through the configured GRPC datastore. The DDCS flags are still effective.

**Pass/fail (two checks):**

1. **Datastore creation:** grep Kit logs for `DataStoreConfigurator[DriverShaderCacheManager]: created GRPC datastore`. If only `created local datastore` appears, FAIL — DDCS is not being used.

2. **Shader cook time (the definitive metric):** grep for `Preparing shaders` and `Shaders are cooked` and compare the `[Nms]` timestamps. Without DDCS the gap is ~100s. With warm DDCS it drops to <1s. If the warm run still shows ~100s, the `drivercachewrapper` is not routing through DDCS (check path doubling and gxcache).

```bash
# Replace <KIT_TEST_POD> with the pod created by the proof-of-life step.
kubectl logs <KIT_TEST_POD> -n $DDCS_NAMESPACE | grep -E "Preparing shaders|Shaders are cooked"
# Expected (warm DDCS):
#   [29346ms] Preparing shaders...
#   [29779ms] Shaders are cooked.    ← 0.4s gap = PASS
# Expected (no DDCS / broken config):
#   [75000ms] Preparing shaders...
#   [181000ms] Shaders are cooked.   ← 106s gap = FAIL
```

The `drivercachewrapper` intercepts the driver-level shader compilation that happens *inside* this phase. When DDCS is warm, driver cache hits cause the entire phase to complete in under 1s.

**Important constraints for the test pod:**
- Image must include the full RTX renderer (`nvcr.io/nvidia/isaac-sim:5.1.0` or `coreapi-service`). The bare `ov-kit-kernel` lacks `gpu.foundation` and will NOT trigger `DriverShaderCacheManager`.
- An app loop is required. Just loading extensions with `--enable` exits immediately. The `isaac-sim.sh` launcher creates the proper render loop.
- GPU node must have RT cores (L4, T4, RTX PRO 6000). A100/H100 are compute-only and will not work.

## Post-deployment verification

After deploying DDCS and configuring write-render-worker, run these checks to confirm shader caching is working.

### Check 1: WRW args are correct

```bash
kubectl get sts write-render-worker -n $DDCS_NAMESPACE \
  -o jsonpath='{.spec.template.spec.containers[0].args}' | python3 -m json.tool
```

Verify `drivercachewrapper` args are present. If deployed via Helm, paths should be doubled. If patched via `kubectl patch`, paths should be single-level.

### Check 2: Shader cook time (definitive)

```bash
kubectl logs write-render-worker-0 -n $DDCS_NAMESPACE | grep -E "Preparing shaders|Shaders are cooked"
```

| Result | Shader cook gap | Meaning |
|--------|----------------|---------|
| <1s | DDCS warm cache serving shaders | Working |
| ~100s | Compiling from scratch | DDCS not used — check args, gxcache, path doubling |

### Check 3: DDCS received data

```bash
kubectl run ddcs-check --rm -i --restart=Never --image=curlimages/curl -n $DDCS_NAMESPACE \
  -- curl -s http://ddcs:3051/metrics 2>/dev/null \
  | grep -E "ddcs_m_api_keys_total|ddcs_m_adapter_entry_cache_total" | grep -v "^#"
```

| Metric | Cold run | Warm run | Meaning |
|--------|----------|----------|---------|
| `grpc_put` | >0 | 0 | Cold populates cache, warm reads from it |
| `grpc_get` | >0 | >0 | WRW querying DDCS on both runs |

### Check 4: gxcache is disabled

```bash
kubectl get sts write-render-worker -n $DDCS_NAMESPACE -o yaml | grep -i gxcache
```

Should show `enabled: false` or nothing. If `enabled: true`, drivercachewrapper cannot intercept.

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Warm shader cook still ~100s | Doubled paths in Kit CLI | Use single-level `--/drivercachewrapper/...` |
| Warm shader cook still ~100s | gxcache enabled (chart default) | Set `gxcache.enabled: false` in Helm values |
| DDCS `grpc_put` = 0 on cold | drivercachewrapper not loaded | Check `gpu.foundation.plugin` appears in WRW logs |
| DDCS `grpc_get` = 0 | WRW not pointing at DDCS | Check args for `enableByProtocol=grpcdns://...` |
| DDCS gets traffic but warm still slow | UJITSO traffic only, not shaders | Verify `drivercachewrapper` args (not just `UJITSO`) |

## Benchmark data (GKE, L4 GPU, warehouse20x20 scene)

| Metric | No DDCS (baseline) | DDCS cold | DDCS warm |
|--------|-------------------|-----------|-----------|
| Shader cook time | 106s | 101.5s | **0.4s** |
| DDCS grpc_put | — | 644 | 0 |
| DDCS grpc_get | — | 1,364 | 710 |
| WRW pod-to-listen | 179s | ~190s | **30s** |

Measured on `mega-cache-test` cluster (GKE Standard, us-west4-a, L4 GPU, driver 580.105.08, WRW 107.3.4).
