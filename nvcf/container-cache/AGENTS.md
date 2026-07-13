# AGENTS.md - container-cache chart

Native Helm chart subtree. Shared chart rules live in `deploy/helm/AGENTS.md`.

## Chart Facts

- Subproject id: `container-cache`
- Chart name: `nvcf-container-cache`
- Chart directory: `deploy`
- Release service name: `nvcf-container-cache`
- Push targets include `ncp-dev`, `nv-ngc-devops`, and additional legacy
  destinations declared in `tools/ci/subproject-validations.yaml`.

## Validate

```bash
tools/ci/validate-helm-chart deploy
```

Run from the repo root, or adjust paths when running inside this subtree.

## Local Gotchas

- The chart contains both container image caching and proxy cache behavior.
- Proxy cache DNS interception depends on `nvcf-unbound`.
- The DaemonSet modifies containerd or CRI-O configuration on nodes. Treat local
  install and cleanup tests as cluster-mutating operations.
- Lua/OpenResty behavior lives under chart files and scripts in this subtree;
  keep Helm template and Lua changes tested together.
