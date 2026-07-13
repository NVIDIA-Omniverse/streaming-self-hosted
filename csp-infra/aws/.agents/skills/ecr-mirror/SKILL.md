---
name: ecr-mirror
description: Mirror every KAS/NVCF manifest image and optional Helm OCI chart from NGC into AWS ECR using generated regsync config.
version: "1.1.0"
author: NVIDIA Omniverse Streaming
tags: ["aws", "ecr", "regsync", "nvcf"]
tools: ["Shell", "Read", "Write"]
---

<!-- SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved. -->
<!-- SPDX-License-Identifier: CC-BY-4.0 AND Apache-2.0 -->

# ECR Mirror

## Purpose

Populate AWS ECR from `image-manifest/manifest.yaml` before installing the
NVCF self-managed stack on EKS. The manifest is the source of truth: mirror
every non-helm `image:tag` entry, and mirror `helm-*` OCI chart artifacts when
`INCLUDE_HELM_CHARTS=true`. For AWS this defaults to `true`.

Use this after AWS infra has created or authorized ECR access. Do not use this
skill for Terraform, EKS cluster creation, NVCF installation, function deploys,
or stream validation.

## Inputs

Required:

| Variable | Description |
|---|---|
| `AWS_ACCOUNT_ID` | AWS account that owns the target ECR registry. |
| `AWS_REGION` | Target ECR region, for example `us-west-2`. |
| `CLUSTER_NAME` | Default ECR repository prefix when `TARGET_REPOSITORY` is unset. |

Optional:

| Variable | Default | Description |
|---|---|---|
| `NGC_API_KEY` | unset | Required only when `DRY_RUN=false`; export in the shell for `regsync` and never print it. |
| `TARGET_REPOSITORY` | `${CLUSTER_NAME}` | Non-empty ECR repository prefix. |
| `MANIFEST_PATH` | `${REPO_ROOT}/image-manifest/manifest.yaml` | Manifest source of truth. |
| `SOURCE_REGISTRY_CONFIG` | beside `MANIFEST_PATH` | Source registry resolver. |
| `INCLUDE_HELM_CHARTS` | `true` | Include `helm-*` OCI chart artifacts in the regsync config. |
| `INCLUDE_GROUPS` | empty | Comma-separated manifest groups to mirror; empty means all groups. |
| `SKIP_KEYS` | `nvcf-stack` | Comma-separated manifest keys to skip **by name** — entries that are not OCI artifacts and 404 if mirrored. The skill can't read `component_type` at runtime (`versions.yaml`, which carries it, isn't shipped beside `manifest.yaml`), so this is a hand-maintained list. Default `nvcf-stack` is `component_type: package` upstream (an SBOM umbrella label). |
| `REGSYNC_PARALLEL` | `4` | Parallel copy count in generated regsync config. |
| `DRY_RUN` | `false` | Generate config, repo list, and inventory without creating repos or copying. |

Never print NGC API keys, ECR passwords, OpenBao tokens, kubeconfig contents, or
other secret values. The generated regsync file uses environment placeholders
only: `{{env "NGC_API_KEY"}}` and `{{env "ECR_PASSWORD"}}`.

## Source Registry Resolution

Use `image-manifest/source-registry-config.yaml` as the primary resolver. The
mirror workflow maps manifest groups to source-registry plugins with the same
mapping as the Azure ACR mirror flow:

| Manifest group | Plugin key |
|---|---|
| `nvcf-self-managed-stack` | `nvcf_self_managed_stack` |
| `nvcf-compute-plane-stack` | `nvcf_compute_plane_stack` |
| `container_cache` | `container_cache` |
| `gxcache` | `gxcache` |
| `ucc` | `ucc` |
| `ddcs` | `ddcs` |
| `lls` | `lls` |
| `storage-api` | `storage_service`, then `storage_api` |

If the config file exists, do not use stale hardcoded defaults. If the config
file is missing, fall back only to documented environment overrides:

```bash
export NGC_SOURCE_REGISTRY_nvcf_self_managed_stack="nvcr.io/nvidia/nvcf"
export NGC_SOURCE_REGISTRY_storage_api="nvcr.io/nvidia/omniverse"
```

The legacy `NGC_SOURCE_REPO_<group>` form is also accepted only in this missing
config fallback mode, using `NGC_SOURCE_REGISTRY` as the host and `nvcr.io` as
the default host.

## Mirror Workflow

Run from a checkout that has `image-manifest/manifest.yaml`, or set
`MANIFEST_PATH` and `SOURCE_REGISTRY_CONFIG` explicitly.

