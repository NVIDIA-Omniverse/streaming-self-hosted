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
| UDP/TCP ingress manifest or provider LoadBalancer resource | downstream | Exposes the topology-derived public UDP port and, when TURN is enabled, the selected TCP/TLS port. Routes to the chart's `streaming-proxy` and `turn-service` endpoints. |

## Canonical Pins

| Thing | Value |
|---|---|
| Docs | https://docs.nvidia.com/nvcf/self-managed/lls-installation |
| Namespace | `gdn-streaming` |
| Helm chart | `https://helm.ngc.nvidia.com/nvidia/omniverse/charts/gdn-streaming-3.0.0.tgz` |
| Chart version | `3.0.0` |
| Source image | `nvcr.io/nvidia/omniverse/streaming-proxy:4.0.2` |
| Optional TURN image | `nvcr.io/nvidia/omniverse/turn:4.0.2` |
| TLS certificate-hook image | `nvcr.io/nvidia/nvcf/nvcf-openbao:2.6.2-nv-1.3.4` |
| Internal media listener | UDP `5004` for the documented chart; confirm the rendered listener contract. |
| Advertised public media port | Resolve from the actual external listener or direct NodePort; no shared default. |
| Plain TCP TURN | TCP `3478`; Service NodePort `30885` |
| TLS TURN | TCP `5349`; Service NodePort `30886` |
| Optional TURN health port | TCP `8080`, path `/v1/turn/health` |
| Health/metrics port | Pod TCP `8000`; health NodePort `30800`, path `/v1/health` |
| Backend dependency | `nvcf-backend` namespace and `nvcf-sbs` service |

In chart 3.0.0, proxy NodePorts `30504` (media) and `30800` (health)
are configurable through `gnatUdp.nodePortService.ports`. TURN NodePorts
`30885` (TCP), `30886` (TLS), and `31334` (health) are fixed in the chart
templates. When routing through NodePorts, match load balancer target ports,
health-check ports, and node firewall rules to the corresponding rendered
Service NodePorts. The advertised port must match the client-facing endpoint.

The chart archive and the `streaming-proxy` and `turn` images above are public
NGC artifacts. Load `NGC_API_KEY` through the downstream auth helper for the
HTTPS chart download; keep shell tracing disabled. The snippets require `curl`
and pass credentials through stdin before giving Helm a temporary local archive.
An `nvcr.io` registry login
does not authenticate `helm.ngc.nvidia.com`. Set `LLS_CHART_REF` when using an
alternate chart location, such as an authenticated provider mirror.
Keep the chart and image versions pinned unless validating a reviewed override.

## Values Contract

Render one provider-specific values file before install. The values must set:

| Values path | Required meaning |
|---|---|
| `gnatUdp.image.repository` | Registry/repository for `streaming-proxy` after optional mirroring. |
| `gnatUdp.image.tag` | `4.0.2`. |
| `gnatUdp.image.pullPolicy` | Usually `IfNotPresent` for immutable mirrors, `Always` while validating mutable tags. |
| `lbDns` | Public hostname or IP advertised to WebRTC clients. Prefer DNS when clients reject IP literals. |
| `gnatUdp.env.lbPort` | Externally reachable UDP port, derived below. Do not assume a top-level `env.lbPort` override changes the rendered advertisement. |
| `nodeSelector` / `availabilityZones` | Provider-owned placement for the streaming node pool. |
| `gnatUdp.replicaCount` | Start with `1`; plan capacity before raising it. |
| `gnatUdp.resources` | Validated sizing is 5 CPU / 24 GiB per proxy pod. |

Optional values:

- Chart 3.0.0 has no `image.pullSecrets` values field. Use kubelet pull
  identity, or a downstream admission policy that sets Pod
  `imagePullSecrets` from an existing Secret in each Pod's namespace. Account
  for the proxy, TURN and certificate-hook Pods separately.
- Explicit `availabilityZones.enabled` and `availabilityZones.zones`; the chart
  defaults to `us-west-2a`. Disable zone affinity when it is not required, or
  supply the target cluster's actual zones. Do not enable it with empty zones.
- Helm merges `nodeSelector` maps. Override the chart's `node-type=compute`
  entry explicitly when selecting another pool; adding a label retains it.
