---
name: generic-kubernetes-provider
description: Build and validate a repeatable generic Kubernetes platform on raw EC2 instances for self-managed streaming stack deployments. Use when the target platform is generic-kubernetes, when provisioning EC2 instances as Kubernetes nodes, installing Kubernetes with a customer-selected distro such as kubeadm, RKE2, k3s, Talos, or another conformant Kubernetes distribution, installing GPU/networking/storage/ingress/registry primitives, or generating a platform capability report for orchestrate-streaming-stack.
---

# Generic Kubernetes Provider

## Overview

Create a repeatable Kubernetes validation environment with a stable capability
contract consumed by `$orchestrate-streaming-stack`. The repo-local validation
path may use raw EC2 instances, but the customer-facing contract is not
AWS-specific: customers may bring any conformant Kubernetes distro on bare
metal, virtual machines, or raw cloud instances.

This provider owns the platform layer only: raw node provisioning, Kubernetes
bootstrap or adoption, CNI, GPU readiness, storage, ingress/load-balancer
components, registry access, and the final capability report. Higher-level NVCF
phases stay owned by the NVCF, cache, web, and storage skills.

Kubernetes distribution choice is intentionally pluggable. Do not hard-code the
provider to one installer. Treat kubeadm, RKE2, k3s, Talos, OpenShift, Rancher,
Canonical Kubernetes, MicroK8s, or another customer-selected conformant distro
as valid when it can satisfy the same capability gates and report contract.

Run from the `streaming-staging` repository root unless a generated artifact
states otherwise.

## Safety Rules

- Never ask for, print, echo, grep, decode, or paste secret values. Treat SSH
  keys, kubeconfigs, registry credentials, cloud credentials, NGC credentials,
  and generated secret manifests as sensitive.
- Prefer plan/generate mode unless the user explicitly asks to provision,
  create, deploy, apply, run, or bring up the environment.
- Before executing cloud-changing commands for `aws-ec2-validation`, confirm
  target AWS account, region, VPC/subnet plan, instance types, node count, SSH
  access method, Kubernetes distro, AWS profile or role alias, and teardown
  expectations in one concise message. Generated examples must accept an
  operator-provided cloud profile or role from configuration, such as an
  exported `AWS_PROFILE`, without naming an internal profile, account, user, or
  SSO role. For non-AWS generic Kubernetes profiles, do not require AWS account,
  region, or VPC context; confirm cluster access, location/zone labels if
  relevant, node topology, management access method, Kubernetes distro, and
  teardown expectations instead.
- Keep this provider generic after profile-specific node provisioning or
  adoption. Do not assume EKS, managed node groups, IRSA, ECR-only registry
  behavior, cloud-managed load balancer semantics, or any cloud-native pod
  identity mechanism unless the capability report explicitly declares it.
- Stop at the first failed readiness gate and report the failing component and
  owner.
- Do not replace a customer-selected Kubernetes distro just because kubeadm or
  RKE2 examples exist. Only reject a distro when a required downstream
  capability cannot be made available or validated.

## Mode Detection

Infer the mode from the user's prompt:

| Mode | Trigger | Behavior |
|---|---|---|
| Plan | "plan", "runbook", "sequence", ambiguous setup language | Produce inputs, phases, choices, and gates. Do not execute. |
| Generate | "generate", "draft", "prepare scripts", "write artifacts" | Generate reviewable scripts/manifests/config. Do not execute. |
| Deploy | "deploy", "apply", "create", "provision", "run", "bring up" | Execute one phase at a time with stop-on-failure gates. |
| Recover | "resume", "continue", "fix failed phase", "rerun" | Inspect current state first, then continue from the earliest failed or incomplete gate. |

When intent is ambiguous, choose Plan or Generate mode and tell the user the
exact phrase to use for execution.

## Required Context

Collect or discover this context before sequencing work:

