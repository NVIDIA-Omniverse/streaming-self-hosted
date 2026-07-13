
# OVCC Client Integration

When OVCC is deployed as part of a MEGA simulation stack, additional configuration is required for OmniClient and storage-service compatibility. The OVCC 4.0.x runtime is byte-identical to UCC 3.0 (`usd-content-cache:3.0.1`), so these client requirements are unchanged from UCC.

## TLS Required for OmniClient < v2.68.1

**OVCC must be deployed with TLS enabled (`tls.enabled: true`) when any client uses OmniClient < v2.68.1.** This is not optional -- an `http://` OVCC endpoint will fail with `SSL connect error (35)`.

Two OmniClient behaviors make TLS mandatory on older versions:

1. **OMPE-71716 (CURLPROXY_HTTPS2):** OmniClient < v2.68.1 unconditionally sets `CURLPROXY_HTTPS2`, causing libcurl to attempt TLS on a plain HTTP proxy.
2. **Scheme stripping:** OmniClient <= v2.68.0 (including 2.67.0 and the reverted 2.68.0) strips the URL scheme before passing to libcurl. NGINX receives a schemeless URL and returns 400 because it can't determine the backend. With TLS, NGINX infers `https` from the connection protocol. OmniClient v2.68.1 (minimum Kit `109.0.1-249766`) fixes this.

**Minimum Kit version with the fix: `109.0.1-249766`** (OmniClient v2.68.1). Kit versions before this -- including 107.3.x, 108.x, 109.0.0, and early 109.0.1 builds -- all require TLS on OVCC. Note that `v2.68.0` does NOT have the fix (it was introduced, reverted, then re-instated as `v2.68.1`).

| Kit version | OmniClient | TLS required? |
|---|---|---|
| <= 107.3.x | 2.67.0 | **Yes** |
| 108.x | 2.67.0 | **Yes** |
| 109.0.0 | 2.67.0 | **Yes** |
| 109.0.1 builds < 249766 | 2.67.0 or 2.68.0 | **Yes** |
| **109.0.1-249766+** | **2.68.1** | Recommended |
| **110.0.0+** | **2.68.1+** | Recommended |

**Current SRTX 1.0.1** ships write-render-worker with Kit **107.3.4** (OmniClient 2.67.0). TLS is mandatory until SRTX ships a version based on Kit >= 109.0.1-249766.

Self-signed TLS cert procedure (requires `NAMESPACE` to be set; it scopes both `TLS_DIR` and the `ovcc-tls` secret):

```bash
: "${NAMESPACE:?Set NAMESPACE to the OVCC namespace before running}"
(
  umask 077
  TLS_DIR="$(mktemp -d "./${NAMESPACE}-tls-tmp.XXXXXX")"
  trap 'rm -rf "${TLS_DIR}"' EXIT
  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout "${TLS_DIR}/ovcc-tls.key" -out "${TLS_DIR}/ovcc-tls.crt" \
    -subj "/CN=ovcc"
  kubectl create secret tls ovcc-tls \
    --key "${TLS_DIR}/ovcc-tls.key" --cert "${TLS_DIR}/ovcc-tls.crt" \
    --namespace="$NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -
)
```

Set `tls.secretName: ovcc-tls` in Helm values. The default is to distribute the
generated CA/cert to clients and let them verify normally — install the cert
into the platform trust store (OS/browser/Java/Go) used by the client.

Skipping certificate verification is an opt-in fallback for non-production
bootstrap (e.g. quick MEGA sim runs against a self-signed cert that has not
yet been propagated). It removes MITM protection on the OVCC channel and must
not be the default for shared or production clusters; supply a properly
signed cert there instead.

## GCS proxyPass Override

For GCS backends, set `nginx.backends.gcs.proxyPass: "https://$host"` to ensure OVCC always uses HTTPS upstream, regardless of the incoming request scheme. Without this, OmniClient's scheme stripping can cause HTTP upstream connections to GCS, which fail.

## storage-service Environment Variables

storage-service must be configured to route through OVCC and skip self-signed
cert verification for the self-signed OVCC cert. Keep the required env vars in
the canonical simulation Helm values artifact described at the top of SKILL.md
(the storage-service env var table). The env var **names** (`UCC_PROXY`,
`UCC_PROXY_SSL_VERIFYCERT`, `UCC_PROXY_SSL_VERIFYHOST`) are part of the
storage-service contract and are unchanged; only the URL value points at the
`ovcc` service. If any value is missing, update that values artifact before
deploying OVCC.

## OmniClient Environment Variables

worldsim and write-render-worker must route presigned URL downloads
through OVCC. See `ovcc-overrides.yaml` for the tested values.
The overrides hardcode the `ovcc` namespace (`ovcc.ovcc.svc.cluster.local`);
if OVCC runs in a different namespace, edit the URLs in `ovcc-overrides.yaml`
to match (its header notes this).

## Cache Prewarming

For large simulation scenes (e.g., warehouse20x20: 47,614 files, ~47 GiB), prewarming the OVCC cache before the simulation starts eliminates cold-cache latency. Run a one-shot workload that opens the target scene with OVCC enabled, then poll the workload and OVCC metrics/logs until it exits successfully. Keep this outside the deploy script because scene paths and launch commands are workload-specific.

## Scene Reference Data

| Scene | Files | Total size | Notes |
|---|---|---|---|
| kion_warehouse | 1,659 | 3.1 GiB | Used for OVCC sizing benchmarks (this skill; carried forward from UCC 3.0) |
| warehouse20x20 | 47,614 | ~47 GiB | MEGA simulation scene (proven on GKE) |