The generated mirror script must write:

- `generated/ecr-regsync.yaml`
- `generated/ecr-repositories.txt`
- `generated/ecr-inventory.tsv`

Each sync entry must use:

```text
source: <source_registry>/<image>:<tag>
target: <aws_account>.dkr.ecr.<region>.amazonaws.com/<TARGET_REPOSITORY>/<image>:<tag>
```

The same rule applies to Helm OCI charts, where `<image>` is the `helm-*` chart
artifact name.

Some plugins (`ucc`, `ddcs`, `storage_api`) set `helm_repo_url` in
`source-registry-config.yaml`: their charts are served over an HTTP Helm repo,
not as OCI artifacts under `source_registry`. For those groups the chart name
drops the `helm-` prefix and the chart is `helm pull`ed over HTTP and
`helm push`ed to ECR, instead of being OCI-copied via regsync.

```bash
set -euo pipefail

for tool in yq; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "ERROR: $tool not installed" >&2
    exit 1
  }
done

: "${AWS_ACCOUNT_ID:?Set AWS_ACCOUNT_ID}"
: "${AWS_REGION:?Set AWS_REGION}"
: "${CLUSTER_NAME:?Set CLUSTER_NAME}"
TARGET_REPOSITORY="${TARGET_REPOSITORY:-$CLUSTER_NAME}"
if [[ -z "$TARGET_REPOSITORY" ]]; then
  echo "ERROR: TARGET_REPOSITORY is empty. Set it or CLUSTER_NAME." >&2
  exit 1
fi

REPO_ROOT="${REPO_ROOT:-$(pwd)}"
MANIFEST_PATH="${MANIFEST_PATH:-$REPO_ROOT/image-manifest/manifest.yaml}"
SOURCE_REGISTRY_CONFIG="${SOURCE_REGISTRY_CONFIG:-$(dirname "$MANIFEST_PATH")/source-registry-config.yaml}"
INCLUDE_HELM_CHARTS="${INCLUDE_HELM_CHARTS:-true}"
INCLUDE_GROUPS="${INCLUDE_GROUPS:-}"
REGSYNC_PARALLEL="${REGSYNC_PARALLEL:-4}"
DRY_RUN="${DRY_RUN:-false}"
# Manifest keys to skip BY NAME because they are not OCI artifacts and 404 if
# mirrored. This is a hand-maintained deny-list, NOT a type lookup: the skill
# can't see component_type at runtime — versions.yaml (which carries it) is not
# shipped beside manifest.yaml. The default, nvcf-stack, is component_type:
# package upstream (an SBOM umbrella label). Durable fix: have the aggregator
# emit component_type into manifest.yaml so the type can be read directly.
# Comma-separated; override via SKIP_KEYS.
SKIP_KEYS="${SKIP_KEYS:-nvcf-stack}"
IFS=',' read -ra SKIP_KEYS_ARR <<< "$SKIP_KEYS"

mkdir -p "$REPO_ROOT/generated"
CONFIG="$REPO_ROOT/generated/ecr-regsync.yaml"
REPOS="$REPO_ROOT/generated/ecr-repositories.txt"
INVENTORY="$REPO_ROOT/generated/ecr-inventory.tsv"
HELM_HTTP="$REPO_ROOT/generated/ecr-helm-http.tsv"
ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

if [[ ! -f "$MANIFEST_PATH" ]]; then
  echo "ERROR: manifest not found at $MANIFEST_PATH" >&2
  exit 1
fi

plugin_for_group() {
  case "$1" in
    nvcf-self-managed-stack) printf '%s\n' nvcf_self_managed_stack ;;
    nvcf-compute-plane-stack) printf '%s\n' nvcf_compute_plane_stack ;;
    container_cache) printf '%s\n' container_cache ;;
    gxcache) printf '%s\n' gxcache ;;
    ucc) printf '%s\n' ucc ;;
    ddcs) printf '%s\n' ddcs ;;
    lls) printf '%s\n' lls ;;
    storage-api) printf '%s\n' storage_service storage_api ;;
  esac
}

env_name() {
  printf '%s' "$1" | tr -c '[:alnum:]' '_'
}

source_registry_for_group() {
  local group="$1" plugin value var
  if [[ -f "$SOURCE_REGISTRY_CONFIG" ]]; then
    while IFS= read -r plugin; do
      value="$(yq -r ".upstream_plugins.\"$plugin\".source_registry // \"\"" "$SOURCE_REGISTRY_CONFIG")"
      if [[ -n "$value" && "$value" != "null" ]]; then
        printf '%s' "${value%/}"
        return 0
      fi
    done < <(plugin_for_group "$group")
    return 1
  fi

  var="NGC_SOURCE_REGISTRY_$(env_name "$group")"
  value="${!var:-}"
  if [[ -n "$value" ]]; then
    printf '%s' "${value%/}"
    return 0
  fi

  var="NGC_SOURCE_REPO_$(env_name "$group")"
  value="${!var:-}"
  if [[ -n "$value" ]]; then
    printf '%s/%s' "${NGC_SOURCE_REGISTRY:-nvcr.io}" "${value#/}"
    return 0
  fi
  return 1
}

# Some plugins serve their helm charts over an HTTP helm repo (helm_repo_url in
# source-registry-config.yaml) rather than as OCI artifacts under source_registry.
# For those groups the chart name drops the manifest's "helm-" prefix and the
# chart must be pulled over HTTP, not OCI-copied via regsync. Emits the repo URL
# on stdout (empty if the group's plugin has no helm_repo_url).
helm_repo_url_for_group() {
  local group="$1" plugin value
  [[ -f "$SOURCE_REGISTRY_CONFIG" ]] || return 0
  while IFS= read -r plugin; do
    value="$(yq -r ".upstream_plugins.\"$plugin\".helm_repo_url // \"\"" "$SOURCE_REGISTRY_CONFIG")"
    if [[ -n "$value" && "$value" != "null" ]]; then
      printf '%s' "${value%/}"
      return 0
    fi
  done < <(plugin_for_group "$group")
}

cat > "$CONFIG" <<EOF
version: 1
creds:
  - registry: nvcr.io
    user: \$oauthtoken
    pass: '{{env "NGC_API_KEY"}}'
    repoAuth: true
  - registry: ${ECR_REGISTRY}
    user: AWS
    pass: '{{env "ECR_PASSWORD"}}'
defaults:
  parallel: ${REGSYNC_PARALLEL}
sync:
EOF
: > "$REPOS"
: > "$INVENTORY"
: > "$HELM_HTTP"

mapfile -t ALL_GROUPS < <(
  yq -r 'keys | .[] | select(. != "version" and . != "generated_at")' "$MANIFEST_PATH"
)

# NB: do NOT name this array GROUPS — bash auto-populates a special read-only
# array of the current user's group IDs under that name, and "Assignments to
# GROUPS have no effect" (bash manual). Using it here silently iterates GIDs
# instead of manifest groups and mirrors nothing.
if [[ -n "$INCLUDE_GROUPS" ]]; then
  IFS=',' read -ra REQUESTED <<< "$INCLUDE_GROUPS"
  SELECTED_GROUPS=()
  for group in "${ALL_GROUPS[@]}"; do
    for requested in "${REQUESTED[@]}"; do
      [[ "$group" == "$requested" ]] && SELECTED_GROUPS+=("$group") && break
    done
  done
else
  SELECTED_GROUPS=("${ALL_GROUPS[@]}")
fi

for group in "${SELECTED_GROUPS[@]}"; do
  source_registry="$(source_registry_for_group "$group")" || {
    echo "ERROR: no source registry for manifest group $group" >&2
    exit 1
  }
  helm_repo_url="$(helm_repo_url_for_group "$group")"

  # Enumerate every key:tag pair (scalar and list values) in mikefarah yq v4
  # syntax — no jq if/then/else or \(...) interpolation, which yq v4 rejects.
  # The kind (helm vs image) is derived in bash from the "helm-" prefix.
  while IFS= read -r pair; do
    name="${pair%%:*}"
    tag="${pair#*:}"
    skip=""
    for s in "${SKIP_KEYS_ARR[@]}"; do [[ "$name" == "$s" ]] && skip=1 && break; done
    if [[ -n "$skip" ]]; then
      echo "SKIP: $group/$name (non-OCI / package artifact, not mirrorable)" >&2
      continue
    fi
    if [[ "$name" == helm-* ]]; then kind="helm"; else kind="image"; fi
    [[ "$kind" == "helm" && "$INCLUDE_HELM_CHARTS" != "true" ]] && continue

    # Charts served over an HTTP helm repo are not OCI artifacts at
    # source_registry — they must be pulled over HTTP (with the "helm-" prefix
    # dropped) and pushed to ECR, not OCI-copied via regsync.
    if [[ "$kind" == "helm" && -n "$helm_repo_url" ]]; then
      chart="${name#helm-}"
      repo="${TARGET_REPOSITORY}/${chart}"
      printf '%s\n' "$repo" >> "$REPOS"
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "helm-http" "$group" "$chart" "$tag" "$repo" "${helm_repo_url}/${chart}" "${ECR_REGISTRY}/${repo}" >> "$INVENTORY"
      printf '%s\t%s\t%s\t%s\n' "$group" "$chart" "$tag" "$repo" >> "$HELM_HTTP"
      continue
    fi

    repo="${TARGET_REPOSITORY}/${name}"
    source="${source_registry}/${name}:${tag}"
    target="${ECR_REGISTRY}/${repo}:${tag}"

    printf '%s\n' "$repo" >> "$REPOS"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$kind" "$group" "$name" "$tag" "$repo" "$source" "$target" >> "$INVENTORY"
    cat >> "$CONFIG" <<EOF
  - source: ${source}
    target: ${target}
    type: image
EOF
  done < <(yq -r "
    .\"$group\"
    | to_entries
    | .[]
    | .key as \$name
    | (.value | [.] | flatten | .[]) as \$tag
    | \$name + \":\" + \$tag
  " "$MANIFEST_PATH")
done

sort -u "$REPOS" -o "$REPOS"

if [[ "$DRY_RUN" == "true" ]]; then
  echo "DRY_RUN=true: generated $CONFIG, $REPOS, $INVENTORY, and $HELM_HTTP"
  sed 's/^/DRY: ensure ECR repo /' "$REPOS"
  if [[ -s "$HELM_HTTP" ]]; then
    while IFS=$'\t' read -r group chart tag repo; do
      echo "DRY: [$group] helm pull $(helm_repo_url_for_group "$group")/${chart}:${tag} (HTTP) -> push oci://${ECR_REGISTRY}/${repo}"
    done < "$HELM_HTTP"
  fi
  exit 0
fi

for tool in aws regsync; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "ERROR: $tool not installed" >&2
    exit 1
  }
done
if [[ -s "$HELM_HTTP" ]]; then
  command -v helm >/dev/null 2>&1 || {
    echo "ERROR: helm not installed (required to mirror HTTP helm charts)" >&2
    exit 1
  }
fi

: "${NGC_API_KEY:?Set NGC_API_KEY in the shell without printing it}"

ACTIVE_ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
if [[ "$ACTIVE_ACCOUNT" != "$AWS_ACCOUNT_ID" ]]; then
  echo "ERROR: active AWS account is $ACTIVE_ACCOUNT, expected $AWS_ACCOUNT_ID" >&2
  exit 1
fi

while IFS= read -r repo; do
  [[ -z "$repo" ]] && continue
  if aws ecr describe-repositories \
      --region "$AWS_REGION" \
      --repository-names "$repo" >/dev/null 2>&1; then
    continue
  fi
  aws ecr create-repository \
    --region "$AWS_REGION" \
    --repository-name "$repo" \
    --image-scanning-configuration scanOnPush=true \
    --encryption-configuration encryptionType=AES256 \
    >/dev/null
done < "$REPOS"

export ECR_PASSWORD
ECR_PASSWORD="$(aws ecr get-login-password --region "$AWS_REGION")"
regsync once -c "$CONFIG"

# Charts served over an HTTP helm repo (helm_repo_url) are pulled over HTTP and
# pushed to ECR as OCI — regsync only does OCI-to-OCI, so it cannot mirror these.
if [[ -s "$HELM_HTTP" ]]; then
  echo "--- Mirroring HTTP helm charts ---"
  echo "$ECR_PASSWORD" | helm registry login --username AWS --password-stdin "$ECR_REGISTRY"
  CHARTS_DIR="$(mktemp -d -t ecr-mirror-charts.XXXXXX)"
  trap 'rm -rf "$CHARTS_DIR"' EXIT
  declare -A HELM_REPO_ADDED=()
  while IFS=$'\t' read -r group chart tag repo; do
    helm_repo_url="$(helm_repo_url_for_group "$group")"
    [[ -z "$helm_repo_url" ]] && continue
    alias="src_$(env_name "$group")"
    if [[ -z "${HELM_REPO_ADDED[$alias]:-}" ]]; then
      helm repo add "$alias" "$helm_repo_url" \
        --username '$oauthtoken' --password "$NGC_API_KEY" >/dev/null
      HELM_REPO_ADDED[$alias]=1
    fi
    helm pull "$alias/$chart" --version "$tag" -d "$CHARTS_DIR"
    helm push "$CHARTS_DIR/${chart}-${tag}.tgz" "oci://${ECR_REGISTRY}/${TARGET_REPOSITORY}"
    rm -f "$CHARTS_DIR/${chart}-${tag}.tgz"
  done < "$HELM_HTTP"
fi
unset ECR_PASSWORD
```