| Context | Source |
|---|---|
| Deployment profile | `generic-bare-metal`, `existing-cluster`, `aws-ec2-validation`, or another explicitly named profile. Default to `generic-bare-metal` for customer bare-metal and `existing-cluster` when kubeconfig already points at a customer cluster. |
| Cloud account | Required only for cloud-backed profiles such as `aws-ec2-validation`; use `aws sts get-caller-identity` only for that profile. Mark `notApplicable` for bare-metal and existing-cluster profiles. |
| Cloud access profile | Required only for cloud-backed profiles. Read it from explicit user input, environment variables, cloud CLI configuration, or generated variables; never assume a customer has a specific local profile, SSO role, or account alias. Mark `notApplicable` for bare-metal and existing-cluster profiles. |
| Region/location | Cloud region for cloud-backed profiles; datacenter, site, rack, zone labels, or `notApplicable` for bare-metal and existing-cluster profiles. |
| Placement and capacity | For cloud-backed profiles, explicit subnet/zone choices, ordered operator-approved fallback zones, and any capacity reservation. For bare-metal, available host/GPU inventory and the owner of hardware capacity. |
| Environment name | `streaming-env.sh`, generated env files, or user prompt |
| Cloud network resources | Required only for cloud-backed profiles; VPC, subnet, and security group IDs for `aws-ec2-validation`; `notApplicable` otherwise. |
| Node identity/profile | Instance profile or role only for cloud-backed profiles; otherwise node identity mechanism or `notApplicable`. |
| Node topology | Control-plane count, CPU platform worker count, GPU worker count, instance types, disk sizes, GPU worker labels/taints, and whether platform services may schedule on GPU workers |
| Kubernetes distro | kubeadm, RKE2, k3s, Talos, another explicitly selected conformant distro, or an existing Kubernetes cluster |
| CNI | Calico, Cilium, Flannel, or another explicitly selected CNI |
| GPU stack | NVIDIA GPU Operator, or manually installed driver/toolkit stack |
| Storage provider | local-path, Longhorn, NFS CSI, Rook/Ceph, or explicitly deferred |
| Ingress/LB provider | MetalLB, Envoy Gateway, NGINX, HAProxy, or explicitly deferred |
| Exposed route contract | For each required TCP/UDP route: advertised endpoint, external listener, Kubernetes Service port and targetPort, effective process listener, transport/security mode, validation source, and owning downstream skill |
| Registry path | Private OCI registry endpoint, external registry, or explicitly deferred |
| Registry authentication lifecycle | Effective node credential provider or namespace/ServiceAccount/pod pull-secret path, renewable identity source, renewal owner, token lifetime when applicable, and node/namespace coverage |
| Object storage | S3, S3-compatible, Azure Blob, NFS/filesystem adapter, or explicitly deferred |
| Object storage credential mode | Kubernetes Secret, External Secrets/Secret Store CSI/Vault, node/VM instance profile, workload identity, or none for public buckets |
| NVCF stack path | User-provided extracted stack path, or repo-local sample path for planning only |

Use `streaming-env.sh` at the repo root as the shared env file. If it is
missing and work is not read-only planning, copy `streaming-env.sh.example` to
`streaming-env.sh`, set mode 600, and populate only non-secret values required
for the selected path. Source repo-local `streaming-env.sh` and then
`$HOME/streaming-env.sh` when present before checking NGC auth. NGC auth may be
provided by `NGC_API_KEY_FILE` or by `NGC_API_KEY` from the sourced env files;
never print either value. If only `NGC_API_KEY` is provided, write it to a mode
600 secret file outside the repo and set `NGC_API_KEY_FILE` to that path for
tools that require a file.

## Provider Phases

### Phase 0 - Preflight

1. Confirm mode, deployment profile, environment or cluster name, node topology,
   selected Kubernetes distro, object storage credential mode, and whether
   commands will execute. For `aws-ec2-validation`, also confirm AWS account,
   region, VPC/subnet/security group plan, and instance profile.
2. Verify local tools. Always check `kubectl`, `helm`, `jq`, `curl`, and
   `python3`. Add `ssh` and `scp` only when node bootstrap or host inspection
   requires SSH. Add `aws` and `terraform` only for `aws-ec2-validation` or
   another AWS-changing profile.
3. Verify Helm compatibility with the selected charts/plugins. Prefer the
   latest compatible Helm. Helm 4.x is allowed only after `helm plugin list`,
   `helm dependency build` or equivalent chart dependency checks, and the
   relevant `helm template` checks pass. If compatibility fails, select a
   known-compatible Helm 3.x binary and put it ahead of Helm 4 in `PATH`.
4. Source repo-local `streaming-env.sh` and `$HOME/streaming-env.sh` when
   present, then check NGC auth without printing contents when GPU Operator or
   NGC-backed pulls are in scope. Accept either a non-empty `NGC_API_KEY_FILE`
   or a non-empty `NGC_API_KEY`; if only `NGC_API_KEY` is present, materialize it
   into a mode 600 file outside the repo for tools that require
   `NGC_API_KEY_FILE`.
5. For `aws-ec2-validation`, inspect existing AWS resources and generated
   artifacts before creating new infrastructure. For other profiles, inspect
   kubeconfig, node inventory, installed storage/ingress/registry capabilities,
   and customer-provided artifacts.
6. For `aws-ec2-validation`, verify that every requested instance type is
   offered in each candidate Availability Zone with
   `describe-instance-type-offerings`, and verify the relevant EC2 quotas.
   Treat this as compatibility and quota preflight only. AWS does not expose a
   non-launching query that guarantees current On-Demand spare capacity, so do
   not describe an offering check, Terraform plan, or EC2 dry run as a live
   capacity probe.
7. Collect the resource and placement requirements for selected downstream
   platform services before sizing or accepting nodes. When OVDC is selected,
   record its replica count, memory profile, CPU request when defined, PVC size
   and topology, and required storage performance. Treat these as schedulable
   Kubernetes requests rather than translating them directly to nominal machine
   RAM.

Gate: toolchain exists, Helm compatibility checks pass, identity matches target
when a cloud profile declares one, cloud account fields are `notApplicable` for
non-cloud profiles, required non-secret values are known, NGC auth is available
from the sourced environment when needed, and no secrets were exposed.

### Phase 1 - EC2 Node Infrastructure

When the user chooses the EC2 validation variant, provision or adopt raw EC2
instances for the cluster:

- Control-plane nodes.
- CPU worker nodes sized for the selected platform services.
- GPU worker nodes.
- Security groups allowing only required SSH, Kubernetes control-plane,
  node-to-node, ingress, and validation traffic.
- For shared QA or customer validation environments, do not make access depend
  on one operator's transient public IP. Prefer account-mediated access such as
  VPN, bastion, SSM Session Manager, private connectivity, or a small set of
  group-managed corporate/NAT CIDRs. If public validation NodePorts are used,
  keep them scoped to those approved CIDRs and record the access model in the
  capability report.
- For shared AWS validation environments, document both requirements for other
  users: their AWS SSO/profile or role alias must resolve to the expected AWS
  account, and their network path must be included in the approved Kubernetes
  API and NodePort ingress CIDRs. The AWS profile alone is not sufficient for
  direct kubeconfig access when security groups restrict source IPs.
- Instance profiles and permissions needed for node bootstrap and image pulls.
- Disks sized for Kubernetes, container runtime, logs, cache, and storage
  provider requirements.

For OVDC, each replica needs an eligible CPU platform node whose Kubernetes
allocatable resources can fit the complete rendered request plus kube/system
reservations, the declared platform reserve, and existing pod requests. A
machine with nominal RAM equal to the OVDC memory request is undersized. In an
`aws-ec2-validation` profile, select `cpu_worker_instance_type` from this
capacity envelope. For customer bare-metal and existing clusters, validate the
provided nodes and stop with a concrete capacity requirement when none qualify.

Generated EC2 infrastructure must accept explicit Availability Zone or subnet
inputs for GPU workers. Do not bind GPU placement to positional discovery such
as the first or second entry returned by an Availability Zone data source.
Keep an ordered list of operator-approved candidate zones/subnets in the run
artifact, validate that the instance type is offered in each one, and show the
selected placement in the Terraform plan.

If EC2 returns `Server.InsufficientInstanceCapacity`, classify it as a
provider-capacity condition rather than a Kubernetes or streaming-stack defect.
Preserve completed infrastructure and Terraform state. Do not repeatedly apply
the same failed placement or silently replace an existing healthy node. Select
the next approved zone/subnet, render a new plan, require the plan to contain no
unintended changes or destruction, and apply only the failed or uncreated node
path. After launch, repeat node join, GPU Operator, allocatable GPU, and CUDA
gates before continuing.

For automatic multi-zone placement, use an AWS construct designed to choose
among multiple subnets, such as an Auto Scaling group or EC2 Fleet, and account
for its lifecycle in Kubernetes node operations. A single `aws_instance` in a
zonal subnet cannot transparently fall back to another zone. When capacity must
be assured, use a matching EC2 Capacity Reservation and record its zone,
matching mode, owner, duration, and cost implications. Reservation creation can
itself fail when AWS cannot supply the requested capacity.

Gate: instances are reachable by the selected SSH path, expected ports are open
between nodes, required disks are present, and hostnames/IPs are recorded.

For customer bare-metal or existing-cluster scenarios, do not provision EC2.
Instead, record the customer-provided node inventory, management access method,
disk layout, GPU inventory, and any externally provided network/load-balancer,
registry, and object-storage services.

### Node Placement Policy

Prefer a production-style topology with CPU platform nodes and separate GPU
worker nodes:

- Schedule platform services on CPU nodes by default: NVCF control plane,
  caches, storage APIs, storage providers, ingress/load-balancer components,
  registry helpers, monitoring, and cluster add-ons.
- Label eligible CPU platform workers with a stable selector such as
  `nvcf.nvidia.com/platform-worker=true`, and publish that exact selector in the
  capability report for downstream skills. Do not publish a node hostname as a
  general placement selector.
- Reserve GPU workers for NVCF compute-plane worker pods and other workloads
  that request `nvidia.com/gpu`.
- Label GPU workers with the detected GPU facts, such as
  `nvidia.com/gpu.present=true`, `nvidia.com/gpu.product`, and a workload label
  chosen by the deployment, such as `nvcf.nvidia.com/gpu-worker=true`.
- Taint GPU workers when the cluster has enough CPU platform capacity, for
  example `nvcf.nvidia.com/gpu-worker=true:NoSchedule`, then add tolerations
  only to workloads that should consume GPU-node capacity.
- For single-node or small EC2 validation clusters, colocation is allowed, but
  mark `platformServicesOnGpuWorkers: true` and add a limitation explaining that
  it is validation-only and may block rolling restarts or GPU worker scheduling.

Publish one internally consistent platform workload placement tuple in the
capability report. When `platformServicesOnGpuWorkers` is false,
`platformNodeSelector` must select CPU platform nodes and
`platformWorkloadTolerations` must not tolerate the GPU-worker taint. When GPU
colocation is explicitly selected, `platformNodeSelector` must select the
intended colocated nodes and `platformWorkloadTolerations` must contain only the
tolerations required to reach them. Do not publish the CPU-only selector for a
GPU-colocation profile.

