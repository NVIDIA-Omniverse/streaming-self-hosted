## Kubernetes Provider Guide

Use this guide for GXCache on any self-managed Kubernetes cluster. The chart,
image schema, webhook behavior, storage needs, and validation sequence are
Kubernetes-level concerns. Provider-specific work is limited to registry access,
storage class choice, node placement, identity, and optional webhook TLS/cert
integration.

## Downstream Dependencies

This source repo does not ship deployment scripts, generated env files, or
values files. Downstream repos provide those artifacts. If an artifact is
missing, create or port it in the downstream repo rather than hard-coding a provider
assumption in this shared skill.

| Reference | Owner | Notes |
|---|---|---|
| Runtime environment or shell exports | downstream | Exports cluster name, namespace, registry, storage class, values-file path, and provider-specific identity settings. |
| Registry/Helm authentication helper | downstream or CI | Authenticates through workload identity, SSO, provider-native identity, or a secret-manager-backed helper. Do not place local secret material directly in generated commands. |
| Rendered GXCache values file | downstream | Contains the chart values listed below. This file is cluster-specific, not a shared default. |
| Worker image-pull posture | downstream | Either worker namespaces can pull the injected `gxcache-init` image, or the values/webhook config rewrites the init image to a provider registry. |

## Canonical Pins

| Thing | Value |
|---|---|
| Docs | https://docs.nvidia.com/nvcf/v0.5/gx-cache |
| Namespace | `gxcache` |
| Helm chart | `oci://nvcr.io/0833294136851237/nvcf-ncp-staging/helm-gxcache` |
| Chart version | `0.8.2` |
| Service image | `nvcr.io/0833294136851237/nvcf-ncp-staging/gxcache-service:b206ce39` |
| Webhook image | `nvcr.io/0833294136851237/nvcf-ncp-staging/gxcache-webhook:59bd8ec5` |
| Init image | `nvcr.io/0833294136851237/nvcf-ncp-staging/gxcache-init:1e47f722` |
| Notary default | `http://notary.nvcf.svc.cluster.local:8080` |
| NVCA prerequisite | `CachingSupport` feature gate |

The `nvcf-ncp-staging` registry path is the current release/customer path. Do
not switch to `test-sandbox` unless intentionally validating unreleased bits.

## Values Contract

Render one provider-specific values file before install. Preserve the chart's
three image shapes exactly:

| Values path | Shape |
|---|---|
| `webhook.deployment.image` plus `webhook.deployment.version` | Separate repo and tag. The chart reads `.version` here. |
| `webhook.client.version.image` plus `webhook.client.version.tag` | Separate repo and tag. Use `tag`, not only `version`. |
| `service.deployment.image` | Full image reference including tag, for example `.../gxcache-service:b206ce39`. |

Other required values:

- `service.persistence.storageClass` matches a real StorageClass in the target
  cluster when persistence is enabled.
- `webhook.nodeSelector` and `service.nodeSelector` match provider-owned node
  labels that survive node replacement.
- `imagePullSecrets` or workload identity lets both GXCache namespace pods and
  webhook-injected worker pods pull the selected images.
- Webhook TLS posture is explicit. Validation can disable TLS only with an
  acknowledged downstream choice; production should use real certs when
  supported.
- `service.kns.keyset.endpoint` points at reachable NVCF notary.

## Install

Run this after the NVCF control plane, NVCA, notary, and storage class exist.

```bash
set -euo pipefail
: "${GXCACHE_VALUES_FILE:?set GXCACHE_VALUES_FILE to the rendered helm-gxcache values file}"
GXCACHE_CHART_REF="${GXCACHE_CHART_REF:-oci://nvcr.io/0833294136851237/nvcf-ncp-staging/helm-gxcache}"

kubectl get namespace nvcf >/dev/null || {
  echo "ERROR: namespace nvcf is missing; install the NVCF control plane before GXCache." >&2
  exit 1
}

kubectl create namespace gxcache --dry-run=client -o yaml | kubectl apply -f -

# Authenticate Helm to the chart registry through downstream helper or ambient
# registry identity before this command. Do not print registry secrets.
if [[ "$GXCACHE_CHART_REF" == oci://nvcr.io/* ]]; then
  if command -v ngc_helm_login >/dev/null 2>&1; then
    ngc_helm_login
  elif [[ -f ./scripts/helm-ngc-login.sh ]]; then
    source ./scripts/helm-ngc-login.sh
    ngc_helm_login
  else
    echo "ERROR: no ngc_helm_login helper found (function or ./scripts/helm-ngc-login.sh)." >&2
    exit 1
  fi
else
  echo "INFO: using non-NVCR chart registry; ensure downstream registry auth is already configured." >&2
fi
helm upgrade --install gxcache \
  "$GXCACHE_CHART_REF" \
  --version 0.8.2 \
  --namespace gxcache \
  -f "$GXCACHE_VALUES_FILE" \
  --wait --timeout 10m

kubectl rollout status statefulset/gxcache -n gxcache --timeout=300s
kubectl rollout status deployment/gxcache-webhook -n gxcache --timeout=300s
kubectl get pods,pvc,svc -n gxcache
```

