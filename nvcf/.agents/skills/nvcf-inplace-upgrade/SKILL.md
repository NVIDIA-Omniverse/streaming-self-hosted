---
name: nvcf-inplace-upgrade
description: >-
  Upgrade an already running NVCF self-managed control plane and matching
  compute-plane stack in place from a new image-manifest/manifest.yaml. Use
  when the user asks to ingest a new manifest, upgrade an existing self-hosted
  or self-managed NVCF cluster with new NVCF images/charts, perform a
  manifest-driven NVCF upgrade, or refresh NVCA/compute-plane components
  without recreating infrastructure. Do NOT use for first-time installation,
  cloud infra upgrades, AKS/EKS/node pool upgrades, registry provisioning, or
  non-NVCF auxiliary services such as LLS, caches, or storage APIs.
license: Apache-2.0
allowed-tools: Bash, Read, Edit, Grep, Glob
metadata:
  internal: false
  author: "nvcf-core-eng <nvcf-core-eng@exchange.nvidia.com>"
  version: "1.1.0"
  compatibility: >-
    Requires helm >= 3.12 < 4, helm-diff plugin >= 3.11, kubectl within one
    minor version of the cluster, yq, jq, and helmfile 1.1.x preferred; reject
    helmfile 1.2.x; helmfile 1.3.0+ requires sequential execution support.
  tags: [nvcf, self-managed, self-hosted, in-place-upgrade, inplace-upgrade, image-manifest, helmfile, control-plane, compute-plane, nvca]
  languages: [bash, yaml]
  frameworks: [helmfile, helm, kubectl]
  domain: cloud-infrastructure
---

<!-- SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved. -->
<!-- SPDX-License-Identifier: CC-BY-4.0 AND Apache-2.0 -->

# NVCF In-Place Upgrade

Upgrade existing NVCF self-managed control-plane and compute-plane releases to
the NVCF versions pinned by a new `image-manifest/manifest.yaml`, without
recreating cloud infrastructure, namespaces, PVCs, registration records, or
non-NVCF auxiliary services.

## Scope

This skill owns only NVCF component upgrade semantics:

- `nvcf-self-managed-stack` manifest group for control-plane charts and images.
- `nvcf-compute-plane-stack` manifest group for NVCA and compute-plane charts
  and images.
- Existing Helmfile bundle roots for `nvcf-self-managed-stack` and, when
  present, `nvcf-compute-plane-stack`.
- Existing Kubernetes clusters and existing registry mirrors.

Use provider or staging skills for provider-specific artifact mirroring before
this skill runs. For Azure, mirror only the NVCF groups through the ACR mirror
flow. For AWS, mirror only the NVCF groups through the ECR mirror flow:

```bash
INCLUDE_GROUPS=nvcf-self-managed-stack,nvcf-compute-plane-stack
```

Do not use this skill to upgrade AKS/EKS, node pools, VPC/VNet, GPU Operator,
LLS, GXCache, UCC, OVDC, storage APIs, user functions, or cloud storage. If the
user asks for the full streaming stack, route to the higher-level orchestration
skill and let it call this skill only for the NVCF phase.

## Source Docs

Align upgrade planning with NVIDIA NVCF docs, especially:

- `https://docs.nvidia.com/nvcf/manifest`
- `https://docs.nvidia.com/nvcf/image-mirroring`
- `https://docs.nvidia.com/nvcf/helmfile-installation`
- `https://docs.nvidia.com/nvcf/control-plane-operations`
- `https://docs.nvidia.com/nvcf/0-5-0-to-0-6-0-upgrade`
- `https://docs.nvidia.com/nvcf/v0.6.1/0-6-0-to-0-6-1-upgrade`
- `https://docs.nvidia.com/nvcf/v0.6.1/0-6-1-release-notes`

## Safety Rules

- Treat NVIDIA's published NVCF docs as authoritative for version-specific
  upgrade paths. When current and target versions match a documented path, use
  that runbook instead of a generic manifest-only rollout.
- Do not imply arbitrary manifest jumps are validated. NVCF self-hosted upgrade
  docs call out Early Access limitations for generic service upgrades; require
  release-note review and explicit operator acceptance for undocumented paths.
- Keep NVCF self-managed stack and compute-plane stack artifacts coordinated as
  umbrella releases. Do not mix arbitrary "latest" images or chart versions
  across releases unless NVIDIA support or a version-specific doc says to.