Build a capacity envelope for every selected platform workload before reporting
the topology ready. For each replica, evaluate the rendered resource requests,
selectors, affinity and anti-affinity, taints and tolerations, current requested
resources, allocatable resources, and PVC topology. OVDC should resolve to CPU
platform nodes by default. GPU placement is an explicit exception that must set
`platformServicesOnGpuWorkers: true` and record the remaining host capacity for
GPU workloads; the absence of a `nvidia.com/gpu` request does not make host CPU
and memory consumption free.

Before installing baseline system add-ons, calculate the nodes on which each
workload can actually schedule after applying node selectors, node affinity,
pod anti-affinity, taints, and tolerations. A `Ready` node that the workload
cannot use does not count as placement capacity. Select and record one of these
availability profiles:

- `non-ha-validation`: Fit stateless system replicas to the eligible node count.
  When only one platform node is eligible for CoreDNS, use one replica and
  disable or constrain any autoscaler that would restore an unschedulable second
  replica. Record DNS as a single point of failure.
- `ha`: Require enough eligible nodes or topology domains to place every
  intended replica. CoreDNS HA requires at least two eligible placement domains;
  stop before apply when the selected topology cannot satisfy that contract.
- `mixed-node-validation`: A targeted toleration may place a critical system
  add-on such as CoreDNS on a tainted GPU worker when the operator selects that
  tradeoff. Keep the general GPU taint, limit the toleration to the named add-on,
  and record the colocation in the capability report.

Do not apply this stateless replica-fitting rule to quorum or stateful systems
such as Cassandra, NATS, OpenBao, or storage providers. Use their owning skills'
topology and data-safety requirements.

For NVCF deployments, keep raw GPU inventory separate from the API-facing NVCF
catalog. Record the physical product label reported by the cluster, such as
`nvidia.com/gpu.product=NVIDIA-L4`, but advertise only the GPU name and
instance type that the deployed self-managed NVCF API/catalog accepts. Validate
those strings with the function deploy API before recording them in the
capability report. For example, one environment may accept GPU `NVIDIA-L4` with
instance type `g6.xlarge`, while another catalog may expose a different
scheduling class. Keep that API-facing instance type consistent across
NVCA/NVCFBackend static GPU catalog, the GPU node label
`nvca.nvcf.nvidia.io/instance-type`, generated worker pod labels, and NVCF
function deploy requests.

When the physical provider shape differs from the NVCF scheduling class, record
both values. For example, a validation cluster may use a larger physical GPU
node for CPU, memory, or disk headroom while advertising a smaller
API-accepted one-GPU scheduling class in NVCA, node labels, and function deploy
specs. Do not assume EKS-style aliases such as `L4` or `NCP.GPU.L4` are valid
for a static generic Kubernetes catalog unless the deployed NVCF API explicitly
accepts them. Likewise, do not use cloud SKU names as NVCF `instanceType`
values unless the deployed NVCF catalog accepts that string.

For QA-style validation where multiple one-GPU functions may run at the same
time, prefer adding GPU capacity over only increasing CPU or memory. On
cloud-hosted raw nodes, this may mean selecting a physical GPU node shape with
multiple GPUs while the NVCF catalog advertises an accepted one-GPU scheduling
class. In that shape, set GPU capacity to the physical GPU count, keep the
per-worker CPU, memory, GPU memory, and storage values aligned to the advertised
one-GPU class, and label the GPU node with the same
`nvca.nvcf.nvidia.io/instance-type` value used by NVCF function deploy specs.
Use a larger single-GPU physical shape instead when the goal is a larger
individual worker rather than more concurrent workers. Treat these as
capacity-gated shapes. For customer-owned hardware, verify the physical GPU
inventory before committing the capability report or NVCF catalog. For cloud
validation, verify SKU offering and quota before apply, then treat a successful
launch as the capacity gate; use the controlled recovery procedure above if the
provider reports insufficient capacity.

Set the NVCF catalog storage request from Kubernetes allocatable
`ephemeral-storage`, not the raw node disk size. Leave headroom for the OS,
container runtime, images, logs, and kube reservations; otherwise worker pods
can pass API validation but remain Pending with `Insufficient
ephemeral-storage`.

For private mirrored sidecar or worker-init images, validate both registry
paths:

- Kubernetes namespace pull secret path, such as `ecr-pull-secret`, so platform
  pods and smoke-test pods can pull mirrored images.
- NVCF registry credential path used by `nvcf-image-credential-helper`, so
  generated worker regcreds for namespaces such as `nvcf-backend` are fresh.

If credential-init logs show ECR `GetAuthorizationToken` failures or generated
worker regcreds pull with expired tokens, refresh or register the ECR credential
through the NVCF registry credential API/CLI before retrying the function
deployment.

For EC2 validation clusters, resizing a GPU worker is a disruptive stop/start
operation even when Terraform can update the instance in place. Before resizing,
scale down or drain NVCF validation workers when the deploy API credential
allows it. After the node returns, verify the GPU operator daemonsets have
recreated cleanly, delete stale `Unknown` GPU operator pods if needed, confirm
`nvidia.com/gpu` is allocatable again, refresh short-lived ECR pull secrets in
all stack namespaces, and restart NATS auth-callout before recycling NVCF/NVCA
pods if clients report NATS NKey authentication failures. Do not mark the
capability report healthy until the deployment status is `ACTIVE` and a worker
pod is `Running` on the GPU node.