- `gnatUdp.affinity` / `gnatUdp.tolerations` apply to the proxy only; chart 3.0.0
  does not expose equivalent TURN values. Ensure TURN can schedule with the
  shared `nodeSelector` and zone affinity before selecting tainted nodes.
- Set `tcpTurn.enabled` explicitly: the chart defaults to `true`; use `false`
  for UDP-only installations.
- Select `tcpTurn.tlsEnabled` explicitly; both modes require the OpenBao setup
  below. TLS requires a hostname-matching certificate trusted by the client.
- `tcpTurn.port=3478`, `tcpTurn.tlsPort=5349`, and
  `tcpTurn.serverDomain=<public TURN host>`.
- `tcpTurn.image.repository` and `tcpTurn.image.tag=4.0.2` for the mirrored or
  directly pulled `turn` image.

The install snippet resolves TURN from `tcpTurn.enabled` in `LLS_VALUES_FILE`,
including the chart's `true` default and any `LLS_SECRETS_FILE` overlay.
For verification, set `LLS_TCP_TURN_ENABLED=true` or `false` from the known
live release configuration. This explicit setting takes precedence over local
files. When it is unset, verification uses the values files; use that fallback
only when those files match the deployed release.

### TURN Mode and OpenBao Prerequisites

| Mode | Values | Pod/Service TCP port | NodePort | Advertised URI |
|---|---|---|---|---|
| Plain TCP | `tlsEnabled: false`, `port: 3478` | 3478 | 30885 | `turn:<serverDomain>:3478` |
| TLS | `tlsEnabled: true`, `tlsPort: 5349` | 5349 | 30886 | `turns:<serverDomain>:5349` |

Set `tcpTurn.serverDomain` in both modes. The chart advertises the selected
`port` or `tlsPort` as well as using it for the listener; it has no independent
TURN advertised-port override. If the public port differs from the table,
adapt the listener value and downstream Service/backend mapping together.
Both NodePorts render. Enabling TLS does not disable the plain TCP listener;
expose only the intended mode and verify the actual listening ports.
Health probes use pod TCP 8080 or NodePort 31334, path `/v1/turn/health`.

Use the NVCF control-plane LLS migrations and HMAC rotation configuration from
its selected release manifest. TURN requires the in-cluster OpenBao service,
vault injector, TURN HMAC data and `public-dns-certificate` secret; this
procedure does not cover split control-plane/compute clusters. Verify those
prerequisites before installing `gdn-streaming`.

For TLS, use the pinned OpenBao image (or its mirror) for the certificate hook:

```yaml
tcpTurn:
  enabled: true
  tlsEnabled: true
  port: 3478
  tlsPort: 5349
  serverDomain: turn.example.com  # Replace with the reachable certificate hostname.
  certSetup:
    image:
      repository: nvcr.io/nvidia/nvcf/nvcf-openbao
      tag: 2.6.2-nv-1.3.4
```

Set `tcpTurn.certSetup.certBase64` to the base64 PEM certificate chain and
private key in a protected, untracked `LLS_SECRETS_FILE`. Pass that file to both
render and install commands below. The hook needs `/bin/sh` and `bao`;
`turn:4.0.2` has no shell and cannot be reused as the hook image. It runs in
`vault-system` using service account `openbao-server-initialize-cluster` and
Secret `openbao-server-root-token`. The current hook logs the stored bundle;
restrict those logs and never copy them into review evidence or transcripts.

A private CA is usable for isolated TLS testing when the client explicitly
trusts it and the certificate matches `tcpTurn.serverDomain`. Read
[Isolated validation](../references/isolated-validation.md) before testing a
second release on a shared cluster: a different release namespace does not
isolate the certificate hook's OpenBao writes.

