---
name: eks-validate
description: Generate a validation script for an AWS KAS/NVCF EKS foundation. Checks AWS account identity, VPC/subnets, EKS state and OIDC, node group composition, ECR pull permissions, optional S3 RBAC/probe, GPU Operator readiness, GPU resources, and an ephemeral CUDA smoke pod.
version: "1.1.0"
author: NVIDIA Omniverse Streaming
tags: ["aws", "eks", "validation", "gpu"]
tools: ["Shell", "Read", "Write"]
---

<!-- SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved. -->
<!-- SPDX-License-Identifier: CC-BY-4.0 AND Apache-2.0 -->

# EKS Foundation Validation

## What This Skill Produces

Generate `generated/<cluster-name>-validate.sh`, a validation script that emits
PASS/WARN/FAIL lines and writes `generated/<cluster-name>-validate-report.json`.

The report shape intentionally matches the Azure `aks-validate` style:

```json
{
  "cluster": "eks-nvcf-validation-usw2",
  "timestamp": "2026-05-27T12:34:56Z",
  "summary": { "pass": 8, "warn": 1, "fail": 0 },
  "checks": [
    { "id": "account",      "status": "PASS", "detail": "active account matches 123456789012 in us-west-2" },
    { "id": "vpc",          "status": "PASS", "detail": "VPC vpc-abc 10.10.0.0/16; subnets: subnet-a, subnet-b, subnet-c" },
    { "id": "eks",          "status": "PASS", "detail": "ACTIVE; v1.30; OIDC enabled" },
    { "id": "nodes",        "status": "PASS", "detail": "system=1, compute=1, gpu=1 (g6.12xlarge, us-west-2a)" },
    { "id": "platform-capacity", "status": "PASS", "detail": "OVDC replicas=1; eligible compute nodes=1; required allocatable memory per node=64 GiB" },
    { "id": "ecr-pull",     "status": "PASS", "detail": "ECR read allowed for node role(s)" },
    { "id": "s3-rbac",      "status": "WARN", "detail": "Skipped (no S3_BUCKET_NAME)" },
    { "id": "gpu-op",       "status": "PASS", "detail": "9/9 pods Ready; chart v25.3.1" },
    { "id": "gpu-resource", "status": "PASS", "detail": "1 node advertises nvidia.com/gpu=4" },
    { "id": "cuda-smoke",   "status": "PASS", "detail": "nvidia-smi pod returned 0; L40S detected" },
    { "id": "s3-probe",     "status": "WARN", "detail": "Skipped (no S3_PROBE_SERVICE_ACCOUNT)" }
  ]
}
```

## Inputs

Required:

| Input | Notes |
|---|---|
| `CLUSTER_NAME` | EKS cluster name and kubeconfig context. |
| `AWS_REGION` | Target AWS region. |

Optional:

| Input | Default | Notes |
|---|---|---|
| `AWS_ACCOUNT_ID` | unset | If set, active caller account must match. |
| `ECR_REPOSITORY_PREFIX` | `${CLUSTER_NAME}` | Prefix used by `ecr` and `ecr-mirror`. |
| `GPU_OPERATOR_VERSION` | unset | If set, checked against Helm metadata when available. |
| `CUDA_IMAGE` | `nvidia/cuda:12.4.0-base-ubuntu22.04` | Image for smoke test. |
| `SKIP_CUDA` | `false` | Skip CUDA smoke with WARN. |
| `ALLOW_GPU_ZERO` | `false` | Treat no GPU nodes/resources as WARN instead of FAIL. |
| `OVDC_REPLICAS` | `0` | Number of OVDC replicas the CPU compute pool must host. |
| `OVDC_MEMORY_REQUEST_GIB` | unset | Required when `OVDC_REPLICAS > 0`; rendered pod request rounded up to GiB. |
| `OVDC_PLATFORM_RESERVE_GIB` | `8` | Additional allocatable-memory headroom required on every eligible compute node. |
| `S3_BUCKET_NAME` | unset | Enables optional S3 RBAC check. |
| `S3_PROBE_NAMESPACE` | `default` | Namespace for optional in-cluster S3 probe. |
| `S3_PROBE_SERVICE_ACCOUNT` | unset | ServiceAccount expected to have S3 access, usually via IRSA/EKS Pod Identity. |
| `S3_PROBE_IMAGE` | `amazon/aws-cli:2.15.0` | Image for optional in-cluster S3 probe. |
| `SKIP_S3_PROBE` | `false` | Skip S3 probe with WARN. |
| `TIMEOUT_MIN` | `5` | Per-check timeout cap. |

