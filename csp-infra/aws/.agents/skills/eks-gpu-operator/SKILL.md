---
name: eks-gpu-operator
description: Generate a Helm-based NVIDIA GPU Operator install script for EKS clusters whose GPU node group uses the AWS GPU-optimized AMI. Use after eks-nodes and before eks-validate.
version: "1.0.0"
author: NVIDIA Omniverse Streaming
tags: ["aws", "eks", "gpu-operator", "helm"]
tools: ["Shell", "Read", "Write"]
---

<!-- SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved. -->
<!-- SPDX-License-Identifier: CC-BY-4.0 AND Apache-2.0 -->

# NVIDIA GPU Operator On EKS

## What This Skill Produces

Generate `generated/<cluster-name>-gpu-operator.sh`, a bash script that
installs or upgrades NVIDIA GPU Operator on an existing EKS cluster.

Terraform must not install GPU Operator. Keep the Helm release outside
Terraform state.

## Prerequisites

- kubeconfig context works for `CLUSTER_NAME`
- GPU node group exists, or the user accepts that validation may warn while it
  is scaled to zero
- GPU nodes use `ami_type = "AL2023_x86_64_NVIDIA"` or a reviewed custom GPU AMI
  with driver and container toolkit already installed

## Inputs

| Input | Default |
|---|---|
| `CLUSTER_NAME` | required |
| `GPU_OPERATOR_VERSION` | `25.3.1` |

## EKS Rules

The AWS infra path uses EKS GPU-optimized AMIs. Those AMIs already provide the
NVIDIA driver and container toolkit, so install GPU Operator with:

```text
driver.enabled=false
toolkit.enabled=false
operator.defaultRuntime=containerd
```

GPU Operator still installs Kubernetes GPU operands such as device plugin,
DCGM, node feature discovery, and validators.

## Bash Script

Generate this script shape:

```bash
#!/bin/bash
set -euo pipefail

: "${CLUSTER_NAME:?Set CLUSTER_NAME before running}"
GPU_OPERATOR_VERSION="${GPU_OPERATOR_VERSION:-25.3.1}"

kubectl --context "$CLUSTER_NAME" get nodes >/dev/null

helm repo add nvidia https://helm.ngc.nvidia.com/nvidia --force-update
helm repo update nvidia

tmpdir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

helm pull nvidia/gpu-operator \
  --version "$GPU_OPERATOR_VERSION" \
  --untar \
  --untardir "$tmpdir"

kubectl --context "$CLUSTER_NAME" create namespace gpu-operator \
  --dry-run=client -o yaml | kubectl --context "$CLUSTER_NAME" apply -f -

kubectl --context "$CLUSTER_NAME" apply -f "$tmpdir/gpu-operator/crds"

helm upgrade --install gpu-operator nvidia/gpu-operator \
  --kube-context "$CLUSTER_NAME" \
  --namespace gpu-operator \
  --version "$GPU_OPERATOR_VERSION" \
  --set operator.defaultRuntime=containerd \
  --set driver.enabled=false \
  --set toolkit.enabled=false \
  --wait \
  --timeout 20m
```

## Teardown

For stack destroy, remove GPU Operator before Terraform destroys the cluster:

```bash
helm uninstall gpu-operator \
  --kube-context "$CLUSTER_NAME" \
  --namespace gpu-operator \
  --wait --timeout 5m || true
kubectl --context "$CLUSTER_NAME" delete namespace gpu-operator --ignore-not-found
```

## Troubleshooting

| Error | Cause | Fix |
|---|---|---|
| `nvidia-driver-daemonset` shows `ErrImagePull` | GPU Operator is trying to install a driver on plain AL2023 | Use `ami_type = "AL2023_x86_64_NVIDIA"`, label GPU nodes with `nvidia.com/gpu.deploy.driver=false`, and set `driver.enabled=false`, `toolkit.enabled=false`. |
| GPU node is `Ready` but has no `nvidia.com/gpu` allocatable value | GPU Operator operands are not ready or the GPU node group is scaled to zero | Scale the GPU node group to at least one node, wait for `gpu-operator` pods, then re-check allocatable resources. |

## Validation Checklist

- [ ] Helm release is installed outside Terraform state.
- [ ] `driver.enabled=false` and `toolkit.enabled=false` are set.
- [ ] CRDs are applied before Helm install/upgrade.
- [ ] Script uses a unique temporary directory and cleans it up.
- [ ] Teardown removes the Helm release before Terraform destroy.
