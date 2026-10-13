---
name: orchestrate-streaming-stack
description: Orchestrate an end-to-end NVIDIA self-managed streaming stack across AWS, Azure, or generic Kubernetes. Use when planning, generating, sequencing, deploying, or validating the full path from CSP or generic Kubernetes base infrastructure through NVCF self-managed control plane, NVCF auxiliary services, caches, storage APIs, and post-deploy readiness gates. Trigger when the user asks for orchestration, full-stack setup, bring-up order, runbook, dependency sequencing, AWS/Azure/generic Kubernetes streaming deployment, csp-infra plus NVCF, caches, or storage API coordination. Do not use for a single component task when the user explicitly asks only for one child skill.
---

# Orchestrate Streaming Stack

## Overview

Coordinate the full self-managed streaming deployment without duplicating the component skills. Treat this skill as the top-level runbook: choose the AWS, Azure, or generic Kubernetes path, load the correct child skills, keep state in `streaming-env.sh`, and advance only when each phase's readiness gate passes.

Run from the `streaming-staging` repository root unless a child skill says otherwise.

## Safety Rules

- Never ask for, print, echo, grep, decode, or paste secret values. Treat `NGC_API_KEY_FILE`, cloud credentials, kubeconfigs, registry passwords, and generated secret manifests as sensitive.
- Prefer generate/plan mode unless the user explicitly asks to deploy, apply, run, provision, or execute.
- Before executing cloud-changing commands, confirm the target platform, account/subscription, region, cluster or environment name, and mode in one concise message.
- Do not skip a readiness gate to continue the sequence. If a gate fails, stop at the failing phase, summarize the failing checks, and route to the owning child skill.
- Keep AWS, Azure, and generic Kubernetes assumptions separate. Do not apply AKS load-balancer, ACR, Azure Blob, or Azure CNI details to EKS or generic Kubernetes. Do not apply EKS, ECR, NLB, managed node group, or IRSA details to AKS or generic Kubernetes. Do not assume generic Kubernetes has managed cloud load balancers, managed storage classes, or cloud identity integration unless the provider capability report says so.

## Mode Detection

Infer the operating mode from the user's prompt:

| Mode | Trigger | Behavior |
|---|---|---|
| Plan | "plan", "runbook", "sequence", "what order", ambiguous setup language | Produce ordered phases, required inputs, and gates. Do not write deploy scripts unless useful and requested. |
| Generate | "generate scripts", "draft manifests", "prepare Terraform", "write runbook artifacts" | Generate artifacts for review, then stop. Do not execute. |
| Deploy | "deploy", "apply", "create", "provision", "run", "bring up" | Generate or use existing artifacts, then execute one phase at a time with stop-on-failure semantics. |
| Recover | "resume", "continue", "fix failed phase", "rerun from phase N" | Inspect current state and logs first, then continue from the earliest failed or incomplete gate. |

When intent is ambiguous, choose Plan or Generate mode and tell the user the exact phrase to use for execution.

## Required Context

Collect or discover this context before sequencing work:

| Context | Source |
|---|---|
| Target platform | User prompt; if missing, ask AWS, Azure, or generic Kubernetes. |
| Cluster name | `streaming-env.sh`, generated env files, Terraform outputs, kube context, or user prompt. |
| Region/location | `streaming-env.sh`, AWS/Azure CLI config, provider capability report, cluster labels, or user prompt. |
| Account/subscription | `aws sts get-caller-identity` for AWS and for generic Kubernetes only when `deploymentProfile: aws-ec2-validation`; `az account show` for Azure. For other generic Kubernetes profiles, mark cloud account/subscription not applicable and rely on cluster/location/provider metadata. |
| Artifact mode | Plan, Generate, Deploy, or Recover. |
| Storage target | Azure Blob, S3, S3-compatible object store, existing object store, generic Kubernetes storage provider, or filesystem adapter. For generic Kubernetes, consume `objectStorage` and credential mode from the provider capability report instead of assuming managed cloud identity. |
| Cache target | OVDC, UCC, GXCache, NVCF container/proxy cache, or none. Prefer OVDC for shader cache when the workload needs Kit/write-render-worker shader caching. Treat NVCF container/proxy cache as required for ARB/validation unless the user explicitly declines registry/S3 proxy caching. |
| NVCF stack path | User-provided extracted `nvcf-self-managed-stack` path, or repo-local sample path when the task is only planning. |