For plain TCP, the TLS hook does not run. TURN 4.0.2 still parses the certificate
bundle at startup. If it is missing or contains an invalid placeholder, seed a
valid PEM certificate/private-key bundle for `tcpTurn.serverDomain` at
`services/turn/kv/keys/public-dns-certificate` using an authenticated
[OpenBao CLI session](https://openbao.org/docs/commands/kv/put/) and a protected
file input (`cert=@<base64-bundle-file>`). An inactive self-signed bundle is
sufficient for plain TCP; it is not a substitute for client trust during TLS.
Do not overwrite a shared TURN certificate while another deployment uses it.

For UDP-only, set `tcpTurn.enabled: false` and skip TURN, its certificate and
its ingress resources.

## Resolve the Advertised Media Endpoint

Determine the path clients actually use before rendering values:

| Exposure | Advertised host and UDP port |
|---|---|
| Direct NodePort | Reachable node address and the selected UDP Service port entry's `nodePort`. |
| LoadBalancer/NLB | Public frontend address and external UDP listener port, even when its backend uses a different NodePort. |
| NAT/port forwarding | Public address and external mapped UDP port; verify the mapping to the Service/pod backend. |

Inspect the downstream ingress definition and, when deployed, the selected
Service and provider frontend. Select the media entry by name/protocol/target;
do not assume it is the first Service port. If the external endpoint is not
known, stop endpoint configuration and resolve it instead of defaulting to the
internal listener or a familiar NodePort. Export `LLS_HOST` and
`LLS_MEDIA_PORT` from that resolved endpoint for verification. `LLS_HOST` must
be the intended public hostname or IP exactly as it should be advertised. Do
not substitute a DNS-resolved IP for a configured hostname: these checks compare
host strings exactly. Derive the expected host from the intended ingress
configuration, rather than copying a potentially incorrect live `LB_DNS`.

Service `port`, `targetPort`, `nodePort`, and the external listener are distinct.
For example, with a Service NodePort of 31742 forwarding to pod UDP 5004:

| Deployment example | Advertised media port |
|---|---|
| Clients connect directly to the node | 31742 |
| An NLB exposes UDP 5004 and forwards to that NodePort | 5004 |
| A NAT rule exposes UDP 15432 and forwards to that NodePort | 15432 |

Known pitfall: the documented chart's media Service exposes NodePort `30504`
(`chart_node_port` in `versions.yaml`) while the internal listener is `5004`.
With direct NodePort access, advertising `5004` makes the browser send media to
a port nothing listens on; advertise the rendered Service `nodePort` instead.
Confirm the value on the rendered or live Service rather than assuming it.

For the direct NodePort example, merge this fragment into the downstream LLS
values file when the selected chart uses `gnatUdp`:

```yaml
# Example only: replace with the actual externally reachable UDP port.
gnatUdp:
  env:
    lbPort: "31742"
```

Keep the internal listener and Service `targetPort` at the chart's required
values. The example numbers are not shared deployment defaults.

Before installing, render the chart with the chosen values and check the
proxy's `LB_DNS`, `LB_PORT`, and `NVCF_LLS_LOAD_BALANCER_PORT` against the resolved
public endpoint. Both port variables must advertise the external media port;
do not assume a top-level `env.lbPort` override changes them, and check that
`LB_DNS` also renders the resolved host. If a value uses `valueFrom`, inspect
its specific configuration source without dumping secrets. The Verify snippet
repeats the check against the live proxy after rollout. Save any correction in
the downstream values file so the next deployment retains it.

```bash
set -euo pipefail
: "${LLS_VALUES_FILE:?set LLS_VALUES_FILE to the rendered gdn-streaming values file}"
LLS_VALUES_ARGS=(-f "$LLS_VALUES_FILE")
# Include the protected certificate values on TLS install/upgrade and render.
if [[ -n "${LLS_SECRETS_FILE:-}" ]]; then
  [[ -f "$LLS_SECRETS_FILE" ]] || { echo "ERROR: LLS_SECRETS_FILE is missing" >&2; exit 1; }
  LLS_VALUES_ARGS+=(-f "$LLS_SECRETS_FILE")
fi
: "${LLS_HOST:?set LLS_HOST to the intended advertised hostname or IP exactly as configured}"
: "${LLS_MEDIA_PORT:?set LLS_MEDIA_PORT to the resolved external UDP port}"
LLS_RELEASE_NAME="${LLS_RELEASE_NAME:-gdn-streaming}"
LLS_CHART_REF="${LLS_CHART_REF:-https://helm.ngc.nvidia.com/nvidia/omniverse/charts/gdn-streaming-3.0.0.tgz}"
if [[ "$LLS_CHART_REF" == https://helm.ngc.nvidia.com/* ]]; then
  set +x
  : "${NGC_API_KEY:?load NGC_API_KEY through the downstream auth helper}"
  [[ "$NGC_API_KEY" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo "ERROR: invalid NGC_API_KEY format" >&2; exit 1; }
  LLS_CHART_ARCHIVE="$(mktemp "${TMPDIR:-/tmp}/gdn-streaming.XXXXXX")"
  trap 'rm -f -- "$LLS_CHART_ARCHIVE"' EXIT
  # Bash printf is a builtin: credentials travel through stdin, never argv.
  printf 'user = "$oauthtoken:%s"\n' "$NGC_API_KEY" |
    curl --config - --fail --silent --show-error --location \
      --proto '=https' --proto-redir '=https' \
      --output "$LLS_CHART_ARCHIVE" "$LLS_CHART_REF"
  LLS_CHART_REF="$LLS_CHART_ARCHIVE"
fi
LLS_PROXY_CONTAINER="${LLS_PROXY_CONTAINER:-}"
# Requires Python with PyYAML. Check before starting the render.
python3 -c 'import yaml' 2>/dev/null || {
  echo "ERROR: render check requires PyYAML in this Python environment; install with python3 -m pip install PyYAML." >&2
  exit 1
}
# Authenticate OCI/private mirrors as required (see Install). Only the three
# advertisement variables are printed; the rest of the render is discarded.
helm template "$LLS_RELEASE_NAME" "$LLS_CHART_REF" \
  --version 3.0.0 \
  --namespace gdn-streaming \
  "${LLS_VALUES_ARGS[@]}" |
python3 -c '
import sys
import yaml

host, port, container_name = sys.argv[1:]
try:
    documents = list(yaml.safe_load_all(sys.stdin))
except yaml.YAMLError:
    sys.exit("ERROR: invalid rendered YAML; inspect the chart locally")
# Keep the container selection below in sync with the Verify snippet.
# Scope the check to the proxy deployment/container, not TURN or sidecars.
deployments = [d for d in documents if isinstance(d, dict)
               and d.get("kind") == "Deployment"
               and (d.get("metadata") or {}).get("name") == "streaming-proxy"]
if len(deployments) != 1:
    sys.exit("ERROR: expected exactly one streaming-proxy Deployment")
try:
    containers = deployments[0]["spec"]["template"]["spec"]["containers"]
    if not isinstance(containers, list) or not containers:
        raise ValueError
    required = {"LB_DNS", "LB_PORT", "NVCF_LLS_LOAD_BALANCER_PORT"}
    selected = []
    present = set()
    for c in containers:
        entries = c.get("env") or []
        if not isinstance(entries, list) or any(not isinstance(e, dict) for e in entries):
            raise ValueError
        names = {e.get("name") for e in entries}
        present |= required & names
        if (c.get("name") == container_name if container_name else required <= names):
            selected.append(c)
except (KeyError, TypeError, AttributeError, ValueError):
    sys.exit("ERROR: invalid proxy Deployment structure; inspect spec/template/containers/env")
# Name the actual problem; print variable names only, never env values.
if container_name and not selected:
    sys.exit("ERROR: no container named " + container_name + " in the streaming-proxy Deployment")
if not selected and required - present:
    sys.exit("ERROR: not set in any proxy container: " + ", ".join(sorted(required - present))
             + "; check the chart schema for the advertisement values keys")
if not selected:
    sys.exit("ERROR: no single container sets all of " + ", ".join(sorted(required))
             + "; set LLS_PROXY_CONTAINER explicitly")
if len(selected) != 1:
    sys.exit("ERROR: multiple proxy containers match; set LLS_PROXY_CONTAINER explicitly")
entries = selected[0].get("env") or []
bad = False
for name, expected in (("LB_DNS", host), ("LB_PORT", port),
                       ("NVCF_LLS_LOAD_BALANCER_PORT", port)):
    matches = [e for e in entries if e.get("name") == name]
    if len(matches) != 1:
        print("ERROR: " + name + " must occur exactly once")
        bad = True
    elif "valueFrom" in matches[0] or "value" not in matches[0]:
        print("UNRESOLVED: " + name + "; verify its source before proceeding")
        bad = True
    elif str(matches[0]["value"]) != expected:
        print("MISMATCH: " + name + "=" + repr(matches[0]["value"]) + ", expected " + repr(expected))
        bad = True
    else:
        print(name + "=" + expected)
sys.exit(1 if bad else 0)
' "$LLS_HOST" "$LLS_MEDIA_PORT" "$LLS_PROXY_CONTAINER"
```

The snippets automatically select a container only when exactly one container
in the proxy Deployment defines all three advertisement variables. Set
`LLS_PROXY_CONTAINER` explicitly when selection is ambiguous; an explicit
selection still requires all three fields to pass validation. The render check
requires Python with PyYAML and returns nonzero for missing, duplicate,
mismatched, or unresolved fields. Resolve any failure before installing. For
`valueFrom`, explicitly verify the referenced endpoint configuration; this
literal-value check cannot certify it and must not be treated as a pass.

## Install

Run this after the NVCF control plane exists. A namespace-only fallback is fine
for render validation, but media validation requires a real NVCF backend and a
streaming function.

```bash
set -euo pipefail
: "${LLS_VALUES_FILE:?set LLS_VALUES_FILE to the rendered gdn-streaming values file}"
LLS_VALUES_ARGS=(-f "$LLS_VALUES_FILE")
# Include the protected certificate values on TLS install/upgrade and render.
if [[ -n "${LLS_SECRETS_FILE:-}" ]]; then
  [[ -f "$LLS_SECRETS_FILE" ]] || { echo "ERROR: LLS_SECRETS_FILE is missing" >&2; exit 1; }
  LLS_VALUES_ARGS+=(-f "$LLS_SECRETS_FILE")
fi
LLS_RELEASE_NAME="${LLS_RELEASE_NAME:-gdn-streaming}"
LLS_CHART_REF="${LLS_CHART_REF:-https://helm.ngc.nvidia.com/nvidia/omniverse/charts/gdn-streaming-3.0.0.tgz}"
if [[ "$LLS_CHART_REF" == https://helm.ngc.nvidia.com/* ]]; then
  set +x
  : "${NGC_API_KEY:?load NGC_API_KEY through the downstream auth helper}"
  [[ "$NGC_API_KEY" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo "ERROR: invalid NGC_API_KEY format" >&2; exit 1; }
  LLS_CHART_ARCHIVE="$(mktemp "${TMPDIR:-/tmp}/gdn-streaming.XXXXXX")"
  trap 'rm -f -- "$LLS_CHART_ARCHIVE"' EXIT
  # Bash printf is a builtin: credentials travel through stdin, never argv.
  printf 'user = "$oauthtoken:%s"\n' "$NGC_API_KEY" |
    curl --config - --fail --silent --show-error --location \
      --proto '=https' --proto-redir '=https' \
      --output "$LLS_CHART_ARCHIVE" "$LLS_CHART_REF"
  LLS_CHART_REF="$LLS_CHART_ARCHIVE"
fi
# Keep this helper in sync with the Verify snippet below; both snippets are
# standalone so users can copy either block.
lls_resolve_turn_enabled() {
  python3 - "${LLS_VALUES_FILE:-}" "${LLS_SECRETS_FILE:-}" "${LLS_TCP_TURN_ENABLED:-}" <<'PY_TURN'
import pathlib
import sys
import yaml

values_path, secrets_path, live_setting = sys.argv[1:]
if not values_path:
    if live_setting not in ("true", "false"):
        sys.exit("ERROR: set LLS_VALUES_FILE or the known live LLS_TCP_TURN_ENABLED boolean")
    print(live_setting)
    sys.exit(0)
enabled = True  # gdn-streaming 3.0.0 default
for name in (values_path, secrets_path):
    if not name:
        continue
    try:
        values = yaml.safe_load(pathlib.Path(name).read_text()) or {}
        turn = values.get("tcpTurn", {})
        enabled = turn.get("enabled", enabled)
    except (OSError, yaml.YAMLError, AttributeError):
        sys.exit("ERROR: cannot read TURN settings; check the protected YAML files locally")
    if not isinstance(enabled, bool):
        sys.exit("ERROR: tcpTurn.enabled must be a YAML boolean")
print(str(enabled).lower())
PY_TURN
}
# Resolve outside an if-condition so invalid/missing configuration fails closed.
LLS_TCP_TURN_ENABLED="$(lls_resolve_turn_enabled)"

kubectl get namespace nvcf-backend >/dev/null || {
  echo "ERROR: namespace nvcf-backend is missing; install the NVCF control plane before LLS." >&2
  exit 1
}

kubectl create namespace gdn-streaming --dry-run=client -o yaml | kubectl apply -f -

# For a private mirror, configure its authentication through a downstream
# helper or ambient registry identity. HTTPS NGC auth is supplied above.
# Do not print registry secrets.
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
fi
helm upgrade --install "$LLS_RELEASE_NAME" \
  "$LLS_CHART_REF" \
  --version 3.0.0 \
  --namespace gdn-streaming \
  "${LLS_VALUES_ARGS[@]}" \
  --wait --timeout 10m

kubectl rollout status deployment/streaming-proxy -n gdn-streaming --timeout=300s
if [[ "$LLS_TCP_TURN_ENABLED" == "true" ]]; then
  kubectl rollout status deployment/turn-service -n gdn-streaming --timeout=300s
fi
kubectl get pods,svc,endpoints,endpointslices -n gdn-streaming
```

## Public UDP/TCP Ingress

LLS is not complete until the advertised public UDP endpoint reaches the
streaming-proxy backend. Use the provider's native Kubernetes
`Service.type=LoadBalancer`, Gateway/API implementation, direct NodePort, or an
external provider LoadBalancer that targets the chart's NodePort/Pod endpoints.

Minimum UDP media contract:

- Public listener and advertised host/port match the resolved ingress topology.
- Backend target reaches the chart's streaming-proxy media endpoint. With the
  chart's `externalTrafficPolicy: Local`, select nodes with a Ready proxy
  endpoint and keep the health-check target consistent with that placement.
- A controller or equivalent provider reconciliation must register new targets
  and deregister removed ones as nodes/endpoints change. A one-time list of node
  IPs is not sufficient for autoscaling; validate both directions during a
  coordinated node-replacement test before claiming lifecycle coverage.
- Health check uses a TCP/HTTP health endpoint such as TCP `8000` when the
  provider cannot health-check UDP directly.
- Firewall/security policy allows only the intended client CIDRs when possible.
- The chart's host and UDP advertisement values render the resolved public
  endpoint into the proxy; both `LB_PORT` and `NVCF_LLS_LOAD_BALANCER_PORT` agree.

Optional TCP TURN contract, only when `tcpTurn.enabled=true`:

- Public listener and backend use the selected mode from the table above:
  plain TCP 3478 to NodePort 30885, or TLS 5349 to NodePort 30886 by default.
- Select Service port `turn-tcp` for plain TCP or `turn-tls` for TLS. Do not
  combine both NodePorts in one target group.
- Health check uses `/v1/turn/health` on TCP `8080` when the provider supports
  HTTP health probes.
- Firewall/security policy allows the intended client CIDRs.
- `tcpTurn.serverDomain`, `tcpTurn.port`, and `tcpTurn.tlsPort` match the
  public TURN endpoint and rendered values.

## Provider Notes

- Mirror the Helm chart plus `streaming-proxy` and optional `turn` images to a
  provider registry when direct NVCR pulls are not allowed. Set `LLS_CHART_REF`
  to the mirrored chart URL before install.
- The public UDP endpoint can be exposed by a direct NodePort, Kubernetes
  LoadBalancer Service, Gateway implementation, or externally managed load
  balancer that targets the chart's Service, NodePort, or Pod endpoints.
- TURN TCP/TLS ingress is a separate downstream-owned path. Expose only the
  selected mode when the rendered values set `tcpTurn.enabled=true`.
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
: "${LLS_HOST:?set LLS_HOST to the intended advertised hostname or IP exactly as configured}"
: "${LLS_MEDIA_PORT:?set LLS_MEDIA_PORT to the resolved external UDP port}"
# Keep this helper in sync with the Install snippet above; both snippets are
# standalone so users can copy either block.
lls_resolve_turn_enabled() {
  python3 - "${LLS_VALUES_FILE:-}" "${LLS_SECRETS_FILE:-}" "${LLS_TCP_TURN_ENABLED:-}" <<'PY_TURN'
import pathlib
import sys
import yaml

values_path, secrets_path, live_setting = sys.argv[1:]
if not values_path:
    if live_setting not in ("true", "false"):
        sys.exit("ERROR: set LLS_VALUES_FILE or the known live LLS_TCP_TURN_ENABLED boolean")
    print(live_setting)
    sys.exit(0)
enabled = True  # gdn-streaming 3.0.0 default
for name in (values_path, secrets_path):
    if not name:
        continue
    try:
        values = yaml.safe_load(pathlib.Path(name).read_text()) or {}
        turn = values.get("tcpTurn", {})
        enabled = turn.get("enabled", enabled)
    except (OSError, yaml.YAMLError, AttributeError):
        sys.exit("ERROR: cannot read TURN settings; check the protected YAML files locally")
    if not isinstance(enabled, bool):
        sys.exit("ERROR: tcpTurn.enabled must be a YAML boolean")
print(str(enabled).lower())
PY_TURN
}
# An explicit live setting wins over potentially stale local values during Verify.
if [[ ${LLS_TCP_TURN_ENABLED+x} ]]; then
  case "$LLS_TCP_TURN_ENABLED" in
    true|false) ;;
    *) echo "ERROR: live LLS_TCP_TURN_ENABLED must be true or false" >&2; exit 1 ;;
  esac
