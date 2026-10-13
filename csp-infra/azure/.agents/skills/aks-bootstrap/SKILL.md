---
name: aks-bootstrap
description: Orchestrates the full mandatory AKS setup in one pass — reads iam-vpc, aks-cluster, aks-nodes, acr, blob-storage, gpu-operator, and aks-validate skills; generates a Terraform module for Stage 02 and stage-prefixed scripts for the remaining stages. Infers intent from the user prompt to either generate artifacts for review or generate-and-deploy (executes sequentially; Stage 02 runs Terraform and writes the downstream env handoff, stages 01 and 03–06 stop on failure, stage07 is tolerant and reports without failing the run). Use when setting up a new AKS cluster end-to-end. Collects all required inputs once from `streaming-env.sh`, then delegates each stage to its canonical skill. Trigger when the user says "bootstrap a cluster", "deploy AKS", "set up the cluster end-to-end", "spin up Azure base", or "run all stages".
---

<!-- SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved. -->
<!-- SPDX-License-Identifier: CC-BY-4.0 AND Apache-2.0 -->

# AKS bootstrap (end-to-end orchestrator)

Mirrors `infra-as-doc/cluster-bootstrap`. Runs the mandatory stages in order, with deterministic stage prefixes for script artifacts. Stage 02 is a Terraform module; stages 01 and 03–07 are script artifacts.

| Stage | Artifact | Skill | Constructive? | Fails the run? |
|---|---|---|---|---|
| 01 | `stage01-<cluster>-iam-vpc.sh` | [`iam-vpc`](../iam-vpc/SKILL.md) | yes | yes |
| 02 | `<cluster>/aks-cluster/` Terraform module | [`aks-cluster`](../aks-cluster/SKILL.md) | yes | yes |
| 03 | `stage03-<cluster>-aks-nodes.sh` | [`aks-nodes`](../aks-nodes/SKILL.md) | yes | yes |
| 04 | `stage04-<cluster>-acr.sh` | [`acr`](../acr/SKILL.md) | yes | yes |
| 05 | `stage05-<cluster>-blob-storage.sh` | [`blob-storage`](../blob-storage/SKILL.md) | yes | yes |
| 06 | `stage06-<cluster>-gpu-operator.sh` | [`gpu-operator`](../gpu-operator/SKILL.md) | yes | yes |
| 07 | `stage07-<cluster>-validate.sh` | [`aks-validate`](../aks-validate/SKILL.md) | **no** | **no** — tolerant; reports FAIL/WARN without aborting the bootstrap |

Stage 07 is purely diagnostic. A non-zero exit means "stack is up but one or more checks failed — inspect the report before accepting"; it never means "stack is broken." Stages 01–06 had to succeed for stage 07 to even run.

## Mode detection

Infer from the user's prompt. Do **not** ask explicitly.

**Deploy mode** — only when the prompt contains explicit execution language:
- "deploy cluster ...", "create cluster ...", "spin up cluster ...", "provision cluster ..."
- "run the bootstrap ...", "execute the stages ..."

**Generate mode** — when the prompt is about producing artifacts, or when intent is ambiguous:
- "generate artifacts ...", "write the bootstrap ...", "draft the stage artifacts ..."
- "set up a cluster ...", "bootstrap a cluster ..." unless paired with explicit execution language

**Terraform destroy mode** — when the prompt explicitly requests teardown or cleanup:
- "destroy cluster ...", "terraform destroy ...", "tear down cluster ...", "clean up cluster ..."
- "delete the cluster ...", "remove the stack ..."

When ambiguous, default to **generate mode** and tell the user they can re-invoke with "deploy" or "create" to execute.

## Inputs

Single source of truth: `streaming-env.sh` at the repo root. The orchestrator reads it once and passes the relevant subset to each stage's generator.

Required (must be set in `streaming-env.sh`):

| Variable | Used by stages |
|---|---|
| `AZURE_SUBSCRIPTION_ID` | 01–06 |
| `RESOURCE_GROUP` | 01–07 |
| `LOCATION` | 01–05 |
| `VNET_NAME` | 01, 02 |
| `CLUSTER_NAME` | 01–07 |
| `ADMIN_AAD_OBJECT_IDS` | 02 |
| `ACR_NAME` | 04 |
| `STORAGE_ACCOUNT_NAME` | 05 |
| `STORAGE_CONTAINERS` | 05 |

