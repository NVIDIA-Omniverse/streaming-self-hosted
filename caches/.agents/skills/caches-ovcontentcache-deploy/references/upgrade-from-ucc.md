
# Upgrade From UCC 3.0.3 to OVCC

OVCC 4.0.x renames the chart `usd-content-cache` (UCC 3.0.3) to `ovcontentcache`
and changes the rendered Kubernetes defaults. The container repository remains
`usd-content-cache`. This skill also selects the `3.0.2` security patch by
overriding the 4.0.4 chart's default image `3.0.1`.

Keep the image selection in your maintained upgrade values file, along with
any installation-specific settings that must carry forward:

```yaml
# ovcc-upgrade-values.yaml
image:
  tag: "3.0.2"
```

Pass this file on every upgrade. Compatibility mode preserves resource names;
it does not select the patched container image.

## Greenfield vs upgrade

- **Fresh install (preferred for new clusters):** use the OVCC defaults. Do not
  set any `compat.*` flag. Follow the main SKILL.md flow.
- **In-place upgrade of an existing UCC 3.0.3 release:** you must opt into
  compatibility mode or the chart blocks the upgrade at render time.

## Why the upgrade is blocked without compat

A stock UCC 3.0.3 install owns a StatefulSet named
`<release>-usd-content-cache`. Kubernetes StatefulSet names and their volume
claim templates are immutable. A default OVCC install renders `<release>-ovcc`,
so an in-place upgrade would require deleting and recreating the StatefulSet —
causing downtime and orphaning the cache PVCs. The chart detects the UCC-era
StatefulSet and fails the upgrade with a message telling you to enable
`compat.useUccDefaults=true`.

## Stock upgrade (default UCC 3.0.3 install)

```bash
helm upgrade <release> "${CACHES_HELM_REPO_NAME}/ovcontentcache" \
  --version 4.0.4 \
  --namespace <namespace> \
  -f ovcc-upgrade-values.yaml \
  --set compat.useUccDefaults=true \
  --wait --timeout 5m
```

`compat.useUccDefaults=true` preserves the UCC-era identity so the existing
StatefulSet rolls in place and rebinds existing PVCs with no data migration:

| Surface | With `compat.useUccDefaults=true` |
|---|---|
| StatefulSet / Service name root | keeps `usd-content-cache` |
| Existing cache PVCs | reused (e.g. `az-<release>-usd-content-cache-0`) |
| TLS secret default | keeps `usd-content-cache-tls` |
| Metrics prefix | keeps `ucc_` |
| Cache data suffix | keeps `/proxy_cache_*/ucc_data` |

## Customized UCC installs

`compat.useUccDefaults=true` targets stock/default v3.0.3 installs. If the UCC
release customized TLS, ports, storage paths, or resource names, keep
`compat.useUccDefaults=true` and additionally carry those values forward
explicitly. Note the values key rename `service.ucc.*` → `service.cache.*`:

```bash
helm upgrade <release> "${CACHES_HELM_REPO_NAME}/ovcontentcache" \
  --version 4.0.4 \
  --namespace <namespace> \
  -f ovcc-upgrade-values.yaml \
  --set compat.useUccDefaults=true \
  --set tls.secretName=<former tls.secretName> \
  --set service.cache.port=<former service.ucc.port> \
  --set service.cache.containerPort=<former service.ucc.containerPort> \
  --wait --timeout 5m
```

If you customized cache directories on the UCC chart, set
`nginx.proxyCache.paths[]` explicitly to the desired upgraded paths.

## Legacy client compatibility (separate from useUccDefaults)

`compat.emitLegacyCacheReset=true` (the chart default) dual-emits the legacy
cache-reset endpoint `/__ucc/cache/reset` and the `UCC-Instance` response header
alongside the new `/__/cache/reset` path and `CC-Instance` header. This lets old
clients and monitoring keep working after the rename. It is independent of
`useUccDefaults` (which governs K8s names, metric prefix, and cache PVC paths).
Disable it only once telemetry confirms zero traffic on the legacy URL.

## Default OVCC names (fresh install, for reference)

| Surface | UCC 3.0.3 | OVCC 4.0.4 default |
|---|---|---|
| Chart name | `usd-content-cache` | `ovcontentcache` |
| K8s name root | `usd-content-cache` | `ovcc` (chart `nameOverride`) |
| Service values key | `service.ucc` | `service.cache` |
| Default TLS secret | `usd-content-cache-tls` | `ovcc-tls` |
| Cache reset path | `/__ucc/cache/reset` | `/__/cache/reset` |
| Instance header | `UCC-Instance` | `CC-Instance` |
| Metrics prefix | `ucc_` | `cc_` |
| Cache path suffix | `/ucc_data` | `/data` |

## Teams still on UCC 3.0.3

Teams that are not ready to move to OVCC should keep using the
`caches-ucc-deploy` skill, which targets the immutable UCC 3.0.3
(`usd-content-cache`) chart.
