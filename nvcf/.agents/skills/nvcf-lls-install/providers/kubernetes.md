## Kubernetes Provider Guide

Use this guide for LLS on any self-managed Kubernetes cluster. The chart,
namespace, ports, health checks, and validation sequence are Kubernetes-level
concerns. Provider-specific work is limited to registry access, public UDP
ingress, optional public TCP TURN ingress, node placement, and identity.

## Downstream Dependencies

This source repo does not ship deployment scripts, generated env files, or
values files. Downstream repos provide those artifacts. If an artifact is
missing, create or port it in the downstream repo rather than hard-coding a provider
assumption in this shared skill.

| Reference | Owner | Notes |
|---|---|---|
| Runtime environment or shell exports | downstream | Exports cluster name, namespace, registry, values-file path, public endpoint, and provider-specific network settings. |
| Registry/Helm authentication helper | downstream or CI | Authenticates through workload identity, SSO, provider-native identity, or a secret-manager-backed helper. Do not place local secret material directly in generated commands. |
| Rendered LLS values file | downstream | Contains the chart values listed below. This file is cluster-specific, not a shared default. |
| UDP/TCP ingress manifest or provider LoadBalancer resource | downstream | Exposes public UDP 5004 and, when TCP TURN is enabled, public TCP 3478. Routes to the chart's `streaming-proxy` and `turn-service` endpoints. |

## Canonical Pins

| Thing | Value |
|---|---|
| Docs | https://docs.nvidia.com/nvcf/v0.5/lls-installation |
| Namespace | `gdn-streaming` |
| Helm chart | `oci://nvcr.io/0795883928596950/gdn-streaming` |
| Chart version | `3.0.0` |
| Source image | `nvcr.io/0795883928596950/streaming-proxy:3.0.2-rc.1` |
| Optional TURN image | `nvcr.io/0795883928596950/turn:3.0.1` |
| Public media port | UDP `5004` |
| Optional public TURN port | TCP `3478` |
| Optional TURN pod/TLS port | TCP `5349` |
| Optional TURN health port | TCP `8080`, path `/v1/turn/health` |
| Health/metrics port | TCP `8000` |
| Backend dependency | `nvcf-backend` namespace and `nvcf-sbs` service |

The `0795883928596950` registry path is the current LLS source path for the
chart, `streaming-proxy`, and `turn` image. Downstreams may mirror those
artifacts to a provider registry, but should keep the same chart and image
versions unless intentionally validating a reviewed override.

## Values Contract

Render one provider-specific values file before install. The values must set:

| Values path | Required meaning |
|---|---|
| `image.repository` | Registry/repository for `streaming-proxy` after optional mirroring. |
| `image.tag` | `3.0.2-rc.1`. |
| `image.pullPolicy` | Usually `IfNotPresent` for immutable mirrors, `Always` while validating mutable tags. |
| `env.lbDns` | Public hostname or IP advertised to WebRTC clients. Prefer DNS when clients reject IP literals. |
| `env.lbPort` | `5004`. |
| `nodeSelector` / affinity | Provider-owned placement for the streaming node pool. |
| `replicaCount` | Start with `1`; plan capacity before raising it. |
| resources | Validated sizing is 5 CPU / 24 GiB per proxy pod. |

Optional values:

- `image.pullSecrets` only when kubelet identity cannot pull the chosen image.
- `availabilityZones.*` only when the provider values require explicit zone
  placement. Do not leave an enabled zone-affinity block with empty zones.
- `gnatUdp.env.lbPort=5004` when the chart values split UDP settings under
  `gnatUdp`.
- `tcpTurn.enabled=true` only when the downstream exposes TCP TURN.
- `tcpTurn.tlsEnabled=false` unless real TURN certificate material is available.
- `tcpTurn.port=3478`, `tcpTurn.tlsPort=5349`, and
  `tcpTurn.serverDomain=<public TURN host>`.
- `tcpTurn.image.repository` and `tcpTurn.image.tag=3.0.1` for the mirrored or
  directly pulled `turn` image.

The install and verification snippets below infer TCP TURN from
`tcpTurn.enabled` in `LLS_VALUES_FILE`. Set `LLS_TCP_TURN_ENABLED=true` only when
the values file is unavailable but the live release is known to have TURN
enabled.

## Install

Run this after the NVCF control plane exists. A namespace-only fallback is fine
for render validation, but media validation requires a real NVCF backend and a
streaming function.

