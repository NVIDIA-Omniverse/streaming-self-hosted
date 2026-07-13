# Omniverse Streaming Skills

This repository contains AI-agent skills for planning and deploying a
self-hosted NVIDIA Omniverse Streaming on NVCF stack on cloud infrastructure.
The skills cover base cloud infrastructure, NVCF self-managed installation,
NVCF auxiliary services, caches, and Storage APIs.

Use this repository with an agent that supports skills. Start at the repository
root for end-to-end orchestration, or open a component directory when you only
want one part of the stack.

## Quick Start

Clone the release repository:

```bash
git clone <release-repository-url> streaming-skills
cd streaming-skills
```

Create your deployment environment file:

For Azure:
```bash
cp streaming-env-azure.sh.example streaming-env.sh
chmod 600 streaming-env.sh
```

For AWS:
```bash
cp streaming-env-aws.sh.example streaming-env.sh
chmod 600 streaming-env.sh
```

Edit `streaming-env.sh` with your cloud account, region, cluster name, registry,
storage, and NGC key-file path. Store the NGC API key in the file referenced by
`NGC_API_KEY_FILE` so the skills can access artifacts from the necessary NGC
orgs; do not paste the key into prompts, scripts, or chat.

Install or verify the tools used by the skills:

- Common: `kubectl`, `helm`, `jq`, `curl`, `python3`
- NVCF: [`nvcf-cli`](https://docs.nvidia.com/nvcf/v0.6.0-rc/cli#download-from-ngc), `helmfile` 1.1.x and the `helm-diff` plugin
- NGC: [`ngc` CLI](https://docs.ngc.nvidia.com/cli/index.html)
- Azure: `az`
- AWS: `aws`, `terraform`
- Image mirroring: `skopeo` or the mirror backend selected by the skill

**Before starting, ensure `nvcf-cli` and `ngc` CLI are installed in addition to the tools listed above.**

Open this repository in your agent and ask it to use the orchestration skill.
Start in plan mode first. Review the generated plan and scripts before asking
the agent to deploy.

## End-to-End Orchestration

Use the root orchestration skill when you want the full deployment sequence:

1. Create base cloud infrastructure with `csp-infra` on Azure or AWS.
2. Mirror required images and charts into ACR or ECR when needed.
3. Install NVCF self-managed prerequisites and control plane.
4. Add NVCF auxiliary services such as LLS for streaming.
5. Deploy cache services such as DDCS, UCC, or GXCache.
6. Deploy Omniverse Storage APIs with the correct cloud adapter.
7. Run final readiness checks.

The orchestration skill delegates each phase to the component skill that owns
that part of the stack. It should stop at failed readiness gates instead of
continuing blindly.

## Prompt Examples

Plan an Azure deployment:

```text
Use $orchestrate-streaming-stack from this repository to plan an end-to-end
self-managed NVCF streaming deployment.

Mode: plan first, then generate scripts for review only. Do not execute cloud-
changing commands until I explicitly say "deploy".

Target CSP: Azure
Cluster name: aks-nvcf-validation-westus3
Region/location: westus3
Storage target: Azure Blob
Cache target: DDCS, UCC, GXCache
NVCF control-plane stack path: nvcf/nvcf-self-managed-stack
NVCF compute-plane stack path: nvcf/nvcf-compute-plane-stack

End-to-end scope must include:
- Azure base infra and AKS prerequisites
- ACR mirroring for all selected images and Helm charts, including non-OCI Helm chart conversion
- NVCF control plane
- NVCF compute plane / NVCA operator / backend
- NVCF CLI prerequisites and cluster registration
- LLS media path for streaming, including streaming-proxy UDP ingress
- TURN service for TCP/ICE fallback, unless I explicitly decline it
- DDCS, UCC, and GXCache
- Storage APIs with Azure Blob adapter and Discovery
- Storage notifications decision: RabbitMQ, event-aggregation, event-consumer
- Final E2E function deployment/readiness validation

Before generating scripts, produce a phase table with:
Phase, owner skill, selected components, optional components needing my decision,
artifacts to generate, readiness gate, and whether the phase is required for a
working streaming deployment.

Important:
- Do not silently skip optional-but-relevant components. Mark them as
  "Needs decision" with a recommendation.
- For streaming, treat LLS as required unless I explicitly say no WebRTC/media.
- Treat compute plane as required; control plane alone is not end-to-end.
- Treat storage notifications as optional, but ask me whether to include them.
- Stop at each failed gate and name the component skill that owns the fix.
- Source credentials from ~/streaming-env.sh, but never print secret values.
```

Plan an AWS deployment:

```text
Use $orchestrate-streaming-stack from this repository to plan an end-to-end
self-managed NVCF streaming deployment.

Mode: plan first, then generate scripts for review only. Do not execute cloud-
changing commands until I explicitly say "deploy".

Target CSP: AWS
Cluster name: nvcf-validation-usw2
Region/location: us-west-2
Storage target: S3
Cache target: DDCS, UCC, GXCache
NVCF control-plane stack path: nvcf/nvcf-self-managed-stack
NVCF compute-plane stack path: nvcf/nvcf-compute-plane-stack

End-to-end scope must include:
- AWS base infra and EKS prerequisites
- ECR mirroring for all selected images and Helm charts, including non-OCI Helm chart conversion
- NVCF control plane
- NVCF compute plane / NVCA operator / backend
- NVCF CLI prerequisites and cluster registration
- LLS media path for streaming, including streaming-proxy UDP ingress
- TURN service for TCP/ICE fallback, unless I explicitly decline it
- DDCS, UCC, and GXCache
- Storage APIs with S3 adapter and Discovery
- Storage notifications decision: RabbitMQ, event-aggregation, event-consumer
- Final E2E function deployment/readiness validation

Before generating scripts, produce a phase table with:
Phase, owner skill, selected components, optional components needing my decision,
artifacts to generate, readiness gate, and whether the phase is required for a
working streaming deployment.

Important:
- Do not silently skip optional-but-relevant components. Mark them as
  "Needs decision" with a recommendation.
- For streaming, treat LLS as required unless I explicitly say no WebRTC/media.
- Treat compute plane as required; control plane alone is not end-to-end.
- Treat storage notifications as optional, but ask me whether to include them.
- Stop at each failed gate and name the component skill that owns the fix.
- Source credentials from ~/streaming-env.sh, but never print secret values.
```

Deploy after reviewing the generated plan:

```text
Use $orchestrate-streaming-stack from this repository.

Mode: deploy.
Target CSP: <AWS or Azure>
Cluster name: <cluster-name>
Region/location: <region>

Execute the approved plan one phase at a time. Stop at the first failed gate,
summarize what failed, and name the component skill that owns the fix.
Source credentials from ~/streaming-env.sh, but never print secret values.
```

Resume after a failed phase:

```text
Use $orchestrate-streaming-stack from this repository.

Mode: recover.
Target CSP: <AWS or Azure>
Cluster name: <cluster-name>

Inspect the current cluster state, generated artifacts, Terraform outputs,
Helm releases, and Kubernetes pods. Identify the earliest failed or incomplete
gate, then continue from there without rerunning completed destructive phases.
Source credentials from ~/streaming-env.sh, but never print secret values.
```

## Component Skills

Use these directly when you only need one part of the stack:

| Area | Skills |
| --- | --- |
| Azure base infrastructure | `csp-infra/azure/.agents/skills/aks-bootstrap` |
| AWS base infrastructure | `csp-infra/aws/.agents/skills/aws-infra` |
| NVCF self-managed stack | `nvcf/.agents/skills/nvcf-self-managed-*` |
| NVCF LLS | `nvcf/.agents/skills/nvcf-lls-install` |
| Caches | `caches/.agents/skills/caches-ddcs-deploy`, `caches/.agents/skills/caches-ovcontentcache-deploy`, `caches/.agents/skills/nvcf-gxcache` |
| Storage APIs | `storage/.agents/skills/ovstorage` |

## Safety Notes

- Review generated Terraform, shell scripts, manifests, and Helm values before
  applying them.
- Keep secrets in local files or approved secret stores. Do not put secret
  values in prompts or committed files.
- Confirm your cloud account or subscription before running deploy mode.
- Treat validation failures as stop points. Fix the failed phase before moving
  to the next one.