- Never print, echo, decode, or paste secret values, including NGC keys,
  registry passwords, OpenBao tokens, kubeconfigs, admin JWTs, and generated
  secrets files.
- Never run `helmfile destroy`, `make destroy`, `nvcf-cli self-hosted down`,
  `nvcf-cli cluster delete`, namespace deletion, PVC deletion, or other
  teardown commands as part of an upgrade.
- Stop before mutation if Cassandra, OpenBao, NATS, SIS, API, or NVCA are
  unhealthy and the user has not explicitly asked for a recovery workflow.
- Treat Cassandra, OpenBao, and NATS changes as stateful dependency upgrades.
  Recommend an appropriate backup or snapshot for each in-scope data-bearing
  StatefulSet and show the operator-reported status and rollback consequence.
  Missing backup evidence alone must not block Apply.
- Do not assume Helm rollback reverts Cassandra data, schema, or PVC contents.
- Backup or snapshot creation is opt-in. Do not create one without the
  operator's explicit request or approval.
- Keep the previous manifest and rendered values available until the upgrade is
  validated and the rollback window is closed.
- Do not prune old image tags or Helm chart artifacts from the registry during
  the rollback window.
- Use the extracted stack's documented Makefile/Helmfile target for the chosen
  upgrade path. Prefer selector-scoped phases; run unscoped `install`, `sync`,
  or `apply` only when the NVIDIA upgrade procedure explicitly reaches its full
  stack step or the operator is repairing a missing release.

## Required Inputs

Collect or discover these before planning the upgrade:

| Input | Purpose |
| --- | --- |
| `CONTROL_PLANE_STACK` | Existing `nvcf-self-managed-stack` root containing `helmfile.d/`, `environments/`, `secrets/`, `global.yaml.gotmpl`, and `Makefile`. |
| `COMPUTE_PLANE_STACK` | Matching `nvcf-compute-plane-stack` root when a compute plane is installed or NVCA must be refreshed. |
| `HELMFILE_ENV` | Environment name used by the existing deployment. Must match `environments/<env>.yaml` and `secrets/<env>-secrets.yaml` where applicable. |
| `CLUSTER_NAME` | Required for compute-plane `make template` and `make apply`. |
| `CONTROL_PLANE_KUBECONFIG_FILE` or context | Kube access for the control-plane cluster. |
| `COMPUTE_PLANE_KUBECONFIG_FILE` or context | Kube access for the compute-plane cluster. May be the same as control plane. |
| `CURRENT_MANIFEST` | Manifest used by the currently running deployment, when available. |
| `CANDIDATE_MANIFEST` | New `image-manifest/manifest.yaml` to ingest and upgrade to. |
| `SOURCE_REGISTRY_CONFIG` | Source registry config paired with the manifest, when artifact mirroring or provenance checks need it. |
| Registry mirror target | Registry host and repository already populated with the candidate NVCF artifacts. |
| Current NVCF version | Current stack, chart, or release version used to select the documented upgrade path. |
| Target NVCF version | Candidate stack, chart, or release version used to select the documented upgrade path. |
| NVCF upgrade doc | Published NVIDIA upgrade page or release notes for this version transition, when available. |

If the candidate manifest is not local, fetch it through the user's approved
repository or CI artifact path first. Record its source ref or artifact URL in
the plan without leaking credentials.

## Prerequisites, Downtime, And Stateful Upgrade Process

Before applying an in-place upgrade, list these prerequisites in the plan and
mark each one satisfied, not applicable, or blocked:

| Prerequisite | Requirement |
| --- | --- |
| Target confirmation | CSP, account/subscription, region/location, cluster name, namespaces, kube context or kubeconfig, Helmfile environment, target registry, and repository path are confirmed. |
| Maintenance window | Operator accepts the expected service interruption risk for changed stateful dependencies and one-replica services. |
| Toolchain | Supported Helm 3, helm-diff, kubectl, yq, jq, and the provider CLI are available. Use helmfile 1.1.x by default; reject helmfile 1.2.x; use helmfile 1.3.0+ only with sequential execution enabled. |
| Current health | Cassandra, OpenBao, NATS, API, SIS, and NVCA, when installed, are healthy before mutation unless the operator explicitly requested recovery. |
| Namespace layout | Fixed NVCF namespaces exist as expected: `cassandra-system`, `nats-system`, `vault-system`, `nvcf`, `api-keys`, `ess`, `sis`, `nvca-operator`, and compute-plane namespaces when installed. |
| Manifest provenance | Current and candidate manifests are recorded, candidate `version` and `generated_at` are present, and changed NVCF entries are classified as charts or images. |
| Version path | Current and target versions are mapped to a published NVIDIA upgrade doc, release notes, or an explicit unsupported-risk acceptance. |
| Stack compatibility | Control-plane and compute-plane artifacts come from compatible self-managed stack releases; do not substitute arbitrary newer artifacts into an older umbrella release. |
| Registry readiness | All changed NVCF images and charts are mirrored and pullable from the registry the cluster will use. Do not depend on source registries during the rollout. |
| Helm rollback context | Capture or display `helm get values` and `helm history` for every in-scope release when available; report gaps and the effect on rollback. |
| StatefulSet backup recommendation | For every StatefulSet in scope, show a recommended method, operator-reported status, and rollback consequence if skipped. Mark no-PVC/non-persistent workloads `not applicable`. Absence alone is not an Apply blocker. |
| Rollback materials | Inventory the previous manifest, rendered values, Helm history, registry paths, and stateful backup options. Report missing materials and their recovery impact. |
| Cluster capacity | Nodes have enough schedulable capacity for rolling updates, or the operator has accepted targeted one-replica `maxSurge=0,maxUnavailable=1` patches when capacity blocks rollout. |
| Secret handling | Required kubeconfigs, registry credentials, OpenBao tokens, NGC keys, and secret manifests are available to the operator but are never printed, decoded, or pasted. |

Expected downtime depends on the changed component:

- Multi-replica stateless NVCF services should roll with no planned downtime
  when PDBs and cluster capacity allow a surge or replacement pod.
- One-replica services can have brief downtime during pod replacement,
  especially on capacity-constrained clusters where `maxSurge=0` is required.
- Single-node Cassandra causes NVCF control-plane outage while the pod restarts
  or migrations run. Multi-node Cassandra can roll by ordinal, but still needs a
  maintenance window because schema/data changes are not Helm-rollback-safe.
- OpenBao HA should tolerate a rolling restart when quorum, unseal state, and
  leader election are healthy. Migration or plugin reload failures can extend
  the window and must be fixed before continuing.
- NATS changes can affect message flow if quorum or routes are unhealthy during
  restart. Validate NATS before upgrading services.
- NVCA/operator changes can temporarily pause compute-plane reconciliation or
  new function scheduling while the operator rolls.

For every StatefulSet upgrade, use this process:

1. Identify every StatefulSet in scope and recommend a backup or snapshot when
   it would make rollback safer, not only for Cassandra.
2. Record the operator-reported backup status and rollback consequence for each
   StatefulSet. Mark no-PVC or non-persistent workloads `not applicable`.
3. Capture current pods, PVCs, PDBs, Helm history, and service-specific health.
4. Render and diff only the stateful release before applying it.
5. Stop on unexpected immutable or data-risky changes: selectors, service name,
   volume claim templates, PVC names, storage class, or storage size reduction.
6. Verify every changed stateful image, migration image, and chart is mirrored.
7. Apply only that stateful release or dependency slice.
8. Wait for the StatefulSet rollout to finish; Kubernetes updates pods in
   ordinal order and preserves PVCs.
9. Run service-specific health checks and migration job checks.
10. Continue to the next phase only after the service is stable and dependent
   NVCF services are not crashing.

## Preflight

Run read-only checks first and report the results:

```bash
helmfile --version
helm version
helm plugin list
kubectl version --client
yq --version
jq --version
```

Reject Helm 4 and helmfile `1.2.x`. Helmfile `1.1.x` is the documented default.
If using helmfile `1.3.0+`, add `--sequential-helmfiles` to every direct
`helmfile apply` or `helmfile sync` command, or confirm the stack Makefile wraps
that flag.

Verify the stack roots:

```bash
ls "$CONTROL_PLANE_STACK/helmfile.d" \
   "$CONTROL_PLANE_STACK/environments" \
   "$CONTROL_PLANE_STACK/secrets" \
   "$CONTROL_PLANE_STACK/global.yaml.gotmpl"

if [ -n "${COMPUTE_PLANE_STACK:-}" ]; then
  ls "$COMPUTE_PLANE_STACK/helmfile.d" \
     "$COMPUTE_PLANE_STACK/environments" \
     "$COMPUTE_PLANE_STACK/global.yaml.gotmpl"
fi
```

