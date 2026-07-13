---
name: aws-infra
description: Orchestrate the AWS KAS/NVCF EKS foundation by delegating to the component AWS infrastructure skills: aws-tf-conventions, aws-iam-vpc, eks-cluster, eks-nodes, eks-storage, ecr, eks-gpu-operator, eks-validate, and optionally ecr-mirror. Use when setting up, reviewing, or tearing down the full AWS foundation end-to-end; not for runtime installation, functions, or stream validation.
version: "1.1.0"
author: NVIDIA Omniverse Streaming
tags: ["aws", "eks", "terraform", "gpu"]
tools: ["Shell", "Read", "Write"]
---

<!-- SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved. -->
<!-- SPDX-License-Identifier: CC-BY-4.0 AND Apache-2.0 -->

# AWS Infra Orchestrator

## Purpose

Set up the AWS infrastructure foundation for KAS/NVCF self-hosted on EKS by
reading and applying the smaller component skills. This skill is the entrypoint
for end-to-end AWS foundation work; it should not carry detailed Terraform,
node, GPU Operator, or validation logic directly.

Use this for infra setup only. Use later NVCF skills for runtime installation,
NVCA, functions, stream validation, caches, UCC, DDCS, or storage APIs. Use
`ecr-mirror` after ECR exists when images or OCI Helm charts need to be mirrored
from NGC into ECR.

## Component Skills

Run or read these skills in order:

| Stage | Skill | Scope |
|---|---|---|
| 00 | `aws-tf-conventions` | Terraform ownership, tags, state, secrets, and module layout rules. |
| 01 | `aws-iam-vpc` | VPC, subnets, routes, NAT/IGW, and IAM foundation. |
| 02 | `eks-cluster` | EKS control plane, OIDC provider, system node group, and kubeconfig handoff. |
| 03 | `eks-nodes` | Compute and GPU managed node groups, labels, AMI type, and scaling. |
| 04 | `eks-storage` | EBS CSI driver addon, node-role IAM policy, and default gp3 StorageClass. |
| 05 | `ecr` | ECR repository namespace and EKS pull permissions. |
| 06 | `eks-gpu-operator` | NVIDIA GPU Operator Helm install for EKS GPU-optimized AMIs. |
| 07 | `eks-validate` | Read-only health checks plus ephemeral CUDA smoke test. |
| optional | `ecr-mirror` | NGC image and OCI chart mirror into ECR after repositories exist. |

Azure parity mapping:

| Azure foundation | AWS foundation |
|---|---|
| Resource group | Terraform stack boundary, tags, and optional resource-name prefix |
| VNet/subnets | VPC, private subnets, public subnets, route tables, NAT gateways |
| AKS | EKS |
| ACR | ECR repositories |
| GPU node pool | EKS managed GPU node group |
| Compute node pool | EKS managed compute node group |
| GPU enablement | NVIDIA GPU Operator on EKS |

## Required Inputs

Collect these once, then pass them to the component skills:

| Input | Notes |
|---|---|
| `AWS_ACCOUNT_ID` | Must match `aws sts get-caller-identity --query Account --output text`. |
| `AWS_REGION` | Default to `us-west-2` only when the user has no preference. |
| `CLUSTER_NAME` | Lowercase alphanumeric plus hyphens. Keep under 20 chars for downstream streaming compatibility. |
| `OWNER` or owner tag | Team/user tag for resource ownership. |

Confirm these when missing:

| Input | Default |
|---|---|
| VPC CIDR | `10.10.0.0/16` |
| private subnet CIDRs | three `/20` ranges across available AZs |
| public subnet CIDRs | three `/24` ranges across available AZs |
| EKS Kubernetes version | AWS default unless the user pins one |
| system node instance type | `m6i.xlarge` |
| compute node instance type | `m6i.2xlarge` |
| GPU node instance type | `g6.12xlarge` or the closest quota-approved GPU SKU |
| GPU node AMI type | `AL2023_x86_64_NVIDIA` |
| GPU min/max | `0` / `2` |
| compute min/max | `1` / `3` |
| GPU Operator version | `25.3.1` unless the user pins another validated version |

## Mode Detection

Default to generate mode: create Terraform and helper scripts for review under
`generated/`. Use deploy mode only when the user explicitly asks to apply,
deploy, run, or execute the stack.

Only enter destroy mode when the user explicitly requests teardown or cleanup:

- "destroy cluster ..."
- "terraform destroy ..."
- "tear down cluster ..."
- "clean up cluster ..."
- "delete the cluster ..."
- "remove the stack ..."

## Generate Workflow

1. Read `aws-tf-conventions` first and apply its rules to every generated file.
2. Use `aws-iam-vpc`, `eks-cluster`, `eks-nodes`, `eks-storage`, and `ecr` to
   generate the Terraform root stack for
   `generated/terraform/aws/envs/<cluster>/`. The `eks-storage` IAM policy
   attachment goes in the same root module as `eks-nodes`.
3. Use `eks-storage` to generate `generated/<cluster>-storage.sh`.
4. Use `eks-gpu-operator` to generate `generated/<cluster>-gpu-operator.sh`.
5. Use `eks-validate` to generate `generated/<cluster>-validate.sh`.
6. Print the generated paths and the exact command order for review.

Expected generated layout:

```text
generated/
├── <cluster>-storage.sh
├── <cluster>-gpu-operator.sh
├── <cluster>-validate.sh
└── terraform/aws/envs/<cluster>/
    ├── main.tf
    ├── providers.tf
    ├── variables.tf
    ├── outputs.tf
    └── terraform.tfvars
```

## Deploy Workflow

Run from the generated Terraform environment directory after reading the plan:

```bash
cd "generated/terraform/aws/envs/${CLUSTER_NAME}"
terraform fmt -recursive
terraform init
terraform validate
terraform plan -out=tfplan
terraform apply tfplan
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" --alias "$CLUSTER_NAME"
```

Read the plan before applying. Investigate every destroy and every resource
outside the expected AWS foundation list.

Then run the post-Terraform scripts in order:

```bash
bash "generated/${CLUSTER_NAME}-storage.sh"
bash "generated/${CLUSTER_NAME}-gpu-operator.sh"
bash "generated/${CLUSTER_NAME}-validate.sh"
```

## Destroy Workflow

Before running any destroy, print the following and require exact cluster-name
confirmation:

```text
You are about to destroy the full AWS stack for cluster <CLUSTER_NAME>:

  Step 1 - GPU operator (Helm):  helm uninstall gpu-operator
  Step 2 - AWS infra (Terraform): terraform destroy deletes VPC, EKS, ECR, IAM

Type the cluster name to confirm:
```

Only proceed if the user types the cluster name exactly.

Destroy in reverse order:

```bash
helm uninstall gpu-operator \
  --kube-context "$CLUSTER_NAME" \
  --namespace gpu-operator \
  --wait --timeout 5m || true
kubectl --context "$CLUSTER_NAME" delete namespace gpu-operator --ignore-not-found

terraform -chdir=generated/terraform/aws/envs/"$CLUSTER_NAME" destroy -auto-approve
```

ECR repositories created by Terraform will be destroyed with the stack. If they
contain mirrored images you want to keep, export or retain them before destroy.

## Validation Checklist

- [ ] Component skills were read instead of recreating detailed logic here.
- [ ] Generated Terraform follows `aws-tf-conventions`.
- [ ] GPU Operator stays outside Terraform state.
- [ ] `ecr-mirror` remains optional and separate from infra apply.
- [ ] Destroy requires exact cluster-name confirmation.
