<!-- markdownlint-disable MD013 -->

# NVCF Infrastructure Deployment

> [!IMPORTANT]
> Mainline development of the NVCF self-managed stack is moving to the NVCF umbrella monorepo.
> New feature work and default-branch changes should target `deploy/stacks/self-managed` in `nvcf/nvcf`.
> This repository remains open for patch and backport work on existing feature and release branches, especially `release/0.6`.
>
> Public mirror: https://github.com/NVIDIA/nvcf/tree/main/deploy/stacks/self-managed

Deploy the NVIDIA Cloud Functions (NVCF) self-managed infrastructure using Helmfile for Kubernetes.

## 🚀 Quick Start (Local Development)

The `local` deploy target assumes the use of nvcr.io as the registry. Access to the `your-org/your-team` org/team is required.

```bash
# 1. Set up secrets (one-time setup)
cp secrets/secrets.yaml.template secrets/local-secrets.yaml

# 2. Configure your secrets
vim secrets/local-secrets.yaml  # Fill in actual values

# 3. Deploy to local cluster (control-plane layer)
make install HELMFILE_ENV=local
```

### Self-hosted: full deployment flow (control plane + compute plane)

A working self-hosted NVCF deployment has two stages. This stack is the control
plane (the API and management layer). The compute plane is required to actually
run functions: it installs the NVCA operator onto each GPU cluster and registers
that cluster with the control plane. The compute plane ships as a separate
stack, `nvcf-compute-plane-stack`, and is deployed after the control plane is
healthy.

Stage 1 - Control plane (this stack):

```bash
# Deploys the helmfile.d/ releases: SIS, ReVal, NVCFAPI, auth-callout,
# OpenBao migrations, etc. Stays running across compute-cluster lifecycles.
make install HELMFILE_ENV=<env>   # <env>: local | eks-cds-dev | eks-cds-qa | volcano-dev-2
```

Stage 2 - Compute plane (required; run from the `nvcf-compute-plane-stack` directory):

```bash
# 1. Register the GPU cluster with the control plane (ICMS). Idempotent:
#    nvcf-cli cluster register --ignore-existing returns the existing record
#    or creates one, so re-running after recreating a cluster does not leave a
#    stale clusterId behind.
make register-cluster \
  CLUSTER_NAME=<name> \
  NCA_ID=<nca> \
  CLUSTER_REGION=<region> \
  ICMS_URL=https://sis.<your-domain>

# 2. Install the NVCA operator (and optional Grove/Dynamo add-ons) onto that cluster.
make install CLUSTER_NAME=<name> HELMFILE_ENV=<env>   # <env>: local | base
```

Repeat Stage 2 for each GPU cluster; `CLUSTER_NAME` scopes all state so multiple
clusters can be managed from one checkout. See the `nvcf-compute-plane-stack`
README for the authoritative compute-plane command reference, multi-cluster
examples, NVCA operator value overrides (for example a `networkPolicy` block for
OpenShift DNS egress), add-on configuration, and the helmfile v1.1.x version
requirement.

## �� Table of Contents