For generic Kubernetes on cloud-hosted raw nodes, keep provider location and
NVCF internal routing region separate. For example, EC2 nodes, ECR, and S3 may
use a provider region selected for the deployment, while the self-managed NVCF
control plane, NATS placement tag, and NVCA `selfManaged.region` may use a
separate internal region or subject namespace. Do not copy the cloud provider
region into NVCA `selfManaged.region` unless the control plane and NATS subjects
use the same value. Function deployment `regions` must match the SIS capacity
metadata for the registered cluster; in a cloud-hosted validation profile this
may still be the provider region even when NATS subjects use a separate internal
namespace.

Likewise, GPU capacity in the generic capability contract must use the
Kubernetes/NVCF-visible GPU resource name reported by the cluster, not only a
cloud SKU shorthand or instance-family name.

Use `streaming-env.sh` at the repo root as the shared env file. If it is missing and work is not read-only planning, copy `streaming-env.sh.example` to `streaming-env.sh`, set mode 600, and populate only the values needed for the selected path. Source repo-local `streaming-env.sh` and then `$HOME/streaming-env.sh` when present before checking NGC auth. NGC auth may be provided by `NGC_API_KEY_FILE` or by `NGC_API_KEY` from the sourced env files; never print either value. If only `NGC_API_KEY` is provided, write it to a mode 600 secret file outside the repo and set `NGC_API_KEY_FILE` to that path for tools that require a file.

## Child Skill Routing

Read the child skill before performing that phase. Open only the provider or component references needed for the selected path.

| Phase | Azure child skill | AWS child skill | Generic Kubernetes child skill | Notes |
|---|---|---|---|---|
| Base infra | `csp-infra/azure/.agents/skills/aks-bootstrap/SKILL.md` | `csp-infra/aws/.agents/skills/aws-infra/SKILL.md` | `csp-infra/generic-kubernetes/.agents/skills/generic-kubernetes-provider/SKILL.md` | Azure has a seven-stage orchestrator. AWS owns Terraform foundation plus GPU Operator. Generic Kubernetes owns raw EC2 nodes only for the `aws-ec2-validation` profile; otherwise it adopts customer-provided bare-metal nodes or an existing cluster, then validates distro, CNI, GPU stack, storage, ingress/LB, registry path, and capability report. |
| Registry mirror | `csp-infra/azure/.agents/skills/acr-mirror/SKILL.md` | `csp-infra/aws/.agents/skills/ecr-mirror/SKILL.md` | Use the registry endpoint/path from the generic Kubernetes capability report; if mirroring needs provider-specific automation, route back to `generic-kubernetes-provider`. | Mirror after registry exists and before installs that require private pulls. |
| NVCF prerequisites | `nvcf/.agents/skills/nvcf-self-managed-prerequisite/SKILL.md` | same | same | Installs cluster prerequisites such as KAI/SMB CSI when required by the selected NVCF stack path. |
| NVCF control plane | `nvcf/.agents/skills/nvcf-self-managed-installation/SKILL.md` | same | same | Requires extracted stack path, helmfile 1.1.x, helm-diff, kubectl, NGC auth, and gateway domain. |
| NVCF CLI | `nvcf/.agents/skills/nvcf-self-managed-cli/SKILL.md` | same | same | Use for post-install function lifecycle commands and CLI interaction when requested. |
| LLS | `nvcf/.agents/skills/nvcf-lls-install/SKILL.md` with `providers/kubernetes.md` | same | same | Required for WebRTC/UDP media ingress. |
| GXCache | `caches/.agents/skills/nvcf-gxcache/SKILL.md` with `providers/kubernetes.md` | same | same | Use when specifically requested or required by the target stack. |
| OVDC | `caches/.agents/skills/caches-ovdc-deploy/SKILL.md` | same, adapt provider assumptions | same, adapt provider assumptions | Use for Kit/write-render-worker shader cache. The child skill is upstream-synced; keep generic Kubernetes placement integration in this orchestrator and the provider capability report. |
| OV Content Cache | `caches/.agents/skills/caches-ovcontentcache-deploy/SKILL.md` | same | same | Use when OV Content Cache is part of the requested cache layer. |
| NVCF container cache | `nvcf/container-cache/README.md` | same | same | Required for ARB/validation unless user explicitly declines. Install into the `container-caching` namespace. On AWS/Azure, configure registry and proxy caching backed by the CSP-native registry (ECR on AWS, ACR on Azure). On generic Kubernetes, use the registry and storage capabilities reported by `generic-kubernetes-provider`. |
| Storage APIs | `storage/.agents/skills/ovstorage/SKILL.md`, then its `GUIDE.md` | same | same | Choose Azure/S3 production adapter, existing object store adapter, or example filesystem adapter from the storage skill's decision tree. |