For an existing cluster, capture a baseline before any changes:

```bash
kubectl get pods -A
kubectl get pvc -A
helm list -A
kubectl get deploy,statefulset -A -o wide
```

Validate the fixed NVCF namespace layout before selecting an upgrade path:

```bash
for ns in cassandra-system nats-system vault-system nvcf api-keys ess sis nvca-operator; do
  kubectl get namespace "$ns"
done
```

Before upgrading any Helm release, inspect rollback context and, when requested
or available, save release values and revision history:

```bash
helm get values <release> -n <namespace> -o yaml > <release>-values-backup.yaml
helm history <release> -n <namespace>
```

If these artifacts are unavailable or the operator elects not to save them,
report the reduced rollback fidelity in the impact summary. Their absence alone
must not block Apply.

Always pass the saved or reconciled values file during direct `helm upgrade`;
otherwise Helm resets omitted values to chart defaults.

For compute-plane upgrades, verify the registration file exists and keep it:

```bash
test -s "$COMPUTE_PLANE_STACK/registration/${CLUSTER_NAME}-register-values.yaml"
```

Do not re-register the cluster for a normal image/chart upgrade. Re-run
registration only when the operator is intentionally repairing missing
registration values or changing cluster identity.

## Manifest Handling

The candidate manifest is the source of truth. Inspect only the NVCF groups:

```bash
yq '.version, .generated_at, ."nvcf-self-managed-stack", ."nvcf-compute-plane-stack"' "$CANDIDATE_MANIFEST"
```

Validate:

- `version` and `generated_at` are present.
- `nvcf-self-managed-stack` exists and is non-empty.
- `nvcf-compute-plane-stack` exists when a compute plane is installed.
- The control-plane and compute-plane groups come from a compatible
  self-managed stack release. Do not combine arbitrary newer artifact versions
  with an older stack.
- Versions are pinned strings or non-empty string lists; reject `latest`,
  empty values, and unresolved placeholders.
- The current and candidate manifests are both recorded in the upgrade plan.

Diff current and candidate manifests by NVCF group. Classify changed entries as
charts when their key starts with `helm-`; classify the rest as container
images. If the current manifest is missing, treat every candidate entry in the
NVCF groups as required for registry presence and rendered upgrade checks.
If changed keys include `helm-nvcf-cassandra`, `cassandra`, or
`nvcf-cassandra-migrations`, mark the plan as requiring the Cassandra upgrade
path.

## Upgrade Impact Summary

Before requesting Apply approval, show every changed in-scope component in a
single impact table. Include `Component`, `Current version`, `Target version`,
`Workload type`, `Risk`, `Downtime expectation`, `Backup recommendation`,
`Backup status`, and `Rollback impact`. Use live release and pod data where
available, and mark unknown values explicitly.

For data-bearing StatefulSets, suggest the backup or snapshot method that would
make rollback easiest and explain when Helm rollback cannot restore data or
schema. Backup status may be `available`, `planned`, `skipped`, or `unknown`;
none of those statuses alone is an Apply blocker. Components with no PVC or
persistent data should be marked `not applicable`. Continue to enforce health,
compatibility, immutable-field, artifact-readiness, and render/diff gates.

## Doc-Aligned Upgrade Selection

Select the upgrade path from current and target NVCF versions before rendering
or applying:

- For `0.5.x` to `0.6.0`, follow NVIDIA's `0.5.0 to 0.6.0 Upgrade` procedure.
  This is a migration upgrade, not a generic image refresh.
- For `0.6.0` to `0.6.1`, follow NVIDIA's `0.6.0 to 0.6.1 Upgrade` procedure
  and `0.6.1` release notes. Existing data-bearing Cassandra clusters require a
  migration method; OpenBao requires a controlled server pod rotation.
- For single-service hotfixes or patch chart bumps, use the Control Plane
  Operations pre-upgrade checklist, values backup, release-note review, and
  rollback guidance.
- For undocumented version jumps or version changes whose release notes mention
  database migrations, API compatibility, or coordinated stack changes, stop in
  Plan or Diff mode until the operator accepts the unsupported upgrade risk or
  provides the applicable NVIDIA runbook.

When using a new extracted stack bundle, reconcile site-specific settings from
the previous environment and secrets files into the target version's templates.
Do not replace the target version's files wholesale with old files, because
available values may change between releases. Preserve registry, storage,
endpoint, credential, and secret values unless the NVIDIA procedure explicitly
instructs a change.

