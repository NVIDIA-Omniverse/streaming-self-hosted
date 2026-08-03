# CHANGELOG

## 26.07.1 — 2026-07-29

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

## 26.07.0 — 2026-07-13

Initial release of NVIDIA Omniverse Streaming self-hosted skills.
