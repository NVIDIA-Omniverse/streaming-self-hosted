---
name: acr-mirror
description: Generates a bash script that mirrors manifest-listed NVCF images and optional Helm charts into separate Azure Container Registry namespaces. Resolves source registries, HTTP Helm repositories, chart aliases, and source-only artifacts from `image-manifest/source-registry-config.yaml`; supports regsync or az acr import for images; and rejects target tag collisions before writing to ACR. Use after the `acr` foundation skill and before `nvcf-self-managed-installation`. Trigger for ACR population, NGC-to-ACR mirroring, regsync, az acr import, air-gapped Helm charts, or image-manifest synchronization.
---

<!-- SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved. -->
<!-- SPDX-License-Identifier: CC-BY-4.0 AND Apache-2.0 -->

# Bulk mirror NGC → ACR

## What this skill produces

A self-contained bash script that:

1. Locates the NVCF image-manifest SBOM (`image-manifest/manifest.yaml` at the repo root of a streaming-staging clone) — see [Manifest sources](#manifest-sources) for how this works from a streaming-staging clone vs an azure-base-only checkout.
2. Iterates the selected manifest groups, including `nvcf-observability-stack`, emitting one mirror entry per `image:tag` pair.
3. Sends images and chart artifacts to separate ACR repository prefixes, so an image and chart with the same name and tag cannot overwrite one another.
4. Handles both scalar values (`bitnami-cassandra: 5.0.6-nv-1`) and list values (`nvcf-openbao: [2.2.2-nv-1, 2.5.1-nv-1.1.0]` during upgrade transitions).
5. Writes an inventory and either a `regsync.yaml` + run command (default), or a loop of `az acr import` commands for images; Helm handles OCI and HTTP-sourced charts.
6. Rejects distinct artifacts that resolve to the same ACR repository and tag before authenticating or copying anything.

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
| `SOURCE_REGISTRY_CONFIG` | Source registry resolver. Checks beside `MANIFEST_PATH`, then `.gitlab/source-registry-config.yaml`; fetched with the manifest when `FETCH_FROM_GITLAB=true`. | auto-detected |
| `NGC_SOURCE_REGISTRY` | Source registry host | `nvcr.io` |
| `TARGET_REPOSITORY` | Backward-compatible base ACR repository prefix. Trailing slashes are removed. | `${CLUSTER_NAME}` |
| `TARGET_IMAGE_REPOSITORY` | Repository prefix for container images. Trailing slashes are removed. | `${TARGET_REPOSITORY}` |
| `TARGET_CHART_REPOSITORY` | Separate repository prefix for Helm charts. Trailing slashes are removed and the result must differ from `TARGET_IMAGE_REPOSITORY`. | `${TARGET_REPOSITORY}/charts` |
| `INCLUDE_GROUPS` | Comma-separated manifest groups to mirror (subset filter). Empty = all non-metadata groups. | (all) |
| `NGC_SOURCE_REGISTRY_<GROUP>` / `NGC_SOURCE_REPO_<GROUP>` | Full source-registry override, or legacy path beneath `NGC_SOURCE_REGISTRY`. Group punctuation becomes underscores. | source config |
| `MIRROR_TOOL` | `regsync` (recommended) or `az_acr_import` | `regsync` |
| `INCLUDE_HELM_CHARTS` | Also mirror `helm-*` chart artifacts from OCI or configured HTTP Helm repositories | `false` |
| `SKIP_KEYS` | Comma-separated manifest keys to skip **by name** — entries that are not OCI artifacts and 404 if mirrored. The skill can't read `component_type` at runtime (`versions.yaml`, which carries it, isn't shipped beside `manifest.yaml`), so this is a hand-maintained list. Default `nvcf-stack` is `component_type: package` upstream (an SBOM umbrella label). | `nvcf-stack` |
| `DRY_RUN` | Skip the actual push; emit the config and print what would be mirrored | `false` |

## Per-group source mapping

Use `image-manifest/source-registry-config.yaml` as the source of truth. Manifest
groups map to plugin keys by replacing hyphens with underscores; `storage-api`
tries `storage_api` and then the legacy `storage_service` key. This resolves the
group's `source_registry` and, when present:

- `component_source_registries` for image or chart-specific source overrides,
- `component_chart_names` for published chart aliases,
- `source_only_components` for charts that must come from the extracted release,
- `helm_repo_url` for non-OCI charts that require `helm repo add` + `helm pull`.

This includes the current `ovdc` group, whose `helm-ovderivedcache` chart is
served by the configured HTTPS Helm repository while the `ovderivedcache` image
comes from the plugin's OCI source registry. Legacy built-in defaults remain
only for bundles that do not ship a source registry config; they cover current
groups plus the former `ddcs` group.

A manifest group with neither a config entry nor an environment override is a
hard error. Use `INCLUDE_GROUPS` to scope a partial run.

**To override per-group:** set the full `NGC_SOURCE_REGISTRY_<GROUP>` or legacy
`NGC_SOURCE_REPO_<GROUP>` in `streaming-env.sh`, replacing punctuation with
underscores. Example:

```bash
# In streaming-env.sh
export NGC_SOURCE_REPO_nvcf_self_managed_stack="0833294136851237/some-other-team"
export NGC_SOURCE_REGISTRY_storage_api="nvcr.io/nvidia/something-else"
```

### Multiple NGC source orgs — one key may not cover them all

The groups source from **more than one NGC org** (see the source registry config
for the current paths). The mirror authenticates to `nvcr.io` with a single
`NGC_API_KEY`, and access to **private** orgs is membership-scoped: if the key's
NGC user isn't a member of a private source org, the pull returns `403
Forbidden` for that org — which looks like a bad or expired key but is actually
an org-access gap, and is easy to lose hours to.

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
- **regsync config:** `generated/regsync.yaml` — always emitted for review and consumed when `MIRROR_TOOL=regsync`.
- **Inventory:** `generated/acr-inventory.tsv` — one row per image or mirrorable chart tag, used for collision checks and verification.

The script does NOT write a `.env.acr-mirror` file because nothing downstream consumes its outputs — successful exit is the signal. It does print a final tally line (`mirrored N images, M charts`) and (in `DRY_RUN=true`) the list of pairs without executing.

## Manifest sources

Two scenarios, in priority order:

### From a streaming-staging clone

`image-manifest/manifest.yaml` ships at the repo root, pre-synced from `omniverse/ovonsm/image-manifest` (alongside a `COMMIT` file for provenance and `source-registry-config.yaml`). The default `MANIFEST_PATH=${REPO_ROOT}/image-manifest/manifest.yaml` resolves correctly. To advance to a newer manifest, pin a different streaming-staging tag/SHA and `git pull`.

### From an azure-base-only checkout

No manifest ships with azure-base. Two options:

1. Set `MANIFEST_PATH` in `streaming-env.sh` to a local manifest checkout (e.g., a sibling clone of `omniverse/ovonsm/image-manifest`).
2. Set `FETCH_FROM_GITLAB=true` and provide `GITLAB_TOKEN`. The script fetches both the manifest and `.gitlab/source-registry-config.yaml` from the GitLab API at `MANIFEST_REF` — equivalent to what [streaming-staging's `sync-nvcf.sh`](../../../streaming-staging/sync-nvcf.sh) does, but at deploy time.

The script echoes `manifest source: <path>` and the `version` / `generated_at` fields so the source is auditable from logs.

## Why separate sub-paths matter

The base prefix cannot be empty or static, and image/chart prefixes must differ:

1. **Empty breaks helm pulls.** NVCF helm charts concatenate `<registry>/<repository>/<image>:<tag>`. The Helmfile environment's `global.image.repository` must match `TARGET_IMAGE_REPOSITORY`. An empty base or image prefix renders a double-slash path that container runtimes reject.
2. **A static sub-path collides across deployments.** When two clusters share one ACR (team registry, prod ACR, dev/staging side-by-side), both mirroring to `<acr>/nvcf/<image>:<tag>` race to overwrite tags — last write wins, and if the two manifest commits pin different versions of the same image, one cluster pulls the wrong tag.
3. **Images and charts share the OCI namespace.** A registry tag identifies one
   OCI manifest regardless of whether it is a container image or a Helm chart.
   The current release contains both `ovderivedcache:6.0.0` and
   `helm-ovderivedcache:6.0.0`; the HTTP chart publishes as
   `ovderivedcache:6.0.0`. Sending both to one prefix overwrites one artifact.

The default `${CLUSTER_NAME}` gives every deployment its own namespace under the ACR. After mirror, set in the helmfile env file:

```yaml
global:
  image:
    registry: <acr>.azurecr.io                 # not nvcr.io
    repository: aks-nvcf-validation-westus3    # matches TARGET_IMAGE_REPOSITORY
  helm:
    sources:
      registry: <acr>.azurecr.io
      repository: aks-nvcf-validation-westus3/charts  # matches TARGET_CHART_REPOSITORY
```

(See [`nvcf/nvcf-self-managed-stack/environments/base.yaml`](../../../streaming-staging/nvcf/nvcf-self-managed-stack/environments/base.yaml) for the placeholder values that must be replaced.)

**No image-pull secret needed once you point at the ACR.** The [`acr`](../acr/SKILL.md) skill granted the AKS kubelet identity `AcrPull` on this registry, so a pull from `<acr>.azurecr.io/...` is authenticated by the **node identity**. Once `global.image` and `global.helm.sources` point at the ACR you can **drop** the entire NGC pull-secret apparatus the NGC-direct path requires: the per-namespace `nvcr-pull-secret`, the `global.imagePullSecrets` entry, and the `docker login`/`helm registry login nvcr.io` steps. This also removes the multi-org pull-secret problem (function pods otherwise pull several nvcr.io orgs, each needing a different key) — everything is one AcrPull-authenticated registry. See the "Pull from a registry mirror (ACR/ECR)" section of the `nvcf-self-managed-installation` skill for the consumer-side env + step changes.

Override `TARGET_REPOSITORY` only when the ACR has an existing namespacing convention (e.g., `prod/<release-name>`) or when multiple deployments must share tags. Override the image/chart prefixes only when both the mirror and Helmfile consumer use the same distinct values.

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
ovdc:
  helm-ovderivedcache: 6.0.0
  ovderivedcache: 6.0.0
storage-api:
  helm-discovery-service: 2.3.8
  storage-service: 1.0.2
# ... etc. (ucc and other release groups)
```