### 0.5.x To 0.6.0 Gates

Before the `0.6.0` sync:

- If starting from `0.5.0` with private registry pulls through
  `global.imagePullSecrets`, upgrade to `0.5.1` or later first so migration and
  sidecar images can pull.
- Require `nvcf-cli` `1.8.3` or later before GPU cluster re-registration.
- Enable OpenBao issuer discovery for CSP clusters before the sync.
- Enable NATS Gateway routing and verify TCP port `4222` route/listener
  readiness before NVCA refresh.
- If NVCA is `2.50.5` or older, upgrade to `2.51.0` and verify health before
  moving to NVCA `3.x`.

Run the migration stops in order:

1. Cassandra schema migration: keep `global.storageClass` and
   `global.storageSize` matching the live StatefulSet, quiesce control-plane
   services that write to Cassandra, sync only `name=cassandra`, and verify the
   migration Job completed.
2. Spot Instance Service auth-client-id migration: temporarily deploy the
   documented migration runtime, scale only SIS up, enable the migration task
   variables, and confirm eligible cluster rows have `auth_client_id`
   populated.
3. Enable SIS NATS reconnect, then run the full `0.6.0` stack sync while SIS can
   recreate required global NATS streams. Verify those streams before
   continuing.
4. Remove temporary SIS migration overrides, sync SIS to the cleanup runtime,
   and remove migration task variables.
5. Refresh GPU cluster registration and NVCA operator through the compute-plane
   flow after the control plane is healthy.

Do not continue past any stop until its verification passes.

### 0.6.0 To 0.6.1 Gates

For `0.6.0` to `0.6.1`, do not run an unscoped target-stack install before
completing the documented stateful work. This includes `make install`,
`helmfile sync`, and equivalent unscoped sync commands.

OpenBao must be handled before the rest of the patch stack:

- Verify current OpenBao pods and jobs are healthy and the StatefulSet uses
  `OnDelete`.
- Sync only `name=openbao-server` from the `0.6.1` stack.
- Confirm the OpenBao migration Job completed and the StatefulSet template now
  references the updated image.
- Rotate OpenBao server pods manually, one at a time: standby pods first,
  active pod last.
- After each pod recreate, verify it is initialized, unsealed, ready, and in a
  healthy HA mode. Stop on any sealed, uninitialized, or not-ready pod.

Existing data-bearing Cassandra clusters require one documented migration
method. Do not treat this as a normal in-place Helm rolling upgrade because the
runtime image, chart shape, and on-disk data layout changed.

Choose and report one method before mutation:

| Method | Downtime | Data handling | Requirement |
| --- | --- | --- | --- |
| Datacenter expansion | Effectively none | New datacenter streams data from old datacenter. | Capacity for both datacenters and datacenter-aware client cutover. |
| In-place volume adoption | Brief restart per node | New pods reuse retained existing volumes. | Manual StatefulSet recreate, PVC retention check, and `persistence.subPath: "data"` or one-time layout relocation. |
| Backup and restore | Maintenance window | Restore snapshots into fresh 0.6.1 Cassandra. | Snapshot copy off-node and capacity for parallel restore/verification. |

Before any Cassandra method, verify pods are Running, PVCs are Bound,
`nodetool status` reports expected nodes `UN`, known table row counts are
recorded, and schema migration records are not dirty. Recommend `nodetool
flush` plus `nodetool snapshot` on every node with snapshots copied off-node,
or volume snapshots, because Helm rollback does not restore Cassandra data or
schema. If the operator skips this recommendation, show that restore-based
rollback is unavailable or unverified, but do not block Apply solely for that
reason. Never delete Cassandra PVCs during the migration.

## Artifact Readiness Gate

Before changing Helm releases, verify the candidate NVCF artifacts are already
available from the registry the cluster uses. Provider skills own the mechanics
of mirroring to ACR or ECR; this skill owns the gate that the NVCF upgrade must
not proceed until the mirror is ready.

For a stack-version upgrade using a private target registry, require all
candidate NVCF control-plane and compute-plane artifacts to be present, not only
the entries that appear changed from the previous manifest. A new stack release
can introduce new chart or sidecar artifacts, and missing private-registry
artifacts surface as `ImagePullBackOff` or chart resolution failures during the
rollout.

Check at minimum:

- All non-`helm-*` entries from `nvcf-self-managed-stack`.
- All `helm-*` entries from `nvcf-self-managed-stack`.
- All entries from `nvcf-compute-plane-stack` when compute plane is installed.
- Any list-valued manifest entry has every listed tag available, because lists
  are used during upgrade transitions.

If a chart was served from a non-OCI Helm repository, require evidence that it
was converted and pushed into the OCI mirror before pointing
`global.helm.sources` at that mirror.

## Render And Diff

Work from the existing stack directories. Do not create a fresh deployment
directory unless the operator intentionally copied the bundle for testing.

If the Helmfile bundle reads chart versions from `image-manifest/manifest.yaml`,
replace or update that file with the candidate manifest in the bundle location
documented by the distribution package. If the bundle carries literal chart
versions, update only the relevant NVCF chart versions from the candidate
manifest and keep the old file for rollback.

Render first:

```bash
make -C "$CONTROL_PLANE_STACK" template \
  HELMFILE_ENV="$HELMFILE_ENV" \
  KUBECONFIG_FILE="$CONTROL_PLANE_KUBECONFIG_FILE"
```

For compute plane:

```bash
make -C "$COMPUTE_PLANE_STACK" template \
  HELMFILE_ENV="$HELMFILE_ENV" \
  CLUSTER_NAME="$CLUSTER_NAME" \
  KUBECONFIG_FILE="$COMPUTE_PLANE_KUBECONFIG_FILE"
```

Run `helmfile diff` from the stack root, using the same environment, kubeconfig,
and selector arguments that will be used for `apply`. Review the planned changes
before the first mutation. The plan must call out stateful changes to Cassandra,
OpenBao, or NATS explicitly.

## Stateful Dependencies And Cassandra

Cassandra is deployed as a StatefulSet. For ordinary chart/image changes,
Kubernetes can roll pods one at a time while retaining existing PVCs. This
generic path does not apply to documented Cassandra migration releases such as
`0.6.0` to `0.6.1`, where the runtime image, chart shape, and on-disk data
layout changed. For those releases, use the doc-aligned migration method chosen
above.

Before mutating Cassandra, capture read-only health and ownership state. Use the
actual Cassandra namespace and pod names discovered in the cluster; the commands
below assume `cassandra-system` and `cassandra-0` only as common defaults:

```bash
kubectl get sts,pods,pvc -n cassandra-system
kubectl get pdb -n cassandra-system
helm history cassandra -n cassandra-system
kubectl exec -n cassandra-system cassandra-0 -- nodetool status
kubectl exec -n cassandra-system cassandra-0 -- nodetool describecluster
kubectl exec -n cassandra-system cassandra-0 -- nodetool netstats
kubectl exec -n cassandra-system cassandra-0 -- nodetool compactionstats
```

Recommend a Cassandra backup before applying changes: either volume snapshots
or `nodetool flush` plus `nodetool snapshot`. When evidence is available, record
the timestamp, covered PVCs/keyspaces, and where off-node restore artifacts
live. When it is skipped or unknown, record that data/schema restore may be
unavailable and rollback may require rolling forward; absence alone does not
block Apply. For a single-node Cassandra cluster, expect an NVCF control-plane
outage while the Cassandra pod restarts or data is restored.

For ordinary Cassandra chart/image changes, render and diff Cassandra by itself
before applying it:

```bash
HELMFILE_ENV="$HELMFILE_ENV" helmfile --selector name=cassandra template
HELMFILE_ENV="$HELMFILE_ENV" helmfile --selector name=cassandra diff
```

Use the equivalent `make -C "$CONTROL_PLANE_STACK"` invocation when the stack
wraps Helmfile arguments through Makefile targets. Stop if the diff changes
immutable or data-risky StatefulSet fields, including `spec.selector`,
`spec.serviceName`, `volumeClaimTemplates`, `storageClassName`, PVC names, or
storage size reductions.

Verify all Cassandra artifacts are mirrored before mutation:

- `cassandra`
- `helm-nvcf-cassandra`
- `nvcf-cassandra-migrations`

Apply ordinary Cassandra changes alone and validate them before any broader
dependency or service phase:

```bash
make -C "$CONTROL_PLANE_STACK" apply \
  HELMFILE_ENV="$HELMFILE_ENV" \
  KUBECONFIG_FILE="$CONTROL_PLANE_KUBECONFIG_FILE" \
  HELMFILE_SELECTOR='name=cassandra'
```

