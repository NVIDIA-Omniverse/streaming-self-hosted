---
name: nvcf-gxcache
description: Use for installing, debugging, or modifying NVCF GXCache across self-managed Kubernetes environments. Trigger on explicit GXCache, helm-gxcache, gxcache-init, gxcache-webhook, distributed shader cache, NVCA cache feature gates, or GXCache provider adaptation for Kubernetes clusters.
version: "1.0.0"
author: nvcf-auxiliary-services
tags: [nvcf, gxcache, helm, kubernetes, shader-cache]
tools: [Shell, Read, Write]
---

<!-- SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved. -->
<!-- SPDX-License-Identifier: CC-BY-4.0 AND Apache-2.0 -->

# NVCF GXCache

Run commands from the repo root; artifact paths below are repo-root relative.

Before any command touches registry credentials, use a downstream auth helper, workload identity, or secret-manager-backed login. Never echo an NGC key, paste it into an environment variable, decode Kubernetes Secret data, or run `kubectl get secret -o yaml`.

## When to Use

- Use this skill for GXCache install, verification, provider adaptation, and cache-related failures.
- Use the upstream `nvcf-self-managed-installation` NVCA section before end-to-end function tests, because GXCache admission depends on NVCA cache feature gates.
- Use a provider-specific registry skill only if the deployment posture changes from direct NGC pulls to a mirrored provider registry.

## Purpose

GXCache is the distributed shader cache for NVIDIA RTX and Kit workloads. It caches precompiled shaders so repeated function cold starts avoid full shader compilation.

The chart installs three moving pieces in the `gxcache` namespace:

| Component | Role |
|---|---|
| `gxcache` service pod | Cache server and persistent data path. With the currently validated chart it renders as a StatefulSet. |
| `gxcache-init` | Init image injected into matching worker pods so they can use the cache. |
| `gxcache-webhook` | Mutating webhook that injects the GXCache client/init container into eligible pods. |

## TL;DR

1. Confirm the NVCF control plane, NVCA, and `CachingSupport` feature gate are installed before end-to-end worker validation.
2. Open `providers/kubernetes.md`; use the Kubernetes workflow first, then apply only the provider notes needed for the target cluster.
3. Render provider-specific values for storage class, node selectors/tolerations, image pull posture, webhook TLS posture, resources, and notary endpoint.
4. Preserve the chart's image schema: `webhook.deployment` uses separate `image` plus `version`, `webhook.client.version` uses separate `image` plus `tag`, and `service.deployment.image` must include the tag in the image string.
5. Ensure `webhook.client.version.tag` is present. Writing only `webhook.client.version.version` can render an empty injected init tag and produce `InvalidImageName`.
6. Ensure GXCache pods and injected worker pods can pull their images, either from NGC with safe pull secrets or from a provider registry mirror.
7. Verify webhook registration, service readiness, worker pod mutation, and cache feature gates before declaring end-to-end readiness.

## Instructions

1. Confirm prerequisites: NVCF control plane, NVCA, notary, and `CachingSupport`.
2. Use `providers/kubernetes.md` for the target cluster and choose the values/storage/registry pattern that matches the provider.
3. Render values without changing the chart image schema: `webhook.deployment.version`, `webhook.client.version.tag`, and full-tag `service.deployment.image`.
4. Install `helm-gxcache` v`0.8.2` with safe registry authentication.
5. Verify `StatefulSet/gxcache`, `Deployment/gxcache-webhook`, the mutating webhook, rendered image tags, and a mutated worker pod.

## Error Handling

Classify the symptom before reinstalling the chart:

| Symptom | First checks | Action |
|---|---|---|
| `gxcache` pod is Pending or rollout times out | `kubectl describe pod -n gxcache -l app.kubernetes.io/name=gxcache`; inspect node labels, storage class, PVC binding, taints, CPU, and memory. | Fix provider node pool or storage class first; lower resources only for an explicit test environment after confirming capacity. |
| `gxcache-webhook` is not Ready or worker pods are not mutated | `kubectl get mutatingwebhookconfiguration` filtered for `gxcache`; `kubectl logs -n gxcache deploy/gxcache-webhook`; inspect webhook TLS and namespace selector settings in the provider path. | Repair webhook certificates, selector scope, or provider TLS posture; do not bypass mutation except for isolated service-pod validation. |
| Worker pods show `ImagePullBackOff` for `gxcache-init` | `kubectl describe pod -n nvcf-backend <worker-pod>` and verify rendered image references plus pull secret names without decoding Kubernetes Secret data. | Fix registry mirror, pull identity, or provider-specific secret delivery. Never print, decode, or paste credentials while debugging. |
| Rendered images are untagged or still point at the wrong registry | `helm template ...`, then grep for `gxcache`, `nvcr.io`, or `image:`; confirm `webhook.deployment.version`, `webhook.client.version.tag`, and full-tag `service.deployment.image`. | Restore the chart image schema exactly as documented; do not normalize the three subchart image shapes. |
| Cache usage fails while pods are Ready | Verify NVCA `CachingSupport`, notary endpoint reachability, worker pod annotation/mutation, and a real Kit/RTX workload. | Repair NVCA feature gates or notary before reinstalling GXCache; use `providers/kubernetes.md` troubleshooting/provider notes for storage and networking checks. |

## Example

Representative downstream install using a provider-rendered values file:

```bash
set -euo pipefail
: "${GXCACHE_VALUES_FILE:?set GXCACHE_VALUES_FILE to the rendered helm-gxcache values file}"
GXCACHE_CHART_REF="${GXCACHE_CHART_REF:-oci://nvcr.io/0833294136851237/nvcf-ncp-staging/helm-gxcache}"
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

kubectl create namespace gxcache --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install gxcache \
  "$GXCACHE_CHART_REF" \
  --version 0.8.2 \
  --namespace gxcache \
  -f "$GXCACHE_VALUES_FILE" \
  --wait --timeout 10m
kubectl rollout status statefulset/gxcache -n gxcache --timeout=300s
kubectl rollout status deployment/gxcache-webhook -n gxcache --timeout=300s
```

## Provider Adaptation

Keep this distinction explicit:

- Provider-neutral: GXCache chart version, image schema, NVCA `CachingSupport`, notary dependency, pull-secret safety, webhook mutation, and worker opt-in validation.
- Provider-specific: storage class, node labels/selectors, registry mirror, secret delivery mechanism, webhook TLS/certificate posture, network policy, metrics stack, and default resource sizing.

Do not copy storage-class names, node-pool labels, registry identities, workload-identity settings, or validation TLS assumptions across providers. Recreate the provider equivalent and render a cluster-specific values file before installing.

## Provider Paths

Use the generic workflow above for provider-neutral planning, then open the Kubernetes provider path for concrete commands, values contracts, and provider adaptation notes. Kubernetes providers share the same chart workflow; only registry, storage class, identity, webhook TLS, and worker image-pull details differ.

| Provider | Path | Status |
|---|---|---|
| Kubernetes | `providers/kubernetes.md` | Provider-neutral Helm install and verification flow with Kubernetes adaptation notes. |

The provider file may reference downstream-owned manifests, scripts, generated env files, and provider resources. Do not apply assumptions from one provider to another without adapting those dependencies.

The provider file documents the expected values shape, but concrete values files are downstream-owned artifacts. Do not treat any provider values file as a provider-neutral default.