Generation rules:
- Only map-valued top-level entries are groups; scalar metadata is ignored.
- Resolve each group's registry data through `source-registry-config.yaml`, then environment or legacy built-in fallback.
- Within each group:
  - Keys starting with `helm-` are chart inventory keys. **Skip in the image pass.** If `INCLUDE_HELM_CHARTS=true`, use `helm_repo_url` to choose HTTP pull or OCI pull, then push beneath `TARGET_CHART_REPOSITORY`.
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
TARGET_REPOSITORY="${TARGET_REPOSITORY:-${CLUSTER_NAME:-}}"
while [[ "$TARGET_REPOSITORY" == */ ]]; do TARGET_REPOSITORY="${TARGET_REPOSITORY%/}"; done
[[ -n "$TARGET_REPOSITORY" ]] || { echo "ERROR: TARGET_REPOSITORY is empty (no CLUSTER_NAME fallback). Set it in streaming-env.sh." >&2; exit 1; }
TARGET_IMAGE_REPOSITORY="${TARGET_IMAGE_REPOSITORY:-$TARGET_REPOSITORY}"
TARGET_CHART_REPOSITORY="${TARGET_CHART_REPOSITORY:-${TARGET_REPOSITORY}/charts}"
while [[ "$TARGET_IMAGE_REPOSITORY" == */ ]]; do TARGET_IMAGE_REPOSITORY="${TARGET_IMAGE_REPOSITORY%/}"; done
while [[ "$TARGET_CHART_REPOSITORY" == */ ]]; do TARGET_CHART_REPOSITORY="${TARGET_CHART_REPOSITORY%/}"; done
if [[ -z "$TARGET_IMAGE_REPOSITORY" || -z "$TARGET_CHART_REPOSITORY" ]]; then
  echo "ERROR: image and chart repository prefixes must both be non-empty." >&2
  exit 1
fi
if [[ "$TARGET_IMAGE_REPOSITORY" == "$TARGET_CHART_REPOSITORY" ]]; then
  echo "ERROR: TARGET_IMAGE_REPOSITORY and TARGET_CHART_REPOSITORY must differ." >&2
  exit 1
fi
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
SOURCE_REGISTRY_CONFIG="${SOURCE_REGISTRY_CONFIG:-}"

# Temp paths allocated lazily below. One cleanup trap covers fetched inputs,
# chart archives, and isolated registry configs for concurrent safety.
FETCHED_MANIFEST=""
FETCHED_SOURCE_REGISTRY_CONFIG=""
CHARTS_DIR=""
REGISTRY_CONFIG_DIR=""
cleanup() {
  [[ -n "$FETCHED_MANIFEST" && -f "$FETCHED_MANIFEST" ]] && rm -f "$FETCHED_MANIFEST"
  [[ -n "$FETCHED_SOURCE_REGISTRY_CONFIG" && -f "$FETCHED_SOURCE_REGISTRY_CONFIG" ]] && rm -f "$FETCHED_SOURCE_REGISTRY_CONFIG"
  [[ -n "$CHARTS_DIR" && -d "$CHARTS_DIR" ]] && rm -rf "$CHARTS_DIR"
  [[ -n "$REGISTRY_CONFIG_DIR" && -d "$REGISTRY_CONFIG_DIR" ]] && rm -rf "$REGISTRY_CONFIG_DIR"
  # Always succeed: as the last command in an EXIT trap, a short-circuited &&
  # guard (e.g. both paths empty in a default run) would otherwise set the
  # script's exit status to 1 after a fully successful mirror.
  return 0
}
trap cleanup EXIT