Optional (defaults documented in each child skill's Inputs table). If `streaming-env.sh` is missing a required var, the bootstrap fails fast with a single message listing every missing value (see [`streaming-env.sh.example`](../../../streaming-env.sh.example)).

When the requested stack includes OVDC, collect these optional foundation
capacity inputs and pass them unchanged to stages 03 and 07:

| Variable | Default | Used by stages |
|---|---|---|
| `OVDC_REPLICAS` | `0` | 03, 07 |
| `OVDC_MEMORY_REQUEST_GIB` | required when `OVDC_REPLICAS > 0` | 03, 07 |
| `OVDC_PLATFORM_RESERVE_GIB` | `8` | 03, 07 |

`OVDC_MEMORY_REQUEST_GIB` is the rendered OVDC pod memory request rounded up to
GiB. When replicas are requested, Stage 03 must enable and size the CPU compute
pool; Stage 07 must verify live allocatable memory. Never route OVDC to the GPU
pool to compensate for an undersized CPU pool.

## Outputs

Bootstrap artifacts in `generated/`, plus inter-stage env files written at runtime:

```
generated/
├── stage01-<cluster>-iam-vpc.sh
├── <cluster>/aks-cluster/
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   └── providers.tf
├── stage03-<cluster>-aks-nodes.sh
├── stage04-<cluster>-acr.sh
├── stage05-<cluster>-blob-storage.sh
├── stage06-<cluster>-gpu-operator.sh
├── stage07-<cluster>-validate.sh
├── .env.iam-vpc           # written by stage01
├── .env.aks-cluster       # written after Stage 02 terraform apply from outputs
├── .env.acr               # written by stage04
├── .env.blob-storage      # written by stage05
└── stage07-<cluster>-validate-report.json   # written by stage07 at runtime
```

The `stage0N-` prefix makes execution order unambiguous in the filesystem.

## Instructions

### Step 1 — Populate `streaming-env.sh`

1a. **Bootstrap the file if absent.** If `streaming-env.sh` does not exist at the repo root, copy from the template and tighten permissions:

```bash
cp streaming-env.sh.example streaming-env.sh
chmod 600 streaming-env.sh
```

1b. **Source it and identify empty required variables.** Source the file, then check which of the required variables in the table below are still empty or unset. **Do not** prompt for any variable that is already populated — respect existing user input.

| Variable | Prompt for? | Notes |
|---|---|---|
| `AZURE_SUBSCRIPTION_ID` | yes if empty | Format: GUID. Hint: `az account show --query id -o tsv` |
| `ADMIN_AAD_OBJECT_IDS` | yes if empty | Comma-separated AAD object IDs. Hint: `az ad signed-in-user show --query id -o tsv` |
| `AUTHORIZED_IP_RANGES` | no (optional hardening) | Corp-egress CIDR(s), comma-separated. Empty means no API-server IP allowlist; access is gated by AAD + Azure RBAC. If set, NOT a laptop /32 (per `tf-conventions` R3). |
| `CLUSTER_NAME` | yes if empty | Hyphens; pattern `aks-<workload>-<env>-<region>`. e.g. `aks-nvcf-validation-westus3` |
| `ACR_NAME` | yes if empty | 5–50 chars, lowercase alphanumeric, NO hyphens, globally unique. |
| `STORAGE_ACCOUNT_NAME` | yes if empty | 3–24 chars, lowercase alphanumeric, NO hyphens, globally unique. |
| `STORAGE_CONTAINERS` | no (has default `models,outputs,scratch`) | Only ask if the user wants to change it. |
| `LOCATION` | no (has default `westus3`) | Only ask if the user wants a different region. |
| `RESOURCE_GROUP`, `VNET_NAME` | no — **derived** from `CLUSTER_NAME` | Override only by explicit user request; do not prompt. |
| `NGC_API_KEY_FILE` | no (has default `$HOME/.nvcf-secrets/ngc-api-key`) | Remind the user to create that file (mode 600, single line, no newline) — do NOT ask for the key value itself. |

1c. **Ask in one batched message.** Collect ALL missing values in a single user prompt — do not ask one variable at a time. For each missing variable, state what it is, the format constraint, an example, and (when relevant) the `az` command that fetches it.

1d. **Write values back to `streaming-env.sh`.** For each variable the user provided, update the corresponding line in-place via `sed`, preserving every comment and the file's overall structure:

```bash
sed -i.bak "s|^export VAR_NAME=.*|export VAR_NAME=\"$VALUE\"|" streaming-env.sh
rm -f streaming-env.sh.bak
```

Re-source the file after writing so subsequent steps see the populated values.

1e. **Confirm and stop on data issues.** Print the populated variables to the user (one line each, name + value). For `NGC_API_KEY_FILE`, print the path only — NEVER read or display the key contents. If the user provides a value that violates a documented constraint (ACR name with hyphens, AAD object ID wrong shape, `AUTHORIZED_IP_RANGES` containing a `/32`), stop and ask them to correct it before continuing.

### Step 2 — Detect the mode

Detect the mode from the user's prompt (see **Mode detection** above) and confirm it to the user before generating.

### Step 3 — Generate stage artifacts

For each stage in order, read the child skill's SKILL.md and generate its artifact:
- Stage 01 → read [`iam-vpc/SKILL.md`](../iam-vpc/SKILL.md) and write `generated/stage01-<cluster>-iam-vpc.sh`
- Stage 02 → read [`aks-cluster/SKILL.md`](../aks-cluster/SKILL.md) and write the Terraform module under `generated/<cluster>/aks-cluster/`
- Stages 03–07 → write `generated/stageNN-<cluster>-<skill>.sh`

### Step 4 — Generate-mode output

If **generate mode**: print the run-order summary (see below). Do NOT execute.

### Step 5 — Deploy-mode execution

If **deploy mode**: execute the scripts sequentially per **Deploy mode execution** below.

## Generate mode output

After writing the Stage 02 Terraform module and the remaining stage scripts:

```
Generated AKS bootstrap artifacts in generated/. Apply or run them in order:

  1. bash generated/stage01-<cluster>-iam-vpc.sh       # RG + VNet + subnets + cluster identity
  2. terraform -chdir=generated/<cluster>/aks-cluster init
     terraform -chdir=generated/<cluster>/aks-cluster apply
     # then write generated/.env.aks-cluster from terraform outputs
  3. bash generated/stage03-<cluster>-aks-nodes.sh     # GPU pool (+ optional compute pool)
  4. bash generated/stage04-<cluster>-acr.sh           # ACR + AcrPull to kubelet
  5. bash generated/stage05-<cluster>-blob-storage.sh  # Storage account + containers + Blob RBAC
  6. bash generated/stage06-<cluster>-gpu-operator.sh  # NVIDIA GPU operator (Helm)
  7. bash generated/stage07-<cluster>-validate.sh      # Read-only diagnostic; writes JSON report

Confirm each stage 01–06 succeeded before running the next. Stage 07 is
diagnostic — its exit code is the "cluster is ready" signal.

To deploy automatically next time, re-invoke with: "deploy cluster <CLUSTER_NAME>"
```

## Stage 02 Terraform handoff

After applying `generated/<cluster>/aks-cluster/`, write `generated/.env.aks-cluster` before running Stage 03. Later stages source this env-file contract. The handoff maps Terraform outputs and kubeconfig metadata; it does not provision or mutate the AKS cluster with Azure CLI.

```bash
AKS_DIR="generated/${CLUSTER_NAME}/aks-cluster"
mkdir -p generated
export KUBECONFIG="${KUBECONFIG:-/tmp/kubeconfig-${CLUSTER_NAME}}"
az account set --subscription "$AZURE_SUBSCRIPTION_ID"
az aks get-credentials --name "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" --overwrite-existing --file "$KUBECONFIG"
command -v kubelogin >/dev/null || {
  echo "ERROR: kubelogin not found. Install with: az aks install-cli" >&2
  exit 1
}
kubelogin convert-kubeconfig -l azurecli
cat > generated/.env.aks-cluster <<EOF
export AKS_CLUSTER_ID="$(terraform -chdir="$AKS_DIR" output -raw cluster_id)"
export KUBELET_IDENTITY_OBJECT_ID="$(terraform -chdir="$AKS_DIR" output -raw kubelet_identity_object_id)"
export OIDC_ISSUER_URL="$(terraform -chdir="$AKS_DIR" output -raw oidc_issuer_url)"
export KUBECONFIG="$KUBECONFIG"
EOF
```

## Deploy mode execution

1. Run `bash generated/stage01-<cluster>-iam-vpc.sh`.
   - Exit != 0 → stop immediately. Report which stage failed and the last lines of output. Do NOT proceed.
   - Exit == 0 → confirm and continue.
2. Apply Stage 02 with Terraform:
   - Run `terraform -chdir=generated/<cluster>/aks-cluster init`.
   - Run `terraform -chdir=generated/<cluster>/aks-cluster apply -auto-approve`.
   - Run the **Stage 02 Terraform handoff** above to write `generated/.env.aks-cluster`. The handoff's `az aks get-credentials` + `kubelogin` works only because Stage 02 grants `ADMIN_AAD_OBJECT_IDS` both "Cluster User Role" and "RBAC Cluster Admin" on the cluster — without that grant, every later `kubectl` (and stage 07) is `Forbidden` under `disable_local_accounts=true`.
   - **Propagation-race exception:** an apply failure with `ResourceMissingPermissionError` (`…joinLoadBalancer…` on the API-server subnet) is Stage 01's Network Contributor grants still propagating, NOT a real failure. Propagation lag varies (typically ~60–90s but can run longer), so retry `terraform apply -auto-approve` (idempotent) with a short backoff for a **bounded window** — e.g. up to 5 attempts / ~10 minutes — before treating it as fatal.
   - If the retries are exhausted, or the error is anything other than that propagation race → stop immediately. Report Stage 02 and the last lines of output. Do NOT proceed.
3. Run stages 03 → 04 → 05 → 06 in order, with the same stop-on-failure semantics.
4. Run `bash generated/stage07-<cluster>-validate.sh`.
   - **Tolerant execution:** always report the exit code, but do NOT treat a non-zero exit as a bootstrap failure.
   - Exit 0 → print full-success message (below).
   - Exit 1 → print the stage07 summary line + report path, then: "Bootstrap completed but validation reported failures — inspect the report before accepting the cluster." Do NOT exit non-zero from this orchestrator.
   - Exit 2 → "Stage 07 preflight failed (missing tool or cluster unreachable). Stages 01–06 succeeded."

On full success:

```
Cluster <CLUSTER_NAME> is ready. All 7 stages completed successfully.

  stage01 — IAM + VPC:               OK
  stage02 — AKS control plane:       OK
  stage03 — Node pools:              OK
  stage04 — ACR + AcrPull:           OK
  stage05 — Blob storage + RBAC:     OK
  stage06 — GPU operator:            OK
  stage07 — Validation:              OK (see generated/stage07-<cluster>-validate-report.json)
```

## Terraform destroy mode

Tears down the full stack in reverse stage order. Stage 02 always uses Terraform; Terraform destroy is applicable to any other stage that was generated as a Terraform module under `generated/<cluster>/`.

### Confirmation prompt

Before running any destroy, print the following and require explicit confirmation:

```
You are about to destroy the full stack for cluster <CLUSTER_NAME>:

  Stage 06 — GPU operator (Helm):          helm uninstall
  Stage 05 — Blob storage:                 terraform destroy
  Stage 04 — ACR:                          terraform destroy
  Stage 03 — AKS node pools:              terraform destroy
  Stage 02 — AKS cluster:                 terraform destroy
  Stage 01 — IAM + VNet (RG):             terraform destroy  ⚠ deletes the Resource Group

⚠ WARNING: ACR and Storage Account have prevent_destroy = true. See note below before proceeding.

Type the cluster name to confirm:
```

Only proceed if the user types the cluster name exactly.

### prevent_destroy caveat

`iam-vpc` sets `prevent_destroy = true` on the Resource Group. `acr` and `blob-storage` set it on the ACR and Storage Account respectively (data-bearing resources). Running `terraform destroy` on these modules will fail with a lifecycle error until the block is removed.

Before destroying those modules, either:
- Temporarily comment out the `lifecycle { prevent_destroy = true }` block in the relevant `.tf` file and re-run `terraform apply` to update state, then destroy; or
- Remove the resource from state first: `terraform -chdir=generated/<cluster>/<skill> state rm <resource_address>` and delete manually via `az`.

Surface this to the user before running destroy on stages 05, 04, and 01.

### Destroy sequence

Run in reverse order. Stop on failure for stages 05–02 (hard errors indicate a resource may still have dependents). Stage 01 (RG delete) cascades everything — confirm it last.

```bash
# Stage 06 — GPU operator (Helm, not Terraform)
helm uninstall gpu-operator -n gpu-operator --wait --timeout=5m || true
kubectl delete namespace gpu-operator --ignore-not-found

# Stage 05 — Blob storage
terraform -chdir=generated/<cluster>/blob-storage destroy -auto-approve

# Stage 04 — ACR
terraform -chdir=generated/<cluster>/acr destroy -auto-approve

# Stage 03 — AKS node pools
terraform -chdir=generated/<cluster>/aks-nodes destroy -auto-approve

# Stage 02 — AKS cluster
terraform -chdir=generated/<cluster>/aks-cluster destroy -auto-approve

# Stage 01 — IAM + VNet + RG (cascades the MC_ node RG too)
terraform -chdir=generated/<cluster>/iam-vpc destroy -auto-approve
```

Stage 07 (validate) is read-only — nothing to destroy.

After all stages complete, print:

```
Stack for <CLUSTER_NAME> destroyed.

  stage06 — GPU operator:   removed (Helm)
  stage05 — Blob storage:   destroyed
  stage04 — ACR:            destroyed
  stage03 — Node pools:     destroyed
  stage02 — AKS cluster:    destroyed
  stage01 — IAM + VNet:     destroyed (RG deleted)
```

## Optional add-ons (out of scope here)

`azure-base` is foundation-only. The post-foundation chain in order:

| # | Task | Skill |
|---|---|---|
| 1 | Bulk-mirror NGC images (and optionally helm charts) into the ACR | [`acr-mirror`](../acr-mirror/SKILL.md) (this repo, post-foundation) |
| 2 | Install NVCF self-managed prerequisites (KAI Scheduler, SMB CSI) | `nvcf/ai-tooling/user/skills/nvcf-self-managed-prerequisite` |
| 3 | Install NVCF self-managed stack (NATS, OpenBao, Cassandra, NVCF API) | `nvcf/ai-tooling/user/skills/nvcf-self-managed-installation` |
| 4 | Install NVCA operator | `nvcf/ai-tooling/user/skills/nvcf-self-managed-installation` (Section 7 — opt-in) |
| 5+ | Caches, LLS, function deploy/invoke | Upstream `nvcf/nvcf` (skills landing as the NVCF team factors them out) |

## Validation checklist

This skill is a thin orchestrator. Validation defers to each child skill's own checklist. Additional checks specific to the orchestrator:

- [ ] Stage 02 writes `generated/<cluster>/aks-cluster/`
- [ ] Stage 02 writes `generated/.env.aks-cluster` from Terraform outputs after apply
- [ ] Stages 01 and 03–07 write stage-prefixed scripts to `generated/`
- [ ] `streaming-env.sh` exists before any stage script is generated; if absent, it was copied from `streaming-env.sh.example` with mode 600
- [ ] Missing required variables were prompted for in **one batched message**, not one at a time
- [ ] Variables that already had a value were NOT re-prompted
- [ ] `RESOURCE_GROUP` and `VNET_NAME` were not prompted for — they derive from `CLUSTER_NAME`
- [ ] User-provided values were written back via `sed -i.bak` so comments and structure are preserved
- [ ] `NGC_API_KEY_FILE` was treated as a path-only input — the key value itself was never asked for or displayed
- [ ] Format violations (ACR name with hyphens, `/32` in `AUTHORIZED_IP_RANGES`, wrong AAD object-ID shape) were caught and surfaced before generation continued
- [ ] `streaming-env.sh` was read once and the same values flow into every stage
- [ ] When `OVDC_REPLICAS > 0`, the OVDC capacity inputs flow unchanged to
      stages 03 and 07, and the compute pool is enabled rather than using GPU
      nodes as fallback capacity
- [ ] Mode was detected from user intent and confirmed before generating
- [ ] Ambiguous wording such as "set up an AKS cluster for me" maps to generate mode unless explicit execution language is present
- [ ] **Generate mode:** run-order summary printed after all bootstrap artifacts are written
- [ ] **Deploy mode:** stages 01–06 execute sequentially with stop-on-failure; stage 07 always runs if 01–06 succeeded, and its non-zero exit is reported but does NOT cause the orchestrator to fail
- [ ] **Terraform destroy mode:** only triggered by explicit teardown language; cluster name confirmation prompt shown before any destroy runs; `prevent_destroy` caveat surfaced for stages 01, 04, 05; destroy runs in reverse order (06→01); stage 07 skipped

## References

| Topic | Source |
|---|---|
| Pattern: stage-prefixed orchestrator | [infra-as-doc/cluster-bootstrap](../../../../infra-as-doc/cluster-bootstrap/SKILL.md) |
| Single env source | [streaming-env.sh.example](../../../streaming-env.sh.example) |
