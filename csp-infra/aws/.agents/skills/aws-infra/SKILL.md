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
NVCA, functions, stream validation, caches, UCC, OVDC, or storage APIs. Use
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

When the requested stack includes OVDC, collect these values before generating
the compute node group and pass them unchanged to `eks-nodes` and
`eks-validate`:

| Input | Default | Notes |
|---|---|---|
| `OVDC_REPLICAS` | `0` | `0` means OVDC capacity is not part of this foundation run. |
| `OVDC_MEMORY_REQUEST_GIB` | required when `OVDC_REPLICAS > 0` | Rendered OVDC pod memory request, rounded up to GiB. |
| `OVDC_PLATFORM_RESERVE_GIB` | `8` | Per-node allocatable-memory headroom for Kubernetes and other platform services. |

The `m6i.2xlarge` compute default applies only when OVDC capacity is not
requested. For OVDC, `eks-nodes` must select a CPU instance class whose memory
can satisfy the rendered request plus reserve, and `eks-validate` must gate on
the joined node's Kubernetes allocatable memory. Do not use a GPU node as an
OVDC capacity fallback.

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
   attachment goes in the same root module as `eks-nodes`. When
   `OVDC_REPLICAS > 0`, size the compute group through the OVDC capacity
   contract above and set compute desired/minimum capacity to at least the
   replica count.
3. Use `eks-storage` to generate `generated/<cluster>-storage.sh`.
4. Use `eks-gpu-operator` to generate `generated/<cluster>-gpu-operator.sh`.
5. Use `eks-validate` to generate `generated/<cluster>-validate.sh`. Pass the
   OVDC capacity inputs so the script verifies the live CPU-node allocatable
   memory before the foundation is accepted.
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
  Step 2 - Cloud resources k8s made outside Terraform: delete LoadBalancer
           Services (Classic ELB + k8s-elb-* SG + ENIs) and PVCs
  Step 3 - AWS infra (Terraform): terraform destroy deletes VPC, EKS, ECR, IAM
  Step 4 - Sweep leaked EBS volumes tagged kubernetes.io/cluster/<CLUSTER_NAME>

Type the cluster name to confirm:
```

Only proceed if the user types the cluster name exactly.

Destroy in reverse order. A real deployment provisions AWS resources *outside*
Terraform state — the ingress/Envoy Gateway `Service type=LoadBalancer` creates a
Classic ELB plus a non-default `k8s-elb-*` security group, and every NVCF PVC
(Cassandra/OpenBao/NATS/OVDC/UCC) creates a CSI-owned EBS volume. Terraform does
not own these, so they must be cleared before `terraform destroy` (the orphaned
ELB security group otherwise blocks `DeleteVpc` with a `DependencyViolation`) and
leaked volumes swept afterward. Requires `AWS_REGION` in scope.

**Scoping guarantee.** The added steps never touch Terraform-owned resources
(`terraform destroy` handles those) and never touch another cluster's resources.
Kubernetes stamps `kubernetes.io/cluster/<CLUSTER_NAME> = owned` on exactly the
resources it provisions for *this* cluster; deletes are gated on that tag being
`owned` (never `shared`), on this cluster's VPC, and — for volumes — on the
CSI-only `kubernetes.io/created-for/pvc/name` tag plus `status=available`
(detached). The two account-wide destructive branches (force-deleting a stalled
ELB, sweeping leaked volumes) must **print the exact resources and re-confirm the
cluster name** before deleting; the initial cluster-name confirmation is generic
and cannot list runtime resource IDs.

```bash
# --- Step 1: GPU operator (Helm) ---
helm uninstall gpu-operator \
  --kube-context "$CLUSTER_NAME" \
  --namespace gpu-operator \
  --wait --timeout 5m || true
kubectl --context "$CLUSTER_NAME" delete namespace gpu-operator --ignore-not-found

# Pin cluster identity up front — the VPC is gone after terraform destroy, and it
# scopes the ELB match below. (Also confirms the kube-context resolves this cluster.)
CLUSTER_VPC=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text)
echo "Cluster $CLUSTER_NAME -> VPC $CLUSTER_VPC"

# --- Step 2: Release cloud resources k8s created OUTSIDE Terraform state ---
# 2a. Delete every type=LoadBalancer Service so the in-tree cloud controller
#     tears down its Classic ELB, the k8s-elb-* security group, and ENIs.
kubectl --context "$CLUSTER_NAME" get svc -A \
  -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' \
  | while IFS=/ read -r ns name; do
      [ -n "$name" ] && kubectl --context "$CLUSTER_NAME" -n "$ns" \
        delete svc "$name" --wait=true --timeout=5m || true
    done