# Fallbacks are used only when source-registry-config.yaml is unavailable.
declare -A DEFAULT_SOURCE_REGISTRY=(
  ["nvcf-self-managed-stack"]="nvcr.io/0651155215864979/ncp-dev"
  ["nvcf-compute-plane-stack"]="nvcr.io/0651155215864979/ncp-dev"
  ["nvcf-observability-stack"]="nvcr.io/0651155215864979/ncp-dev"
  ["container_cache"]="nvcr.io/0651155215864979/ncp-dev"
  ["gxcache"]="nvcr.io/0833294136851237/nvcf-ncp-staging"
  ["lls"]="nvcr.io/0795883928596950"
  ["ucc"]="nvcr.io/nvidia/omniverse"
  ["ddcs"]="nvcr.io/nvidia/omniverse"
  ["ovdc"]="nvcr.io/nvidia/omniverse"
  ["storage-api"]="nvcr.io/nvidia/omniverse"
)
declare -A DEFAULT_HELM_REPO_URL=(
  ["ucc"]="https://helm.ngc.nvidia.com/nvidia/omniverse"
  ["ddcs"]="https://helm.ngc.nvidia.com/nvidia/omniverse"
  ["ovdc"]="https://helm.ngc.nvidia.com/nvidia/omniverse"
  ["storage-api"]="https://helm.ngc.nvidia.com/nvidia/omniverse"
)
declare -A FALLBACK_COMPONENT_SOURCE_PREFIX=(
  ["nvcf-observability-stack/opentelemetry-collector-contrib"]="ghcr.io/open-telemetry/opentelemetry-collector-releases"
  ["nvcf-observability-stack/opentelemetry-operator"]="ghcr.io/open-telemetry/opentelemetry-operator"
  ["nvcf-observability-stack/victoria-metrics"]="docker.io/victoriametrics"
)
declare -A FALLBACK_CHART_SOURCE_NAME=(
  ["nvcf-observability-stack/helm-opentelemetry-operator"]="opentelemetry-operator"
  ["nvcf-observability-stack/helm-prometheus-operator-crds"]="prometheus-operator-crds"
  ["nvcf-observability-stack/helm-victoria-metrics-single"]="victoria-metrics-single"
)
declare -A FALLBACK_SOURCE_ONLY_CHART=(
  ["nvcf-observability-stack/helm-nvcf-default-monitors"]=1
  ["nvcf-observability-stack/helm-nvcf-otel-collector"]=1
)

env_name() {
  printf '%s' "$1" | tr -c '[:alnum:]' '_'
}

plugins_for_group() {
  case "$1" in
    storage-api) printf '%s\n' storage_api storage_service ;;
    *) printf '%s\n' "${1//-/_}" ;;
  esac
}

config_group_value() {
  local group="$1" field="$2" plugin value
  [[ -f "$SOURCE_REGISTRY_CONFIG" ]] || return 1
  while IFS= read -r plugin; do
    value="$(yq -r ".upstream_plugins.\"$plugin\".\"$field\" // \"\"" "$SOURCE_REGISTRY_CONFIG")"
    if [[ -n "$value" && "$value" != "null" ]]; then
      printf '%s' "${value%/}"
      return 0
    fi
  done < <(plugins_for_group "$group")
  return 1
}

config_component_value() {
  local group="$1" field="$2" name="$3" plugin value
  [[ -f "$SOURCE_REGISTRY_CONFIG" ]] || return 1
  while IFS= read -r plugin; do
    value="$(yq -r ".upstream_plugins.\"$plugin\".\"$field\".\"$name\" // \"\"" "$SOURCE_REGISTRY_CONFIG")"
    if [[ -n "$value" && "$value" != "null" ]]; then
      printf '%s' "${value%/}"
      return 0
    fi
  done < <(plugins_for_group "$group")
  return 1
}

source_registry_for_group() {
  local group="$1" suffix value var
  suffix="$(env_name "$group")"
  var="NGC_SOURCE_REGISTRY_${suffix}"
  value="${!var:-}"
  if [[ -n "$value" ]]; then printf '%s' "${value%/}"; return 0; fi
  var="NGC_SOURCE_REPO_${suffix}"
  value="${!var:-}"
  if [[ -n "$value" ]]; then printf '%s/%s' "${NGC_SOURCE_REGISTRY%/}" "${value#/}"; return 0; fi
  if config_group_value "$group" source_registry; then return 0; fi
  value="${DEFAULT_SOURCE_REGISTRY[$group]:-}"
  [[ -n "$value" ]] || return 1
  printf '%s' "${value%/}"
}

source_registry_for_component() {
  local group="$1" name="$2" value key="$1/$2"
  if value="$(config_component_value "$group" component_source_registries "$name")"; then
    printf '%s' "$value"
    return 0
  fi
  value="${FALLBACK_COMPONENT_SOURCE_PREFIX[$key]:-}"
  if [[ -n "$value" ]]; then printf '%s' "$value"; return 0; fi
  source_registry_for_group "$group"
}

configured_chart_name() {
  local group="$1" name="$2" value key="$1/$2"
  if value="$(config_component_value "$group" component_chart_names "$name")"; then
    printf '%s' "$value"
    return 0
  fi
  value="${FALLBACK_CHART_SOURCE_NAME[$key]:-}"
  [[ -n "$value" ]] || return 1
  printf '%s' "$value"
}

is_source_only_chart() {
  local group="$1" name="$2" plugin found key="$1/$2"
  if [[ -f "$SOURCE_REGISTRY_CONFIG" ]]; then
    while IFS= read -r plugin; do
      found="$(yq -r ".upstream_plugins.\"$plugin\".source_only_components // [] | .[] | select(. == \"$name\")" "$SOURCE_REGISTRY_CONFIG")"
      [[ -n "$found" ]] && return 0
    done < <(plugins_for_group "$group")
  fi
  [[ -n "${FALLBACK_SOURCE_ONLY_CHART[$key]:-}" ]]
}