This creates missing ECR repositories before mirroring:

```text
${TARGET_REPOSITORY}/${image}
${TARGET_REPOSITORY}/${chart}
```

## NVCF Helmfile Handoff

After mirroring, configure the NVCF Helmfile environment to pull both images and
OCI charts from ECR:

```yaml
global:
  image:
    registry: <aws_account>.dkr.ecr.<region>.amazonaws.com
    repository: <TARGET_REPOSITORY>
  helm:
    sources:
      registry: <aws_account>.dkr.ecr.<region>.amazonaws.com
      repository: <TARGET_REPOSITORY>
```

For EKS pulls, confirm the node role or pod identity has ECR read access:

```text
ecr:GetAuthorizationToken
ecr:BatchCheckLayerAvailability
ecr:GetDownloadUrlForLayer
ecr:BatchGetImage
```

## Verification

The mirror script writes `generated/ecr-inventory.tsv` with one row per
expected manifest tag. After mirroring, verify every image and chart tag exists
in ECR:

```bash
missing=0
while IFS=$'\t' read -r kind group name tag repo source target; do
  if ! aws ecr describe-images \
      --region "$AWS_REGION" \
      --repository-name "$repo" \
      --image-ids "imageTag=$tag" >/dev/null 2>&1; then
    echo "MISSING: $repo:$tag ($kind $group/$name)"
    missing=1
  fi
done < generated/ecr-inventory.tsv
test "$missing" -eq 0
```