Required tools:

- `aws`
- `kubectl`
- `jq`

## Check Parity

| Azure check | AWS equivalent |
|---|---|
| `rg` | `account` validates active AWS account and region context. |
| `vnet` | `vpc` validates EKS VPC, CIDR, and attached subnets. |
| `aks` | `eks` validates EKS `ACTIVE`, Kubernetes version, and OIDC issuer. |
| `nodes` | `nodes` validates system/compute/GPU node labels plus GPU instance type/zone detail. |
| `platform-capacity` | `platform-capacity` validates Ready, non-GPU compute nodes for OVDC replicas and allocatable memory. |
| `acr-pull` | `ecr-pull` validates ECR read access for EKS node role(s). |
| `blob-rbac` | `s3-rbac` optionally validates S3 permissions when `S3_BUCKET_NAME` is set. |
| `gpu-op` | `gpu-op` validates GPU Operator pod readiness and chart version when discoverable. |
| `gpu-resource` | `gpu-resource` validates advertised `nvidia.com/gpu`. |
| `cuda-smoke` | `cuda-smoke` runs an ephemeral `nvidia-smi` pod and cleans it up. |
| `blob-probe` | `s3-probe` optionally runs an in-cluster AWS CLI pod using the supplied service account. |

## Bash Script

Generate this script shape:

```bash
#!/bin/bash
set -uo pipefail

: "${CLUSTER_NAME:?Set CLUSTER_NAME before running}"
: "${AWS_REGION:?Set AWS_REGION before running}"

ECR_REPOSITORY_PREFIX="${ECR_REPOSITORY_PREFIX:-$CLUSTER_NAME}"
CUDA_IMAGE="${CUDA_IMAGE:-nvidia/cuda:12.4.0-base-ubuntu22.04}"
SKIP_CUDA="${SKIP_CUDA:-false}"
ALLOW_GPU_ZERO="${ALLOW_GPU_ZERO:-false}"
OVDC_REPLICAS="${OVDC_REPLICAS:-0}"
OVDC_PLATFORM_RESERVE_GIB="${OVDC_PLATFORM_RESERVE_GIB:-8}"
S3_PROBE_NAMESPACE="${S3_PROBE_NAMESPACE:-default}"
S3_PROBE_IMAGE="${S3_PROBE_IMAGE:-amazon/aws-cli:2.15.0}"
SKIP_S3_PROBE="${SKIP_S3_PROBE:-false}"
TIMEOUT_MIN="${TIMEOUT_MIN:-5}"

for tool in aws kubectl jq; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "ERROR: $tool is required but not installed" >&2
    exit 2
  }
done

kubectl --context "$CLUSTER_NAME" get nodes >/dev/null 2>&1 || {
  echo "ERROR: cannot reach cluster context $CLUSTER_NAME" >&2
  exit 2
}

mkdir -p generated
REPORT_FILE="generated/${CLUSTER_NAME}-validate-report.json"

PASS=0; WARN=0; FAIL=0
CHECKS=()
NODE_ROLE_ARNS=()

json_escape() {
  jq -Rn --arg s "$1" '$s'
}

record() {
  local id="$1" status="$2" detail="$3"
  CHECKS+=("{\"id\":$(json_escape "$id"),\"status\":$(json_escape "$status"),\"detail\":$(json_escape "$detail")}")
  case "$status" in
    PASS) ((PASS++)) ;;
    WARN) ((WARN++)) ;;
    FAIL) ((FAIL++)) ;;
  esac
  printf '[%s] %s - %s\n' "$status" "$id" "$detail"
}

# --- check: account ---
ACTIVE_ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"
if [[ -z "$ACTIVE_ACCOUNT" || "$ACTIVE_ACCOUNT" == "None" ]]; then
  record account FAIL "cannot resolve active AWS account"
elif [[ -n "${AWS_ACCOUNT_ID:-}" && "$ACTIVE_ACCOUNT" != "$AWS_ACCOUNT_ID" ]]; then
  record account FAIL "active account $ACTIVE_ACCOUNT does not match expected $AWS_ACCOUNT_ID"
elif [[ -n "${AWS_ACCOUNT_ID:-}" ]]; then
  record account PASS "active account matches $AWS_ACCOUNT_ID in $AWS_REGION"
else
  record account WARN "AWS_ACCOUNT_ID unset; active account is $ACTIVE_ACCOUNT in $AWS_REGION"
fi

CLUSTER_JSON="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --output json 2>/dev/null || true)"
CLUSTER_READABLE=true
if [[ -z "$CLUSTER_JSON" ]]; then
  record eks FAIL "cluster $CLUSTER_NAME not found or not readable in $AWS_REGION"
  CLUSTER_JSON='{"cluster":{}}'
  CLUSTER_READABLE=false
fi

# --- check: vpc ---
VPC_ID="$(echo "$CLUSTER_JSON" | jq -r '.cluster.resourcesVpcConfig.vpcId // ""')"
if [[ -z "$VPC_ID" ]]; then
  record vpc FAIL "cluster VPC ID unavailable"
else
  VPC_CIDR="$(aws ec2 describe-vpcs --region "$AWS_REGION" --vpc-ids "$VPC_ID" --query 'Vpcs[0].CidrBlock' --output text 2>/dev/null || true)"
  mapfile -t SUBNET_IDS < <(echo "$CLUSTER_JSON" | jq -r '.cluster.resourcesVpcConfig.subnetIds[]?')
  if [[ "${#SUBNET_IDS[@]}" -eq 0 ]]; then
    record vpc FAIL "VPC $VPC_ID has no EKS subnet IDs in cluster config"
  else
    SUBNET_NAMES="$(aws ec2 describe-subnets --region "$AWS_REGION" --subnet-ids "${SUBNET_IDS[@]}" \
      --query 'Subnets[].{id:SubnetId,name:Tags[?Key==`Name`]|[0].Value,cidr:CidrBlock}' \
      --output json 2>/dev/null | jq -r '.[] | (.name // .id) + " " + .cidr' | paste -sd ', ' -)"
    record vpc PASS "VPC $VPC_ID ${VPC_CIDR:-unknown}; subnets: ${SUBNET_NAMES:-unknown}"
  fi
fi

# --- check: eks ---
# Skip when describe-cluster was unreadable; the empty-CLUSTER_JSON guard above
# already recorded the eks FAIL, so re-recording here would double-count it.
if [[ "$CLUSTER_READABLE" == "true" ]]; then
  EKS_STATUS="$(echo "$CLUSTER_JSON" | jq -r '.cluster.status // ""')"
  EKS_VERSION="$(echo "$CLUSTER_JSON" | jq -r '.cluster.version // ""')"
  OIDC_ISSUER="$(echo "$CLUSTER_JSON" | jq -r '.cluster.identity.oidc.issuer // ""')"
  if [[ "$EKS_STATUS" == "ACTIVE" && -n "$OIDC_ISSUER" ]]; then
    record eks PASS "ACTIVE; v${EKS_VERSION:-unknown}; OIDC enabled"
  elif [[ "$EKS_STATUS" == "ACTIVE" ]]; then
    record eks FAIL "ACTIVE but OIDC issuer is unset"
  else
    record eks FAIL "status=${EKS_STATUS:-UNKNOWN}; version=${EKS_VERSION:-unknown}; oidc=${OIDC_ISSUER:-unset}"
  fi
fi

# --- collect node group roles for ECR/S3 checks ---
mapfile -t NODEGROUPS < <(aws eks list-nodegroups --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'nodegroups[]' --output text 2>/dev/null | tr '\t' '\n')
for ng in "${NODEGROUPS[@]}"; do
  [[ -z "$ng" ]] && continue
  role_arn="$(aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$ng" --region "$AWS_REGION" --query 'nodegroup.nodeRole' --output text 2>/dev/null || true)"
  [[ -n "$role_arn" && "$role_arn" != "None" ]] && NODE_ROLE_ARNS+=("$role_arn")
done

# --- check: nodes ---
NODES_JSON="$(kubectl --context "$CLUSTER_NAME" get nodes -o json 2>/dev/null || echo '{"items":[]}')"
SYSTEM_COUNT="$(echo "$NODES_JSON" | jq '[.items[] | select(.metadata.labels["node-type"]=="system")] | length')"
COMPUTE_COUNT="$(echo "$NODES_JSON" | jq '[.items[] | select(.metadata.labels["node-type"]=="compute")] | length')"
GPU_COUNT="$(echo "$NODES_JSON" | jq '[.items[] | select(.metadata.labels["node-type"]=="gpu")] | length')"
NOT_READY="$(echo "$NODES_JSON" | jq '[.items[] | select((.status.conditions // []) | map(select(.type=="Ready" and .status=="True")) | length == 0)] | length')"
GPU_DETAILS="$(echo "$NODES_JSON" | jq -r '[.items[] | select(.metadata.labels["node-type"]=="gpu") | ((.metadata.labels["node.kubernetes.io/instance-type"] // "unknown") + ", " + (.metadata.labels["topology.kubernetes.io/zone"] // "unknown"))] | unique | join("; ")')"
NODE_DETAIL="system=${SYSTEM_COUNT}, compute=${COMPUTE_COUNT}, gpu=${GPU_COUNT}${GPU_DETAILS:+ (${GPU_DETAILS})}"
if [[ "$NOT_READY" -gt 0 ]]; then
  record nodes FAIL "$NODE_DETAIL; not-ready=${NOT_READY}"
elif [[ "$SYSTEM_COUNT" -eq 0 ]]; then
  record nodes FAIL "$NODE_DETAIL; missing node-type=system"
elif [[ "$GPU_COUNT" -eq 0 && "$ALLOW_GPU_ZERO" == "true" ]]; then
  record nodes WARN "$NODE_DETAIL; no GPU nodes and ALLOW_GPU_ZERO=true"
elif [[ "$GPU_COUNT" -eq 0 ]]; then
  record nodes FAIL "$NODE_DETAIL; missing node-type=gpu"
else
  record nodes PASS "$NODE_DETAIL"
fi

# --- check: platform-capacity ---
# OVDC scheduling uses hard anti-affinity, so each replica needs one distinct
# Ready CPU compute node. Kubernetes allocatable memory is authoritative.
if ! [[ "$OVDC_REPLICAS" =~ ^[0-9]+$ ]] || \
   ! [[ "$OVDC_PLATFORM_RESERVE_GIB" =~ ^[0-9]+$ ]]; then
  record platform-capacity FAIL "OVDC_REPLICAS and OVDC_PLATFORM_RESERVE_GIB must be non-negative integers"
elif [[ "$OVDC_REPLICAS" -eq 0 ]]; then
  record platform-capacity WARN "not requested (OVDC_REPLICAS=0)"
elif ! [[ "${OVDC_MEMORY_REQUEST_GIB:-}" =~ ^[1-9][0-9]*$ ]]; then
  record platform-capacity FAIL "OVDC_MEMORY_REQUEST_GIB must be a positive integer when OVDC_REPLICAS>0"
else
  REQUIRED_MIB=$(( (OVDC_MEMORY_REQUEST_GIB + OVDC_PLATFORM_RESERVE_GIB) * 1024 ))
  ELIGIBLE_COMPUTE_NODES="$(echo "$NODES_JSON" | jq --argjson required "$REQUIRED_MIB" '
    def mem_mib:
      if test("Ki$") then (rtrimstr("Ki") | tonumber / 1024)
      elif test("Mi$") then (rtrimstr("Mi") | tonumber)
      elif test("Gi$") then (rtrimstr("Gi") | tonumber * 1024)
      elif test("K$") then (rtrimstr("K") | tonumber * 1000 / 1048576)
      elif test("M$") then (rtrimstr("M") | tonumber * 1000000 / 1048576)
      elif test("G$") then (rtrimstr("G") | tonumber * 1000000000 / 1048576)
      else (tonumber / 1048576) end;
    [.items[] |
      select(.metadata.labels["node-type"] == "compute") |
      select(any(.status.conditions[]?; .type == "Ready" and .status == "True")) |
      select(((.status.allocatable["nvidia.com/gpu"] // "0") | tonumber) == 0) |
      select((.status.allocatable.memory | mem_mib) >= $required)
    ] | length')"
  REQUIRED_GIB=$((OVDC_MEMORY_REQUEST_GIB + OVDC_PLATFORM_RESERVE_GIB))
  if [[ "$ELIGIBLE_COMPUTE_NODES" -ge "$OVDC_REPLICAS" ]]; then
    record platform-capacity PASS "OVDC replicas=${OVDC_REPLICAS}; eligible compute nodes=${ELIGIBLE_COMPUTE_NODES}; required allocatable memory per node=${REQUIRED_GIB} GiB"
  else
    record platform-capacity FAIL "OVDC replicas=${OVDC_REPLICAS}; eligible compute nodes=${ELIGIBLE_COMPUTE_NODES}; need ${OVDC_REPLICAS} Ready non-GPU node-type=compute nodes with at least ${REQUIRED_GIB} GiB allocatable each"
  fi
fi

# --- check: ecr-pull ---
ECR_REPO_JSON="$(aws ecr describe-repositories --region "$AWS_REGION" \
  --query "repositories[?starts_with(repositoryName, '${ECR_REPOSITORY_PREFIX}/')].{name:repositoryName,arn:repositoryArn}" \
  --output json 2>/dev/null || echo '[]')"
ECR_REPOS="$(echo "$ECR_REPO_JSON" | jq -r '.[].name' | paste -sd ' ' -)"
mapfile -t ECR_REPO_ARNS < <(echo "$ECR_REPO_JSON" | jq -r '.[].arn')
ECR_REPO_COUNT="${#ECR_REPO_ARNS[@]}"
if [[ "${#NODE_ROLE_ARNS[@]}" -eq 0 ]]; then
  record ecr-pull WARN "no EKS node role ARNs found; cannot prove ECR pull access"
else
  ECR_AUTH_ACTION=(ecr:GetAuthorizationToken)
  ECR_REPO_ACTIONS=(ecr:BatchCheckLayerAvailability ecr:GetDownloadUrlForLayer ecr:BatchGetImage)
  all_allowed=true
  sim_available=true
  for role_arn in "${NODE_ROLE_ARNS[@]}"; do
    auth_sim_json="$(aws iam simulate-principal-policy \
      --policy-source-arn "$role_arn" \
      --action-names "${ECR_AUTH_ACTION[@]}" \
      --resource-arns "*" \
      --output json 2>/dev/null || true)"
    repo_sim_json=""
    if [[ "${#ECR_REPO_ARNS[@]}" -gt 0 ]]; then
      repo_sim_json="$(aws iam simulate-principal-policy \
        --policy-source-arn "$role_arn" \
        --action-names "${ECR_REPO_ACTIONS[@]}" \
        --resource-arns "${ECR_REPO_ARNS[@]}" \
        --output json 2>/dev/null || true)"
    fi
    if [[ -z "$auth_sim_json" || ( "${#ECR_REPO_ARNS[@]}" -gt 0 && -z "$repo_sim_json" ) ]]; then
      sim_available=false
      role_name="${role_arn##*/}"
      attached="$(aws iam list-attached-role-policies --role-name "$role_name" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null || true)"
      if [[ "$attached" != *"AmazonEC2ContainerRegistryReadOnly"* && "$attached" != *"AmazonEC2ContainerRegistryPowerUser"* ]]; then
        all_allowed=false
      fi
    else
      denied="$(echo "$auth_sim_json" | jq '[.EvaluationResults[] | select(.EvalDecision != "allowed")] | length')"
      if [[ "${#ECR_REPO_ARNS[@]}" -gt 0 ]]; then
        repo_denied="$(echo "$repo_sim_json" | jq '[.EvaluationResults[] | select(.EvalDecision != "allowed")] | length')"
        denied=$((denied + repo_denied))
      fi
      [[ "$denied" -gt 0 ]] && all_allowed=false
    fi
  done
  if [[ "$all_allowed" == "true" ]]; then
    if [[ "$ECR_REPO_COUNT" -gt 0 ]]; then
      record ecr-pull PASS "ECR read allowed for node role(s); ${ECR_REPO_COUNT} repo(s) under ${ECR_REPOSITORY_PREFIX}/"
    else
      record ecr-pull PASS "ECR read allowed for node role(s); no repos yet under ${ECR_REPOSITORY_PREFIX}/"
    fi
  elif [[ "$sim_available" == "false" ]]; then
    record ecr-pull WARN "could not prove ECR read for every node role; iam:SimulatePrincipalPolicy unavailable and managed policy fallback did not match"
  else
    record ecr-pull FAIL "one or more node roles lack required ECR read actions"
  fi
fi

# --- check: s3-rbac ---
if [[ -z "${S3_BUCKET_NAME:-}" ]]; then
  record s3-rbac WARN "Skipped (no S3_BUCKET_NAME)"
elif [[ "${#NODE_ROLE_ARNS[@]}" -eq 0 && -z "${S3_PROBE_ROLE_ARN:-}" ]]; then
  record s3-rbac WARN "S3_BUCKET_NAME set, but no role ARN is available for IAM simulation"
else
  S3_ROLE_ARN="${S3_PROBE_ROLE_ARN:-${NODE_ROLE_ARNS[0]}}"
  s3_sim="$(aws iam simulate-principal-policy \
    --policy-source-arn "$S3_ROLE_ARN" \
    --action-names s3:ListBucket s3:GetObject \
    --resource-arns "arn:aws:s3:::${S3_BUCKET_NAME}" "arn:aws:s3:::${S3_BUCKET_NAME}/*" \
    --output json 2>/dev/null || true)"
  if [[ -z "$s3_sim" ]]; then
    record s3-rbac WARN "Could not simulate S3 access for $S3_ROLE_ARN"
  else
    denied="$(echo "$s3_sim" | jq '[.EvaluationResults[] | select(.EvalDecision != "allowed")] | length')"
    if [[ "$denied" -eq 0 ]]; then
      record s3-rbac PASS "S3 List/Get allowed on $S3_BUCKET_NAME for ${S3_ROLE_ARN##*/}"
    else
      record s3-rbac FAIL "S3 List/Get not fully allowed on $S3_BUCKET_NAME for ${S3_ROLE_ARN##*/}"
    fi
  fi
fi

# --- check: gpu-op ---
PODS_JSON="$(kubectl --context "$CLUSTER_NAME" get pods -n gpu-operator -o json 2>/dev/null || echo '{"items":[]}')"
GPU_OP_TOTAL="$(echo "$PODS_JSON" | jq '.items | length')"
GPU_OP_NOT_READY="$(echo "$PODS_JSON" | jq '[.items[] | select(.status.phase != "Succeeded") | select(((.status.conditions // []) | map(select(.type=="Ready" and .status=="True")) | length) == 0)] | length')"
GPU_OP_READY=$((GPU_OP_TOTAL - GPU_OP_NOT_READY))
CHART_VER="$(helm --kube-context "$CLUSTER_NAME" list -n gpu-operator -o json 2>/dev/null | jq -r '.[] | select(.name=="gpu-operator") | .chart // ""' | sed 's/^gpu-operator-v\?//' || true)"
if [[ "$GPU_OP_TOTAL" -eq 0 ]]; then
  record gpu-op FAIL "no pods found in gpu-operator namespace"
elif [[ "$GPU_OP_NOT_READY" -eq 0 ]]; then
  if [[ -n "${GPU_OPERATOR_VERSION:-}" && -n "$CHART_VER" && "$CHART_VER" != "${GPU_OPERATOR_VERSION#v}" ]]; then
    record gpu-op WARN "${GPU_OP_READY}/${GPU_OP_TOTAL} pods Ready; chart v${CHART_VER}, expected v${GPU_OPERATOR_VERSION#v}"
  else
    record gpu-op PASS "${GPU_OP_READY}/${GPU_OP_TOTAL} pods Ready${CHART_VER:+; chart v$CHART_VER}"
  fi
else
  record gpu-op FAIL "${GPU_OP_READY}/${GPU_OP_TOTAL} pods Ready"
fi

# --- check: gpu-resource ---
GPU_RESOURCE_NODES="$(echo "$NODES_JSON" | jq '[.items[] | select((.status.allocatable["nvidia.com/gpu"] // "0" | tonumber) >= 1)] | length')"
GPU_RESOURCE_TOTAL="$(echo "$NODES_JSON" | jq '[.items[] | (.status.allocatable["nvidia.com/gpu"] // "0" | tonumber)] | add // 0')"
if [[ "$GPU_RESOURCE_NODES" -gt 0 ]]; then
  record gpu-resource PASS "${GPU_RESOURCE_NODES} node(s) advertise nvidia.com/gpu=${GPU_RESOURCE_TOTAL}"
elif [[ "$ALLOW_GPU_ZERO" == "true" ]]; then
  record gpu-resource WARN "no nodes advertise nvidia.com/gpu and ALLOW_GPU_ZERO=true"
else
  record gpu-resource FAIL "no nodes advertise nvidia.com/gpu"
fi

# --- check: cuda-smoke ---
SMOKE_POD="aws-validate-cuda-smoke-$$"
cleanup_smoke() {
  kubectl --context "$CLUSTER_NAME" delete pod "$SMOKE_POD" --ignore-not-found >/dev/null 2>&1 || true
}
if [[ "$SKIP_CUDA" == "true" ]]; then
  record cuda-smoke WARN "Skipped (SKIP_CUDA=true)"
elif [[ "$GPU_RESOURCE_NODES" -eq 0 ]]; then
  record cuda-smoke WARN "Skipped (no GPU nodes available)"
else
  trap cleanup_smoke EXIT
  kubectl --context "$CLUSTER_NAME" run "$SMOKE_POD" \
    --image="$CUDA_IMAGE" \
    --restart=Never \
    --overrides='{"spec":{"nodeSelector":{"node-type":"gpu"},"tolerations":[{"key":"nvidia.com/gpu","operator":"Exists","effect":"NoSchedule"}],"containers":[{"name":"smoke","image":"'"$CUDA_IMAGE"'","command":["nvidia-smi"],"resources":{"limits":{"nvidia.com/gpu":"1"}}}]}}' \
    >/dev/null 2>&1
  end=$((SECONDS + TIMEOUT_MIN * 60))
  phase=""
  while (( SECONDS < end )); do
    phase="$(kubectl --context "$CLUSTER_NAME" get pod "$SMOKE_POD" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [[ "$phase" == "Succeeded" || "$phase" == "Failed" ]] && break
    sleep 5
  done

  if [[ "$phase" == "Succeeded" ]]; then
    GPU_MODEL="$(kubectl --context "$CLUSTER_NAME" logs "$SMOKE_POD" 2>/dev/null | grep -Eom1 'A10|L40S|T4|H100|A100|V100|L4' || true)"
    record cuda-smoke PASS "nvidia-smi pod returned 0${GPU_MODEL:+; $GPU_MODEL detected}"
  else
    detail="phase=${phase:-UNKNOWN}"
    pod_log="$(kubectl --context "$CLUSTER_NAME" logs "$SMOKE_POD" 2>/dev/null | tail -20 | tr '\n' ' ' || true)"
    [[ -n "$pod_log" ]] && detail="$detail; logs: $pod_log"
    record cuda-smoke FAIL "nvidia-smi pod did not complete successfully ($detail)"
  fi
  cleanup_smoke
  trap - EXIT
fi

# --- check: s3-probe ---
S3_POD="aws-validate-s3-probe-$$"
cleanup_s3_probe() {
  kubectl --context "$CLUSTER_NAME" delete pod "$S3_POD" -n "$S3_PROBE_NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
}
if [[ "$SKIP_S3_PROBE" == "true" || -z "${S3_BUCKET_NAME:-}" || -z "${S3_PROBE_SERVICE_ACCOUNT:-}" ]]; then
  record s3-probe WARN "Skipped (SKIP_S3_PROBE=${SKIP_S3_PROBE} S3_BUCKET_NAME=${S3_BUCKET_NAME:-unset} S3_PROBE_SERVICE_ACCOUNT=${S3_PROBE_SERVICE_ACCOUNT:-unset})"
else
  trap cleanup_s3_probe EXIT
  kubectl --context "$CLUSTER_NAME" run "$S3_POD" -n "$S3_PROBE_NAMESPACE" \
    --image="$S3_PROBE_IMAGE" \
    --restart=Never \
    --overrides='{"spec":{"serviceAccountName":"'"$S3_PROBE_SERVICE_ACCOUNT"'","containers":[{"name":"aws","image":"'"$S3_PROBE_IMAGE"'","command":["aws","s3api","list-objects-v2","--bucket","'"$S3_BUCKET_NAME"'","--max-items","1"]}]}}' \
    >/dev/null 2>&1
  if kubectl --context "$CLUSTER_NAME" wait pod "$S3_POD" -n "$S3_PROBE_NAMESPACE" --for=jsonpath='{.status.phase}'=Succeeded --timeout="${TIMEOUT_MIN}m" >/dev/null 2>&1; then
    record s3-probe PASS "serviceAccount=$S3_PROBE_SERVICE_ACCOUNT listed $S3_BUCKET_NAME"
  else
    phase="$(kubectl --context "$CLUSTER_NAME" get pod "$S3_POD" -n "$S3_PROBE_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo unknown)"
    record s3-probe FAIL "S3 probe failed (phase=$phase serviceAccount=$S3_PROBE_SERVICE_ACCOUNT bucket=$S3_BUCKET_NAME)"
  fi
  cleanup_s3_probe
  trap - EXIT
fi

# --- emit report ---
printf '{ "cluster": "%s", "timestamp": "%s", "summary": { "pass": %d, "warn": %d, "fail": %d }, "checks": [%s] }\n' \
  "$CLUSTER_NAME" "$(date -u +%FT%TZ)" "$PASS" "$WARN" "$FAIL" "$(IFS=,; echo "${CHECKS[*]}")" \
  | jq . > "$REPORT_FILE"

echo ""
echo "=== Summary: PASS=$PASS WARN=$WARN FAIL=$FAIL ==="
echo "Report: $REPORT_FILE"

[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
```