helm_repo_url_for_group() {
  local group="$1" value
  if value="$(config_group_value "$group" helm_repo_url)"; then printf '%s' "$value"; return 0; fi
  value="${DEFAULT_HELM_REPO_URL[$group]:-}"
  [[ -n "$value" ]] && printf '%s' "${value%/}"
  return 0
}

# Resolve manifest — local first, then optionally fetch from GitLab.
if [[ ! -f "$MANIFEST_PATH" ]]; then
  if [[ "${FETCH_FROM_GITLAB:-false}" == "true" ]]; then
    : "${GITLAB_TOKEN:?required when FETCH_FROM_GITLAB=true}"
    MANIFEST_REF="${MANIFEST_REF:-main}"
    echo "--- Fetching manifest from upstream (ref=$MANIFEST_REF) ---"
    FETCHED_MANIFEST=$(mktemp -t acr-mirror-manifest.XXXXXX)
    FETCHED_SOURCE_REGISTRY_CONFIG=$(mktemp -t acr-mirror-source-registry.XXXXXX)
    curl -fsSL -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
      "https://gitlab-master.nvidia.com/api/v4/projects/omniverse%2Fovonsm%2Fimage-manifest/repository/files/manifest.yaml/raw?ref=${MANIFEST_REF}" \
      -o "$FETCHED_MANIFEST"
    curl -fsSL -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
      "https://gitlab-master.nvidia.com/api/v4/projects/omniverse%2Fovonsm%2Fimage-manifest/repository/files/.gitlab%2Fsource-registry-config.yaml/raw?ref=${MANIFEST_REF}" \
      -o "$FETCHED_SOURCE_REGISTRY_CONFIG"
    MANIFEST_PATH="$FETCHED_MANIFEST"
    SOURCE_REGISTRY_CONFIG="$FETCHED_SOURCE_REGISTRY_CONFIG"
  else
    echo "ERROR: manifest not found at $MANIFEST_PATH" >&2
    echo "  Either: (a) run from a streaming-staging clone (ships image-manifest/manifest.yaml at repo root)," >&2
    echo "          (b) set MANIFEST_PATH in streaming-env.sh to a local manifest checkout, or" >&2
    echo "          (c) set FETCH_FROM_GITLAB=true + GITLAB_TOKEN to fetch from upstream." >&2
    exit 1
  fi
fi

if [[ -z "$SOURCE_REGISTRY_CONFIG" ]]; then
  if [[ -f "$(dirname "$MANIFEST_PATH")/source-registry-config.yaml" ]]; then
    SOURCE_REGISTRY_CONFIG="$(dirname "$MANIFEST_PATH")/source-registry-config.yaml"
  elif [[ -f "$(dirname "$MANIFEST_PATH")/.gitlab/source-registry-config.yaml" ]]; then
    SOURCE_REGISTRY_CONFIG="$(dirname "$MANIFEST_PATH")/.gitlab/source-registry-config.yaml"
  fi
elif [[ ! -f "$SOURCE_REGISTRY_CONFIG" ]]; then
  echo "ERROR: SOURCE_REGISTRY_CONFIG not found at $SOURCE_REGISTRY_CONFIG" >&2
  exit 1
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
if [[ -n "$SOURCE_REGISTRY_CONFIG" ]]; then
  echo "--- Source registry config: $SOURCE_REGISTRY_CONFIG ---"
else
  echo "WARN: source-registry-config.yaml not found; using legacy built-in source mappings" >&2
fi

# Collect only map-valued groups; scalar metadata is ignored automatically.
mapfile -t ALL_GROUPS < <(yq -r 'to_entries | .[] | select(.value | type == "!!map") | .key' "$MANIFEST_PATH")

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

# Build a complete inventory before authentication or writes so collisions fail
# fast. Columns: kind, group, name, tag, target repository, source, target.
mkdir -p "$REPO_ROOT/generated"
CONFIG="$REPO_ROOT/generated/regsync.yaml"
INVENTORY="$REPO_ROOT/generated/acr-inventory.tsv"
ACR_REGISTRY="${ACR_NAME}.azurecr.io"
: > "$INVENTORY"