When removing or recycling the only GPU validation worker, also verify the
NVCFBackend static GPU discovery fields before redeploying the function. The
top-level `allocatedGPUCapacity` and each GPU class' embedded
`allocatedGPUCapacity` must reflect zero allocated GPUs after the worker is
terminated; otherwise SIS may continue to reject new deployments as no-capacity
even while Kubernetes and NVCA report free `nvidia.com/gpu` capacity.

Keep the credential locations clear in the generated runbook and capability
report:

- NGC or NVCF API keys sourced from `streaming-env.sh` are local operator
  inputs. They are not Kubernetes Secrets unless a later component explicitly
  creates a scoped Secret from them.
- The NVCF registry credential created by the CLI/API is stored in the
  self-managed NVCF control plane registry-credential store. It is consumed by
  `nvcf-image-credential-helper` when generated function workers need private
  image pulls.
- Kubernetes image pull Secrets such as `ecr-pull-secret` or generated
  namespace regcreds are cluster artifacts used by pods. For ECR, the password
  is a temporary authorization token and must be refreshed or regenerated before
  it expires.
- ECR may be treated as a recognized registry by the NVCF API or credential
  helper. In that mode, static docker auth alone may not be enough; the
  component that validates or refreshes ECR credentials also needs an AWS SDK
  credential source such as node/VM identity, workload identity, or a
  short-lived Kubernetes Secret for validation-only runs.
- Generating NVCF API keys, updating registry credentials, or writing new
  Kubernetes Secrets requires explicit user authorization in deploy/recover
  mode. For validation, prefer short-lived, least-scope keys such as registry
  credential management plus function listing when those scopes are sufficient.

### Phase 2 - Kubernetes Distro Bootstrap Or Adoption

Install or adopt Kubernetes using the selected distro path:

- kubeadm for a close-to-upstream bootstrap path.
- RKE2 for a packaged Kubernetes distro with integrated operational defaults.
- k3s for lightweight validation environments when it can satisfy GPU,
  networking, storage, and ingress requirements.
- Talos or another immutable/node-image oriented distro when the customer owns
  its machine configuration flow.
- Another conformant distro when the customer provides the installer or runbook.
- Existing Kubernetes when the customer has already installed the cluster and
  wants only capability validation and downstream stack deployment.

Every distro adapter must provide:

- Kubernetes API access through a kubeconfig.
- Node inventory with control-plane, CPU worker, and GPU worker roles.
- Node placement policy, including CPU platform selectors, GPU workload
  selectors, GPU worker taints, and whether platform services are allowed on GPU
  workers.
- Container runtime compatibility with NVIDIA runtime configuration.
- A documented CNI path, whether installed by the distro or by this provider.
- A repeatable join or adoption process for additional worker and GPU nodes.
- Registry authentication bootstrap on every node that may pull private
  images, including replacement nodes. For ECR on EC2, include the selected
  instance-role and kubelet credential-provider configuration in the node
  provisioning/join artifacts; follow the Phase 7 registry reference before
  deploying components that need those images.
- Persistent, distro-native configuration for baseline add-on replica and
  placement overrides. A live Deployment patch is recovery evidence, not a
  repeatable bootstrap result.
- A rollback or teardown note appropriate for the selected installer.

For RKE2, CoreDNS is a packaged Helm chart and its autoscaler is enabled by
default. When the selected profile has one eligible platform node and keeps GPU
workers tainted, generate an `rke2-coredns` `HelmChartConfig` in `kube-system`
using values supported by the pinned RKE2 chart to set one CoreDNS replica and
disable or constrain its autoscaler. Persist the resource through the RKE2
server manifests/bootstrap path so node replacement or cluster rebuild retains
the decision. For HA or mixed-node profiles, render the corresponding replica
and placement/toleration values instead of silently accepting a Pending replica.

When this provider generates bootstrap scripts, render them before apply and
verify that every invoked executable is present in the base image or installed
by the script. If a deployment profile declares a kubeconfig publication or
handoff mechanism, verify that handoff before reporting bootstrap complete. If
Kubernetes is healthy but only the handoff failed, recover the artifact in place
instead of replacing healthy cluster nodes merely to rerun bootstrap commands.

Gate: `kubectl cluster-info` succeeds, all nodes appear in `kubectl get nodes`,
and no node is stuck in an unexpected `NotReady` state. When the selected
profile declares a kubeconfig handoff, that handoff must also pass. For an
adopted cluster, the same Kubernetes gate applies without reinstalling
Kubernetes.

## Customer Bare-Metal Contract

Present generic Kubernetes as a "bring any conformant Kubernetes, expose these
capabilities" contract. Do not make the customer use the repo's EC2/RKE2
validation path unless they ask for that exact environment.

Required capabilities for a working self-managed streaming deployment:

- A reachable Kubernetes API and a kubeconfig for the target cluster.
- At least one schedulable worker node; GPU workloads require at least one GPU
  node exposing `nvidia.com/gpu`.