## End-to-End Sequence

### Phase 0 - Preflight

1. Confirm mode, CSP, account/subscription, region, cluster name, and whether commands will execute.
2. Verify local tools for the selected path:
   - Common: `kubectl`, `helm`, `jq`, `curl`, `python3`. Prefer the latest Helm
     version that is compatible with the selected charts and plugins. Helm 4.x
     is allowed only after `helm plugin list`, `helm dependency build` or
     equivalent chart dependency checks, and the relevant `helm template` or
     `helmfile template` pass. If compatibility fails, select a known-compatible
     Helm 3.x binary and put it ahead of Helm 4 in `PATH`.
   - NVCF: `helmfile` and `helm-diff`; prefer the version family validated by
     the selected NVCF stack, and prove compatibility with `helmfile template`
     before `helmfile sync`.
   - Azure: `az`, and `terraform` only if generating Terraform artifacts.
   - AWS: `aws`, `terraform`.
   - Registry mirroring: `skopeo` or the child skill's selected mirror backend.
3. Source repo-local `streaming-env.sh` and `$HOME/streaming-env.sh` when present,
   then check NGC auth without printing contents. Accept either a non-empty
   `NGC_API_KEY_FILE` or a non-empty `NGC_API_KEY`; if only `NGC_API_KEY` is
   present, materialize it into a mode 600 file outside the repo for tools that
   require `NGC_API_KEY_FILE`.
4. Inspect `image-manifest/manifest.yaml` for chart/image versions before pinning versions manually.
5. Select the cache components before sizing infrastructure. When OVDC is in
   scope, record its replica count, memory profile, storage requirements, and
   placement policy as provider inputs; do not wait until the auxiliary-service
   phase to discover that the CPU platform pool cannot fit it.

Gate: toolchain exists, Helm and Helmfile compatibility checks pass for the
selected charts/plugins, identity matches target, `streaming-env.sh` has
required non-secret values, NGC auth is available from the sourced environment,
and no secrets were exposed.

### Phase 1 - Base CSP Infrastructure

Azure:

1. Load `aks-bootstrap`.
2. Use its mode detection and required `streaming-env.sh` variables.
3. Generate or execute stages 01-07 in order.

AWS:

1. Load `aws-infra`.
2. Generate or apply Terraform for VPC, subnets, EKS, node groups, IAM, and ECR.
3. Install GPU Operator after kubeconfig works.

Gate: `kubectl cluster-info` succeeds, GPU nodes can become schedulable, GPU Operator is healthy, registry exists, and provider storage primitives exist or are explicitly deferred.

Generic Kubernetes:

1. Load `generic-kubernetes-provider`.
2. For `aws-ec2-validation`, provision or adopt EC2 instances as raw nodes. For customer bare-metal or existing-cluster profiles, adopt customer-provided nodes without requiring AWS resources.
3. Install or adopt Kubernetes via the customer-selected distro path such as kubeadm, RKE2, k3s, Talos, another conformant distro, or an existing cluster.
4. Record node placement policy. For production/customer bare-metal profiles,
   prefer CPU platform nodes for NVCF control plane, caches, storage, ingress,
   registry helpers, and observability, with GPU worker nodes labeled and
   optionally tainted for NVCF worker workloads. A minimal EC2 validation
   cluster may colocate platform services and GPU capacity, but mark that as
   validation-only with capacity risk in the capability report.
   Pass the selected OVDC resource profile to the provider and require its
   `platformCapacity` result to name enough eligible nodes for every OVDC
   replica. Require CPU platform nodes by default. Accept GPU nodes only when
   `platformServicesOnGpuWorkers: true` was explicitly selected and the report
   supplies the matching selector, tolerations, and remaining capacity. Nominal
   node size is insufficient evidence; use Kubernetes allocatable and current
   requested resources.
