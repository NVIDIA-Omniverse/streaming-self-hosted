---
name: eks-nodes
description: Generate Terraform for additional EKS managed node groups: compute and GPU pools for KAS/NVCF workloads. Use after eks-cluster and before eks-storage.
version: "1.0.0"
author: NVIDIA Omniverse Streaming
tags: ["aws", "eks", "node-groups", "gpu"]
tools: ["Shell", "Read", "Write"]
---

<!-- SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved. -->
<!-- SPDX-License-Identifier: CC-BY-4.0 AND Apache-2.0 -->

# EKS Additional Node Groups

## What This Skill Produces

Generate Terraform for workload node groups on an existing EKS cluster:

- compute managed node group for CPU-heavy services such as streaming proxy,
  gateway-side helpers, and OVDC
- GPU managed node group for function workloads

Do not create the EKS control plane here. Do not install GPU Operator here.

## Inputs

Required:

| Input | Notes |
|---|---|
| `CLUSTER_NAME` | Existing EKS cluster name. |
| `private_subnet_ids` | Private subnet IDs from `aws-iam-vpc`. |
| `node_role_arn` or node IAM role config | Role used by managed node groups. |

Defaults:

| Input | Default |
|---|---|
| compute node instance type | `m6i.2xlarge` |
| compute min/max/desired | `1` / `3` / `1` |
| GPU node instance type | `g6.12xlarge` or closest quota-approved GPU SKU |
| GPU AMI type | `AL2023_x86_64_NVIDIA` |
| GPU min/max/desired | `0` / `2` / `1` |

OVDC capacity inputs:

| Input | Default | Notes |
|---|---|---|
| `OVDC_REPLICAS` | `0` | Number of OVDC replicas the compute pool must host. |
| `OVDC_MEMORY_REQUEST_GIB` | required when `OVDC_REPLICAS > 0` | Rendered pod request rounded up to GiB. |
| `OVDC_PLATFORM_RESERVE_GIB` | `8` | Allocatable-memory headroom per OVDC node. |

## OVDC Compute Capacity Contract

When `OVDC_REPLICAS > 0`:

1. Require `OVDC_MEMORY_REQUEST_GIB` to be a positive integer.
2. Set compute minimum and desired capacity to at least `OVDC_REPLICAS`.
   OVDC uses hard pod anti-affinity, so each replica needs a separate eligible
   node.
3. Choose a CPU instance type whose physical memory is greater than
   `OVDC_MEMORY_REQUEST_GIB + OVDC_PLATFORM_RESERVE_GIB`. Nominal instance RAM
   is only a planning preflight; kubelet and operating-system reservations make
   the joined node's allocatable memory authoritative.
4. Keep `node-type=compute` on the pool. Do not satisfy an undersized compute
   pool by allowing OVDC onto a GPU node.
5. Pass the same three inputs to `eks-validate`, which must find at least
   `OVDC_REPLICAS` Ready, non-GPU compute nodes with enough allocatable memory.

Useful planning examples with the default 8 GiB reserve:

| OVDC request | Minimum planning class |
|---|---|
| 16 GiB | 32 GiB physical memory, subject to the allocatable gate |
| 32 GiB | 64 GiB physical memory |
| 56 GiB | 128 GiB physical memory; 64 GiB nominal is too close after reservations |

## Node Group Labels

Required labels:

```text
compute: node-type=compute
gpu:     node-type=gpu, nvidia.com/gpu.deploy.driver=false
```

Terraform module values should carry the same contract:

```hcl
ami_type = "AL2023_x86_64_NVIDIA"

labels = {
  "node-type"                    = "gpu"
  "nvidia.com/gpu.deploy.driver" = "false"
}
```

The GPU node group must use `ami_type = "AL2023_x86_64_NVIDIA"` or a reviewed
custom GPU AMI with the NVIDIA driver and container toolkit already installed.

## Instance Metadata (IMDS)

Managed node groups launch instances with the default IMDS
`HttpPutResponseHopLimit = 1`. A hop limit of 1 lets host-network pods reach
IMDS but blocks ordinary (extra-hop) pods, so controllers that rely on the node
instance-role credentials cannot read them. The `aws-ebs-csi-driver`
**controller** (a normal Deployment) then CrashLoops with
`no EC2 IMDS role found … context deadline exceeded`, while its hostNetwork
**node** DaemonSet works — persistent-volume provisioning stays broken.

Each node group must therefore raise the hop limit to `2` via a launch template
`metadata_options` block (so it survives scaling), and keep IMDSv2 required:

```hcl
metadata_options {
  http_endpoint               = "enabled"
  http_tokens                 = "required"  # IMDSv2
  http_put_response_hop_limit = 2           # allow non-hostNetwork pods to reach IMDS
}
```

When the node group is created via `aws_eks_node_group`, attach this through a
`launch_template` (managed node groups do not expose `metadata_options`
directly). Alternatively, provision IRSA / EKS Pod Identity for the EBS CSI
driver (and other controllers) so they do not depend on node-role IMDS at all;
in that case the hop limit may stay at 1. Raising the hop limit is the simpler
default and mirrors AWS best practice for EKS + IMDSv2.

## Generation Rules

- Read `aws-tf-conventions` before generating Terraform.
- Keep GPU Operator out of Terraform; this skill only creates nodes.
- GPU `desired_size` defaults to `1` so a freshly applied cluster has a GPU
  node and `eks-validate` `gpu-resource`/`cuda-smoke` checks pass out of the
  box. If you intentionally set GPU min/desired to zero (scale-to-zero for
  cost), `eks-validate` will FAIL those checks unless you run it with
  `ALLOW_GPU_ZERO=true`, which downgrades them to WARN.
- Add taints only when the workload scheduling contract requires them; if a
  taint is used for GPU nodes, make sure validation and smoke-test pod include
  the matching toleration.
- When OVDC capacity is requested, reject generation if the selected compute
  instance's published memory cannot exceed request plus reserve. Still require
  the post-join allocatable-memory validation; the catalog value cannot prove
  schedulable capacity.

## Validation Checklist

- [ ] Compute nodes are labeled `node-type=compute`.
- [ ] When `OVDC_REPLICAS > 0`, compute min/desired capacity is at least the
      replica count and the selected CPU instance passes the request-plus-reserve
      planning check.
- [ ] OVDC capacity is never satisfied by GPU nodes; live allocatable memory is
      delegated to the `eks-validate` platform-capacity gate.
- [ ] GPU nodes are labeled `node-type=gpu`.
- [ ] GPU nodes include `nvidia.com/gpu.deploy.driver=false`.
- [ ] GPU node group uses `AL2023_x86_64_NVIDIA` or reviewed equivalent.
- [ ] Autoscaling bounds are explicit.
- [ ] Node groups set IMDS `http_put_response_hop_limit = 2` (via launch
      template) with `http_tokens = "required"`, or IRSA / EKS Pod Identity is
      provisioned for IMDS-dependent controllers (e.g. `aws-ebs-csi-driver`).
- [ ] No Helm releases or Kubernetes objects are created here.