## Render Checks

Run this before every tag or registry change. The snippet below performs NVCR
auth itself when `GXCACHE_CHART_REF` points to `oci://nvcr.io/...` (matching
Install); for any other registry, ensure this shell session is already
authenticated before rendering. For mirrored provider registries, set
`GXCACHE_CHART_REF` to the same chart URL used for install.

```bash
set -euo pipefail
: "${GXCACHE_VALUES_FILE:?}"
GXCACHE_CHART_REF="${GXCACHE_CHART_REF:-oci://nvcr.io/0833294136851237/nvcf-ncp-staging/helm-gxcache}"

# Authenticate Helm to the chart registry before rendering, matching Install.
# Do not print registry secrets.
if [[ "$GXCACHE_CHART_REF" == oci://nvcr.io/* ]]; then
  if command -v ngc_helm_login >/dev/null 2>&1; then
    ngc_helm_login
  elif [[ -f ./scripts/helm-ngc-login.sh ]]; then
    source ./scripts/helm-ngc-login.sh
    ngc_helm_login
  else
    echo "ERROR: no ngc_helm_login helper found (function or ./scripts/helm-ngc-login.sh)." >&2
    exit 1
  fi
else
  echo "INFO: using non-NVCR chart registry; ensure downstream registry auth is already configured." >&2
fi

rendered_manifest="$(helm template gxcache \
  "$GXCACHE_CHART_REF" \
  --version 0.8.2 \
  --namespace gxcache \
  -f "$GXCACHE_VALUES_FILE")"
rendered_images="$(printf '%s\n' "$rendered_manifest" | grep -E 'image: .*gxcache-(service|webhook|init)' || true)"
printf '%s\n' "$rendered_images"

if [[ -z "${rendered_images//[[:space:]]/}" ]]; then
  echo "ERROR: no GXCache image references were rendered; check chart access and values file." >&2
  exit 1
fi

if printf '%s\n' "$rendered_images" | grep -E "image:[[:space:]]+(\"[^\"[:space:]]+:\"|'[^'[:space:]]+:'|[^[:space:]'\"]+:)[[:space:]]*$" >/dev/null; then
  echo "ERROR: rendered GXCache image has an empty tag." >&2
  exit 1
fi
if printf '%s\n' "$rendered_images" | grep -E ":latest($|[[:space:]'\"])" >/dev/null; then
  echo "ERROR: rendered GXCache image uses :latest." >&2
  exit 1
fi
if printf '%s\n' "$rendered_images" | grep -Ev "^[[:space:]]*image:[[:space:]]+(\"[^\"[:space:]]+:[A-Za-z0-9._-]+\"|'[^'[:space:]]+:[A-Za-z0-9._-]+'|[^'\"[:space:]]+:[A-Za-z0-9._-]+)[[:space:]]*$" >/dev/null; then
  echo "ERROR: rendered GXCache image is missing an explicit tag." >&2
  exit 1
fi
```

## Provider Notes

- Use a StorageClass that exists in the target cluster and supports the chart's
  persistence mode.
- Mirror the Helm chart and images to a provider registry when direct NGC pulls
  are not allowed. Set `GXCACHE_CHART_REF` to the mirrored chart URL for both
  install and render checks.
- If worker pods pull `gxcache-init` directly from NGC, the worker namespace
  needs a pull secret or dedicated workload identity. Prefer mirroring so the
  worker namespace does not need NGC credentials.