5. Install CNI and baseline networking.
6. Install NVIDIA GPU Operator or a driver/toolkit/device-plugin stack.
7. Install storage provider such as local-path, Longhorn, NFS CSI, or Rook/Ceph.
8. Install ingress/load-balancer components such as MetalLB, Envoy Gateway, NGINX, or HAProxy.
9. Set up a private OCI registry path or integrate with an externally provided registry.
10. Generate the generic Kubernetes platform capability report.

Gate: `kubectl cluster-info` succeeds, nodes are Ready, GPU nodes report
`nvidia.com/gpu` allocatable resources, placement policy is recorded, storage
PVC validation passes, ingress/load-balancer validation passes or is explicitly
deferred, registry pull validation passes, and the capability report exists.
When OVDC is selected, the gate also requires validated CPU platform capacity
and storage topology for its rendered requests.

### Phase 2 - Registry Mirror

Mirror images and charts only after base infra creates the target registry.

- Azure: load `acr-mirror` and mirror to ACR.
- AWS: load `csp-infra/aws/.agents/skills/ecr-mirror/SKILL.md` and mirror to ECR.
- Generic Kubernetes: use the registry endpoint/path from the `generic-kubernetes-provider` capability report. If mirroring automation or registry bootstrap is missing, route back to `generic-kubernetes-provider`.

Before reporting mirroring blockers, require the provider mirror skill to verify
exact-version image and chart sources, including per-component registry
overrides and HTTP Helm catalog sources. Distinguish source configuration
defects, authentication failures, unreleased artifacts, and unverified sources.
Do not infer artifact unavailability from a failed OCI lookup alone.

> **OCI vs non-OCI charts.** The manifest has a mix of OCI and non-OCI artifacts. Container images (`nvcr.io/...`) are already OCI and mirror as-is. Some Helm charts are published to an `https://` Helm repository (for example `helm.ngc.nvidia.com`). Those are not OCI and cannot be resolved by `global.helm.sources` (OCI) or mirrored directly. Before pointing the stack at your mirror, convert each `https://` chart to OCI: `helm repo add` / `helm pull` the `.tgz`, then `helm push <chart>.tgz oci://<your-registry>/<mirror-sub-path>`. Only OCI charts can live under `global.helm.sources`.

For generic Kubernetes with a private registry mirror, validate two credential
paths before compute-plane validation: namespace pull secrets for platform pods
and NVCF registry credentials consumed by `nvcf-image-credential-helper` for
generated worker regcreds. A platform pull smoke test can pass while function
workers still fail if the NVCF registry credential path has an expired ECR token
or stale mirrored-registry credential.

Record where each credential lives. NGC/NVCF API keys sourced from
`streaming-env.sh` are local operator inputs and must not be printed. NVCF
registry credentials live in the self-managed NVCF control plane
registry-credential store and are used to mint generated worker pull secrets.
Kubernetes pull secrets live in the relevant namespaces and are used directly by
pods. Creating short-lived NVCF API keys, updating registry credentials, or
writing Kubernetes Secrets is a deploy/recover mutation and requires explicit
user authorization before execution.

Keep credential purposes explicit. NGC API keys are registry credentials for
pulling images and Helm charts. Generated WebRTC validation backends need a
self-managed NVCF function API key with invocation scope, usually produced or
shown by the NVCF CLI. Do not pass the NVCF key via `--set` or other command
arguments; inject it through a Secret or environment file after explicit user
authorization for that credential source.

Gate: target registry contains required images/charts for NVCF, LLS, caches, and storage components selected for the deployment. Verify `helm-nvcf-container-cache`, `nvcf-container-cache`, and `nvcf-proxy-tls-certs` are mirrored when container/proxy cache is in scope. For generic Kubernetes, the selected registry path must also pass the provider capability report's pull validation.

### Phase 3 - NVCF Prerequisites and Control Plane