## Validation Checklist

- [ ] Report uses Azure-compatible `cluster`, `timestamp`, `summary`, `checks[].id`, `checks[].status`, and `checks[].detail` fields.
- [ ] Preflight exits with code 2 if a tool is missing or the cluster is unreachable.
- [ ] Account check validates `AWS_ACCOUNT_ID` when supplied.
- [ ] VPC check reports the EKS VPC CIDR and attached subnet names/CIDRs.
- [ ] EKS check requires `ACTIVE` and OIDC issuer.
- [ ] Node check verifies `node-type=system` and `node-type=gpu`; `ALLOW_GPU_ZERO=true` downgrades missing GPU nodes to WARN.
- [ ] Platform-capacity check requires one distinct Ready, non-GPU
      `node-type=compute` node per OVDC replica and gates on Kubernetes
      allocatable memory, not nominal EC2 instance memory.
- [ ] ECR pull check proves required read actions with IAM simulation when possible, with managed-policy fallback.
- [ ] Optional S3 RBAC and S3 probe checks WARN when not configured.
- [ ] GPU Operator check inspects pod Ready conditions, not just pod phase.
- [ ] CUDA smoke pod requests one GPU, waits for `Succeeded`, and is deleted on every exit path.
- [ ] No secret values, kubeconfig contents, ECR passwords, or AWS credentials are printed.