For a local dry-run count check against the current manifest:

```bash
MANIFEST_PATH=image-manifest/manifest.yaml
IMAGE_COUNT=$(yq -r '
  to_entries | .[]
  | select(.key != "version" and .key != "generated_at")
  | .value | to_entries | .[]
  | select(.key | test("^helm-") | not)
  | (.value | if type == "array" then .[] else . end)
  | "x"
' "$MANIFEST_PATH" | wc -l | tr -d ' ')
CHART_COUNT=$(yq -r '
  to_entries | .[]
  | select(.key != "version" and .key != "generated_at")
  | .value | to_entries | .[]
  | select(.key | test("^helm-"))
  | (.value | if type == "array" then .[] else . end)
  | "x"
' "$MANIFEST_PATH" | wc -l | tr -d ' ')
echo "images=$IMAGE_COUNT charts=$CHART_COUNT"
```

Expected for the referenced manifest:

```text
images=42 charts=20
```

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Generated entry count is lower than manifest count | Source registry config is missing or a group cannot resolve | Provide `image-manifest/source-registry-config.yaml`; only use env fallbacks when that file is unavailable. |
| `TARGET_REPOSITORY` is empty | Both `TARGET_REPOSITORY` and `CLUSTER_NAME` are unset | Stop and set one; do not mirror to the registry root. |
| Image pull fails after a successful mirror | Chart-rendered image name differs from manifest name or the source registry content drifted | Compare chart render output with `generated/ecr-inventory.tsv`, then mirror the exact rendered image or update the manifest/source mapping. |