1. Load `nvcf-self-managed-prerequisite` for cluster prerequisites required by the selected stack.
2. Load `nvcf-self-managed-installation` for the extracted `nvcf-self-managed-stack`.
3. In `<nvcf-self-managed-stack>/environments/base.yaml`, set:
   ```yaml
   addon:
     lls:
       enabled: true
   ```
   If TURN enablement is not automatically derived from the addon flag, set this in `<nvcf-self-managed-stack>/global.yaml.gotmpl`:
   ```yaml
   notary:
     turn:
       enabled: true
   ```
   For streaming deployments, enable the NVCF rate limiter unless the selected
   release explicitly documents a no-rate-limiter mode. Mirror both
   `helm-nvcf-rate-limiter` and the `nvcf-ratelimiter` image into the selected
   private registry. Verify `invocation-service` has `RATE_LIMIT_ENABLED=true`
   and `RATE_LIMIT_ADDRESS=http://ratelimiter.nvcf.svc.cluster.local:7777`, and
   `grpc-proxy` has `RATE_LIMIT_ENABLED=true` and
   `RATE_LIMIT_ADDR=http://ratelimiter.nvcf.svc.cluster.local:7777`.
4. Configure gateway/domain values from the provider ingress/LB output.
5. For generic Kubernetes, set the complete single-cluster
   `global.workerEndpoints` map unless the capability report declares a
   split-cluster route. At minimum include worker-visible NVCF HTTP, NVCF gRPC,
   NATS, ESS, NVCT, invocation, and gRPC-proxy callback URLs. These values feed
   both API-advertised worker launch metadata and SIS/ICMS worker creation.
   For BYOC/ONPREM-style workers, do not leave
   `global.workerEndpoints.nvcfNatsServiceURL` on an in-cluster ClusterIP unless
   every generated worker is guaranteed to run in the same Service network.
   Expose NATS through the selected provider route, such as Gateway API
   `TCPRoute`, NodePort, MetalLB, or another customer load balancer, and record
   that endpoint in the capability report.
6. For generic Kubernetes, verify rendered API and SIS ConfigMaps agree on
   worker-facing sidecar images and service URLs. Do not allow SIS to keep
   upstream defaults such as public/HTTPS service names or stale `niclls`
   images while API advertises mirrored/current worker sidecars.
7. Run `helmfile template` before `helmfile sync`.

Gate: dependency namespaces are healthy, NVCF API/backend services are ready,
API and SIS worker launch metadata are aligned, ingress routes exist, the
worker-facing NATS route is reachable when BYOC/ONPREM workers are in scope,
and the selected gateway host resolves or is otherwise reachable for
validation.

### Phase 4 - NVCF Auxiliary Services

Install only the services required by the target workload:

1. LLS for WebRTC/UDP streaming. Load the Kubernetes provider guide and apply the notes for the target cluster.
2. GXCache only when the stack or workload requires it. When installed, validate with `helm list -n <ns> | grep -E 'helm-gxcache|gxcache'` and confirm the GXCache Deployment/StatefulSet, service, and webhook are Ready.
3. OVDC for shader cache when Kit/write-render-worker startup shader compilation
   needs acceleration. Install with `--set monitoring.enabled=false` when
   Prometheus CRDs (e.g. `PodMonitoring`) are not present on the cluster. For
   generic Kubernetes, consume the provider's `platformServicesOnGpuWorkers`,
   `platformNodeSelector`, `platformWorkloadTolerations`, and
   `platformCapacity` result. Generate one run-scoped Helm values overlay beside
   the deployment artifacts using exactly one placement mode:
   - Default CPU mode: require `platformServicesOnGpuWorkers: false`, set
     `cluster.nodeSelector` to the reported CPU platform selector, and do not
     add a GPU-worker toleration.
   - Explicit GPU-colocation mode: require
     `platformServicesOnGpuWorkers: true`, set `cluster.nodeSelector` to the
     reported colocation selector, and set only the reported platform workload
     tolerations needed for those nodes. Do not also apply the CPU selector.
   Refuse to render when the selected mode, selector, tolerations, and eligible
   nodes disagree. Do not add provider-specific reference files under
   `caches-ovdc-deploy`; that directory is replaced by `sync-caches.sh` from its
   upstream repository.
   Layer the generated placement overlay with the selected upstream memory
   profile and provider StorageClass, then render before apply. Verify the
   effective rendered selector and tolerations match the selected placement
   mode, OVDC requests no `nvidia.com/gpu`, is not pinned to a hostname, and
   fits every eligible node named by `platformCapacity`. When changing
   placement, inspect the bound PV first;
   stop for a reviewed cache rebuild or storage migration if its node affinity
   excludes every node allowed by the selected placement mode. When installed,
   validate with `helm list -n <ns> |
   grep -E 'helm-ddcs|ddcs-dist-kv'` and confirm the OVDC workload is Ready on
   a node eligible under the selected placement mode.
