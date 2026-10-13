# Omniverse Streaming Skills

This repository contains AI-agent skills for planning and deploying a
self-hosted NVIDIA Omniverse Streaming on NVCF stack on AWS, Azure, or on-prem
Kubernetes. The skills cover platform infrastructure, NVCF self-managed
installation, NVCF auxiliary services, caches, and Storage APIs.

Use this repository with an agent that supports skills. Start at the repository
root for end-to-end orchestration, or open a component directory when you only
want one part of the stack.

## Quick Start

Clone the release repository:

```bash
git clone https://github.com/NVIDIA-Omniverse/streaming-self-hosted.git streaming-skills
cd streaming-skills
```

Create your deployment environment file:

For Azure or AWS, copy the matching example:

```bash
PLATFORM=azure  # or aws
cp "streaming-env-${PLATFORM}.sh.example" streaming-env.sh
chmod 600 streaming-env.sh
```

For on-prem, create a repo-local `streaming-env.sh` with mode `600` containing
the required environment values, including `NGC_API_KEY_FILE`. Provide your
kubeconfig/context or node inventory, Kubernetes distribution, registry endpoint,
storage and ingress/load-balancer choices to the agent.

For each platform, configure your cluster name, location, registry, storage,
and NGC key-file path; include cloud account details for AWS or Azure. Store the
NGC API key in the file referenced by
`NGC_API_KEY_FILE` so the skills can access artifacts from the necessary NGC
orgs; do not paste the key into prompts, scripts, or chat.

Install or verify the tools used by the skills:

- Common: `kubectl`, `helm`, `jq`, `curl`, `python3`
- NVCF: [`nvcf-cli`](https://docs.nvidia.com/nvcf/1.0.3/overview/cli), `helmfile` 1.1.x and the `helm-diff` plugin
- NGC: [`ngc` CLI](https://docs.ngc.nvidia.com/cli/index.html)
- Azure: `az`
- AWS: `aws`, `terraform`
- On-prem: access to your nodes or an existing Kubernetes context; the provider
  skill identifies additional tools for your chosen Kubernetes distribution
- Image mirroring: `skopeo` or the mirror backend selected by the skill

Open this repository in your agent and ask it to use the orchestration skill.
Start in plan mode first. Review the generated plan and scripts before asking
the agent to deploy.

## End-to-End Orchestration

Use the root orchestration skill when you want the full deployment sequence:

1. Create AWS or Azure base infrastructure, or bootstrap/adopt on-prem
   Kubernetes with `csp-infra/generic-kubernetes`.
2. Mirror required images and charts into ACR, ECR, or your OCI registry when needed.
3. Install NVCF self-managed prerequisites and control plane.
4. Install the compute plane, register the cluster, and add LLS and TURN for streaming.
5. Deploy cache services such as OVDC, UCC, or GXCache.
6. Deploy Omniverse Storage APIs with the appropriate storage adapter and Discovery.
7. Run final readiness checks.

The orchestration skill delegates each phase to the component skill that owns
that part of the stack. It should stop at failed readiness gates instead of
continuing blindly.

## Prompt Examples

Use one of the compact prompts below. Each plan should cover the full sequence
above, including image/chart mirroring (and non-OCI Helm chart conversion),
NVCF prerequisites and CLI, control and compute planes, cluster registration,
LLS media ingress, TURN fallback, caches, Storage APIs and Discovery, and final
function deployment/readiness validation. Use the repo-local stack paths
`nvcf/nvcf-self-managed-stack` and `nvcf/nvcf-compute-plane-stack` for planning.
Include container/proxy caching when required by the workload.

Ask the agent to produce a phase table with owner skill, components, generated
artifacts, readiness gates, and required/optional status. It should recommend
optional components and ask whether to include storage notifications
(RabbitMQ, event-aggregation, event-consumer). Start in plan mode, generate
scripts for review, and execute only after approval. Stop at failed gates and
name the skill that owns the fix. Source credentials from repo-local
`streaming-env.sh` and `~/streaming-env.sh` when present; never print secrets.

Plan an Azure deployment:

```text
Use $orchestrate-streaming-stack from this repository to plan an end-to-end
self-managed NVCF streaming deployment.

Mode: plan; generate scripts for review only. Follow the README planning requirements.

Target platform: Azure
Cluster name: aks-nvcf-validation-westus3
Region/location: westus3
Storage target: Azure Blob
Cache target: OVDC, UCC, GXCache
Platform: AKS; registry: ACR.
```

Plan an AWS deployment:

```text
Use $orchestrate-streaming-stack from this repository to plan an end-to-end
self-managed NVCF streaming deployment.

Mode: plan; generate scripts for review only. Follow the README planning requirements.

Target platform: AWS
Cluster name: nvcf-validation-usw2
Region/location: us-west-2
Storage target: S3
Cache target: OVDC, UCC, GXCache
Platform: EKS; registry: ECR.
```

Plan an on-prem deployment:

```text
Use $orchestrate-streaming-stack from this repository to plan an end-to-end
self-managed NVCF streaming deployment.

Mode: plan; generate scripts for review only. Follow the README planning requirements.
Target platform: generic-kubernetes
Deployment profile: existing-cluster
Cluster name: <cluster-name>; kube context: <context>; location: <site>
Kubernetes distribution: <distribution>
Registry: <OCI-registry-endpoint>
Storage target: <object-store-or-filesystem>; credential mode: <mode>
Cache target: OVDC, UCC, GXCache

Inspect GPU, networking, persistent storage, ingress/load-balancer, registry,
and object-storage capabilities before planning the stack. Report missing prerequisites.
```

For customer nodes needing Kubernetes bootstrap, use `generic-bare-metal` and
provide the node inventory instead of a kube context. To validate this on-prem
deployment model on AWS EC2, use `aws-ec2-validation`, specify the AWS account,
region and node topology, and choose ECR/S3 as needed. This profile bootstraps
generic Kubernetes on raw EC2 nodes; it does not use EKS. Cloud region and NVCF
internal routing region must be configured independently when they differ.

Plan an in-place upgrade of an existing deployment:

```text
Use $streaming-inplace-upgrade-orchestrator from this repository to upgrade an
existing self-managed streaming deployment from its current image manifest to a
candidate image manifest.

Mode: diff first. Do not apply changes until I approve the impact summary.

Target platform: <AWS, Azure, or generic-kubernetes for on-prem>
Account/subscription: <account-id-or-subscription-id>
Region/location: <region-or-location>
Cluster name: <cluster-name>
Helmfile environment: <environment-name>
NVCF control-plane stack path: <path-to-nvcf-self-managed-stack>
NVCF compute-plane stack path: <path-to-nvcf-compute-plane-stack-or-empty>
Control-plane kubeconfig: <path-or-current-context>
Compute-plane kubeconfig: <path-or-same-as-control-plane>
Current manifest: <path-to-current-image-manifest/manifest.yaml>
Candidate manifest: <path-to-candidate-image-manifest/manifest.yaml>
Target registry: <ECR, ACR, or on-prem OCI registry>
Target repository: <existing-registry-prefix>

Before requesting approval, show one impact table with:
Component, current version, target version, workload type, risk, downtime
expectation, backup recommendation, backup status, rollback impact, and owner
phase.

Important:
- Treat backup status as impact information. A skipped, unknown, or unavailable
  backup must not block the upgrade by itself.
- Do not create a backup or snapshot unless I explicitly request or approve it.
- Continue to enforce health, compatibility, artifact-readiness,
  immutable-field, route-contract, and render/diff gates.
- Follow the published NVIDIA NVCF upgrade procedure for the detected version
  path when one exists.
- Mirror required candidate images and charts into the target registry before
  upgrading their releases.
- Upgrade only changed in-scope components, one phase at a time, and stop at
  the first genuine readiness or rollout failure.
- After Apply, validate pods, Helm releases, StatefulSets, NVCF status,
  streaming routes when changed, and running-image drift against the candidate
  manifest.
- Source repo-local streaming-env.sh and ~/streaming-env.sh when present;
never print secret values.
```

Deploy after reviewing the generated plan:

```text
Use $orchestrate-streaming-stack from this repository.

Mode: deploy.
Target platform: <AWS, Azure, or generic-kubernetes for on-prem>
Cluster name: <cluster-name>
Region/location: <cloud-region-or-site>

Execute the approved plan one phase at a time. Stop at the first failed gate,
summarize what failed, and name the component skill that owns the fix.
Source repo-local streaming-env.sh and ~/streaming-env.sh when present;
never print secret values.
```

Resume after a failed phase:

```text
Use $orchestrate-streaming-stack from this repository.

Mode: recover.
Target platform: <AWS, Azure, or generic-kubernetes for on-prem>
Cluster name: <cluster-name>

Inspect the current cluster state, generated artifacts, Terraform outputs,
Helm releases, and Kubernetes pods. Identify the earliest failed or incomplete
gate, then continue from there without rerunning completed destructive phases.
Source repo-local streaming-env.sh and ~/streaming-env.sh when present;
never print secret values.
```

## Component Skills

Use these directly when you only need one part of the stack:

| Area | Skills |
| --- | --- |
| Azure base infrastructure | `csp-infra/azure/.agents/skills/aks-bootstrap` |
| AWS base infrastructure | `csp-infra/aws/.agents/skills/aws-infra` |
| On-prem Kubernetes / AWS EC2 validation | `csp-infra/generic-kubernetes/.agents/skills/generic-kubernetes-provider` |
| NVCF self-managed stack | `nvcf/.agents/skills/nvcf-self-managed-*` |
| NVCF LLS | `nvcf/.agents/skills/nvcf-lls-install` |
| Caches | `caches/.agents/skills/caches-ovdc-deploy`, `caches/.agents/skills/caches-ovcontentcache-deploy`, `caches/.agents/skills/nvcf-gxcache` |
| Storage APIs | `storage/.agents/skills/ovstorage` |

## Safety Notes

- Review generated Terraform, shell scripts, manifests, and Helm values before
  applying them.
- Keep secrets in local files or approved secret stores. Do not put secret
  values in prompts or committed files.
- Confirm your Kubernetes context and site for on-prem, or cloud account,
  subscription and region for AWS/Azure, before running deploy mode.
- Treat validation failures as stop points. Fix the failed phase before moving
  to the next one.
