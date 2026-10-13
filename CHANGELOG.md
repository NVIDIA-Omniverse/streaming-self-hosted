# CHANGELOG

## 26.10.0

### Added

- On-prem Kubernetes deployment skills, including an AWS EC2 validation profile.
- In-place upgrade skills for the streaming stack, with impact assessment and rollback guidance.
- NVCF compute-plane and observability stacks `1.0.0`.

### Updated

- Replaced DDCS deployment guidance with Omniverse Derived Cache (OVDC) `6.0.1`.
- Renamed the content-cache manifest section from `ucc` to `ovcc`; `usd-content-cache`: `3.0.1` → `3.0.2` (Helm chart remains `4.0.4`).
- NVCF self-managed stack: `0.6.1` → `1.0.1`; NVCA and NVCA Operator: `3.0.3` → `3.10.0`.
- `nvcf_worker_niclls`: `2.109.4` → `2.117.1`, including CVE dependency fixes.
- LLS streaming proxy: `3.0.4` → `4.0.2`; TURN: `3.0.2` → `4.0.2`.
- LLS charts and images now use the public `nvidia/omniverse` NGC org; the TURN TLS certificate hook uses `nvcf-openbao`. Include that image when mirroring TURN dependencies.
- Storage Service and its Helm chart: `1.0.2` → `1.2.0`.
- Discovery Helm chart: `2.3.8` → `2.3.11`; `simple-nginx`: `1.0.2` → `1.1.0`.

### Fixed

- Updated component images with CVE fixes.
- Corrected default OVDC placement on generic Kubernetes to use capacity-validated CPU platform nodes.
- Clarified on-prem OVCC storage choices: use PVC storage to retain cache across pod recreation; the bundled ephemeral example loses its cache when pods are recreated.

### Deprecated

- GXCache is deprecated in favor of OVDC. It remains available for existing deployments; use OVDC for new installations.

### Known Issues

- The bundled deployment skills do not deploy the NVCF function autoscaler. Streaming functions remain at their configured minimum instance count without automatic scale-out.

## 26.08.0

Omniverse Streaming on NVCF 26.08.0 is a patch release that updates the Low Latency Streaming (LLS) streaming proxy container to 3.0.4. The Reference Architecture remains on NVCF v0.6.1.

### Updated

- `streaming-proxy`: `3.0.2` → `3.0.4`

## 26.07.1

### Updated

- NVCF self-managed stack updated from `0.6.0` to `0.6.1`.
- Worker containers renamed to OSS variants: `nvcf-worker-init-oss`, `nvcf-worker-llm-credentials-oss`, and `nvcf-worker-utils-oss` replace their non-OSS counterparts.
- Cassandra updated to `5.0.8-nv-2.0.1`; EA image removed.
- Key component version bumps:
  - `nvcf-invocation-service`: `0.8.5` → `0.8.8`
  - `nvcf-cassandra-migrations`: `0.8.1` → `0.10.3`
  - `nvcf-openbao`: `2.5.4-nv-1.3.0` → `2.5.5-nv-1.3.1`
  - `helm-nvcf-cassandra`: `0.15.5` → `0.18.0`
  - `helm-nvcf-llm-api-gateway`: `1.2.0` → `1.3.5`
  - `helm-nvcf-sis`: `1.18.3` → `1.18.8`

### Fixed

- Resolved an issue where proxy TLS cert version was not correctly pinned.
- Improved vulnerability scanning reliability.

---

## 26.07.0

Initial release of NVIDIA Omniverse Streaming self-hosted skills.
