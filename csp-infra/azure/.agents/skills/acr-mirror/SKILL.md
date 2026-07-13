---
name: acr-mirror
description: Generates a bash script that bulk-mirrors NVCF images (and optionally helm charts) from NGC to Azure Container Registry by iterating an `image-manifest/manifest.yaml` SBOM. Resolves the NGC source path **per manifest group** from a built-in mapping table that mirrors `image-manifest/source-registry-config.yaml` (see the per-group source mapping below), overridable per-group via `streaming-env.sh`. Two emit modes — `regsync` (declarative, idempotent, parallel; preferred) or `az acr import` loop (no extra deps). Handles scalar and list tag values, skips `helm-*` keys for the image pass, and applies the `<acr>.azurecr.io/<sub-path>/<image>:<tag>` convention so NVCF helm charts (which concatenate `<registry>/<repository>/<image>`) don't render double-slash paths. Use after the `acr` foundation skill has provisioned the ACR and before `nvcf-self-managed-installation`. Trigger when the user mentions "mirror images", "populate ACR", "regsync", "az acr import", "NGC → ACR", "bulk mirror", "image-manifest sync", or "sync NVCF SBOM to ACR".
---

<!-- SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved. -->
<!-- SPDX-License-Identifier: CC-BY-4.0 AND Apache-2.0 -->

# Bulk mirror NGC → ACR

## What this skill produces

A self-contained bash script that:

1. Locates the NVCF image-manifest SBOM (`image-manifest/manifest.yaml` at the repo root of a streaming-staging clone) — see [Manifest sources](#manifest-sources) for how this works from a streaming-staging clone vs an azure-base-only checkout.
2. Iterates the `nvcf-self-managed-stack` group, emitting one mirror entry per `image:tag` pair.
3. Skips chart artifacts (keys prefixed `helm-`) for the image pass. Mirroring them is covered in [Helm chart mirroring](#helm-chart-mirroring-optional).
4. Handles both scalar values (`bitnami-cassandra: 5.0.6-nv-1`) and list values (`nvcf-openbao: [2.2.2-nv-1, 2.5.1-nv-1.1.0]` during upgrade transitions).
5. Writes either a `regsync.yaml` + run command (default), or a loop of `az acr import` commands.

This skill is the operational counterpart to [`acr`](../acr/SKILL.md): `acr` creates the registry; `acr-mirror` populates it.

## When to use it

In the [`aks-bootstrap`](../aks-bootstrap/SKILL.md) flow, this is **stage 04b** — runs after `acr` (stage 04) creates the registry and before `nvcf-self-managed-installation` (post-foundation) installs the helmfile bundle, because that install tries to pull images from `<acr>.azurecr.io/<repo>/...`.

It is *not* part of the mandatory `aks-bootstrap` cycle — bootstrap is foundation-only. Mirroring is the first post-foundation step.

## Inputs

Sourced from `streaming-env.sh` and the upstream stages' `generated/.env.*` files.

**Required:**

| Variable | Description | Example |
|---|---|---|
| `ACR_NAME` | Target ACR (from `streaming-env.sh`) | `acrnvcftestwestus3` |
| `NGC_API_KEY_FILE` | Path to a mode-600 file containing the raw NGC API key | `$HOME/.nvcf-secrets/ngc-api-key` |

**Optional (firm defaults):**

| Variable | Description | Default |
|---|---|---|
| `MANIFEST_PATH` | Path to `manifest.yaml`. See [Manifest sources](#manifest-sources). | `${REPO_ROOT}/image-manifest/manifest.yaml` |
| `MANIFEST_REF` | Used only when `FETCH_FROM_GITLAB=true` — tag or SHA of the manifest commit to fetch | `main` |
| `FETCH_FROM_GITLAB` | If `true` and `MANIFEST_PATH` doesn't exist, fetch the manifest from `omniverse/ovonsm/image-manifest` via the GitLab API. Requires `GITLAB_TOKEN`. | `false` |
| `NGC_SOURCE_REGISTRY` | Source registry host | `nvcr.io` |
| `TARGET_REPOSITORY` | Sub-path under the ACR. **Never empty** — see [Why the sub-path matters](#why-the-sub-path-matters). Defaults to `${CLUSTER_NAME}` so multiple deployments sharing one ACR don't collide. | `${CLUSTER_NAME}` |
| `INCLUDE_GROUPS` | Comma-separated manifest groups to mirror (subset filter). Empty = all non-metadata groups. | (all) |
| `NGC_SOURCE_REPO_<GROUP>` | Per-group override for the NGC source path. Group hyphens become underscores in the env var name (e.g. `NGC_SOURCE_REPO_nvcf_self_managed_stack`). See [Per-group source mapping](#per-group-source-mapping) for built-in defaults. | (defaults below) |
| `MIRROR_TOOL` | `regsync` (recommended) or `az_acr_import` | `regsync` |
| `INCLUDE_HELM_CHARTS` | Also mirror `helm-*` chart artifacts (OCI helm) | `false` |
| `SKIP_KEYS` | Comma-separated manifest keys to skip **by name** — entries that are not OCI artifacts and 404 if mirrored. The skill can't read `component_type` at runtime (`versions.yaml`, which carries it, isn't shipped beside `manifest.yaml`), so this is a hand-maintained list. Default `nvcf-stack` is `component_type: package` upstream (an SBOM umbrella label). | `nvcf-stack` |
| `DRY_RUN` | Skip the actual push; emit the config and print what would be mirrored | `false` |

## Per-group source mapping

The skill ships with these defaults for every group currently in `manifest.yaml`:

| Manifest group | Default NGC source path (under `nvcr.io/`) |
|---|---|
| `nvcf-self-managed-stack` | `0651155215864979/ncp-dev` |
| `nvcf-compute-plane-stack` | `0651155215864979/ncp-dev` |
| `container_cache` | `0651155215864979/ncp-dev` |
| `gxcache` | `0833294136851237/nvcf-ncp-staging` |
| `lls` | `0795883928596950` |
| `ucc` | `nvidia/omniverse` |
| `ddcs` | `nvidia/omniverse` |
| `storage-api` | `nvidia/omniverse` |

These mirror `image-manifest/source-registry-config.yaml` (the deployment source of truth) — group keys match `manifest.yaml` exactly (`container_cache`, not `caches`). A group present in the manifest but absent from this map is a hard error, not a silent skip; use `INCLUDE_GROUPS` to scope a partial run.

**To override per-group:** set `NGC_SOURCE_REPO_<GROUP>` in `streaming-env.sh`, replacing hyphens with underscores. Example:

```bash
# In streaming-env.sh
export NGC_SOURCE_REPO_nvcf_self_managed_stack="0833294136851237/some-other-team"
export NGC_SOURCE_REPO_storage_api="nvidia/something-else"
```

A group that's in the manifest but missing from both the built-in defaults AND any override produces a `WARN` and is skipped — the script doesn't fail, so unknown future groups don't break existing mirrors. Set the env var to include them.

### Multiple NGC source orgs — one key may not cover them all

The groups source from **more than one NGC org** (see the per-group source table above for the current paths). The mirror authenticates to `nvcr.io` with a single `NGC_API_KEY`, and access to **private** orgs is membership-scoped: if the key's NGC user isn't a member of a private source org, the pull returns `403 Forbidden` for that org — which looks like a bad or expired key but is actually an org-access gap, and is easy to lose hours to.

**Public orgs don't gate on membership.** Some groups source from a public NGC org, where any valid NGC key resolves the images — it's the authenticated token that matters, not org membership. Only the **private** source orgs require membership, so a key that belongs to the private org you source the control-plane groups from will *also* pull the public-org groups.

Consequences:

1. **Usually one key is enough:** a key whose user is a member of the **private** org(s) the manifest sources from covers everything, public-org groups included. Point `NGC_API_KEY_FILE` at it.
2. **Two private orgs need per-org passes:** the multi-key problem only bites when the manifest spans **two private orgs that no single key is a member of both** (e.g. the key belongs to one private org but a group is sourced from a different private org — the failure in the bug). Then run the mirror once per private org — `INCLUDE_GROUPS` to that org's groups, `NGC_API_KEY_FILE` to that org's key:
   ```bash
   # Pass 1 — groups sourced from private org A, using org A's key
   INCLUDE_GROUPS="<groups-for-org-A>" NGC_API_KEY_FILE=~/.nvcf-secrets/ngc-key-A ./<script>.sh
   # Pass 2 — groups sourced from private org B, using org B's key
   INCLUDE_GROUPS="<groups-for-org-B>" NGC_API_KEY_FILE=~/.nvcf-secrets/ngc-key-B ./<script>.sh
   # (Public-org groups can ride along in any pass — any valid key pulls them.)
   ```

This applies only to the **mirror step** (which pulls *from* NGC). Once everything lands in the one ACR, the split disappears for the *cluster*: `AcrPull` node identity authenticates all pulls, so no per-org pull secrets are needed in-cluster.

## Outputs

- **Bash:** `generated/stageNN-<cluster-name>-acr-mirror.sh` (NN = next available stage number in the deployment cycle; commonly 04b or 08).
- **regsync config (when `MIRROR_TOOL=regsync`):** `generated/regsync.yaml` — emitted at script runtime; consumed by `regsync once -c generated/regsync.yaml`.

The script does NOT write a `.env.acr-mirror` file because nothing downstream consumes its outputs — successful exit is the signal. It does print a final tally line (`mirrored N images, M charts`) and (in `DRY_RUN=true`) the list of pairs without executing.

## Manifest sources

Two scenarios, in priority order:

### From a streaming-staging clone

`image-manifest/manifest.yaml` ships at the repo root, pre-synced from `omniverse/ovonsm/image-manifest` (alongside a `COMMIT` file for provenance and `source-registry-config.yaml`). The default `MANIFEST_PATH=${REPO_ROOT}/image-manifest/manifest.yaml` resolves correctly. To advance to a newer manifest, pin a different streaming-staging tag/SHA and `git pull`.

### From an azure-base-only checkout

No manifest ships with azure-base. Two options:

1. Set `MANIFEST_PATH` in `streaming-env.sh` to a local manifest checkout (e.g., a sibling clone of `omniverse/ovonsm/image-manifest`).
2. Set `FETCH_FROM_GITLAB=true` and provide `GITLAB_TOKEN`. The script fetches the manifest from the GitLab API at `MANIFEST_REF` — equivalent to what [streaming-staging's `sync-nvcf.sh`](../../../streaming-staging/sync-nvcf.sh) does, but at deploy time.

The script echoes `manifest source: <path>` and the `version` / `generated_at` fields so the source is auditable from logs.

## Why the sub-path matters

Two reasons the sub-path cannot be empty or static:

1. **Empty breaks helm pulls.** NVCF helm charts concatenate `<registry>/<repository>/<image>:<tag>`. The helmfile env file's `global.image.repository` is set to match `TARGET_REPOSITORY`. If `TARGET_REPOSITORY` is empty, the chart renders `<acr>.azurecr.io//<image>:<tag>` (double slash), which `docker pull` and many container runtimes reject.
2. **A static sub-path collides across deployments.** When two clusters share one ACR (team registry, prod ACR, dev/staging side-by-side), both mirroring to `<acr>/nvcf/<image>:<tag>` race to overwrite tags — last write wins, and if the two manifest commits pin different versions of the same image, one cluster pulls the wrong tag.

The default `${CLUSTER_NAME}` gives every deployment its own namespace under the ACR. After mirror, set in the helmfile env file:

```yaml
global:
  image:
    registry: <acr>.azurecr.io                 # not nvcr.io
    repository: aks-nvcf-validation-westus3    # matches TARGET_REPOSITORY (= ${CLUSTER_NAME})
  helm:
    sources:
      registry: <acr>.azurecr.io
      repository: aks-nvcf-validation-westus3
```

(See [`nvcf/nvcf-self-managed-stack/environments/base.yaml`](../../../streaming-staging/nvcf/nvcf-self-managed-stack/environments/base.yaml) for the placeholder values that must be replaced.)

**No image-pull secret needed once you point at the ACR.** The [`acr`](../acr/SKILL.md) skill granted the AKS kubelet identity `AcrPull` on this registry, so a pull from `<acr>.azurecr.io/...` is authenticated by the **node identity**. Once `global.image` and `global.helm.sources` point at the ACR you can **drop** the entire NGC pull-secret apparatus the NGC-direct path requires: the per-namespace `nvcr-pull-secret`, the `global.imagePullSecrets` entry, and the `docker login`/`helm registry login nvcr.io` steps. This also removes the multi-org pull-secret problem (function pods otherwise pull several nvcr.io orgs, each needing a different key) — everything is one AcrPull-authenticated registry. See the "Pull from a registry mirror (ACR/ECR)" section of the `nvcf-self-managed-installation` skill for the consumer-side env + step changes.

Override `TARGET_REPOSITORY` only when the ACR has an existing namespacing convention (e.g., `prod/<release-name>`) or when multiple deployments must share tags.

## Manifest schema (consumed by this skill)

```yaml
version: '1.0'
generated_at: '2026-05-28T22:34:11Z'
nvcf-self-managed-stack:
  bitnami-cassandra: 5.0.6-nv-1                       # scalar
  nvcf-openbao:                                       # list (upgrade transition; rare)
    - 2.2.2-nv-1
    - 2.5.1-nv-1.1.0
  helm-nvcf-cassandra: 0.11.1                         # chart artifact — skipped in image pass
gxcache:
  gxcache-init: 1e47f722
  gxcache-service: b206ce39
  helm-gxcache: 0.8.2
lls:
  gdn-streaming: 2.0.1
  streaming-proxy: 2.0.1
storage-api:
  helm-discovery-service: 2.3.8
  storage-service: 1.0.2
# ... etc. (ucc, ddcs)
```

Generation rules:
- Top-level meta keys (`version`, `generated_at`) are not groups — skip.
- Every other top-level key is a group. Resolve its NGC source path via the [per-group mapping](#per-group-source-mapping) (built-in default or env override).
- Within each group:
  - Keys starting with `helm-` are OCI helm charts. **Skip in the image pass.** If `INCLUDE_HELM_CHARTS=true`, mirror them via OCI helm push (see [Helm chart mirroring](#helm-chart-mirroring-optional)).
  - All other keys are container images. The key IS the image name.
  - The value is either a string tag (scalar) or a list of tags. Mirror each tag separately.

## Bash snippet (reference)

```bash
#!/bin/bash
set -euo pipefail

# Resolve repo root from script location — works regardless of CWD.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$REPO_ROOT/streaming-env.sh"
if [[ ! -f "$REPO_ROOT/generated/.env.acr" ]]; then
  echo "ERROR: $REPO_ROOT/generated/.env.acr not found. Run the acr skill (stage 04) first." >&2
  exit 1
fi
source "$REPO_ROOT/generated/.env.acr"

: "${ACR_NAME:?}" "${NGC_API_KEY_FILE:?}"
[[ -f "$NGC_API_KEY_FILE" ]] || { echo "ERROR: NGC_API_KEY_FILE='$NGC_API_KEY_FILE' is not a file" >&2; exit 1; }

NGC_SOURCE_REGISTRY="${NGC_SOURCE_REGISTRY:-nvcr.io}"
TARGET_REPOSITORY="${TARGET_REPOSITORY:-$CLUSTER_NAME}"
[[ -n "$TARGET_REPOSITORY" ]] || { echo "ERROR: TARGET_REPOSITORY is empty (no CLUSTER_NAME fallback). Set it in streaming-env.sh." >&2; exit 1; }
MIRROR_TOOL="${MIRROR_TOOL:-regsync}"
INCLUDE_HELM_CHARTS="${INCLUDE_HELM_CHARTS:-false}"
DRY_RUN="${DRY_RUN:-false}"
# Manifest keys to skip BY NAME because they are not OCI artifacts and 404 if
# mirrored. This is a hand-maintained deny-list, NOT a type lookup: the skill
# can't see component_type at runtime — versions.yaml (which carries it) is not
# shipped beside manifest.yaml. The default, nvcf-stack, is component_type:
# package upstream (an SBOM umbrella label). Durable fix: have the aggregator
# emit component_type into manifest.yaml so the type can be read directly.
SKIP_KEYS="${SKIP_KEYS:-nvcf-stack}"
IFS=',' read -ra SKIP_KEYS_ARR <<< "$SKIP_KEYS"
MANIFEST_PATH="${MANIFEST_PATH:-$REPO_ROOT/image-manifest/manifest.yaml}"

# Temp paths allocated lazily below. Single cleanup trap covers both the
# fetched-manifest tempfile and the helm-charts tempdir so concurrent script
# runs cannot collide on shared /tmp paths.
FETCHED_MANIFEST=""
CHARTS_DIR=""
cleanup() {
  [[ -n "$FETCHED_MANIFEST" && -f "$FETCHED_MANIFEST" ]] && rm -f "$FETCHED_MANIFEST"
  [[ -n "$CHARTS_DIR" && -d "$CHARTS_DIR" ]] && rm -rf "$CHARTS_DIR"
  # Always succeed: as the last command in an EXIT trap, a short-circuited &&
  # guard (e.g. both paths empty in a default run) would otherwise set the
  # script's exit status to 1 after a fully successful mirror.
  return 0
}
trap cleanup EXIT

# Per-group NGC source path defaults. Override per-group via env vars named
# NGC_SOURCE_REPO_<group> with hyphens replaced by underscores (e.g.
# NGC_SOURCE_REPO_nvcf_self_managed_stack). A group with no default and no
# override emits a WARN and is skipped — the script still mirrors the rest.
# Mirrors image-manifest/source-registry-config.yaml (the source of truth).
# Keys are the manifest group names exactly as they appear in manifest.yaml
# (e.g. container_cache, not caches).
declare -A DEFAULT_SOURCE_REPO=(
  ["nvcf-self-managed-stack"]="0651155215864979/ncp-dev"
  ["nvcf-compute-plane-stack"]="0651155215864979/ncp-dev"
  ["container_cache"]="0651155215864979/ncp-dev"
  ["gxcache"]="0833294136851237/nvcf-ncp-staging"
  ["lls"]="0795883928596950"
  ["ucc"]="nvidia/omniverse"
  ["ddcs"]="nvidia/omniverse"
  ["storage-api"]="nvidia/omniverse"
)
resolve_source_repo() {
  local group="$1" var="NGC_SOURCE_REPO_${1//-/_}"
  printf '%s' "${!var:-${DEFAULT_SOURCE_REPO[$group]:-}}"
}

# Resolve manifest — local first, then optionally fetch from GitLab.
if [[ ! -f "$MANIFEST_PATH" ]]; then
  if [[ "${FETCH_FROM_GITLAB:-false}" == "true" ]]; then
    : "${GITLAB_TOKEN:?required when FETCH_FROM_GITLAB=true}"
    MANIFEST_REF="${MANIFEST_REF:-main}"
    echo "--- Fetching manifest from upstream (ref=$MANIFEST_REF) ---"
    FETCHED_MANIFEST=$(mktemp -t acr-mirror-manifest.XXXXXX)
    curl -fsSL -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
      "https://gitlab-master.nvidia.com/api/v4/projects/omniverse%2Fovonsm%2Fimage-manifest/repository/files/manifest.yaml/raw?ref=${MANIFEST_REF}" \
      -o "$FETCHED_MANIFEST"
    MANIFEST_PATH="$FETCHED_MANIFEST"
  else
    echo "ERROR: manifest not found at $MANIFEST_PATH" >&2
    echo "  Either: (a) run from a streaming-staging clone (ships image-manifest/manifest.yaml at repo root)," >&2
    echo "          (b) set MANIFEST_PATH in streaming-env.sh to a local manifest checkout, or" >&2
    echo "          (c) set FETCH_FROM_GITLAB=true + GITLAB_TOKEN to fetch from upstream." >&2
    exit 1
  fi
fi

command -v yq >/dev/null  || { echo "ERROR: yq required" >&2; exit 1; }
# The enumeration queries below are written for mikefarah yq v4 (the QA/repo
# toolchain). The jq-wrapper yq (python/kislyuk) uses incompatible expression
# syntax, so fail clearly rather than emit a confusing lexer error mid-run.
yq --version 2>&1 | grep -qi mikefarah || {
  echo "ERROR: this script targets mikefarah yq v4 (https://github.com/mikefarah/yq)." >&2
  echo "       Found: $(yq --version 2>&1). Install mikefarah yq and re-run." >&2
  exit 1
}
echo "--- Manifest source: $MANIFEST_PATH ---"
yq -r '"  version: " + .version + "  generated_at: " + .generated_at' "$MANIFEST_PATH"

# Collect groups (top-level keys minus metadata).
mapfile -t ALL_GROUPS < <(yq -r 'keys | .[] | select(. != "version" and . != "generated_at")' "$MANIFEST_PATH")

# Apply INCLUDE_GROUPS filter if set.
# NB: do NOT name this array GROUPS — bash auto-populates a special array of
# that name with the caller's supplementary group IDs; assignments to it are
# dropped, so the loop would iterate GIDs and mirror nothing.
if [[ -n "${INCLUDE_GROUPS:-}" ]]; then
  IFS=',' read -ra REQUESTED <<< "$INCLUDE_GROUPS"
  SELECTED_GROUPS=()
  for g in "${ALL_GROUPS[@]}"; do
    for r in "${REQUESTED[@]}"; do [[ "$g" == "$r" ]] && SELECTED_GROUPS+=("$g") && break; done
  done
else
  SELECTED_GROUPS=("${ALL_GROUPS[@]}")
fi
echo "--- Groups to process: ${SELECTED_GROUPS[*]} ---"

# Auth.
echo "--- Authenticating to ACR ---"
az acr login --name "$ACR_NAME"
if [[ "$INCLUDE_HELM_CHARTS" == "true" ]]; then
  echo "--- Authenticating to NGC for helm OCI ---"
  helm registry login "$NGC_SOURCE_REGISTRY" -u '$oauthtoken' --password-stdin < "$NGC_API_KEY_FILE"
fi

# Build the flat list of (group, image, tag, source-repo) tuples, skipping
# helm-* keys (charts handled separately).
TUPLES=()  # "<group>\t<image>\t<tag>\t<source-repo>"
for group in "${SELECTED_GROUPS[@]}"; do
  source_repo=$(resolve_source_repo "$group")
  if [[ -z "$source_repo" ]]; then
    # Hard-fail rather than WARN-skip: a silent skip drops a whole group's
    # images and only surfaces later as ImagePullBackOff. If a group is
    # intentionally excluded, use INCLUDE_GROUPS instead.
    echo "ERROR: no NGC source path for group '$group'. Add it to DEFAULT_SOURCE_REPO or set NGC_SOURCE_REPO_${group//-/_}; use INCLUDE_GROUPS to scope the run." >&2
    exit 1
  fi
  while IFS= read -r pair; do
    image="${pair%%:*}"; tag="${pair#*:}"
    skip=""; for s in "${SKIP_KEYS_ARR[@]}"; do [[ "$image" == "$s" ]] && skip=1 && break; done
    if [[ -n "$skip" ]]; then
      echo "SKIP: $group/$image (non-OCI / package artifact, not mirrorable)" >&2
      continue
    fi
    TUPLES+=("${group}\t${image}\t${tag}\t${source_repo}")
  done < <(yq -r "
    .\"$group\"
    | to_entries
    | .[]
    | select(.key | test(\"^helm-\") | not)
    | .key as \$name
    | (.value | [.] | flatten | .[]) as \$tag
    | \$name + \":\" + \$tag
  " "$MANIFEST_PATH")
done
echo "--- ${#TUPLES[@]} image:tag pairs to mirror ---"
# A silent no-op (0 pairs) is the dangerous failure mode — a later ACR-backed
# install then fails with ImagePullBackOff while this step looked successful.
# Fail loudly instead, unless the operator deliberately filtered to nothing.
if [[ "${#TUPLES[@]}" -eq 0 && -z "${INCLUDE_GROUPS:-}" ]]; then
  echo "ERROR: resolved 0 image:tag pairs from $MANIFEST_PATH — nothing to mirror." >&2
  echo "       Check the manifest has non-helm image keys and that yq enumerated them." >&2
  exit 1
fi

if [[ "$MIRROR_TOOL" == "regsync" ]]; then
  mkdir -p "$REPO_ROOT/generated"
  CONFIG="$REPO_ROOT/generated/regsync.yaml"
  {
    cat <<EOF
version: 1
creds:
  # repoAuth: true forces per-repo auth. NGC's namespace returns a fresh
  # auth challenge per repo; the cached-token path mishandles this with
  # "invalid challenge header".
  - registry: ${NGC_SOURCE_REGISTRY}
    user: \$oauthtoken
    pass: '{{env "NGC_API_KEY"}}'
    repoAuth: true
  - registry: ${ACR_NAME}.azurecr.io
defaults:
  parallel: 4
sync:
EOF
    for tuple in "${TUPLES[@]}"; do
      IFS=$'\t' read -r group image tag source_repo <<< "$(printf '%b' "$tuple")"
      cat <<EOF
  - source: ${NGC_SOURCE_REGISTRY}/${source_repo}/${image}:${tag}
    target: ${ACR_NAME}.azurecr.io/${TARGET_REPOSITORY}/${image}:${tag}
    type: image
EOF
    done
  } > "$CONFIG"
  echo "  wrote $CONFIG"

  command -v regsync >/dev/null || { echo "ERROR: regsync required (brew install regclient)"; exit 1; }
  export NGC_API_KEY
  NGC_API_KEY="$(< "$NGC_API_KEY_FILE")"; NGC_API_KEY="${NGC_API_KEY%$'\n'}"
  if [[ "$DRY_RUN" == "true" ]]; then regsync check -c "$CONFIG"; else regsync once -c "$CONFIG"; fi
  unset NGC_API_KEY

elif [[ "$MIRROR_TOOL" == "az_acr_import" ]]; then
  # No extra binary needed; sequential and slower (no parallelism).
  for tuple in "${TUPLES[@]}"; do
    IFS=$'\t' read -r group image tag source_repo <<< "$(printf '%b' "$tuple")"
    src="${NGC_SOURCE_REGISTRY}/${source_repo}/${image}:${tag}"
    dst="${TARGET_REPOSITORY}/${image}:${tag}"
    if [[ "$DRY_RUN" == "true" ]]; then
      echo "  DRY: az acr import --source $src --image $dst   (group=$group)"
    else
      echo "  [$group] $src → $dst"
      az acr import --name "$ACR_NAME" \
        --source "$src" --image "$dst" \
        --username '$oauthtoken' --password "$(< "$NGC_API_KEY_FILE")" \
        --only-show-errors
    fi
  done
else
  echo "ERROR: unknown MIRROR_TOOL='$MIRROR_TOOL' (use regsync or az_acr_import)" >&2
  exit 1
fi

# Helm charts (optional). Same per-group source resolution as for images.
if [[ "$INCLUDE_HELM_CHARTS" == "true" ]]; then
  echo "--- Mirroring helm charts (OCI) ---"
  CHARTS_DIR=$(mktemp -d -t acr-mirror-charts.XXXXXX)
  for group in "${SELECTED_GROUPS[@]}"; do
    source_repo=$(resolve_source_repo "$group"); [[ -z "$source_repo" ]] && continue
    while IFS= read -r pair; do
      chart="${pair%%:*}"; tag="${pair#*:}"
      if [[ "$DRY_RUN" == "true" ]]; then
        echo "  DRY: [$group] pull oci://${NGC_SOURCE_REGISTRY}/${source_repo}/${chart}:${tag} → push oci://${ACR_NAME}.azurecr.io/${TARGET_REPOSITORY}"
      else
        helm pull "oci://${NGC_SOURCE_REGISTRY}/${source_repo}/${chart}" --version "$tag" -d "$CHARTS_DIR"
        helm push "$CHARTS_DIR/${chart}-${tag}.tgz" "oci://${ACR_NAME}.azurecr.io/${TARGET_REPOSITORY}"
        rm -f "$CHARTS_DIR/${chart}-${tag}.tgz"
      fi
    done < <(yq -r "
      .\"$group\"
      | to_entries
      | .[]
      | select(.key | test(\"^helm-\"))
      | .key as \$name
      | (.value | [.] | flatten | .[]) as \$tag
      | \$name + \":\" + \$tag
    " "$MANIFEST_PATH")
  done
fi

echo "--- Done. Verify: az acr repository list --name $ACR_NAME --output table ---"
```

## Helm chart mirroring (optional)

Charts in the manifest are keys prefixed `helm-` (e.g., `helm-nvcf-cassandra: 0.11.1`). They are **OCI helm artifacts** at the source — they need `helm pull` + `helm push`, not `regsync` or `az acr import`. The script above handles this when `INCLUDE_HELM_CHARTS=true`.

Why optional: if the cluster has outbound access to `nvcr.io` and a working NGC auth secret, the helmfile install pulls charts directly from NGC at install time — no mirror needed. Mirror them only for **full air-gap** where the cluster must not reach `nvcr.io`.

When mirroring charts, update the helmfile env file:

```yaml
global:
  helm:
    sources:
      registry: <acr>.azurecr.io
      repository: <target-repository>   # same sub-path as the images
```

## Verification

After mirror, spot-check:

```bash
# Image:tag count vs SBOM (across all groups; same exclusion as the mirror — skip helm-*).
# Both counts are at the tag level — an image with 2 tags (e.g. nvcf-openbao
# during an upgrade transition) contributes 2 to each side.
SBOM_COUNT=$(yq -r '
  to_entries | .[]
  | select(.key != "version" and .key != "generated_at")
  | .value | to_entries | .[]
  | select(.key | test("^helm-") | not)
  | (.value | [.] | flatten | .[])
  | "x"
' "$MANIFEST_PATH" | wc -l | tr -d ' ')

ACR_COUNT=0
while IFS= read -r repo; do
  [[ -z "$repo" ]] && continue
  tag_count=$(az acr repository show-tags --name "$ACR_NAME" --repository "$repo" -o tsv 2>/dev/null | wc -l | tr -d ' ')
  ACR_COUNT=$((ACR_COUNT + tag_count))
done < <(az acr repository list --name "$ACR_NAME" -o tsv | grep "^${TARGET_REPOSITORY}/")

echo "SBOM expects: $SBOM_COUNT image:tag pair(s)  /  ACR has: $ACR_COUNT under ${TARGET_REPOSITORY}/"

# Spot-check a tag from any group
az acr repository show-tags --name "$ACR_NAME" --repository "${TARGET_REPOSITORY}/bitnami-cassandra" -o tsv
```

If counts diverge, re-run with `DRY_RUN=true` to inspect the planned sync list (each entry is prefixed with its `[group]`), then re-run for real.

## Teardown

Mirror state is just data in ACR. Either:
- `az acr repository delete --name "$ACR_NAME" --repository "<sub-path>/<image>" --yes` per image (when retiring specific images), or
- Let the ACR itself be torn down by the `acr` skill's `--teardown` (which destroys the registry and everything in it).

There is no `acr-mirror --teardown` because the deliberate destructive action lives in the foundation skill.

## Validation checklist

- [ ] Script opens with `set -euo pipefail` and resolves repo root via `BASH_SOURCE`
- [ ] Sources `streaming-env.sh` and `.env.acr` (guard: error if stage 04 hasn't run)
- [ ] Required vars (`ACR_NAME`, `NGC_API_KEY_FILE`) have fail-fast checks; no other required inputs
- [ ] `NGC_API_KEY_FILE` is verified to be a file (`[[ -f ]]`) before any redirection — the leak-postmortem pattern from earlier in this project
- [ ] `DEFAULT_SOURCE_REPO` table is present and covers every group currently in `manifest.yaml` (nvcf-self-managed-stack, nvcf-compute-plane-stack, container_cache, gxcache, lls, ucc, ddcs, storage-api) and matches `source-registry-config.yaml`
- [ ] An unmapped non-metadata group is a hard error (exit 1), not a WARN-skip
- [ ] `cleanup()` ends with `return 0` so the EXIT trap can't fail a successful run
- [ ] `resolve_source_repo` honors per-group env override (`NGC_SOURCE_REPO_<GROUP>` with hyphens→underscores) before falling back to the default table
- [ ] Unknown groups emit `WARN` and are skipped — the script does NOT fail on them
- [ ] Manifest path resolves with the streaming-staging-clone default; fallback to GitLab fetch is gated behind `FETCH_FROM_GITLAB=true`
- [ ] Tempfiles for the fetched manifest and helm-charts directory are allocated via `mktemp` / `mktemp -d` (never fixed `/tmp/<name>` paths) and a single `trap cleanup EXIT` removes them on every exit path — safe under concurrent runs
- [ ] Manifest provenance is echoed (`version`, `generated_at`) for audit
- [ ] Top-level metadata keys (`version`, `generated_at`) are NOT treated as groups
- [ ] `INCLUDE_GROUPS` filter (comma-separated) subsets the groups when set
- [ ] `SKIP_KEYS` (default `nvcf-stack`) drops non-OCI `package`-type keys from the image pass with a logged note
- [ ] `helm-*` keys are skipped in the image pass
- [ ] Both scalar and list tag values handled (verify against the `nvcf-openbao` upgrade-transition case)
- [ ] `TARGET_REPOSITORY` is non-empty (defaults to `${CLUSTER_NAME}`); explicit fail-fast guards against empty (e.g., if both env var and `CLUSTER_NAME` are unset)
- [ ] "Why the sub-path matters" covers both the double-slash and the multi-deployment collision risk
- [ ] `MIRROR_TOOL=regsync` emits `regsync.yaml` with `repoAuth: true` on the NGC creds entry (NGC's per-repo auth challenge breaks token caching)
- [ ] `MIRROR_TOOL=az_acr_import` works without regsync installed
- [ ] Each generated mirror entry (regsync or az acr import) uses the per-group source repo, not a single hardcoded one
- [ ] `DRY_RUN=true` produces output without pushing anything; output is prefixed with `[group]` so per-group entries are visible
- [ ] `INCLUDE_HELM_CHARTS=true` mirrors OCI helm artifacts via `helm pull` + `helm push`, with the same per-group source resolution
- [ ] Verification snippet (image-count compare across all groups) is documented

## References

| Topic | Source |
|---|---|
| `omniverse/ovonsm/image-manifest` (SBOM authority) | https://gitlab-master.nvidia.com/omniverse/ovonsm/image-manifest |
| Helmfile env placeholder values (where NGC paths are replaced with ACR) | `streaming-staging/nvcf/nvcf-self-managed-stack/environments/base.yaml` |
| Streaming-staging sync script (mirrors the manifest into the bundle) | `streaming-staging/sync-nvcf.sh` |
| regsync (regclient) docs | https://regclient.org/usage/regsync/ |
| `az acr import` | https://learn.microsoft.com/cli/azure/acr#az-acr-import |
| Why per-repo auth (`repoAuth: true`) for NGC | NGC namespace returns fresh challenges per repo; cached token mishandles this |
