---
name: orchestrate-streaming-stack
description: Orchestrate an end-to-end NVIDIA self-managed streaming stack across AWS or Azure. Use when planning, generating, sequencing, deploying, or validating the full path from CSP base infrastructure through NVCF self-managed control plane, NVCF auxiliary services, caches, storage APIs, and post-deploy readiness gates. Trigger when the user asks for orchestration, full-stack setup, bring-up order, runbook, dependency sequencing, AWS/Azure streaming deployment, csp-infra plus NVCF, caches, or storage API coordination. Do not use for a single component task when the user explicitly asks only for one child skill.
---

# Orchestrate Streaming Stack

## Overview

Coordinate the full self-managed streaming deployment without duplicating the component skills. Treat this skill as the top-level runbook: choose the CSP path, load the correct child skills, keep state in `streaming-env.sh`, and advance only when each phase's readiness gate passes.

Run from the `streaming-staging` repository root unless a child skill says otherwise.

## Safety Rules

- Never ask for, print, echo, grep, decode, or paste secret values. Treat `NGC_API_KEY_FILE`, cloud credentials, kubeconfigs, registry passwords, and generated secret manifests as sensitive.
- Prefer generate/plan mode unless the user explicitly asks to deploy, apply, run, provision, or execute.
- Before executing cloud-changing commands, confirm the target CSP, account/subscription, region, cluster name, and mode in one concise message.
- Do not skip a readiness gate to continue the sequence. If a gate fails, stop at the failing phase, summarize the failing checks, and route to the owning child skill.
- Keep AWS and Azure assumptions separate. Do not apply AKS load-balancer, ACR, Azure Blob, or Azure CNI details to EKS. Do not apply EKS, ECR, NLB, or IRSA details to AKS.

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
| CSP | User prompt; if missing, ask AWS or Azure. |
| Cluster name | `streaming-env.sh`, generated env files, Terraform outputs, kube context, or user prompt. |
| Region/location | `streaming-env.sh`, AWS/Azure CLI config, or user prompt. |
| Account/subscription | `aws sts get-caller-identity` for AWS; `az account show` for Azure. |
| Artifact mode | Plan, Generate, Deploy, or Recover. |
| Storage target | Azure Blob, S3, existing object store, or filesystem adapter. |
| Cache target | DDCS, UCC, GXCache, NVCF container/proxy cache, or none. Prefer DDCS for shader cache when the workload needs Kit/write-render-worker shader caching. Treat NVCF container/proxy cache as required for ARB/validation unless the user explicitly declines registry/S3 proxy caching. |
| NVCF stack path | User-provided extracted `nvcf-self-managed-stack` path, or repo-local sample path when the task is only planning. |

Use `streaming-env.sh` at the repo root as the shared env file. If it is missing and work is not read-only planning, copy `streaming-env.sh.example` to `streaming-env.sh`, set mode 600, and populate only the values needed for the selected path.

## Child Skill Routing

Read the child skill before performing that phase. Open only the provider or component references needed for the selected path.

| Phase | Azure child skill | AWS child skill | Notes |
|---|---|---|---|
| Base infra | `csp-infra/azure/.agents/skills/aks-bootstrap/SKILL.md` | `csp-infra/aws/.agents/skills/aws-infra/SKILL.md` | Azure has a seven-stage orchestrator. AWS owns Terraform foundation plus GPU Operator. |
| Registry mirror | `csp-infra/azure/.agents/skills/acr-mirror/SKILL.md` | `csp-infra/aws/.agents/skills/aws-infra/ecr-mirror/SKILL.md` | Mirror after registry exists and before installs that require private pulls. |
| NVCF prerequisites | `nvcf/.agents/skills/nvcf-self-managed-prerequisite/SKILL.md` | same | Installs cluster prerequisites such as KAI/SMB CSI when required by the selected NVCF stack path. |
| NVCF control plane | `nvcf/.agents/skills/nvcf-self-managed-installation/SKILL.md` | same | Requires extracted stack path, helmfile 1.1.x, helm-diff, kubectl, NGC auth, and gateway domain. |
| NVCF CLI | `nvcf/.agents/skills/nvcf-self-managed-cli/SKILL.md` | same | Use for post-install function and CLI interaction when requested. |
| LLS | `nvcf/.agents/skills/nvcf-lls-install/SKILL.md` with `providers/kubernetes.md` | same | Required for WebRTC/UDP media ingress. |
| GXCache | `caches/.agents/skills/nvcf-gxcache/SKILL.md` with `providers/kubernetes.md` | same | Use when specifically requested or required by the target stack. |
| DDCS | `caches/.agents/skills/caches-ddcs-deploy/SKILL.md` | same, adapt provider assumptions | Use for Kit/write-render-worker shader cache. GKE examples in the skill are not AWS/Azure defaults. |
| OV Content Cache | `caches/.agents/skills/caches-ovcontentcache-deploy/SKILL.md` | same | Use when OV Content Cache is part of the requested cache layer. |
| NVCF container cache | `nvcf/container-cache/README.md` | same | Required for ARB/validation unless user explicitly declines. Install into the `container-caching` namespace. Configures registry and proxy caching backed by the CSP-native registry (ECR on AWS, ACR on Azure), DaemonSet node runtime config, and PVCs. |
| Storage APIs | `storage/.agents/skills/ovstorage/SKILL.md`, then its `GUIDE.md` | same | Choose Azure/S3 production adapter or example adapter from the storage skill's decision tree. |