After ordinary Cassandra apply, require:

- `kubectl rollout status sts/cassandra -n cassandra-system --timeout=15m`
- Cassandra pods Ready and stable.
- `nodetool status` shows all expected nodes `UN`.
- `nodetool netstats` and `nodetool compactionstats` do not show stuck streams
  or runaway compactions.
- Cassandra migration jobs, if present, completed successfully.
- DB-backed NVCF services are not CrashLoopBackOff.

Only continue to `release-group=services` after Cassandra is healthy. If
Cassandra migrations, data-format changes, or the `0.6.1` data-bearing
migration ran, rollback requires restoring the recorded backup or rolling
forward; Helm rollback alone only reverts the Kubernetes release spec.

## Stateful Dependencies And OpenBao

OpenBao is deployed as a StatefulSet and may run chart hook migrations during
an image upgrade. Render and diff it separately when the manifest changes
`helm-nvcf-openbao-server`, `nvcf-openbao`, `nvcf-openbao-migrations`,
`oss-vault-k8s`, or related OpenBao sidecar images.

For `0.6.0` to `0.6.1`, do not rely on a generic StatefulSet rollout. Sync
`name=openbao-server` first, confirm the migration Job completed, then rotate
server pods manually because the StatefulSet uses `OnDelete`.

Before mutating OpenBao, capture read-only health:

```bash
kubectl get sts,pods,pvc -n vault-system
helm history openbao-server -n vault-system
kubectl exec -n vault-system openbao-server-0 -- bao status
kubectl exec -n vault-system openbao-server-0 -- bao operator raft list-peers
```

Stop if the diff changes immutable StatefulSet fields such as
`spec.selector`, `spec.serviceName`, or `volumeClaimTemplates`, unless a
post-renderer or chart value preserves the live values. Do not delete OpenBao
PVCs during an in-place upgrade.

When manual rotation is required, delete one OpenBao pod at a time. Rotate
standby pods before the active pod. After each recreated pod, verify `bao
status` reports initialized, unsealed, and healthy HA state before continuing.

If OpenBao migrations fail with JWT backend errors after a plugin image change,
verify the configured `vault-plugin-secrets-jwt` catalog checksum matches the
actual binary checksum in the upgraded pod. Register the new checksum, reload
the plugin, and rotate OpenBao pods only after the cluster is unsealed and has
an active leader.

For EKS and AKS issuer discovery, prefer the provider JWKS endpoint when the
cluster has multiple signing keys. A multi-PEM bundle rendered into a single
`jwt_validation_pubkeys` argument can fail migration hooks; enable issuer
discovery instead of hand-flattening keys when the chart supports it.

## Upgrade Order

Use the target stack's documented Makefile/Helmfile target and existing
Helmfile ordering, but apply one phase at a time. NVIDIA docs use `make
install`; some local bundles expose `make apply`. Use the target available in
the extracted stack and keep selectors equivalent.

For documented migration transitions, follow the version-specific gates above
before running any unscoped stack install or sync. In particular, for `0.6.0`
to `0.6.1`, do not run the full stack until OpenBao and the selected
Cassandra migration method have completed.

For ordinary control-plane upgrades:

If the manifest diff includes Cassandra chart, image, or migration changes, run
the Cassandra upgrade path first. Do not apply the whole dependency release
group until Cassandra has passed its post-upgrade checks.

```bash
make -C "$CONTROL_PLANE_STACK" apply \
  HELMFILE_ENV="$HELMFILE_ENV" \
  KUBECONFIG_FILE="$CONTROL_PLANE_KUBECONFIG_FILE" \
  HELMFILE_SELECTOR='release-group=dependencies'

make -C "$CONTROL_PLANE_STACK" apply \
  HELMFILE_ENV="$HELMFILE_ENV" \
  KUBECONFIG_FILE="$CONTROL_PLANE_KUBECONFIG_FILE" \
  HELMFILE_SELECTOR='release-group=services'

make -C "$CONTROL_PLANE_STACK" apply \
  HELMFILE_ENV="$HELMFILE_ENV" \
  KUBECONFIG_FILE="$CONTROL_PLANE_KUBECONFIG_FILE" \
  HELMFILE_SELECTOR='release-group=ingress'

make -C "$CONTROL_PLANE_STACK" apply \
  HELMFILE_ENV="$HELMFILE_ENV" \
  KUBECONFIG_FILE="$CONTROL_PLANE_KUBECONFIG_FILE" \
  HELMFILE_SELECTOR='release-group=observability'
```