else
  # Resolve outside an if-condition so invalid/missing configuration fails closed.
  LLS_TCP_TURN_ENABLED="$(lls_resolve_turn_enabled)"
fi
kubectl rollout status deployment/streaming-proxy -n gdn-streaming --timeout=300s
kubectl get pods -n gdn-streaming -l app=streaming-proxy -o wide
if [[ "$LLS_TCP_TURN_ENABLED" == "true" ]]; then
  kubectl rollout status deployment/turn-service -n gdn-streaming --timeout=300s
  kubectl get pods -n gdn-streaming -l app=turn-service -o wide
fi
kubectl get svc -n gdn-streaming
kubectl get svc nvcf-sbs -n nvcf-backend

nc -zvu -w 3 "$LLS_HOST" "$LLS_MEDIA_PORT" || {
  echo "WARN: UDP probe did not complete; validate with a real WebRTC client before declaring failure." >&2
}
# Keep the container selection below in sync with the render check above.
# Parse in memory and print only the selected container name, not its env.
LLS_PROXY_CONTAINER="$(kubectl get deployment/streaming-proxy -n gdn-streaming -o json |
python3 -c '
import json
import sys
container_name = sys.argv[1]
try:
    deployment = json.load(sys.stdin)
except ValueError:
    sys.exit("ERROR: invalid Deployment JSON")