- A working CNI, CoreDNS, and pod-to-pod networking across nodes.
- A default or explicitly selected `StorageClass` with PVC bind/read/write
  validation.
- An ingress or load-balancer path for HTTP/S control-plane endpoints.
- A worker-visible NATS TCP path for self-managed NVCF worker dispatch, plus a
  UDP media ingress path and TCP fallback path when WebRTC/LLS/TURN is in scope.
- A private OCI registry or externally provided registry path that cluster nodes
  can pull from.
- Registry coverage for streaming control-plane parity, including
  `helm-nvcf-rate-limiter` and `nvcf-ratelimiter` when NVCF streaming
  validation is in scope.
- Object storage endpoint information for Storage APIs and cache/proxy paths
  when those phases are in scope.

For object storage credentials, support these portable modes:

- `kubernetes-secret`: static or temporary credentials stored as Kubernetes
  Secrets. This works on any distro, but rotation is customer-owned.
- `external-secret`: External Secrets Operator, Secret Store CSI, Vault, or a
  customer secret manager syncs credentials into Kubernetes. Prefer this for
  enterprise bare-metal deployments.
- `node-identity`: a node/VM instance profile or cloud metadata credential chain
  is available to pods. This is valid for raw EC2 validation, but is a provider
  variant rather than a generic bare-metal requirement.
- `workload-identity`: provider-specific pod identity such as IRSA or Azure
  Workload Identity. Use only when the capability report declares it.
- `public`: no credentials are required for public read-only buckets or object
  stores.

For S3-compatible storage, capture bucket/container name, endpoint URL, region
or signing region, addressing style, TLS mode, and credential mode. Examples
include AWS S3, MinIO, Ceph RGW, Dell ECS, NetApp StorageGRID, and other
S3-compatible stores.

The provider may include an `aws-ec2-validation` profile that creates raw EC2
nodes, installs a selected Kubernetes distro such as RKE2, validates ECR/S3
paths, and optionally attaches instance profiles. Keep that profile clearly
separate from the customer contract.

### Phase 3 - Baseline Networking

Install and validate the selected CNI:

- Calico, Cilium, Flannel, or another selected CNI.
- Pod-to-pod networking across nodes.
- DNS resolution through CoreDNS.
- Network policies only when explicitly in scope.

Gate: CoreDNS desired and Ready replicas match the selected availability
profile, no baseline system pod is unexpectedly `Pending`, pod-to-pod traffic
works across nodes, pod DNS works, and nodes remain `Ready`. For a deliberately
single-replica CoreDNS deployment, verify the autoscaler cannot recreate an
unschedulable replica and record the non-HA limitation.

### Phase 4 - GPU Enablement

Install and validate one GPU stack:

- NVIDIA GPU Operator, preferred when compatible with the selected distro and
  kernel.
- Manual NVIDIA driver, container toolkit, device plugin, and runtime config
  only when GPU Operator is not selected.

Gate: GPU nodes report `nvidia.com/gpu` allocatable resources, a CUDA test pod
can schedule on a GPU node, and the NVIDIA device plugin or GPU Operator pods
are healthy.

### Phase 5 - Storage Provider

Install the selected storage provider:

- local-path for simple single-node or development validation.
- Longhorn for replicated block storage on raw nodes.
- NFS CSI for externally provided NFS.
- Rook/Ceph for Ceph-backed validation when explicitly requested.

Gate: default or selected `StorageClass` exists, PVCs bind, a write/read test
pod succeeds, and provider pods are healthy.

### Phase 6 - Ingress And Load Balancing

Install the selected ingress/load-balancer components:

- MetalLB for bare-metal style `LoadBalancer` services.
- Envoy Gateway, NGINX, or HAProxy for HTTP/S ingress.
- Provider-specific DNS or host mapping only when explicitly requested.

For every required non-HTTP TCP/UDP route, record and validate the complete
route before declaring ingress ready:

`advertised host:port/protocol -> provider listener -> Service port ->
targetPort/EndpointSlice port -> effective process listener`

Render this mapping before deployment and inspect the live objects after
deployment. Obtain the effective listener and protocol from the owning
component's supported runtime configuration or listener evidence; do not infer
it solely from an environment variable, containerPort declaration, Service
name, or healthy control endpoint. Confirm the selected EndpointSlice is Ready
and exposes the intended numeric target port. Preserve valid external-to-
internal port translation; public, Service, and process ports need not have the
same number.

Validate health and data traffic separately. A healthy HTTP endpoint does not
prove that an adjacent media, relay, or dispatch port works. Run the owning
component skill's protocol-specific probe through the Service path and, from an
approved external network path, through the advertised endpoint. A TCP connect
alone is insufficient when the component defines an application-level probe.
For TLS/DTLS routes, verify the security mode and handshake explicitly; an open
plaintext listener must not be reported as TLS. If the external validation
source is not admitted by the firewall, record the external result as
`deferred` with the required source path rather than treating a timeout as a
backend failure or a pass.