Skip a selector when the stack does not define that release group. After each
selector, wait for that group's rollouts and inspect events before continuing.
Use direct `helm upgrade` only for documented hotfix or spot-upgrade cases, and
always pass the saved or reconciled values file with `-f`.
On capacity-constrained clusters, one-replica services can block with an extra
surge pod stuck Pending. If the operator accepts a brief service outage, patch
only the currently blocked deployment to `maxSurge=0,maxUnavailable=1`, wait
for that rollout to complete, and record the patch in the report. Do not apply
that rollout strategy broadly across unrelated deployments.

For compute plane, apply after the control plane is healthy:

```bash
make -C "$COMPUTE_PLANE_STACK" apply \
  HELMFILE_ENV="$HELMFILE_ENV" \
  CLUSTER_NAME="$CLUSTER_NAME" \
  KUBECONFIG_FILE="$COMPUTE_PLANE_KUBECONFIG_FILE"
```

For multi-cluster deployments, repeat the compute-plane render, diff, apply,
and validation for each registered compute cluster. Do not assume the ambient
kube context is the target; pass the explicit kubeconfig or context each time.

## Validation

After every phase:

```bash
kubectl get pods -A
kubectl get events -A --sort-by='.lastTimestamp'
helm list -A
```

Control-plane validation:

- Dependency pods are Ready: NATS, OpenBao, Cassandra.
- Service pods are Ready: API, API Keys, SIS, ESS, invocation, gRPC proxy,
  notary, ReVal, and any enabled optional NVCF services.
- Gateway routes still exist and point at the expected Gateway.
- `nvcf-cli self-hosted status --json` returns a healthy verdict when CLI
  configuration is available.
- Account bootstrap state remains valid; do not recreate accounts unless a
  failed hook requires explicit repair.

Compute-plane validation:

```bash
kubectl rollout status deployment/nvca-operator -n nvca-operator --timeout=10m
kubectl wait nvcfbackend/"$CLUSTER_NAME" -n nvca-operator \
  --for=jsonpath='{.status.agentStatus}'=healthy --timeout=10m
```

Finally, verify running NVCF workload images match candidate manifest tags. Use
rendered manifests and live pod specs, and exclude completed hook jobs from the
drift count. Report any running old tag that is not expected during a
documented rolling transition.

## Rollback Plan

Before the first `apply`, inventory and, when available, save:

- Current manifest and candidate manifest.
- `helm list -A` output.
- `helm history` for all NVCF releases in scope.
- `helm get values <release> -n <namespace> -o yaml` output for every
  in-scope release.
- Rendered manifests from the current and candidate bundles when available.
- The exact registry mirror path used for images and charts.

For every in-scope StatefulSet, include the backup recommendation,
operator-reported status, and rollback limitation. Missing backup evidence does
not by itself block Apply, but it can make data restore impossible and force a
roll-forward recovery.

If rollback is needed, roll back to the previous manifest and chart/image pins,
then re-run `template`, `diff`, and phased `apply` in reverse upgrade scope:
compute plane first when NVCA is incompatible with the control plane, otherwise
the failing phase first. Use `helm rollback` for an individual failed release
only when the operator has identified that release as the failure boundary.
For direct Helm hotfixes, inspect revision history and roll back the release:

```bash
helm history <release> -n <namespace>
helm rollback <release> -n <namespace> <revision>
kubectl rollout status deployment/<name> -n <namespace> --timeout=120s
kubectl rollout status statefulset/<name> -n <namespace> --timeout=300s
```

Helm rollback reverts the chart version and values recorded in the release, but
it does not revert Cassandra data, schema migrations, restored volumes, or
manual credential/config edits made outside Helm. For documented Cassandra
migration releases, recover through the selected migration method's backup,
restore, or roll-forward procedure.

Do not delete namespaces, PVCs, registration values, or ICMS cluster records as
rollback.

## Report

Return a concise upgrade report:

- Current branch or bundle version and candidate manifest provenance.
- NVCF manifest entries changed, grouped by control plane and compute plane.
- NVCF docs or release notes used for the selected version path.
- Registry mirror target and artifact readiness result.
- Render/diff result.
- Phases applied and rollout status.
- Any components still running old images and why.
- Stateful backup recommendations, operator-reported status, and rollback
  limitations.
- Rollback artifacts and commands prepared.