try:
    containers = deployment["spec"]["template"]["spec"]["containers"]
    if not isinstance(containers, list) or not containers:
        raise ValueError
    required = {"LB_DNS", "LB_PORT", "NVCF_LLS_LOAD_BALANCER_PORT"}
    selected = []
    present = set()
    for c in containers:
        entries = c.get("env") or []
        if not isinstance(entries, list) or any(not isinstance(e, dict) for e in entries):
            raise ValueError
        names = {e.get("name") for e in entries}
        present |= required & names
        if (c.get("name") == container_name if container_name else required <= names):
            selected.append(c)
except (KeyError, TypeError, AttributeError, ValueError):
    sys.exit("ERROR: invalid proxy Deployment structure; inspect spec/template/containers/env")
# Name the actual problem; print variable names only, never env values.
if container_name and not selected:
    sys.exit("ERROR: no container named " + container_name + " in the streaming-proxy Deployment")
if not selected and required - present:
    sys.exit("ERROR: not set in any proxy container: " + ", ".join(sorted(required - present))
             + "; check the chart schema for the advertisement values keys")
if not selected:
    sys.exit("ERROR: no single container sets all of " + ", ".join(sorted(required))
             + "; set LLS_PROXY_CONTAINER explicitly")
if len(selected) != 1:
    sys.exit("ERROR: multiple proxy containers match; set LLS_PROXY_CONTAINER explicitly")