for group in "${SELECTED_GROUPS[@]}"; do
  source_registry="$(source_registry_for_group "$group")" || {
    echo "ERROR: no source registry for group '$group'; update source-registry-config.yaml or use INCLUDE_GROUPS." >&2
    exit 1
  }
  helm_repo_url="$(helm_repo_url_for_group "$group")"
  while IFS= read -r pair; do
    name="${pair%%:*}"; tag="${pair#*:}"
    skip=""; for s in "${SKIP_KEYS_ARR[@]}"; do [[ "$name" == "$s" ]] && skip=1 && break; done
    if [[ -n "$skip" ]]; then
      echo "SKIP: $group/$name (non-OCI / package artifact, not mirrorable)" >&2
      continue
    fi

    if [[ "$name" == helm-* ]]; then
      [[ "$INCLUDE_HELM_CHARTS" == "true" ]] || continue
      if is_source_only_chart "$group" "$name"; then
        echo "SKIP: [$group] $name (source-only; install from the extracted release package)"
        continue
      fi
      chart_name="$(configured_chart_name "$group" "$name")" || chart_name=""
      if [[ -n "$helm_repo_url" ]]; then
        chart_name="${chart_name:-${name#helm-}}"
        kind="helm-http"
        source="$helm_repo_url"
      else
        chart_name="${chart_name:-$name}"
        kind="helm-oci"
        source_prefix="$(source_registry_for_component "$group" "$name")"
        source="${source_prefix}/${chart_name}"
      fi
      repo="${TARGET_CHART_REPOSITORY}/${chart_name}"
      target="${ACR_REGISTRY}/${repo}"
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$kind" "$group" "$chart_name" "$tag" "$repo" "$source" "$target" >> "$INVENTORY"
      continue
    fi

    source_prefix="$(source_registry_for_component "$group" "$name")"
    repo="${TARGET_IMAGE_REPOSITORY}/${name}"
    source="${source_prefix}/${name}"
    target="${ACR_REGISTRY}/${repo}"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "image" "$group" "$name" "$tag" "$repo" "$source" "$target" >> "$INVENTORY"
  done < <(yq -r "
    .\"$group\"
    | to_entries
    | .[]
    | .key as \$name
    | (.value | [.] | flatten | .[]) as \$tag
    | \$name + \":\" + \$tag
  " "$MANIFEST_PATH")
done

if [[ ! -s "$INVENTORY" && -z "${INCLUDE_GROUPS:-}" ]]; then
  echo "ERROR: resolved 0 mirrorable artifacts from $MANIFEST_PATH." >&2
  exit 1
fi

# One target repo:tag can reference only one OCI manifest. Exact duplicate rows
# are harmless; different artifact kinds, names, or sources are rejected.
awk -F '\t' '
  {
    key = $5 SUBSEP $4
    signature = $1 SUBSEP $3 SUBSEP $6
    label = $2 "/" $3 " (" $1 ", source=" $6 ")"
    if ((key in signatures) && signatures[key] != signature) {
      printf "ERROR: target collision at %s:%s between %s and %s\n", \
        $5, $4, labels[key], label > "/dev/stderr"
      collision = 1
    } else {
      signatures[key] = signature
      labels[key] = label
    }
  }
  END { exit collision }
' "$INVENTORY"
sort -u "$INVENTORY" -o "$INVENTORY"

cat > "$CONFIG" <<EOF
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
while IFS=$'\t' read -r kind group name tag repo source target; do
  [[ "$kind" == "image" ]] || continue
  cat >> "$CONFIG" <<EOF
  - source: ${source}:${tag}
    target: ${target}:${tag}
    type: image
EOF
done < "$INVENTORY"

IMAGE_COUNT=$(awk -F '\t' '$1 == "image" { count++ } END { print count + 0 }' "$INVENTORY")
CHART_COUNT=$(awk -F '\t' '$1 ~ /^helm-/ { count++ } END { print count + 0 }' "$INVENTORY")
echo "--- Planned: $IMAGE_COUNT image tag(s), $CHART_COUNT chart tag(s) ---"
echo "  wrote $CONFIG"
echo "  wrote $INVENTORY"

if [[ "$DRY_RUN" == "true" ]]; then
  while IFS=$'\t' read -r kind group name tag repo source target; do
    echo "  DRY: [$group] $kind $source:$tag -> $target:$tag"
  done < "$INVENTORY"
  exit 0
fi

command -v az >/dev/null || { echo "ERROR: az required" >&2; exit 1; }
if [[ "$MIRROR_TOOL" == "regsync" ]]; then
  command -v regsync >/dev/null || { echo "ERROR: regsync required (brew install regclient)" >&2; exit 1; }
elif [[ "$MIRROR_TOOL" != "az_acr_import" ]]; then
  echo "ERROR: unknown MIRROR_TOOL='$MIRROR_TOOL' (use regsync or az_acr_import)" >&2
  exit 1
fi
if [[ "$CHART_COUNT" -gt 0 ]]; then
  command -v helm >/dev/null || { echo "ERROR: helm required to mirror charts" >&2; exit 1; }
fi

# Scope Docker and Helm credentials to this run.
REGISTRY_CONFIG_DIR="$(mktemp -d -t acr-mirror-auth.XXXXXX)"
export DOCKER_CONFIG="$REGISTRY_CONFIG_DIR"
export HELM_REGISTRY_CONFIG="$REGISTRY_CONFIG_DIR/helm-registry.json"
export HELM_REPOSITORY_CONFIG="$REGISTRY_CONFIG_DIR/helm-repositories.yaml"
export HELM_REPOSITORY_CACHE="$REGISTRY_CONFIG_DIR/helm-cache"

echo "--- Authenticating to ACR ---"
az acr login --name "$ACR_NAME"

if [[ "$MIRROR_TOOL" == "regsync" ]]; then

  export NGC_API_KEY
  NGC_API_KEY="$(< "$NGC_API_KEY_FILE")"; NGC_API_KEY="${NGC_API_KEY%$'\n'}"
  regsync once -c "$CONFIG"
  unset NGC_API_KEY
else
  # No extra binary needed; sequential and slower (no parallelism).
  while IFS=$'\t' read -r kind group name tag repo source target; do
    [[ "$kind" == "image" ]] || continue
    src="${source}:${tag}"
    dst="${repo}:${tag}"
    echo "  [$group] $src → $dst"
    if [[ "$src" == "${NGC_SOURCE_REGISTRY}/"* ]]; then
      az acr import --name "$ACR_NAME" \
        --source "$src" --image "$dst" \
        --username '$oauthtoken' --password "$(< "$NGC_API_KEY_FILE")" \
        --only-show-errors
    else
      # Never send the NGC credential to public component registries.
      az acr import --name "$ACR_NAME" \
        --source "$src" --image "$dst" \
        --only-show-errors
    fi
  done < "$INVENTORY"
fi

# Helm handles both OCI and HTTP-sourced charts; images never enter this loop.
if [[ "$CHART_COUNT" -gt 0 ]]; then
  echo "--- Authenticating Helm to ACR ---"
  ACR_HELM_TOKEN="$(az acr login --name "$ACR_NAME" --expose-token --output tsv --query accessToken)"
  printf '%s' "$ACR_HELM_TOKEN" | helm registry login "$ACR_REGISTRY" \
    --username 00000000-0000-0000-0000-000000000000 --password-stdin
  unset ACR_HELM_TOKEN

  if awk -F '\t' '$1 == "helm-oci" && $6 ~ /^nvcr[.]io\// { found=1 } END { exit !found }' "$INVENTORY"; then
    helm registry login "$NGC_SOURCE_REGISTRY" -u '$oauthtoken' --password-stdin < "$NGC_API_KEY_FILE"
  fi

  CHARTS_DIR=$(mktemp -d -t acr-mirror-charts.XXXXXX)
  declare -A HELM_REPO_ADDED=()
  while IFS=$'\t' read -r kind group chart tag repo source target; do
    [[ "$kind" == helm-* ]] || continue
    if [[ "$kind" == "helm-http" ]]; then
      alias="src_$(env_name "$group")"
      if [[ -z "${HELM_REPO_ADDED[$alias]:-}" ]]; then
        if [[ "$source" == https://helm.ngc.nvidia.com/* ]]; then
          helm repo add "$alias" "$source" --username '$oauthtoken' --password "$(< "$NGC_API_KEY_FILE")" >/dev/null
        else
          helm repo add "$alias" "$source" >/dev/null
        fi
        HELM_REPO_ADDED[$alias]=1
      fi
      helm pull "$alias/$chart" --version "$tag" -d "$CHARTS_DIR"
    else
      helm pull "oci://${source}" --version "$tag" -d "$CHARTS_DIR"
    fi
    chart_archive="$CHARTS_DIR/${chart}-${tag}.tgz"
    if [[ ! -f "$chart_archive" ]]; then
      echo "ERROR: expected chart archive not found: $chart_archive" >&2
      exit 1
    fi
    helm push "$chart_archive" "oci://${ACR_REGISTRY}/${TARGET_CHART_REPOSITORY}"
    rm -f "$chart_archive"
  done < "$INVENTORY"
fi

echo "--- Done: mirrored $IMAGE_COUNT image tag(s), $CHART_COUNT chart tag(s) ---"
echo "--- Verify: az acr repository list --name $ACR_NAME --output table ---"
```

## Helm chart mirroring (optional)

Charts in the manifest are keys prefixed `helm-` (for example,
`helm-nvcf-cassandra: 0.11.1`). They never enter the image mirror path. The
script uses `source-registry-config.yaml` to choose one of two flows:

- OCI source: `helm pull oci://...` followed by `helm push` to ACR.
- HTTP source (`helm_repo_url`): drop the `helm-` inventory prefix unless a
  `component_chart_names` alias is configured, then use `helm repo add`,
  `helm pull`, and `helm push`.

Source-only charts are skipped with an instruction to use the extracted release
package. All mirrored charts land beneath `TARGET_CHART_REPOSITORY`, never the
image prefix.

Why optional: if the cluster has outbound access to the configured upstream
registries and a working NGC auth secret, Helmfile can pull charts directly.
Mirror them for a full air-gap or when policy requires ACR-only pulls.

When mirroring charts, update the helmfile env file:

```yaml
global:
  image:
    registry: <acr>.azurecr.io
    repository: <TARGET_IMAGE_REPOSITORY>
  helm:
    sources:
      registry: <acr>.azurecr.io
      repository: <TARGET_CHART_REPOSITORY>
```

## Verification

The inventory is the exact set of artifacts the script attempted to mirror.
Verify each target tag directly, then separately check that the image inventory
count matches the manifest after applying `SKIP_KEYS`:

```bash
missing=0
while IFS=$'\t' read -r kind group name tag repo source target; do
  if ! az acr repository show-tags --name "$ACR_NAME" --repository "$repo" -o tsv 2>/dev/null | grep -Fxq "$tag"; then
    echo "MISSING: $repo:$tag ($kind $group/$name)"
    missing=1
  fi
done < generated/acr-inventory.tsv
test "$missing" -eq 0

SKIP_KEYS="${SKIP_KEYS:-nvcf-stack}"
count_unskipped() {
  awk -v skip="$SKIP_KEYS" '
    BEGIN { n = split(skip, s, ","); for (i = 1; i <= n; i++) skipped[s[i]] }
    !($0 in skipped) { count++ }
    END { print count + 0 }
  '
}
SBOM_IMAGE_COUNT=$(yq -r '
  to_entries | .[]
  | select(.value | type == "!!map")
  | .value | to_entries | .[]
  | select(.key | test("^helm-") | not)
  | (.value | [.] | flatten | .[]) as $tag
  | .key
' "$MANIFEST_PATH" | count_unskipped)
INVENTORY_IMAGE_COUNT=$(awk -F '\t' '$1 == "image" { count++ } END { print count + 0 }' generated/acr-inventory.tsv)
test "$SBOM_IMAGE_COUNT" -eq "$INVENTORY_IMAGE_COUNT"
```

If verification fails, re-run with `DRY_RUN=true` to inspect the inventory and
reported `[group]` entries before retrying the mirror.

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
- [ ] Source registries, component overrides, chart aliases, HTTP Helm repositories, and source-only charts resolve from `source-registry-config.yaml`
- [ ] Legacy fallbacks include both `ovdc` and former `ddcs` manifests when the source config is unavailable
- [ ] Public component registries never receive the NGC credential
- [ ] OVDC resolves `ovderivedcache:6.0.0` as an image and `helm-ovderivedcache:6.0.0` as the HTTP chart `ovderivedcache:6.0.0`
- [ ] An unmapped non-metadata group is a hard error (exit 1), not a WARN-skip
- [ ] `cleanup()` ends with `return 0` so the EXIT trap can't fail a successful run
- [ ] Source resolution honors full-registry and legacy repository environment overrides before config/default fallbacks
- [ ] Manifest path resolves with the streaming-staging default; GitLab fallback fetches both manifest and source config
- [ ] Fetched inputs, chart archives, and auth configs use `mktemp` and one cleanup trap
- [ ] Manifest provenance is echoed (`version`, `generated_at`) for audit
- [ ] Top-level metadata keys (`schema_version`, `version`, `generated_at`) are NOT treated as groups
- [ ] `INCLUDE_GROUPS` filter (comma-separated) subsets the groups when set
- [ ] `SKIP_KEYS` (default `nvcf-stack`) drops non-OCI `package`-type keys from the image pass with a logged note
- [ ] `helm-*` keys are skipped in the image pass
- [ ] Both scalar and list tag values handled (verify against the `nvcf-openbao` upgrade-transition case)
- [ ] Base, image, and chart prefixes are non-empty, have no trailing slash, and image/chart prefixes differ
- [ ] The sub-path guidance covers double slashes, cross-deployment collisions, and image/chart OCI collisions
- [ ] Preflight rejects distinct artifacts that resolve to the same target repository and tag
- [ ] `MIRROR_TOOL=regsync` emits `regsync.yaml` with `repoAuth: true` on the NGC creds entry (NGC's per-repo auth challenge breaks token caching)
- [ ] `MIRROR_TOOL=az_acr_import` works without regsync installed
- [ ] Each generated mirror entry (regsync or az acr import) uses the per-group source repo, not a single hardcoded one
- [ ] `DRY_RUN=true` produces output without pushing anything; output is prefixed with `[group]` so per-group entries are visible
- [ ] `INCLUDE_HELM_CHARTS=true` mirrors configured OCI and HTTP Helm sources beneath `TARGET_CHART_REPOSITORY`
- [ ] Verification checks each inventory target and excludes `SKIP_KEYS` from the manifest image count

## References

| Topic | Source |
|---|---|
| `omniverse/ovonsm/image-manifest` (SBOM authority) | https://gitlab-master.nvidia.com/omniverse/ovonsm/image-manifest |
| Helmfile env placeholder values (where NGC paths are replaced with ACR) | `streaming-staging/nvcf/nvcf-self-managed-stack/environments/base.yaml` |
| Streaming-staging sync script (mirrors the manifest into the bundle) | `streaming-staging/sync-nvcf.sh` |
| regsync (regclient) docs | https://regclient.org/usage/regsync/ |
| `az acr import` | https://learn.microsoft.com/cli/azure/acr#az-acr-import |
| Why per-repo auth (`repoAuth: true`) for NGC | NGC namespace returns fresh challenges per repo; cached token mishandles this |