# 2b. Wait up to ~4 min for the cloud controller to release this cluster's ELBs
#     (and thus their k8s-elb-* SGs/ENIs). Match on owned tag AND cluster VPC.
cluster_elbs() {
  for elb in $(aws elb describe-load-balancers --region "$AWS_REGION" \
                 --query "LoadBalancerDescriptions[?VPCId=='${CLUSTER_VPC}'].LoadBalancerName" \
                 --output text); do
    val=$(aws elb describe-tags --region "$AWS_REGION" --load-balancer-names "$elb" \
            --query "TagDescriptions[0].Tags[?Key=='kubernetes.io/cluster/${CLUSTER_NAME}'].Value" \
            --output text)
    [ "$val" = "owned" ] && printf '%s\n' "$elb"
  done
}
for i in $(seq 1 12); do
  [ -z "$(cluster_elbs)" ] && break
  echo "Waiting for cluster ELBs to release ($i/12): $(cluster_elbs | tr '\n' ' ')"
  sleep 20
done
```

If `cluster_elbs` still returns load balancers, the cloud controller stalled.
**Print the remaining ELB names (all in VPC `$CLUSTER_VPC`) to the user and
require exact cluster-name confirmation**, then force-delete only those so the
orphaned `k8s-elb-*` SG stops blocking `DeleteVpc`:

```bash
for elb in $(cluster_elbs); do
  echo "Force-deleting stalled ELB $elb (VPC $CLUSTER_VPC)"
  aws elb delete-load-balancer --region "$AWS_REGION" --load-balancer-name "$elb"
done
```

Then finish the pre-Terraform cleanup and destroy the stack:

```bash
# 2c. Delete all PVCs so the EBS CSI driver deletes their backing volumes
#     before the cluster/nodes are torn down.
kubectl --context "$CLUSTER_NAME" delete pvc --all -A --wait=true --timeout=5m || true

# --- Step 3: AWS infra (Terraform) ---
terraform -chdir=generated/terraform/aws/envs/"$CLUSTER_NAME" destroy -auto-approve
```

**Step 4 — backstop sweep of EBS volumes the CSI driver leaked** (not in TF
state). Discover them first; the filters require this cluster's `owned` tag, the
CSI-only `created-for` tag, and `status=available` (detached):

```bash
leaked_vols=$(aws ec2 describe-volumes --region "$AWS_REGION" \
  --filters "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned" \
            "Name=tag-key,Values=kubernetes.io/created-for/pvc/name" \
            "Name=status,Values=available" \
  --query 'Volumes[].[VolumeId, Tags[?Key==`kubernetes.io/created-for/pvc/name`]|[0].Value]' \
  --output text)
printf 'Leaked volume (id -> source PVC): %s\n' "$leaked_vols"
```

**Print `leaked_vols` (each volume ID and its source PVC) to the user and require
exact cluster-name confirmation.** Only then delete them:

```bash
echo "$leaked_vols" | awk 'NF {print $1}' | while read -r vol; do
  echo "Deleting leaked EBS volume $vol"
  aws ec2 delete-volume --region "$AWS_REGION" --volume-id "$vol"
done
```

ECR repositories created by Terraform will be destroyed with the stack. If they
contain mirrored images you want to keep, export or retain them before destroy.

> Note: Step 2 covers the in-tree cloud controller's **Classic ELBs** (what the
> NVCF ingress creates). If a deployment fronts a Service with the AWS Load
> Balancer Controller (NLB/ALB via `elbv2`), add an equivalent `aws elbv2`
> wait/delete for load balancers tagged `elbv2.k8s.aws/cluster=<CLUSTER_NAME>`.

## Validation Checklist

- [ ] Component skills were read instead of recreating detailed logic here.
- [ ] Generated Terraform follows `aws-tf-conventions`.
- [ ] GPU Operator stays outside Terraform state.
- [ ] `ecr-mirror` remains optional and separate from infra apply.
- [ ] Destroy requires exact cluster-name confirmation.
- [ ] Destroy deletes LoadBalancer Services and PVCs, waits for the ELB and its
      `k8s-elb-*` security group to clear before `terraform destroy`, and sweeps
      leaked EBS volumes tagged `kubernetes.io/cluster/<cluster>=owned` after.
- [ ] Out-of-Terraform deletes are scoped to this cluster (`owned` tag + cluster
      VPC + CSI `created-for` tag + detached volumes) and the account-wide ELB
      force-delete and volume sweep print the resources and re-confirm first.