Gate: a test `LoadBalancer` or ingress route receives an address, HTTP routing
works from the validation host, NATS TCP reaches `nats-system/nats:4222` through
the provider's selected listener or NodePort when NVCF is in scope, and every
required streaming TCP/UDP route has a consistent rendered/live route contract,
a Ready endpoint, and a successful component-level protocol probe, or is
explicitly deferred with owner and reason.

### Phase 7 - Registry Path

Set up a private OCI registry path or integrate with an external registry:

- Use an externally provided registry when available.
- Deploy or configure an internal/private registry path only when requested.
- Configure image pull secrets or node runtime trust without printing secret
  material.

For private registries, configure or verify credential lifecycle management,
not just initial authentication. A Kubernetes image pull Secret does not renew
itself. A host registry login or AWS SSO refresh does not update cluster pull
credentials. Existing Ready pods and cached images do not prove that a future
replacement can pull its image.

Discover the effective pull path from pod templates, ServiceAccounts, and node
credential providers. Choose a supported renewable identity/provider or a
managed Secret rotation mechanism appropriate to the registry and distro.
Record its owner and coverage, including platform namespaces, GPU workers, and
future nodes/namespaces. Keep the NVCF worker registry-credential path separate;
an NVCF helper scoped to workload namespaces is not evidence that platform
pull Secrets are renewed. Do not relabel platform namespaces as NVCF workloads
to bypass that distinction.

For ECR, read [Private registry authentication lifecycle](references/registry-authentication.md)
before generating or applying registry authentication artifacts. ECR tokens
expire after 12 hours. Prefer the kubelet ECR credential provider with an
appropriate renewable identity on supported nodes; otherwise provide a
credential refresher that updates the effective Secrets before expiration.
A manually minted token is a bootstrap/recovery workaround, not a durable
deployment result. A public registry needs no credential-renewal mechanism;
mark authentication lifecycle checks `notApplicable` for that path.

Generate repeatable identity, node configuration, or controller/RBAC artifacts
for the chosen mechanism. In Deploy/Recover mode, establish it before handing
the registry capability to downstream deployments. For an adopted cluster,
verify the customer's mechanism rather than replacing it. If access or scope
prevents configuring or verifying renewal, mark the capability `failed` or
`deferred` with its owner and next action; do not report a durable registry pass.

Gate: a fresh pull succeeds through the intended authentication path, coverage
and renewal configuration are verified, and registry host/path plus lifecycle
evidence are recorded. Test without cached-image or temporary-secret fallbacks
using isolated validation pods, preserving running workloads and shared Secrets.
Record initial pull and post-expiration renewal validation separately. A later
test that has not run is `pending`, not `passed`; return its owner and runnable
procedure without scheduling it unless the user requested scheduling.

### Phase 8 - Capability Report

Generate a machine-readable and human-readable platform capability report for
`$orchestrate-streaming-stack`.

The report must include:

- Target platform: `generic-kubernetes`.
- Environment/profile name, deployment profile, provider metadata, location when
  applicable, and node inventory.
- For `aws-ec2-validation`, AWS account, region, VPC/subnet/security group IDs,
  selected and fallback zones, capacity assurance mode, and instance profile
  details. Record capacity failures and the final successful placement. For
  non-AWS profiles, set cloud fields to `notApplicable` or omit them when the
  consuming schema permits.
- Kubernetes distro and version.
- Baseline system add-on availability profile, eligible placement-node count,
  desired/Ready replica counts, autoscaler policy, and any non-HA limitation.
- CNI provider and validation result.
- GPU stack provider and `nvidia.com/gpu` allocatable summary.
- Node placement policy, GPU worker labels/taints, platform service placement
  constraints, exact platform workload selector and tolerations, and any
  validation-only colocation warning.
- Per-node allocatable CPU, memory, and ephemeral storage for CPU platform
  workers, plus the selected platform workload requests, eligible nodes,
  remaining capacity, and validation result. Include OVDC here when selected so
  its deployment skill can consume the same capacity and placement contract.
- Storage provider, StorageClasses, and PVC validation result.
- Ingress/load-balancer provider, exposed addresses, and supported TCP/UDP
  behavior. For each required route, include the advertised endpoint, provider
  listener, Service port, targetPort/EndpointSlice port, effective process
  listener, transport/security mode, health result, data-plane probe result,
  external validation source/result, owner, and evidence paths.
- Worker-facing NATS endpoint, exposure method, and validation result when
  self-managed NVCF compute-plane workers will run outside the control-plane
  Service network or when the deployment uses a BYOC/ONPREM worker profile.
  This value must be consumed by downstream
  `global.workerEndpoints.nvcfNatsServiceURL`, and `grpcproxy.natsServiceURL`
  should stay aligned unless an intentional control-plane-local proxy path is
  documented. An in-cluster `nats-system/nats` ClusterIP is acceptable only
  when every generated worker is guaranteed to run inside the same Kubernetes
  Service network.
- gRPC proxy routing mode. For single-cluster generic Kubernetes installs,
  `grpcproxy.nvcfGrpcServiceURL` should normally use the control-plane-local
  NVCF API gRPC service, such as `http://api.nvcf.svc.cluster.local:9090`, even
  when workers receive an external/Gateway `global.workerEndpoints` URL. Use a
  worker-facing Gateway or load-balancer URL for `grpcproxy.nvcfGrpcServiceURL`
  only when grpc-proxy itself runs outside the control-plane Service network.