```bash
set -euo pipefail
: "${LLS_VALUES_FILE:?set LLS_VALUES_FILE to the rendered gdn-streaming values file}"
LLS_RELEASE_NAME="${LLS_RELEASE_NAME:-gdn-streaming}"
LLS_CHART_REF="${LLS_CHART_REF:-oci://nvcr.io/0795883928596950/gdn-streaming}"
# Keep this helper in sync with the Verify snippet below; both snippets are
# standalone so users can copy either block.
lls_tcp_turn_enabled() {
  [[ "${LLS_TCP_TURN_ENABLED:-}" == "true" ]] && return 0
  [[ -n "${LLS_VALUES_FILE:-}" && -f "$LLS_VALUES_FILE" ]] || return 1
  awk '
    /^[^[:space:]#][^:#]*:/ { in_tcp = ($1 == "tcpTurn:"); depth = 0 }
    in_tcp && /^[[:space:]]/ {
      n = 0; s = $0; while (substr(s,1,1)==" ") { n++; s=substr(s,2) }
      if (!depth) depth = n
      if (n == depth && /enabled:[[:space:]]*true([[:space:]#]|$)/) found = 1
    }
    END { exit found ? 0 : 1 }
  ' "$LLS_VALUES_FILE"
}

kubectl get namespace nvcf-backend >/dev/null || {
  echo "ERROR: namespace nvcf-backend is missing; install the NVCF control plane before LLS." >&2
  exit 1
}

kubectl create namespace gdn-streaming --dry-run=client -o yaml | kubectl apply -f -

# Authenticate Helm to the chart registry through downstream helper or ambient
# registry identity before this command. Do not print registry secrets.
if [[ "$LLS_CHART_REF" == oci://nvcr.io/* ]]; then
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
helm upgrade --install "$LLS_RELEASE_NAME" \
  "$LLS_CHART_REF" \
  --version 3.0.0 \
  --namespace gdn-streaming \
  -f "$LLS_VALUES_FILE" \
  --wait --timeout 10m

kubectl rollout status deployment/streaming-proxy -n gdn-streaming --timeout=300s
if lls_tcp_turn_enabled; then
  kubectl rollout status deployment/turn-service -n gdn-streaming --timeout=300s
fi
kubectl get pods,svc,endpoints,endpointslices -n gdn-streaming
```

## Public UDP/TCP Ingress

LLS is not complete until public UDP 5004 reaches the streaming-proxy backend.
Use the provider's native Kubernetes `Service.type=LoadBalancer`, Gateway/API
implementation, or an external provider LoadBalancer that targets the chart's
NodePort/Pod endpoints.

Minimum UDP media contract:

- Public listener is UDP `5004`.
- Backend target reaches the chart's streaming-proxy media endpoint.
- Health check uses a TCP/HTTP health endpoint such as TCP `8000` when the
  provider cannot health-check UDP directly.
- Firewall/security policy allows only the intended client CIDRs when possible.
- `env.lbDns` and `env.lbPort` in the Helm values match the public listener.

Optional TCP TURN contract, only when `tcpTurn.enabled=true`:

- Public listener is TCP `3478`.
- Backend target reaches the chart's `turn-service` endpoint or pod port
  selected by the rendered values, commonly TCP `5349`.
- Health check uses `/v1/turn/health` on TCP `8080` when the provider supports
  HTTP health probes.
- Firewall/security policy allows the intended client CIDRs.
- `tcpTurn.serverDomain`, `tcpTurn.port`, and `tcpTurn.tlsPort` match the
  public TURN endpoint and rendered values.

## Provider Notes

- Mirror the Helm chart plus `streaming-proxy` and optional `turn` images to a
  provider registry when direct NVCR pulls are not allowed. Set `LLS_CHART_REF`
  to the mirrored chart URL before install.
- Public UDP 5004 can be exposed by a Kubernetes LoadBalancer Service, Gateway
  implementation, or externally managed load balancer that targets the chart's
  Service, NodePort, or Pod endpoints.
- Public TCP 3478 for TURN is a separate downstream-owned ingress path. Do not
  enable it unless the rendered values set `tcpTurn.enabled=true`.
- Keep firewall and security rules narrow. Open only the public media listener
  and health-check path required by the selected provider.
- If the provider cannot health-check UDP directly, use a TCP/HTTP health
  endpoint such as TCP `8000` and the traffic policy required by that provider.
- Some downstreams install the Helm release as `streaming-proxy` instead of
  `gdn-streaming`; set `LLS_RELEASE_NAME=streaming-proxy` while keeping the
  namespace `gdn-streaming`.
- Use provider-managed node-pool labels for streaming placement so labels
  survive node rotation.
- Use provider-managed identity or a downstream helper for registry pulls; do
  not paste provider credentials or Docker config JSON into the skill transcript.
- Any provider-specific wrapper image must be revalidated against the current
  `streaming-proxy` tag before use.

## Verify