## End-to-End Sequence

### Phase 0 - Preflight

1. Confirm mode, CSP, account/subscription, region, cluster name, and whether commands will execute.
2. Verify local tools for the selected path:
   - Common: `kubectl`, `helm` (**Helm 3.x, `>=3.12` and `<4` — Helm 4 is
     unsupported**), `jq`, `curl`, `python3`. Confirm with `helm version`; if the
     distro default is Helm 4 (e.g. snap `helm` on current Linux), install Helm
     3.18.x and put it ahead of v4 in `PATH` before continuing.
   - NVCF: `helmfile` 1.1.x and `helm-diff`.
   - Azure: `az`, and `terraform` only if generating Terraform artifacts.
   - AWS: `aws`, `terraform`.
   - Registry mirroring: `skopeo` or the child skill's selected mirror backend.
3. Check `NGC_API_KEY_FILE` exists and is non-empty without printing its contents.
4. Inspect `image-manifest/manifest.yaml` for chart/image versions before pinning versions manually.

Gate: toolchain exists (including `helm` reporting a 3.x version `>=3.12` and
`<4`), identity matches target, `streaming-env.sh` has required non-secret
values, and no secrets were exposed.

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

### Phase 2 - Registry Mirror

Mirror images and charts only after base infra creates the target registry.

- Azure: load `acr-mirror` and mirror to ACR.
- AWS: load `aws-infra/ecr-mirror` and mirror to ECR.

> **OCI vs non-OCI charts.** The manifest has a mix of OCI and non-OCI artifacts. Container images (`nvcr.io/...`) are already OCI and mirror as-is. Some Helm charts are published to an `https://` Helm repository (for example `helm.ngc.nvidia.com`). Those are not OCI and cannot be resolved by `global.helm.sources` (OCI) or mirrored directly. Before pointing the stack at your mirror, convert each `https://` chart to OCI: `helm repo add` / `helm pull` the `.tgz`, then `helm push <chart>.tgz oci://<your-registry>/<mirror-sub-path>`. Only OCI charts can live under `global.helm.sources`.

Gate: target registry contains required images/charts for NVCF, LLS, caches, and storage components selected for the deployment. Verify `helm-nvcf-container-cache`, `nvcf-container-cache`, and `nvcf-proxy-tls-certs` are mirrored when container/proxy cache is in scope.

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
4. Configure gateway/domain values from the provider ingress/LB output.
5. Run `helmfile template` before `helmfile sync`.

Gate: dependency namespaces are healthy, NVCF API/backend services are ready, ingress routes exist, and the selected gateway host resolves or is otherwise reachable for validation.

### Phase 4 - NVCF Auxiliary Services

Install only the services required by the target workload:

1. LLS for WebRTC/UDP streaming. Load the Kubernetes provider guide and apply the notes for the target cluster.
2. GXCache only when the stack or workload requires it.
3. DDCS for shader cache when Kit/write-render-worker startup shader compilation needs acceleration. Install with `--set monitoring.enabled=false` when Prometheus CRDs (e.g. `PodMonitoring`) are not present on the cluster.
4. UCC when object/content cache is in scope.
5. **NVCF container/proxy cache** — required for ARB/validation unless the user explicitly declines. Read `nvcf/container-cache/README.md`, install `nvcf-container-cache` into the `container-caching` namespace, configure images from the CSP-native registry (ECR on AWS, ACR on Azure), and validate the nvcf-container-cache StatefulSet, nvcf-proxy-cache, DaemonSet node runtime config, and PVCs.

Gate: service rollouts complete, provider LoadBalancers or Services have addresses, UDP 5004 is reachable for LLS, cache health/proof-of-life checks pass, and when container cache is installed: `helm list -n container-caching` shows deployed releases, nvcf-container-cache StatefulSet and nvcf-container-cache-cc DaemonSet are Ready, all PVCs are Bound, and node runtime config is applied.

### Phase 5 - Storage API

1. Load `storage/.agents/skills/ovstorage/SKILL.md`.
2. Read `GUIDE.md` in that skill directory.
3. Choose adapter:
   - S3 production adapter for AWS.
   - Azure production adapter for Azure.
   - Example filesystem adapter for development or custom adapter work.
4. Deploy Discovery plus the selected adapter, then optional Event Aggregation, Event Consumer, RabbitMQ, Envoy Auth Extension, Storage Navigator, and ingress only when requested.

Gate: Discovery answers, adapter CRUD works, notifications/permissions checks pass when enabled, and storage endpoint details are recorded for downstream functions.

### Phase 6 - Final Readiness

Run a concise acceptance pass:

- `kubectl get pods -A` has no unexpected CrashLoopBackOff, ImagePullBackOff, or Pending pods.
- GPU allocatable resources are visible.
- NVCF API health and auth path are reachable.
- LLS/media path is validated when streaming is in scope.
- Cache proof-of-life passes for selected cache services.
- When container/proxy cache is in scope: `helm list -n container-caching` shows deployed, nvcf-container-cache StatefulSet and nvcf-container-cache-cc DaemonSet are Ready, all PVCs are Bound, and node runtime config is applied on GPU nodes.
- Storage API CRUD and Discovery checks pass.
- Generated artifacts and env files are listed with paths.

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
