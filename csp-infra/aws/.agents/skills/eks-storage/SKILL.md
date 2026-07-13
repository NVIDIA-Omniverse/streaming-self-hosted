---
name: eks-storage
description: Install the aws-ebs-csi-driver EKS managed addon and create a default gp3 StorageClass. Use after eks-nodes and before ecr or eks-gpu-operator. Closes the gap where eks-nodes sets IMDS hop-limit=2 for the driver but nothing installs it.
version: "1.0.0"
author: NVIDIA Omniverse Streaming
tags: ["aws", "eks", "ebs-csi", "storage", "storageclass"]
tools: ["Shell", "Read", "Write"]
---

<!-- SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved. -->
<!-- SPDX-License-Identifier: CC-BY-4.0 AND Apache-2.0 -->

# EKS Storage — EBS CSI Driver and Default StorageClass

## What This Skill Produces

1. A Terraform `aws_iam_role_policy_attachment` resource that attaches
   `AmazonEBSCSIDriverPolicy` to the existing EKS node IAM role, so the
   EBS CSI controller can call EC2 APIs using node-role credentials read
   from IMDS. The hop-limit-2 launch-template setting that `eks-nodes`
   already configures makes this work for non-hostNetwork pods.
2. `generated/<cluster-name>-storage.sh` — a bash script that:
   - Installs or upgrades the `aws-ebs-csi-driver` EKS managed addon.
   - Creates a `gp3` StorageClass marked as the cluster default.
   - Removes the `storageclass.kubernetes.io/is-default-class` annotation
     from the legacy `gp2` StorageClass (non-functional on EKS 1.29+ which
     dropped the in-tree `kubernetes.io/aws-ebs` provisioner).

This skill does **not** configure IRSA or EKS Pod Identity. The node-role +
IMDS hop-limit-2 path is sufficient and simpler. If per-pod IAM isolation is
required, add IRSA outside this skill.

## Why

EKS clusters come with a `gp2` StorageClass backed by the removed in-tree
provisioner `kubernetes.io/aws-ebs`. On EKS 1.29+ that provisioner is absent,
so any PVC that lands on `gp2` hangs `Pending` forever. The fix is a working
CSI driver and a `gp3` default StorageClass. The driver uses the node IAM role
for EC2 API calls provided the IMDS hop limit is 2, which `eks-nodes` already
sets via launch template.

The `eks-nodes` skill documents this dependency at its IMDS section and
validation checklist (hop-limit-2 note), but no prior skill installs the driver
or policies it. This skill closes that gap.

## Prerequisites

- `eks-nodes` has been applied (IMDS `http_put_response_hop_limit = 2` is set
  via launch template on every node group).
- The node IAM role name is known (output from `eks-cluster` or `eks-nodes`
  Terraform state).
- kubeconfig context works for `CLUSTER_NAME`.

## Inputs

| Input | Notes |
|---|---|
| `CLUSTER_NAME` | Existing EKS cluster name. |
| `AWS_REGION` | Region where the cluster runs. |
| `node_role_name` | Node IAM role name; referenced as a Terraform variable or literal. |
| `EBS_CSI_ADDON_VERSION` | Optional. Leave unset to let AWS manage the latest compatible version. |

## Terraform — IAM Policy Attachment

Add a single resource in the cluster's Terraform root module (same state file
as `eks-nodes`). Do not create a new workspace or module for one resource.

```hcl
# Grants the aws-ebs-csi-driver controller EC2 permissions via node-role IMDS.
# Requires http_put_response_hop_limit = 2 in the eks-nodes launch template.
resource "aws_iam_role_policy_attachment" "ebs_csi_driver" {
  role       = var.node_role_name   # or module.eks_nodes.node_role_name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}
```

Apply the IAM change before running the storage script:

```bash
terraform -chdir="generated/terraform/aws/envs/${CLUSTER_NAME}" \
  plan -target=aws_iam_role_policy_attachment.ebs_csi_driver -out=tfplan
terraform -chdir="generated/terraform/aws/envs/${CLUSTER_NAME}" apply tfplan
```

## Bash Script

Generate `generated/<cluster>-storage.sh`:

```bash
#!/bin/bash
set -euo pipefail

: "${CLUSTER_NAME:?Set CLUSTER_NAME before running}"
: "${AWS_REGION:?Set AWS_REGION before running}"
EBS_CSI_ADDON_VERSION="${EBS_CSI_ADDON_VERSION:-}"   # empty = AWS-managed latest

echo "==> Installing aws-ebs-csi-driver addon on cluster ${CLUSTER_NAME}"

addon_args=(
  --cluster-name "$CLUSTER_NAME"
  --region       "$AWS_REGION"
  --addon-name   "aws-ebs-csi-driver"
)
[[ -n "$EBS_CSI_ADDON_VERSION" ]] && addon_args+=(--addon-version "$EBS_CSI_ADDON_VERSION")

if aws eks describe-addon "${addon_args[@]}" \
     --query "addon.addonName" --output text 2>/dev/null \
     | grep -q "aws-ebs-csi-driver"; then
  echo "    addon exists — updating"
  aws eks update-addon "${addon_args[@]}"
else
  echo "    addon absent — creating"
  aws eks create-addon "${addon_args[@]}"
fi

echo "==> Waiting for addon to become ACTIVE (up to 5 min)"
aws eks wait addon-active \
  --cluster-name "$CLUSTER_NAME" \
  --region       "$AWS_REGION" \
  --addon-name   "aws-ebs-csi-driver"

echo "==> Creating gp3 default StorageClass"
kubectl --context "$CLUSTER_NAME" apply -f - <<'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
allowVolumeExpansion: true
parameters:
  type: gp3
  encrypted: "true"
EOF

echo "==> Removing default annotation from legacy gp2 StorageClass"
kubectl --context "$CLUSTER_NAME" annotate storageclass gp2 \
  storageclass.kubernetes.io/is-default-class- \
  --overwrite 2>/dev/null || true

echo "==> Verifying default StorageClass"
kubectl --context "$CLUSTER_NAME" get storageclass
echo "done."
```

## Generation Rules

- Read `aws-tf-conventions` before generating Terraform.
- The IAM policy attachment goes in the same root module as `eks-nodes` (same
  state file). Do not create a new Terraform workspace for a single resource.
- The storage script must be idempotent: `create-addon` only when absent,
  `apply -f -` is safe to re-run, `annotate --overwrite || true` handles
  missing gp2 gracefully.
- Do not pin `EBS_CSI_ADDON_VERSION` by default; let AWS pick the latest
  compatible version for the cluster unless the user specifies one.
- Always set `volumeBindingMode: WaitForFirstConsumer` — required for multi-AZ
  clusters so PVCs bind in the same AZ as the scheduled pod.
- Always set `encrypted: "true"` on the gp3 StorageClass.

## Destroy Notes

The EKS managed addon is deleted automatically when the EKS cluster is
destroyed by Terraform. The gp3 StorageClass is a Kubernetes object that
disappears with the cluster. No explicit teardown step is needed beyond what
`aws-infra` already does.

## Validation Checklist

- [ ] `AmazonEBSCSIDriverPolicy` is attached to the node IAM role.
- [ ] `aws-ebs-csi-driver` addon reaches `ACTIVE` state.
- [ ] `gp3` StorageClass exists and is marked `is-default-class: "true"`.
- [ ] `gp2` StorageClass no longer carries the default annotation.
- [ ] `volumeBindingMode: WaitForFirstConsumer` is set on gp3.
- [ ] `encrypted: "true"` is set on gp3.
- [ ] A test PVC using the default StorageClass binds within 30 s.