- If the chart writes the injected init image into `gxc-webhook-config` using a
  source registry path, patch only the registry/repository prefix to the
  provider mirror and preserve the tag already rendered by the chart. After any
  ConfigMap rewrite, restart `deployment/gxcache-webhook` so the webhook loads
  the updated image reference.
- Some validation values disable webhook client TLS. Require an explicit
  downstream acknowledgement for that posture and replace it with real TLS
  before production.
- Put required node labels on provider-owned node-pool configuration, not by
  one-off `kubectl label nodes`, so labels survive node replacement.
- Use provider-managed identity or a downstream helper for any pull secret; do
  not paste provider credentials or Docker config JSON into the skill transcript.

## Verify

```bash
set -euo pipefail
kubectl rollout status statefulset/gxcache -n gxcache --timeout=300s
kubectl rollout status deployment/gxcache-webhook -n gxcache --timeout=300s
kubectl get pods,pvc,svc -n gxcache
kubectl get mutatingwebhookconfiguration | grep gxcache

helm get values gxcache -n gxcache --all -o json \
  | jq '.webhook.deployment, .webhook.client.version, .service.deployment.image'

kubectl get pods -n gxcache \
  -o jsonpath='{range .items[*].spec.containers[*]}{.image}{"\n"}{end}' \
  | grep gxcache

# After launching a test worker pod, verify webhook mutation and image pull.
: "${WORKER_NAMESPACE:?set WORKER_NAMESPACE to the test worker pod namespace}"
: "${WORKER_POD:?set WORKER_POD to a mutated test worker pod name}"
kubectl wait --for=condition=Ready "pod/$WORKER_POD" \
  -n "$WORKER_NAMESPACE" --timeout=300s
worker_init_images="$(kubectl get pod "$WORKER_POD" -n "$WORKER_NAMESPACE" \
  -o jsonpath='{range .spec.initContainers[?(@.name=="gxcache-init")]}{.image}{"\n"}{end}')"
printf '%s\n' "$worker_init_images" | grep -E 'gxcache-init:[A-Za-z0-9._-]+$'
if printf '%s\n' "$worker_init_images" | grep -E ':latest($|[[:space:]])' >/dev/null; then
  echo "ERROR: worker pod uses the latest gxcache-init tag." >&2
  exit 1
fi
```

Expected:

- `statefulset/gxcache` and `deployment/gxcache-webhook` are Ready.
- GXCache images all include explicit non-`latest` tags.
- A GXCache mutating webhook exists.
- NVCA has `CachingSupport` enabled before end-to-end worker validation.
- `kubectl wait` succeeds for the test worker pod, and its `gxcache-init`
  initContainer image includes an explicit non-`latest` tag.

## Troubleshooting

| Symptom | Checks | Fix |
|---|---|---|
| Pod Pending | Node labels, taints, storage class, PVC binding, allocatable CPU/memory. | Fix provider node-pool/storage posture before reinstalling. |
| ImagePullBackOff | Rendered image references, registry mirror, kubelet identity, pull secret name. | Fix registry identity or mirror; do not print or decode secrets. |
| Webhook not Ready | Webhook pod logs, TLS values, namespace selector, `gxc-webhook-config`. | Repair certificates/config or provider image rewrite; do not disable mutation for production. |
| Worker pods not mutated | MutatingWebhookConfiguration, namespace labels, NVCA feature gates. | Fix webhook selectors or enable `CachingSupport`; do not reinstall GXCache first. |
| Cache calls fail while pods are Ready | Notary endpoint, network policy, worker annotation/mutation, real Kit/RTX workload. | Repair notary/NVCA or provider network policy. |

## Cleanup

```bash
set -euo pipefail
if helm status gxcache -n gxcache >/dev/null 2>&1; then
  helm uninstall gxcache -n gxcache
fi
kubectl delete mutatingwebhookconfiguration -l app.kubernetes.io/instance=gxcache --ignore-not-found
if [[ "${DELETE_GXCACHE_DATA:-false}" == "true" ]]; then
  kubectl delete namespace gxcache --ignore-not-found
else
  echo "INFO: keeping gxcache namespace and PVCs; set DELETE_GXCACHE_DATA=true to remove them." >&2
fi
```

Namespace/PVC deletion is opt-in because it can remove cache data. Registry
mirrors, node labels, provider IAM, and any worker namespace pull secrets are
downstream-owned resources. Remove them only through the provider repo or
cluster lifecycle that created them.