4. UCC when object/content cache is in scope. When installed, validate with `helm list -n <ns> | grep -E 'helm-ovcontentcache|usd-content-cache'` and confirm the UCC workload is Ready.
5. **NVCF container/proxy cache** — required for ARB/validation unless the user explicitly declines. Read `nvcf/container-cache/README.md`, install `nvcf-container-cache` into the `container-caching` namespace, configure images from the CSP-native registry (ECR on AWS, ACR on Azure), and validate the nvcf-container-cache StatefulSet, nvcf-proxy-cache, DaemonSet node runtime config, and PVCs.

Gate: service rollouts complete, provider LoadBalancers or Services have
addresses, UDP 5004 is reachable for LLS, generic ingress has a streaming-safe
timeout for `/sign_in` WebSocket/session startup, and for every cache
component installed in this phase (GXCache, OVDC, UCC, container/proxy
cache) the matching `helm list` release is present and its workload is
Ready — do not report this gate as passed for a cache that was installed
but not confirmed present in `helm list` output. When container cache is
installed: `helm list -n container-caching` shows deployed releases,
nvcf-container-cache StatefulSet and nvcf-container-cache-cc DaemonSet are
Ready, all PVCs are Bound, and node runtime config is applied.

### Phase 5 - Storage API

1. Load `storage/.agents/skills/ovstorage/SKILL.md`.
2. Read `GUIDE.md` in that skill directory.
3. Choose adapter:
   - S3 production adapter for AWS or S3-compatible object stores.
   - Azure production adapter for Azure.
   - Example filesystem adapter for development or custom adapter work.
   - For generic Kubernetes, choose the adapter and credentials from the
     provider capability report. Accept Kubernetes Secret, External
     Secrets/Secret Store CSI/Vault, node/VM instance profile, workload
     identity, or public object storage modes. Do not assume local SSO
     credentials are usable by pods.
4. Deploy Discovery plus the selected adapter, then optional Event Aggregation, Event Consumer, RabbitMQ, Envoy Auth Extension, Storage Navigator, and ingress only when requested.

Gate: Discovery answers, adapter CRUD works, notifications/permissions checks pass when enabled, and storage endpoint details are recorded for downstream functions.

### Phase 6 - Final Readiness

Run a concise acceptance pass:

- `kubectl get pods -A` has no unexpected CrashLoopBackOff, ImagePullBackOff, or Pending pods.
- GPU allocatable resources are visible.
- NVCF API health and auth path are reachable.
- LLS/streaming infrastructure pods, Services, and provider ingress/LB endpoints are ready when streaming is in scope.
- Cache proof-of-life passes for selected cache services. For every cache installed in Phase 4 (GXCache, OVDC, UCC), confirm its Helm release is present in `helm list -n <ns>` (`helm-gxcache`/`gxcache`, `helm-ddcs`/`ddcs-dist-kv`, `helm-ovcontentcache`/`usd-content-cache` respectively) and its workload is Ready — infra is not complete if a selected cache's release cannot be found.
- On generic Kubernetes, OVDC has no GPU resource request, its PV topology
  matches its node, and enough CPU/memory capacity remains for the other
  declared platform services. In default CPU mode, verify the pod matches the
  recorded CPU platform selector and has no GPU-worker toleration. In explicit
  GPU-colocation mode, verify the pod matches the reported colocation selector
  and tolerations, and report the remaining host CPU, memory, and GPU workload
  capacity.
- When container/proxy cache is in scope: `helm list -n container-caching` shows deployed, nvcf-container-cache StatefulSet and nvcf-container-cache-cc DaemonSet are Ready, all PVCs are Bound, and node runtime config is applied on GPU nodes.
- Storage API CRUD and Discovery checks pass.
- Generated artifacts and env files are listed with paths.

Gate: the selected infra stack is healthy enough to attempt validation. If any readiness check fails, stop before function/client validation and route the fix to the owning child skill.

### Phase 7 - Streaming Validation