if not selected[0].get("name"):
    sys.exit("ERROR: selected proxy container has no name")
print(selected[0]["name"])
' "${LLS_PROXY_CONTAINER:-}")"
lls_advertisement_failed=false
# Query only the selected proxy container and advertisement variables.
for lls_var in LB_DNS LB_PORT NVCF_LLS_LOAD_BALANCER_PORT; do
  lls_val="$(kubectl get deployment/streaming-proxy -n gdn-streaming \
    -o jsonpath="{.spec.template.spec.containers[?(@.name==\"$LLS_PROXY_CONTAINER\")].env[?(@.name==\"$lls_var\")].value}")"
  lls_want="$LLS_MEDIA_PORT"; [[ "$lls_var" == LB_DNS ]] && lls_want="$LLS_HOST"
  if [[ "$lls_val" == "$lls_want" ]]; then
    echo "$lls_var=$lls_val"
  else
    lls_advertisement_failed=true
    echo "ERROR: live $lls_var='${lls_val:-<unset or valueFrom>}' does not match $lls_want" >&2
  fi
done
if [[ "$lls_advertisement_failed" == true ]]; then
  exit 1
fi

if [[ "$LLS_TCP_TURN_ENABLED" == "true" ]]; then
  : "${LLS_TURN_HOST:?set the resolved public TURN hostname}"
  : "${LLS_TURN_PORT:?set the resolved public TURN port for the selected mode}"
  nc -zv -w 3 "$LLS_TURN_HOST" "$LLS_TURN_PORT" || {
    echo "WARN: TCP TURN probe failed; inspect provider ingress and validate with a real WebRTC client." >&2
  }
fi
```

Expected:

- `streaming-proxy` Deployment is Ready.
- When enabled, `turn-service` Deployment is Ready (`turn` plus the injected
  OpenBao agent normally shows `2/2`).
- `nvcf-sbs` resolves in `nvcf-backend`.
- The resolved public UDP endpoint reaches the selected ingress path.
- Both live advertisement port variables match the resolved endpoint. During
  end-to-end validation, confirm the browser receives the expected LLS remote
  ICE candidate; readiness and `nc -u` alone do not prove media delivery.
- When enabled, the selected TURN endpoint is reachable. For TLS, verify the
  served certificate and hostname using a client that trusts its issuer.
  A TCP socket probe alone does not validate TLS or TURN allocation.
- For a TURN media claim, force relay use and confirm a relayed ICE candidate
  plus advancing decoded frames; a TLS handshake alone is insufficient.
- TURN can bind TLS to its PodIP rather than localhost. A failed
  `kubectl port-forward` to localhost does not establish a failed TLS listener;
  test the PodIP from an authorized in-cluster client. Record internal and
  external TLS results separately, including intermittent failures.
- A real WebRTC client can establish signaling and media with a streaming
  function.

## Troubleshooting

| Symptom | Checks | Fix |
|---|---|---|
| Pod Pending | `kubectl describe pod`, node labels, taints, allocatable CPU/memory. | Fix node-pool placement or capacity; lower resources only for explicit validation. |
| ImagePullBackOff | Rendered image repository/tag, registry mirror, kubelet identity, pull secret name. | Fix registry identity or mirror; do not print or decode secrets. |
| No public endpoint | Service events, frontend IP/DNS, target registration, firewall/security policy. | Repair provider LoadBalancer and rerun only ingress steps. |
| TURN endpoint unhealthy | `turn-service` rollout, selected TCP/TLS listener, backend target, `/v1/turn/health`, and rendered `tcpTurn.*` values. | Fix downstream TCP ingress or values; keep provider-specific load-balancer logic downstream. |
| ICE/media failure after signaling | Browser ICE candidate versus actual ingress host/port, both proxy advertisement variables, UDP reachability, optional TURN endpoint reachability, health check status, endpoint/node placement. | Fix public UDP/TCP route, firewall, or advertised endpoint. |
| SBS connection errors | `kubectl get svc nvcf-sbs -n nvcf-backend`, backend namespace health. | Repair the NVCF control plane/NVCA before reinstalling LLS. |

## Cleanup

For user-created target bindings to existing target groups, delete those
bindings before uninstalling LLS. Keep the controller and target groups
available until deregistration finishes. For bindings generated by a controller
from a Service or Ingress, remove the owning resource through the downstream
provider procedure rather than deleting its generated binding directly.

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
