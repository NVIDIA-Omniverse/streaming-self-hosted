<div id="main-content" class="bd-main" role="main">

<div class="bd-content">

<div class="bd-article-container">

<div class="bd-header-article d-print-none">

<div class="header-article-items header-article__inner">

<div class="header-article-items__start">

<div class="header-article-item">

  - [**](index.html)
  - <span class="ellipsis">Changelog</span>

</div>

</div>

</div>

</div>

<div id="searchbox">

</div>

<div id="changelog" class="section">

<span id="id1"></span>

# Changelog

## v1.0.0 GA Release (April 2026)

Updated chart versions from EA2/beta to 1.0.0 GA:

| Service | EA2 Chart | v1.0.0 Chart |
|---------|-----------|--------------|
| `storage-service` | 0.7.19 | **1.0.2** |
| `discovery-service` | 2.3.2 | **2.3.8** |
| `event-aggregation-service` | 1.4.13 | **1.5.52** |
| `event-consumer-service` | 1.7.16 | **1.9.6** |
| `envoy-auth-extension` | 2.3.2 | **2.3.3** |
| `storage-navigator` | 0.0.46 | **1.0.1** |
| `storage-api-integration-tests` | 0.7.4 | **1.0.3** |
| `rabbitmq` | 99.3.0 | 99.3.0 (unchanged) |

New known issues documented in this release:
- `FILESERVICE_STATIC_DIR` env var ignored in Kubernetes/Docker deployments — workaround: pass `filesystem --static-dir /data/storage` as container startup args
- IRSA Web Identity Tokens not consumed on EKS — workaround: inject AWS credentials explicitly via K8s secret

New integration test configuration options:
- `skipConnectivityChecks` — bypass preflight health checks
- `serviceIdentity.clientCredentials.*` — explicit OAuth2 client credentials block for authenticated deployments

`storage-service` 1.2.2 notes (relative to the v1.0.0 GA 1.0.2 chart):

The chart/image moved 1.0.2 -> **1.2.2**, spanning the 1.2.0, 1.2.1 and 1.2.2 releases. Operator-visible changes:

**New capabilities**
- **PostgreSQL metadata backend** (`config.metadata`) alongside the existing CosmosDB option, with advanced query limits and a faster continuation-token format. Migrations run from an init container before replicas serve; the token provisioner runs as a native sidecar, so this path needs **Kubernetes 1.29+**.
- **Shared Redis/Valkey L2 cache tier** (`config.redis.address`) for the Metadata API and, separately, for the manifest cache (`config.manifest.*`).
- **Manifest layer** (`config.manifest.enabled`) with its own optional L2 tier and cache capacity limit.
- **Workload identity** — AKS Workload Identity and EKS IRSA credentials, plus injected AWS/Azure client credentials and an access-token-file service identity provider.
- **Synthetic directory events** (`config.syntheticDirEvents`) derived from file events, with its own retry policy.
- **Standardized `observability` block** — `observability.metrics.enabled` / `tracing.enabled` with `endpoint.grpc`, `metrics.exportIntervalMs` (default 15000), and `observability.logging.structured.enabled` for JSON logs. This supersedes the older `service.metrics.enabled` switch, which it takes precedence over.
- **Probe configuration** (`probes.liveness` / `probes.readiness`, each `periodSeconds` + `failureThreshold`) and a dedicated gRPC probe service.
- Batch metadata operations, `UpdateMetadataBatch` (v1alpha), and multiple storage event subscribers of the same kind.

**Behaviour changes to watch when upgrading**
- `enable_permissions` / `enablePermissions` was **renamed** to `permissions_enabled` / `permissionsEnabled`. Values files carrying the old name silently lose the setting.
- `allowUnconfiguredEndpoints` (S3 and Azure Blob) — when `false`, the router rejects requests to unconfigured endpoints instead of forwarding them.
- `Copy` and `Move` **across different backends** now return `UNIMPLEMENTED` (REST 501) rather than `INVALID_ARGUMENT`.
- Discovery v2alpha now advertises the REST version mount base (`/v1alpha`) instead of embedding the resource name; clients combine it with the endpoint name and the group's OpenAPI paths.
- Deprecated and unused chart properties were removed — the chart ships a migration guide. Default HTTPProxy route timeouts increased, with a separate timeout policy for streamed routes.
- Responses served from the workspace manifest cache are now authorized; previously they bypassed permission checks (OMPE-105165).

---

## 1.0.0-beta Initial Release

## 1.0.0-beta Initial Release[\#](#beta-initial-release "Link to this heading")

  - Initial release of the Omniverse Storage APIs and Service Adapters.

  - Added the following APIs: - Discovery - Storage - Permissions - Notifications

  - Added the following Examples - Storage Navigator - Permissions UI - Deployment

</div>

</div>

<div class="prev-next-area">

[**](knownissues.html "previous page")

<div class="prev-next-info">

previous

Known Issues

</div>

[](additional-utilities.html "next page")

<div class="prev-next-info">

next

Additional Utilities

</div>

**

</div>

</div>

<div id="pst-secondary-sidebar" class="bd-sidebar-secondary bd-toc">

<div class="sidebar-secondary-items sidebar-secondary__inner">

<div class="sidebar-secondary-item">

<div id="pst-page-navigation-heading-2" class="page-toc tocsection onthispage">

** On this page

</div>

  - [0.1.0 Initial Release](#initial-release)

</div>

</div>

</div>

</div>

</div>