Run this phase after Phase 6 passes. If streaming is not in scope, mark it not applicable.

Load `nvcf/.agents/skills/nvcf-self-managed-cli/SKILL.md` when self-managed CLI syntax or session commands are needed, and use the LLS child skill for protocol-specific route checks.

- Default to Level 1 when the user asks to validate infrastructure, function lifecycle, or function readiness. It proves STREAMING function `ACTIVE` state and fresh Ready GPU worker behavior, but not media playback.
- Use Level 2 when the user asks for full streaming, browser, WebRTC, media, LLS, video, or end-to-end playback proof. It requires Level 1 first and proves the generated backend `/health`, browser-visible `/sign_in`, LLS/streaming-proxy/TURN/ICE path when configured, port-forward or ingress route, and headed-browser/user-browser decoded frames.
- For generic Kubernetes, include an NATS routing sanity check before browser
  playback: a STREAMING invocation must reach the same request subject family
  the launched `niclls` worker subscribes to. A healthy worker subscribed to
  `llsrq.<env>.<version>.>` does not prove Level 2 if invocation publishes the
  request only to `rq.<region>.<version>.*` and no worker receives it. Treat a
  missing LLS metro/environment in worker config as an NVCF control-plane or
  LLS-registration gate failure, not a GPU/Kubernetes readiness pass.
- If an override that moves invocation to the worker's `default` environment
  causes JetStream placement failures, treat that as confirmation that the
  final fix should align worker/function launch metadata to the existing NATS
  placement environment, not as evidence to move the control plane to
  `default`.
- Also verify the API, SIS, and gRPC-proxy ConfigMaps agree on the
  worker-facing NATS URL. If `/sign_in` messages are consumed from the `rq`
  stream but no streaming-proxy/SBS session appears, compare the generic
  Kubernetes route against a known-good environment and fix the NATS
  listener/TCPRoute/worker endpoint before resizing GPU capacity.
- For BYOC/ONPREM-style generic Kubernetes workers, expose and validate
  worker-facing API gRPC routes in addition to HTTP invocation. Match the
  EKS-style contract where `worker-api.<domain>` routes to NVCF API gRPC and
  `worker-tasks.<domain>` routes to NVCT API gRPC, and ensure those names
  resolve from worker pods by real DNS, CoreDNS host mapping, or the customer's
  equivalent resolver mechanism. In raw NodePort validation environments,
  include the NodePort in advertised worker URLs, such as
  `http://worker-api.<domain>:30080`; leaving it implicit can send workers to
  an unrelated port 80/443 listener even when DNS is correct.
- For generic Kubernetes NodePort or host-routed gateway endpoints, make sure
  the generated `@nvidia/nvcf-proxy` backend carries both the exact
  `NVCF_FUNCTION_VERSION_ID` validated in Level 1 and the NVCF API route host as
  `NVCF_HOST_HEADER`. Also verify the proxy implementation actually applies the
  host override to proxied HTTP and WebSocket requests; the environment variable
  alone is not proof. A healthy `/health` with `/sign_in` returning `403`
  usually means the proxy reached the route but used an expired, wrong-owner, or
  wrong-credential bearer, commonly an NGC key instead of an NVCF function API
  key.
- Do not assume a fixed stream type, Secret name, or worker container count. Resolve live names and readiness from the selected deployment. Do not rotate keys, patch Secrets, restart workloads, delete pods, or change port-forwards without explicit operator authorization.

Gate: Phase 7 passes only when every check for the selected validation level passes. If it fails, stop and report the failed component, evidence, and owning shipped child skill.

## Recovery Workflow

For resume or repair requests:

1. Identify the last completed gate from generated scripts, Terraform outputs, Helm releases, namespaces, and pod state.
2. Do not rerun earlier destructive phases unless the child skill declares them idempotent.
3. Route to the owning child skill for the failed phase.
4. After fixing, rerun the failed phase's gate, then continue the top-level sequence.

## Output Format

For Plan or Generate mode, return a phase table:

| Phase | Owner skill | Action | Gate | Status |
|---|---|---|---|---|

For Deploy or Recover mode, report after every phase:

- Completed action.
- Artifact paths created or used.
- Gate result.
- Next phase and what it needs.

Keep the final answer short, with the current state, failed gate if any, and exact next command or prompt needed.