```bash
set -euo pipefail
# Keep this helper in sync with the Install snippet above; both snippets are
# standalone so users can copy either block.
lls_tcp_turn_enabled() {
  [[ "${LLS_TCP_TURN_ENABLED:-}" == "true" ]] && return 0
  [[ -n "${LLS_VALUES_FILE:-}" && -f "$LLS_VALUES_FILE" ]] || return 1
  awk '
    /^[^[:space:]#][^:#]*:/ { in_tcp = ($1 == "tcpTurn:"); depth = 0 }
    in_tcp && /^[[:space:]]/ {
      n = 0; s = $0; while (substr(s,1,1)==" ") { n++; s=substr(s,2) }
      if (!depth) depth = n
      if (n == depth && /enabled:[[:space:]]*true([[:space:]#]|$)/) found = 1
    }
    END { exit found ? 0 : 1 }
  ' "$LLS_VALUES_FILE"
}
kubectl rollout status deployment/streaming-proxy -n gdn-streaming --timeout=300s
kubectl get pods -n gdn-streaming -l app=streaming-proxy -o wide
if lls_tcp_turn_enabled; then
  kubectl rollout status deployment/turn-service -n gdn-streaming --timeout=300s
  kubectl get pods -n gdn-streaming -l app=turn-service -o wide
fi
kubectl get svc -n gdn-streaming
kubectl get svc nvcf-sbs -n nvcf-backend

LLS_HOST="${LLS_HOST:-}"
if [[ -n "$LLS_HOST" ]]; then
  nc -zvu -w 3 "$LLS_HOST" 5004 || {
    echo "WARN: UDP probe did not complete; validate with a real WebRTC client before declaring failure." >&2
  }
fi

LLS_TURN_HOST="${LLS_TURN_HOST:-}"
LLS_TURN_PORT="${LLS_TURN_PORT:-3478}"
if lls_tcp_turn_enabled && [[ -n "$LLS_TURN_HOST" ]]; then
  nc -zv -w 3 "$LLS_TURN_HOST" "$LLS_TURN_PORT" || {
    echo "WARN: TCP TURN probe failed; inspect provider ingress and validate with a real WebRTC client." >&2
  }
fi
```

Expected:

- `streaming-proxy` Deployment is Ready.
- When enabled, `turn-service` Deployment is Ready.
- `nvcf-sbs` resolves in `nvcf-backend`.
- Public UDP 5004 reaches the selected LoadBalancer path.
- When enabled, public TCP 3478 reaches the selected TURN LoadBalancer path.
- A real WebRTC client can establish signaling and media with a streaming
  function.

## Troubleshooting

| Symptom | Checks | Fix |
|---|---|---|
| Pod Pending | `kubectl describe pod`, node labels, taints, allocatable CPU/memory. | Fix node-pool placement or capacity; lower resources only for explicit validation. |
| ImagePullBackOff | Rendered image repository/tag, registry mirror, kubelet identity, pull secret name. | Fix registry identity or mirror; do not print or decode secrets. |
| No public endpoint | Service events, frontend IP/DNS, target registration, firewall/security policy. | Repair provider LoadBalancer and rerun only ingress steps. |
| TURN endpoint unhealthy | `turn-service` rollout, TCP 3478 listener, backend target, `/v1/turn/health`, and rendered `tcpTurn.*` values. | Fix downstream TCP ingress or values; keep provider-specific load-balancer logic downstream. |
| ICE/media failure after signaling | `env.lbDns`, UDP 5004 reachability, optional TCP 3478 reachability, health check status, endpoint/node placement. | Fix public UDP/TCP route, firewall, or advertised endpoint. |
| SBS connection errors | `kubectl get svc nvcf-sbs -n nvcf-backend`, backend namespace health. | Repair the NVCF control plane/NVCA before reinstalling LLS. |

## Cleanup

```bash
set -euo pipefail
LLS_RELEASE_NAME="${LLS_RELEASE_NAME:-gdn-streaming}"
LLS_DELETE_NAMESPACE="${LLS_DELETE_NAMESPACE:-false}"
if helm status "$LLS_RELEASE_NAME" -n gdn-streaming >/dev/null 2>&1; then
  helm uninstall "$LLS_RELEASE_NAME" -n gdn-streaming
fi
if [[ "$LLS_DELETE_NAMESPACE" == "true" ]]; then
  kubectl delete namespace gdn-streaming --ignore-not-found
else
  echo "INFO: keeping gdn-streaming namespace; set LLS_DELETE_NAMESPACE=true to remove it." >&2
fi
```

Namespace deletion is opt-in because downstream repos may place provider-owned
secrets or ingress artifacts there. Provider LoadBalancers, frontend addresses,
registry mirrors, node labels, and role assignments are downstream-owned
resources. Remove them only through the provider repo or cluster lifecycle that
created them.