Live deployment drift observed:

- The chart/manifests can drift from available registry content.
- `nvct-api` rendered `nvct-service-oss:1.3.11` from staging, but that tag was
  not pullable there; it existed in `ncp-dev` and in ECR as
  `ov-qa-cluster/nvct-service-oss:1.3.11`.
- `nvcf-api` rendered `nvcf-service-oss:2.234.0`, but the manifest image name
  is `strap:2.234.0`; `strap:2.234.0` was pullable from `ncp-dev` but missing
  from ECR.
- `nats-auth-callout-service:0.3.3` existed in ECR as
  `ov-qa-cluster/nvcf-nats-auth-callout-service:0.3.3`.

Do not hardcode `ov-qa-cluster`; use `${TARGET_REPOSITORY}`. The observed names
are only examples for diagnosing chart/render drift.

## Validation Checklist

- [ ] Mirror workflow consumes `image-manifest/manifest.yaml` as source of truth.
- [ ] Mirror workflow resolves source registries from `source-registry-config.yaml`.
- [ ] Scalar and list-valued tags both produce sync entries.
- [ ] Non-helm image entries are all present in generated regsync config.
- [ ] `helm-*` chart entries are present when `INCLUDE_HELM_CHARTS=true`.
- [ ] Missing ECR repositories are created before `regsync once`.
- [ ] No secret values are printed or written into generated files.
- [ ] Verification checks every generated inventory row in ECR.