- Streaming client endpoint for generated OV WebRTC validation. For
  self-managed NVCF `STREAMING` functions, record the gRPC proxy client
  listener separately from `invocationServiceURL`, for example in-cluster
  `http://grpc.nvcf.svc.cluster.local:10081` and the external TCP route,
  NodePort, MetalLB address, or customer load-balancer listener for that same
  port. Do not validate WebRTC `/sign_in` against the HTTP invocation-service
  route unless explicitly testing that route; streaming workers consume the LLS
  `llsrq.*` path from grpc-proxy, while invocation-service publishes `rq.*`.
- Registry endpoint/path, pull validation result, authentication mode, renewable
  identity source, renewal owner, node/namespace coverage, and lifecycle
  validation evidence. Record any manual-token limitation and pending
  post-expiration check explicitly.
- Known limitations, deferred capabilities, and any required higher-level
  values for NVCF deployment.

Gate: report exists, all profile-required capability fields are populated, and
any missing capability is marked `deferred`, `unsupported`, or `failed` with an
owner and next action.

## Capability Contract

Write the report as YAML. Use this shape unless a repo-local schema supersedes
it:

```yaml
targetPlatform: generic-kubernetes
deploymentProfile: generic-bare-metal
environment:
  name: ""
  location: ""
  generatedAt: ""
provider:
  cloud: notApplicable
  accountId: notApplicable
  region: notApplicable
  network: {}
  instanceProfile: notApplicable
  placement:
    selectedZones: []
    fallbackZones: []
    capacityAssurance: notApplicable # on-demand, capacity-reservation, or notApplicable
    capacityEvents: []
nodes:
  controlPlane: []
  workers: []
  gpuWorkers: []
placementPolicy:
  platformServicesOnGpuWorkers: false
  gpuWorkersTainted: false
  gpuWorkerTaints: []
  platformNodeSelector: {}
  platformWorkloadTolerations: []
  gpuWorkloadNodeSelector: {}
  notes: []
platformCapacity:
  nodes: []
  # Each node records name, selectors, taints, allocatable CPU/memory/storage,
  # current requested resources, and declared platform reserve.
  workloads: []
  # Each workload records name, replicas, requests, selector, tolerations,
  # affinity constraints, storage topology, eligible nodes, and remaining
  # capacity after placement.
  validation: unknown
kubernetes:
  distro: ""
  version: ""
  installMode: ""
  installer: ""
  kubeconfigPath: ""
  status: unknown
networking:
  cni: ""
  podToPod: unknown
  dns: unknown
  coreDNS:
    availabilityProfile: "" # non-ha-validation, ha, or mixed-node-validation
    eligibleNodeCount: 0
    desiredReplicas: 0
    readyReplicas: 0
    autoscalerPolicy: "" # disabled, constrained, or enabled
    placement: "" # platform-only or targeted-gpu-toleration
    limitations: []
gpu:
  provider: ""
  allocatableResource: nvidia.com/gpu
  allocatableCount: 0
  validation: unknown
storage:
  provider: ""
  defaultStorageClass: ""
  validation: unknown
ingress:
  loadBalancerProvider: ""
  ingressProvider: ""
  addresses: []
  tcp: unknown
  udp: unknown
  routes: []
  # Each route records: name, owner, advertisedEndpoint, providerListener,
  # service, targetPort, endpointPort, runtimeListener, transport, security,
  # healthValidation, dataPlaneValidation, externalValidation, and evidencePaths.
workerDispatch:
  natsEndpoint: ""
  natsExposureMethod: ""
  natsNodePort: null
  natsValidation: unknown
registry:
  endpoint: ""
  namespace: ""
  pullValidation: unknown
  authentication:
    mode: "" # kubelet-provider, managed-secret, public, or manual-bootstrap
    identitySource: "" # Identity reference only; never credentials
    owner: ""
    nodeCoverage: []
    namespaceCoverage: []
    secretRefs: [] # Namespace/name only, when applicable
    tokenLifetime: "" # e.g. 12h for ECR tokens
    refreshBeforeExpiry: "" # Refresher margin or provider cache policy
    configurationValidation: unknown
    freshPullValidation: unknown
    renewalValidation: unknown # pending until observed; notApplicable for public
    lastValidatedAt: ""
    evidencePaths: []
objectStorage:
  type: ""
  provider: ""
  endpoint: ""
  bucketOrContainer: ""
  region: ""
  addressingStyle: ""
  credentialMode: ""
  validation: unknown
limitations: []
deferred: []
failed: []
downstreamValues: {}
```

## Output Format

For Plan or Generate mode, return a phase table:

| Phase | Action | Gate | Status |
|---|---|---|---|

For Deploy or Recover mode, report after every phase:

- Completed action.
- Artifact paths created or used.
- Gate result.
- Next phase and what it needs.

Keep the final answer short, with the current state, failed gate if any, and the
exact next command or prompt needed.