- [Architecture](#️-architecture)
- [Prerequisites](#-prerequisites)
- [Installation](#-installation)
- [Configuration](#️-configuration)
- [Deployment](#-deployment)
- [Secret Management](#-secret-management)
- [Environments](#-environments)
- [Troubleshooting](#-troubleshooting)
- [Development](#️-development)

## 🏗️ Architecture

This Helmfile deploys a complete NVCF infrastructure stack including:

### Core Infrastructure

- **NATS** - Message streaming and communication
- **Cassandra** - Data persistence layer
- **OpenBao** - Secrets management and vault

### NVCF Services

- **API Gateway** - Main NVCF API endpoint
- **API Keys Service** - Authentication and key management
- **SIS** - System Information Service
- **Invocation Service** - Function execution management
- **ESS API** - Event Streaming Service
- **Notary Service** - Digital signing and verification
- **GRPC Proxy** - GRPC proxy service

### Optional Components

- **State Metrics Service** - Prometheus metrics for NVCF state (disabled by default)
- **NVCA Operator** - NVIDIA Container Analytics worker component, enabled only in `local` by default
- **Image Pull Secret Setup** - Automated registry authentication

For pinned chart versions, see `helmfile.d/01-dependencies.yaml.gotmpl` (infrastructure) and `helmfile.d/02-core.yaml.gotmpl` (NVCF services).

## 📋 Prerequisites

### Required Tools

- **Kubernetes cluster** (local or cloud)
- **Helm** v3.x - [Installation guide](https://helm.sh/docs/intro/install/)
  - ⚠️ **Helm 4 is NOT supported** - Use Helm 3.x only
  - Development Makefile auto-downloads v3.15.4 to `bin/`
- **Helmfile** v1.1.x - [Installation guide](https://helmfile.helmfile.sh/)
  - ⚠️ **Do not use helmfile v1.2.0+** - Breaks deployment ordering due to parallel processing
  - Use helmfile v1.1.9 or earlier
  - Development Makefile auto-downloads v1.1.9 to `bin/`
- **Docker** (for containerized execution) - [Installation guide](https://docs.docker.com/get-docker/)

### Required Helm Plugin

```bash
# Helm diff plugin (required by helmfile for diff operations)
helm plugin install https://github.com/databus23/helm-diff

# Note: Development Makefile auto-installs this plugin
# Customers must install manually
```

### Optional Tools

```bash
# Kubectl for cluster management
# https://kubernetes.io/docs/tasks/tools/
```


## 🔧 Installation

### 1. Clone and Setup

```bash
cd /path/to/nvcf-infrastructure/deploy

# Copy the secret template to create your environment secret file
cp secrets/secrets.yaml.template secrets/local-secrets.yaml
```

### 2. Configure Secrets

Edit your environment-specific secret file:

```bash
# Required: Fill in actual values
vim secrets/local-secrets.yaml
```

### 3. Verify Configuration

```bash
# Test templating without deployment
make template HELMFILE_ENV=local

# Check generated manifests
ls out/
```

## ⚙️ Configuration

### Values Hierarchy (Low to High Priority)

1. `environments/base.yaml` - Global defaults and structure definitions
2. `environments/<env>.yaml` - Environment-specific overrides
3. `secrets/<env>-secrets.yaml` - Environment secrets (gitignored)
4. `global.yaml.gotmpl` - Templated global values (applies global settings to all services)
5. Inline values in `helmfile.d/*.yaml.gotmpl`

### Configuration Architecture

The deployment uses a **centralized global configuration** approach:

- **Global Settings**: Node selectors, storage, and registry settings defined once in environment files
- **Centralized Application**: `global.yaml.gotmpl` applies global settings consistently to all services
- **Environment Overrides**: Each environment can override global defaults (registry, storage class, etc.)
- **Clean Separation**: Environment files focus on high-level environment differences, not per-service configuration

### Worker Endpoint URL Flow

Worker-facing control-plane URLs are configured in the stack and passed through
the owning upstream services before they reach workload pods. This keeps
single-cluster and split-cluster installs consistent: workers receive URLs from
the control plane instead of deriving local service DNS names. See
[Worker Endpoint URL Flow](docs/worker-endpoint-url-flow.md) for the NVCF API,
NVCT API, NATS, ESS, invocation, gRPC proxy, and worker observability pattern.

### Key Configuration Files

```text
./
├── global.yaml.gotmpl        # Applies global settings to all services
├── helmfile.d/
│   ├── 000-prepare.yaml.gotmpl      # Validation hooks (dev only)
│   ├── 01-dependencies.yaml.gotmpl  # NATS, Cassandra, OpenBao
│   ├── 02-core.yaml.gotmpl          # NVCF services
│   └── 03-observability.yaml.gotmpl # Observability stack (optional)
├── environments/
│   ├── base.yaml             # Global defaults and configuration structure
│   ├── local.yaml            # Local development overrides
│   ├── eks-cds-dev.yaml      # AWS EKS (CDS dev)
│   ├── eks-cds-qa.yaml       # AWS EKS (CDS qa)
│   └── volcano-dev-2.yaml    # VolcanoEngine development environment
└── secrets/
    ├── secrets.yaml.template # Secret template (tracked)
    └── *-secrets.yaml        # Actual secrets (gitignored)
```

### Observability: Tracing

Tracing is opt-in and disabled by default. Enable it by overriding the
`global.observability.tracing` block in your environment file:

```yaml
global:
  observability:
    tracing:
      enabled: true
      collectorEndpoint: "otel-collector.observability.svc.cluster.local"
      collectorPort: 4318
      collectorProtocol: http
```

When enabled, the helmfile fans the toggle out to per-service environment
variables in the shape each service expects. The exact env-var names live
inline in `global.yaml.gotmpl`; the deployer-facing surface is the toggle
above.

Notes:

- `collectorEndpoint` is the bare hostname only. The helmfile composes the
  full URL (`<protocol>://<host>:<port>/v1/traces`) for services that take
  one, and supplies host and port separately for services that don't.
- `collectorPort` must match the transport your collector listens on:
  typically `4318` for OTLP HTTP and `4317` for OTLP gRPC.
- `collectorProtocol` is `http` or `https`.
- The toggle controls helmfile injection only. Each service may also carry
  an internal default in its packaged config; the injected env vars
  override those defaults at runtime.

## 🚀 Deployment

### Using Make (Recommended)

> **Note:** Use `make install` for initial installation and `make apply` for subsequent updates. The `install` command ensures clean first-time setup, while `apply` handles incremental changes.

```bash
# Initial installation (first time)
make install HELMFILE_ENV=local

# Subsequent updates
make apply HELMFILE_ENV=default

# Local deployment with fake GPU
make apply HELMFILE_ENV=local

# AWS EKS deployment (CDS dev / qa)
make apply HELMFILE_ENV=eks-cds-dev
make apply HELMFILE_ENV=eks-cds-qa

# VolcanoEngine development environment
make apply HELMFILE_ENV=volcano-dev-2
```

### Using Docker (Consistent Environment)

```bash
# Template generation
make template-docker HELMFILE_ENV=local

# Deployment via Docker
make apply-docker HELMFILE_ENV=local
```

### Available Commands

| Command | Description |
|---------|-------------|
| `make help` | Show all available commands |
| `make template` | Generate K8s manifests without applying |
| `make install` | Initial deployment to cluster (first-time setup) |
| `make apply` | Update existing deployment |
| `make destroy` | Remove all releases and namespaces |
| `make clean` | Remove generated output files |

### Deployment Options

| Variable | Default | Description |
|----------|---------|-------------|
| `HELMFILE_ENV` | `default` | Target environment |
| `OUTPUT_DIR` | `./out` | Manifest output directory |

### Dockerized Execution

When using Docker targets, credentials are handled specially:

```bash
# Custom Docker config for private registries
make template-docker DOCKER_CONFIG_PATH=/path/to/config.json HELMFILE_ENV=local

# Custom kubeconfig
make apply-docker KUBECONFIG_PATH=/path/to/kubeconfig HELMFILE_ENV=local
```

**Note**: Docker credential helpers (like `docker-credential-osxkeychain`) won't work inside containers. Use explicit authentication tokens in your Docker config for containerized execution.

## 🔐 Secret Management

### Setup

Initialize secret files from templates and configure them:

```bash
# Copy the template to create your environment secret file
cp secrets/secrets.yaml.template secrets/local-secrets.yaml

# Edit the file to add your actual secret values
vim secrets/local-secrets.yaml
```

**Important**: Secret files (`*-secrets.yaml`) are automatically ignored by git to keep your secrets secure.

### Manual Configuration

#### 1. Container Registry Authentication

```bash
# Method 1: Use existing Docker config
cat ~/.docker/config.json | base64 -w 0

# Method 2: Manual creation for NVCR
echo '{"auths":{"nvcr.io":{"auth":"base64-user:token"}}}' | base64 -w 0

# Method 3: Login first, then encode
docker login nvcr.io
cat ~/.docker/config.json | base64 -w 0
```

#### 2. Service-Specific Secrets

These secret values are not special files on their own—they are simply YAML values that are merged with other values files during deployment. However, **they must be set in the corresponding file under `secrets/`**, named after your environment (e.g., `secrets/local-secrets.yaml`, `secrets/default-secrets.yaml`). These files are included in `.gitignore` to ensure your secrets remain private and are not committed to version control.

**Example secret structure:**

```yaml
openbao:
  migrations:
    env:
      - name: DEFAULT_CASSANDRA_PASSWORD
        value: "ch@ng3m3"  # Cassandra database password
      - name: NVCF_API_SIDECARS_IMAGE_PULL_SECRET
        value: REPLACE_WITH_BASE64_DOCKER_CREDENTIAL  # Base64 encoded Docker credential

api:
  accountBootstrap:
    registryCredentials:
      # Container registry credential (typically same as sidecars pull secret)
      - registryHostname: "nvcr.io"
        secret:
          name: "nvcr-io-container"
          value: REPLACE_WITH_BASE64_DOCKER_CREDENTIAL  # Same credential as sidecars
        artifactTypes: ["CONTAINER"]
        description: "NVIDIA Container Registry for containers"
      # Model registry credential (can be same registry, different artifact type)
      - registryHostname: "api.ngc.nvidia.com"
        secret:
          name: "nvcr-io-model"
          value: REPLACE_WITH_BASE64_DOCKER_CREDENTIAL  # Same credential
        artifactTypes: ["MODEL"]
        description: "NVIDIA Container Registry for models"
```

Corresponding NVCF API Configuration:

```yaml
NVCF_SIDECARS_HOSTNAME: "nvcr.io"
NVCF_SIDECARS_REPOSITORY: "YOUR_ORG/YOUR_TEAM"
NVCF_REGISTRIES_NGC_CONTAINER_REGISTRY_URL: "https://nvcr.io"
NVCF_REGISTRIES_NGC_BASE_URL: "https://api.ngc.nvidia.com"
NVCF_REGISTRIES_NGC_OAUTH2_BASE_URL: "https://authn.nvidia.com"
NVCF_REGISTRIES_NGC_OAUTH2_GROUP_SCOPE: "ngc"
NVCF_REGISTRIES_RECOGNIZED_CONTAINER_NGC_HOSTNAME: "nvcr.io"
NVCF_REGISTRIES_RECOGNIZED_HELM_NGC_HOSTNAME: "helm.ngc.nvidia.com"
NVCF_REGISTRIES_RECOGNIZED_HELM_NGC_OAUTH2_BASE_URL: "https://authn.nvidia.com"
NVCF_REGISTRIES_RECOGNIZED_HELM_NGC_OAUTH2_GROUP_SCOPE: "ngc"
NVCF_REGISTRIES_RECOGNIZED_MODEL_NGC_HOSTNAME: "api.ngc.nvidia.com"
NVCF_REGISTRIES_RECOGNIZED_MODEL_NGC_OAUTH2_BASE_URL: "https://authn.nvidia.com"
NVCF_REGISTRIES_RECOGNIZED_MODEL_NGC_OAUTH2_GROUP_SCOPE: "ngc"
NVCF_REGISTRIES_RECOGNIZED_RESOURCE_NGC_HOSTNAME: "api.ngc.nvidia.com"
NVCF_REGISTRIES_RECOGNIZED_RESOURCE_NGC_OAUTH2_BASE_URL: "https://authn.nvidia.com"
NVCF_REGISTRIES_RECOGNIZED_RESOURCE_NGC_OAUTH2_GROUP_SCOPE: "ngc"
```

**Important Notes:**

- **Credential Encoding**: Despite the `REPLACE_WITH_BASE64_DOCKER_CREDENTIAL` placeholder name, each value is a raw docker registry auth string: the base64 of `$oauthtoken:<NGC_API_KEY>`, not the base64 of a dockerconfigjson. Generate it with `printf '$oauthtoken:%s' "$NGC_API_KEY" | openssl base64 -A` (single quotes keep `$oauthtoken` literal; it is the fixed NGC username). The wrong encoding makes `function create` return `400 "must be base64 encoded username:password format"`.
- **Shared Credentials**: In most cases, `NVCF_API_SIDECARS_IMAGE_PULL_SECRET` and `registryCredentials[].secret.value` will be the same base64-encoded credential since they target the same registry
- **Well-known Registries**: The NVCF API must support the registry.
- **API Configuration**: The NVCF API must be configured with the same registry through environment variables.

### Security Best Practices

- ✅ Never commit secret files (automatically gitignored)
- ✅ Use different secrets per environment
- ✅ Rotate secrets regularly (90-day recommendation)
- ✅ Use least-privilege access controls
- ✅ Monitor secret access and changes
- ✅ Backup secrets securely outside of git

## 🌍 Environments

### Available Environments

| Environment | Purpose | Features |
|-------------|---------|----------|
| `local` | Development | Local storage (`local-path`), node selectors disabled, `nvca-operator` enabled |
| `eks-cds-dev` | AWS EKS (CDS dev) | EBS storage (`gp3`), node selectors disabled, production storage sizes |
| `eks-cds-qa` | AWS EKS (CDS qa) | EBS storage (`gp3`), node selectors disabled, production storage sizes |
| `volcano-dev-2` | VolcanoEngine dev cluster | Custom registry, node selectors enabled, EBS storage (`ebs-ssd`) |

### Environment Configuration

Each environment automatically loads values in this order:

```bash
environments/base.yaml           # Global defaults and structure
+ environments/{env}.yaml        # Environment-specific overrides
+ secrets/{env}-secrets.yaml     # Environment secrets
```

**Global Configuration Structure:**

All environments inherit from `base.yaml` which defines:

- **Node Selectors**: Global node selector definitions with `enabled` flag
- **Storage Settings**: Default storage class and size
- **Image Registry**: Default container registry configuration
- **Service Enablement**: Which services and optional worker components are enabled by default

**Environment-specific features:**

- **local**: Local storage (`local-path`), node selectors disabled, `nvca-operator` enabled
- **eks-cds-dev / eks-cds-qa**: AWS EBS storage (`gp3`), node selectors disabled, production storage sizes
- **volcano-dev-2**: VolcanoEngine registry, node selectors enabled for production workloads, EBS storage

**Example Global Configuration:**

```yaml
# base.yaml - Global structure
global:
  nodeSelectors:
    enabled: false  # Can be overridden per environment
    controlplane:
      key: nvcf.nvidia.com/workload
      value: control-plane
  storageClass: ""  # Can be overridden per environment
  storageSize: "10Gi"

# volcano-dev-2.yaml - Environment override
global:
  nodeSelectors:
    enabled: true   # Override: enable node selectors for this environment
    controlplane:
      nvcf.nvidia.com/workload: control-plane  # Direct format for enabled selectors
  storageClass: ebs-ssd  # Override: use EBS storage
```

### Adding New Environments

1. **Create an environment values file:**

   ```bash
   # Create environment-specific overrides
   cat > environments/staging.yaml << EOF
   global:
     nodeSelectors:
       enabled: true
     storageClass: fast-ssd
     storageSize: 50Gi
     image:
       registry: staging-registry.company.com
       repository: nvcf-staging
   EOF
   ```

2. **Create a secrets file for the environment:**

   ```bash
   cp secrets/secrets.yaml.template secrets/staging-secrets.yaml
   vim secrets/staging-secrets.yaml
   ```

3. **Test deployment:**

   ```bash
   make template HELMFILE_ENV=staging
   make apply HELMFILE_ENV=staging
   ```

**Benefits of New Architecture:**

- **Consistency**: All services get the same global settings automatically
- **Maintainability**: Change node selectors once, apply everywhere
- **Environment Focus**: Environment files only contain high-level differences
- **Reduced Duplication**: No need to repeat per-service configuration

## 🔧 Troubleshooting

### Common Issues

#### Deployment Failures

```bash
# Check Helmfile version
helmfile version

# Verify cluster connectivity
kubectl cluster-info

# Check namespace creation
kubectl get namespaces

# View release status
helm list -A
```

#### Image Pull Issues

```bash
# Verify pull secrets exist
kubectl get secrets -A | grep pull-secret

# Check secret data
kubectl get secret global-project-pull-secret -n nats-system -o yaml

# Test registry authentication
kubectl run test-pull --image=nvcr.io/nvidia/test --dry-run=client -o yaml
```

#### Secret Configuration

```bash
# Verify secret files exist
ls -la secrets/

# Check file permissions
ls -la secrets/*-secrets.yaml  # Should be 600

# Validate secret content
grep -v "^#" secrets/local-secrets.yaml | grep '""'  # Should show empty values needing config
```

### Debug Commands

```bash
# Detailed helmfile output
helmfile -e local template --debug

# Validate generated manifests
kubectl apply --dry-run=client -f out/

# Check resource dependencies
kubectl get events --sort-by='.lastTimestamp' -A
```

### Getting Help

- **Logs**: Check pod logs for specific service issues
- **Events**: Use `kubectl get events` for cluster-level issues
- **Status**: Use `helm status <release-name>` for release information
- **Dependencies**: Check service startup order and dependencies

## 🛠️ Development

### Project Structure

```text
./
├── helmfile.d/                # Helmfile split configuration
│   ├── 000-prepare.yaml.gotmpl
│   ├── 01-dependencies.yaml.gotmpl
│   ├── 02-core.yaml.gotmpl
│   └── 03-observability.yaml.gotmpl
├── environments/              # Environment configs
├── secrets/                   # Secret files (gitignored)
├── scripts/                   # Utility scripts
├── global.yaml.gotmpl        # Global value templates
└── Makefile                  # Build automation
```

### Local Development Workflow

```bash
# 1. Make changes to helmfile or values
vim helmfile.d/02-core.yaml.gotmpl

# 2. Test changes locally
make template HELMFILE_ENV=local

# 3. Review generated manifests
ls out/

# 4. Apply changes
make apply HELMFILE_ENV=local

# 5. Test functionality
kubectl get pods -A
```

### Adding New Services

1. **Add release to the appropriate `helmfile.d/*.yaml.gotmpl`:**

   ```yaml
   - name: new-service
     version: 1.0.0
     namespace: new-service
     inherit:
       - template: service
   ```

2. **Update secret templates if needed:**

   ```yaml
   # In secrets/*.yaml.template
   newService:
     secretValues:
       apiKey: ""
   ```

3. **Configure global values in `global.yaml.gotmpl`:**

   ```yaml
   newService:
     image:
       registry: {{ .Values.global.image.registry }}
       repository: {{ .Values.global.image.repository }}/new-service
   ```

### Optional Vanity Gateway

The Vanity Gateway service is disabled by default. Enable it only when the
deployment needs vanity or OpenAI-compatible invocation routes in front of the
standard invocation service.

```yaml
addons:
  vanityGateway:
    enabled: true
    config:
      nvcfApiEndpoint: http://invocation.nvcf.svc.cluster.local:8080
    mappingConfig:
      v2config:
        openai: {}
        vanity: {}

ingress:
  gatewayApi:
    routes:
      vanityGateway:
        hostnames:
          - vanity.example.com
        routeAnnotations: {}
```

When enabled, Helmfile installs `vanity-gateway` in the `nvcf` namespace after
`invocation-service`, and the Gateway Routes chart exposes `vanity.{domain}`.

### Versioning Strategy

- **Helmfile**: Pin to specific Helmfile version in Makefile and Docker image
- **Charts**: Use semantic versioning for all chart dependencies
- **Images**: Reference specific image tags, avoid `latest`
- **Dependencies**: Document compatibility matrix for chart versions

### CI/CD Integration

The project supports automated deployment via:

- **Docker execution**: Consistent tooling across environments
- **Template validation**: Generate manifests without cluster access
- **Environment isolation**: Separate configurations per deployment target

## 🌐 Accessing Services

Once deployed, external access to NVCF services is provided via the **Gateway Routes** chart, which uses the [Kubernetes Gateway API](https://gateway-api.sigs.k8s.io/).

### Prerequisites

- A Gateway API-compliant gateway installed (e.g., Envoy Gateway, Istio, Traefik, Kong)
- An existing `Gateway` resource configured with appropriate listeners

### Configuration

Gateway routes are configured in your environment file under `nvcfGatewayRoutes`:

```yaml
nvcfGatewayRoutes:
  enabled: true
  domain: "nvcf.example.com"           # Your base domain
  gateways:
    shared:
      name: gateway                     # Name of your Gateway resource
      namespace: gateway                # Namespace where Gateway exists
      listenerName: http
    grpc:
      name: tcp-gateway                 # Gateway for gRPC/TCP routes
      namespace: gateway
      listenerName: tcp
```

### Service Endpoints

Based on your configured `domain`, the following endpoints are created:

| Service | Endpoint | Protocol | Description |
|---------|----------|----------|-------------|
| **NVCF API** | `api.{domain}` | HTTP | Main API for function management |
| **API Keys** | `api-keys.{domain}` | HTTP | Authentication and key management |
| **Invocation** | `*.invocation.{domain}` | HTTP | Function invocation (wildcard for dynamic routing) |
| **Invocation** | `invocation.{domain}` | HTTP | Base invocation endpoint and health checks |
| **Vanity Gateway** | `vanity.{domain}` | HTTP | Optional vanity/OpenAI-compatible invocation gateway |
| **gRPC Proxy** | `grpc.{domain}` | TCP/gRPC | gRPC protocol support |

**Example:** With `domain: nvcf.example.com`, your API endpoint would be `api.nvcf.example.com`.

### Verification

```bash
# Check Gateway status
kubectl get gateway <gateway-name> -n <gateway-namespace>

# List deployed routes
kubectl get httproute,tcproute -n <gateway-namespace>

# Get Gateway endpoint address
GATEWAY_ADDR=$(kubectl get gateway <gateway-name> -n <gateway-namespace> \
  -o jsonpath='{.status.addresses[0].value}')

# Test connectivity
curl -H "Host: api.nvcf.example.com" http://$GATEWAY_ADDR/health
```

### Local Development (No Gateway)

For local clusters without a Gateway, use port-forwarding:

```bash
kubectl port-forward svc/nvcf-api-service 8080:80 -n nvcf
# Access at http://localhost:8080
```

## 📚 Post-Deployment Setup

After successful deployment, see [Function Creation](https://docs.nvidia.com/nvcf/dev/function-creation) for function deployment and invocation.

---

**📚 Additional Resources:**

- [Helmfile Documentation](https://helmfile.helmfile.sh/)
- [Helm Documentation](https://helm.sh/docs/)
- [NVCF Documentation](https://docs.nvidia.com/cloud-functions/)
