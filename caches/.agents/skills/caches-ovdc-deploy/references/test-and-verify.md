
# OVDC Test, Verification, and Troubleshooting

Operational detail for validating an OVDC deployment. `references/deployment.md` holds install/teardown; this file holds the optional proof-of-life test, the post-deploy verification checks, the troubleshooting matrix.

## Step 7 — Proof-of-life test (optional)

Only when `ENABLE_TEST=true` or `--test` flag is passed. This deploys a Kit pod (Isaac Sim) that connects to OVDC and validates the shader cache pipeline.

**Critical: GKE NVIDIA lib path fix.** On GKE Container-Optimized OS, NVIDIA libs are at `/usr/local/nvidia/lib64/` but not in the `ldconfig` cache. Kit's `startup.sh` checks `ldconfig -p | grep libGLX_nvidia.so.0` and fails without this fix:

```bash
set -euo pipefail
echo "/usr/local/nvidia/lib64" > /etc/ld.so.conf.d/nvidia-gke.conf
ldconfig
```

This requires `runAsUser: 0` and `OMNI_KIT_ALLOW_ROOT=1`.

**Kit launch command (warmup mode):**

The preferred Kit invocation uses `kit/kit` directly with `warmupMode=1` instead of `isaac-sim.sh`. This forces the extension warmup pipeline (shader compilation) without needing an external USD scene, and `fastShutdown=1` prevents Kit from hanging during shutdown.

```bash
set -euo pipefail
: "${OVDC_ENDPOINT:?Set OVDC_ENDPOINT to ovdc.<namespace>.svc.cluster.local:3010}"
TENANT_ARGS=()
if [ -n "${TENANT_ID:-}" ]; then
  TENANT_ARGS=("--/UJITSO/datastore/GRPCDataStore/tenantID=${TENANT_ID}")
fi
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
  --/drivercachewrapper/enableByProtocol=grpcdns://${OVDC_ENDPOINT} \
  --/drivercachewrapper/grpcDnsName=${OVDC_ENDPOINT} \
  --/drivercachewrapper/grpcUseTLS=false \
  --/UJITSO/datastore/GRPCDataStore/useTLS=false \
  --/UJITSO/datastore/GRPCDataStore/selfFile/enabled=false \
  "${TENANT_ARGS[@]}" \
  --/UJITSO/datastore/grpcDnsName=${OVDC_ENDPOINT} \
  --/log/outputStreamLevel=verbose \
  --/log/channels/omni.datastore=verbose \
  --/log/channels/gpu.foundation.plugin=verbose
```

Note: `warmupMode=1` is an application-level hint for asset pre-loading by extensions and does NOT bypass the `DriverShaderCacheManager`'s routing through the configured GRPC datastore. The OVDC flags are still effective.

**Pass/fail (two checks):**

1. **Datastore creation:** grep Kit logs for `DataStoreConfigurator[DriverShaderCacheManager]: created GRPC datastore`. If only `created local datastore` appears, FAIL — OVDC is not being used.

2. **Cold/warm comparison:** record the timestamps of `Preparing shaders` and
`Shaders are cooked` for the same workload before and after populating OVDC.
A warm run should improve when cache traffic confirms successful hits. Timing
alone is not a pass/fail contract; correlate it with datastore creation logs
and the deployed version's metrics.

```bash
set -euo pipefail
kubectl logs "${KIT_TEST_POD:?Set KIT_TEST_POD}" -n "${OVDC_NAMESPACE:?Set OVDC_NAMESPACE to the OVDC namespace}" | grep -E "Preparing shaders|Shaders are cooked"
```

**Important constraints for the test pod:**
- Image must include the full RTX renderer (`nvcr.io/nvidia/isaac-sim:5.1.0` or `coreapi-service`). The bare `ov-kit-kernel` lacks `gpu.foundation` and will NOT trigger `DriverShaderCacheManager`.
- An app loop is required. Just loading extensions with `--enable` exits immediately. The `isaac-sim.sh` launcher creates the proper render loop.
- GPU node must have RT cores (L4, T4, RTX PRO 6000). A100/H100 are compute-only and will not work.

## Post-deployment verification

After deploying OVDC and configuring write-render-worker, run these checks to confirm shader caching is working.

### Check 1: WRW args are correct

```bash
set -euo pipefail
kubectl get sts write-render-worker -n "${WRW_NAMESPACE:?Set WRW_NAMESPACE to the simulation namespace}" \
  -o jsonpath='{.spec.template.spec.containers[0].args}' | python3 -m json.tool
```

Verify `drivercachewrapper` args are present. Use the single-level paths shown in `ovdc-overrides.yaml`; confirm the rendered WRW args rather than adding path prefixes.

### Check 2: Shader cook time (supporting evidence)

```bash
set -euo pipefail
kubectl logs write-render-worker-0 -n "${WRW_NAMESPACE:?Set WRW_NAMESPACE to the simulation namespace}" | grep -E "Preparing shaders|Shaders are cooked"
```

Compare the same scene on cold and warm runs, alongside cache traffic.
Timing alone does not prove that OVDC served shader-cache hits.

### Check 3: OVDC received data

```bash
set -euo pipefail
kubectl run ovdc-check --rm -i --restart=Never --image=curlimages/curl -n "${OVDC_NAMESPACE:?Set OVDC_NAMESPACE to the OVDC namespace}" \
  -- curl -fsS http://ovdc:3051/metrics \
  | grep -v "^#"
```

Record the deployed version's metric names, labels and counter values before
and after each run. Compare counter increases for the same replicas; a restart
can reset counters. Do not treat bare `grpc_get` or `grpc_put` names as a
verified OVDC metric contract.

| Observation | Evidence to collect |
|-------------|---------------------|
| Cold population | Write/put counter increases for the selected workload |
| Cache reads | Read/get counter increases across each run |
| Warm cache reuse | Cache-hit counter increases, correlated with the shader datastore creation logs |

Warm runs may still write new data. A zero write counter is not a required
warm-run result, and cumulative counter totals are not per-run measurements.
When OVDC also serves UJITSO traffic, aggregate cache activity alone does not
identify shader-cache traffic.

### Check 4: gxcache is disabled

```bash
set -euo pipefail
worker_yaml=$(kubectl get sts write-render-worker -n "${WRW_NAMESPACE:?Set WRW_NAMESPACE to the simulation namespace}" -o yaml)
# No match is an expected result; the kubectl read above must still succeed.
grep -i gxcache <<<"$worker_yaml" || [ "$?" -eq 1 ]
```

Should show `enabled: false` or nothing. If `enabled: true`, drivercachewrapper cannot intercept.

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Warm shader cook shows no improvement | Doubled paths in Kit CLI | Use single-level `--/drivercachewrapper/...` |
| Warm shader cook shows no improvement | gxcache enabled (chart default) | Set `gxcache.enabled: false` in Helm values |
| No write/put counter increase on a cold run | Shader datastore may not be configured | Check `gpu.foundation.plugin` and shader datastore creation in WRW logs |
| No read/get counter increase | WRW may not be pointing at OVDC | Check args for `enableByProtocol=grpcdns://...` |
| OVDC gets traffic but warm still slow | UJITSO traffic only, not shaders | Verify `drivercachewrapper` args (not just `UJITSO`) |


OVDC metric names must be discovered from the deployed version. Compare get/put
and cache hit/miss counters once identified; do not assume renamed DDCS names.
Shader timing varies by scene and hardware; compare cold and warm runs on the
same workload rather than treating historical DDCS timings as an OVDC guarantee.
