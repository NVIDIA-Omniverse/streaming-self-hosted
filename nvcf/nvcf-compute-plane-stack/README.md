# nvcf-compute-plane-stack

Helmfile stack for the NVCF compute plane. Installs the NVCA operator and optional
ML-framework operators (Grove, Dynamo) onto GPU clusters registered with an NVCF control plane.

## Prerequisites

- An NVCF control plane deployed via `nvcf-self-managed-stack`
- `helmfile` v1.1.x (v1.2.0+ breaks ordering; see version note below)
- `helm` v3.x
- `helm-diff` plugin
- `nvcf-cli` (for cluster registration)
- A kubeconfig pointing at the target GPU cluster

## Quickstart

```sh
# 1. Register the cluster with ICMS (idempotent)
make register-cluster \
  CLUSTER_NAME=gpu-east \
  NCA_ID=nvcf-default \
  CLUSTER_REGION=us-west-1 \
  ICMS_URL=https://sis.your-nvcf.example.com

# 2. Deploy the compute plane
make install \
  CLUSTER_NAME=gpu-east \
  HELMFILE_ENV=local
```

Repeat steps 1-2 for each GPU cluster (see [this example](#multi-cluster-example)).
The `CLUSTER_NAME` variable scopes all state to
that cluster so multiple clusters can be managed from a single checkout.
`register-cluster` writes `registration/<cluster>-register-values.yaml`.
`install`, `apply`, and `template` copy that file into `out/` before running
Helmfile.

## Helmfile Version Note

Helmfile v1.2.0+ changed `helmfile.d/` processing to parallel mode which breaks
implicit ordering. Use helmfile v1.1.x:

```sh
# Pinned binaries are auto-downloaded by the dev Makefile:
make install CLUSTER_NAME=...   # downloads helmfile v1.1.9 + helm v3.15.4 on first run
```

## Optional Add-ons

Grove (topology-aware scheduling) and Dynamo (inference framework scheduling) are disabled
by default. Enable per-environment in `environments/<env>.yaml`:

```yaml
addons:
  groveOperator:
    enabled: true
  dynamoOperator:
    enabled: true
```

## Multi-Cluster Example

Each cluster is registered and installed independently. Pass `KUBECONFIG_FILE`
to every target so that registration reads the JWKS/issuer from the correct
cluster. Omitting it during `register-cluster` causes both clusters to register
with the ambient context's JWKS, which leads to PSAT auth failures at runtime.

```sh
make register-cluster \
  CLUSTER_NAME=gpu-east \
  CLUSTER_REGION=us-east-1 \
  KUBECONFIG_FILE=~/.kube/gpu-east.yaml

make register-cluster \
  CLUSTER_NAME=gpu-west \
  CLUSTER_REGION=us-west-2 \
  KUBECONFIG_FILE=~/.kube/gpu-west.yaml

make install \
  CLUSTER_NAME=gpu-east \
  HELMFILE_ENV=local \
  KUBECONFIG_FILE=~/.kube/gpu-east.yaml

make install \
  CLUSTER_NAME=gpu-west \
  HELMFILE_ENV=local \
  KUBECONFIG_FILE=~/.kube/gpu-west.yaml
```
