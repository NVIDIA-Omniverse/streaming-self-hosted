---
name: streaming-inplace-upgrade-orchestrator
description: >-
  Orchestrate in-place upgrades for an existing NVIDIA self-managed streaming
  stack across supported cloud providers. Use when the user asks for an upgrade
  plan, upgrade sequencing, component upgrade coordination, manifest-driven
  refresh, or an end-to-end upgrade runbook that may involve provider-native
  registry mirroring plus NVCF control-plane, compute-plane, LLS, TURN, cache,
  storage, or validation phases.
  Do not use for first-time installation or for a single component when the
  user explicitly asks for only that child skill.
license: Apache-2.0
allowed-tools: Bash, Read, Edit, Grep, Glob
metadata:
  internal: false
  version: "1.1.0"
  tags: [streaming, upgrade, orchestrator, streaming-staging, aws, azure, manifest]
  languages: [bash, yaml]
  frameworks: [helmfile, helm, kubectl]
  domain: cloud-infrastructure
---

<!-- SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved. -->
<!-- SPDX-License-Identifier: CC-BY-4.0 AND Apache-2.0 -->

# Streaming In-Place Upgrade Orchestrator

Coordinate upgrades of an existing self-managed streaming stack without
duplicating component skills. This skill decides order, routes to provider and
component skills, keeps the upgrade scoped, and stops at readiness gates.

Use this for upgrade coordination across components. Use
`nvcf-inplace-upgrade` directly when the user asks only to upgrade existing NVCF
control-plane or compute-plane releases from a new manifest.

## Scope

This orchestrator may coordinate:

- Provider-native registry mirroring for changed artifacts. Use the target OCI
  registry selected for the CSP, such as ACR on Azure or ECR on AWS.
- Manifest-driven NVCF control-plane and compute-plane upgrades through
  `nvcf/.agents/skills/nvcf-inplace-upgrade/SKILL.md`.
- Streaming adjunct upgrades such as LLS and TURN when requested or when their
  manifest entries changed.
- Cache, storage, and validation phases when they are explicitly in scope.

It does not recreate AKS/EKS clusters, node pools, VPC/VNet, namespaces, PVCs,
registration records, or cloud storage as part of a normal upgrade. Route those
to provider infrastructure skills only when the operator explicitly asks for an
infrastructure repair or version upgrade.

Before any Apply step, identify every StatefulSet in upgrade scope and show an
appropriate backup or snapshot recommendation, the operator-reported status,
and the rollback consequence if it is skipped or unknown. This applies beyond
Cassandra to OpenBao, NATS, cache, storage, and any other selected StatefulSet.
Mark workloads without persistent data or PVCs `not applicable`. Backup status
is impact information, not an Apply gate: do not require evidence, confirmation,
or an exemption, and do not create a backup unless the operator explicitly asks
for or approves it.

## Required Context

Discover or collect before sequencing:

| Context | Source |
| --- | --- |
| CSP | User prompt, `streaming-env.sh`, kube context, or target registry host. |
| Cluster name | User prompt, `streaming-env.sh`, Terraform outputs, or kube context. |
| Account/subscription and region/location | `aws sts get-caller-identity`, `az account show`, env file, or user prompt. |
| Current manifest | Existing deployment bundle, previous release artifact, or operator-provided path. |
| Candidate manifest | New `image-manifest/manifest.yaml` or release artifact. |
| Installed components | Helm releases, namespaces, and registration files. |
| Execution mode | Plan, Diff, Apply, Recover, or Validate. |

Never print or decode secret values. Treat cloud credentials, kubeconfigs,
registry passwords, NGC keys, OpenBao tokens, and generated secret manifests as
sensitive.

## Mode Detection

| Mode | Trigger | Behavior |
| --- | --- | --- |
| Plan | "plan", "runbook", "what order", ambiguous upgrade language | Produce phases, owners, required inputs, and gates. Do not mutate. |
| Diff | "diff", "dry run", "render", "preview" | Verify tools, manifests, registry readiness, render output, and planned changes. Stop before apply. |
| Apply | "upgrade", "apply", "perform", "run", "execute" | Confirm target details, then execute one phase at a time with stop-on-failure gates. |
| Recover | "resume", "continue", "fix failed upgrade" | Inspect live state first and continue from the earliest failed or incomplete gate. |
| Validate | "check upgraded", "latest images", "verify" | Run health and image-drift checks without changing the cluster. |

When intent is ambiguous, choose Plan or Diff.

## Upgrade Prerequisites

Before sequencing component upgrades, report the prerequisite status:

- Target details: CSP, account/subscription, region/location, cluster name,
  kube context or kubeconfig, target OCI registry, and repository path.
- Current and candidate manifests, including version, generated timestamp, and
  the component groups that changed.
- Published NVIDIA NVCF upgrade doc or release notes for the current-to-target
  NVCF version path when NVCF artifacts changed.
- Artifact readiness for every changed image and chart in the target OCI
  registry. Select the provider mirror flow from CSP: ECR for AWS, ACR for
  Azure.
- Maintenance window and expected downtime risk for stateful dependencies,
  one-replica services, LLS/TURN, caches, storage APIs, and validation traffic.
- A backup or snapshot recommendation, operator-reported status, and rollback
  consequence for every StatefulSet in upgrade scope. Use `available`,
  `planned`, `skipped`, `unknown`, or `not applicable`; none of these statuses
  alone blocks Apply.
- Baseline health for installed stateful dependencies and services before any
  mutation.
- For installed LLS/TURN or other non-HTTP streaming routes, the live
  advertised endpoint, provider listener, Service port, targetPort/EndpointSlice
  port, effective process listener, transport/security mode, and separate
  control-health and data-plane probe results.
- Rollback materials: previous manifest, rendered values, Helm history, and
  registry paths for prior images/charts.

If a required non-backup prerequisite is incomplete, stay in Plan or Diff mode
and report the blocker before applying any change. Missing backup evidence is
not such a blocker; show its recovery impact and proceed after the normal Apply
authorization.

## NVCF Docs Alignment

When NVCF control-plane or compute-plane artifacts changed, identify the current
and target NVCF stack versions before sequencing. Route the NVCF phase through
the published NVIDIA upgrade procedure when one exists, especially documented
migration paths such as `0.5.x` to `0.6.0` and `0.6.0` to `0.6.1`.

Do not treat a documented migration release as a simple image refresh. If no
published path or release-note guidance applies, stop at Plan or Diff unless the
operator explicitly accepts the unsupported upgrade risk.

## Upgrade Impact Summary

Before requesting Apply approval, show the operator what will change so they can
assess risk before approving mutation. The first operator-facing result after
manifest comparison must be this impact summary:

| Field | Requirement |
| --- | --- |
| Component | Use the installed release, workload, or manifest key name. |
| Current version | Use the live image/chart, current manifest, or Helm values. Mark unknown explicitly. |
| Target version | Use the candidate manifest image/chart value. |
| Workload type | Classify as Deployment, StatefulSet, Job/hook, DaemonSet, or external artifact. |
| Risk | Low, Medium, or High based on replica count, statefulness, session impact, and migration risk. |
| Downtime expectation | State "none expected", "brief restart risk", or "maintenance window required". |
| Backup recommendation | Suggest the stateful backup or snapshot that would improve recovery; use `not applicable` for non-persistent workloads. |
| Backup status | Report `available`, `planned`, `skipped`, `unknown`, or `not applicable` from operator-provided information. Do not block Apply based on this field alone. |
| Rollback impact | Explain what recovery remains possible if the recommendation is skipped or unknown. |
| Owner phase | Registry, NVCF, LLS/TURN, cache, storage, or validation. |

Call out StatefulSets, one-replica services, LLS/TURN, and components with
migrations separately. If the diff cannot identify current versions or workload
types, stop before Apply and report what must be inspected to complete the
impact summary.

## Child Skill Routing

Read each child skill before executing that phase.

| Phase | AWS child skill | Azure child skill | Purpose |
| --- | --- | --- | --- |
| Registry mirror | `csp-infra/aws/.agents/skills/ecr-mirror/SKILL.md` | `csp-infra/azure/.agents/skills/acr-mirror/SKILL.md` | Mirror changed NVCF and in-scope component images/charts into the target registry. |
| NVCF in-place upgrade | `nvcf/.agents/skills/nvcf-inplace-upgrade/SKILL.md` | same | Upgrade existing NVCF control-plane and compute-plane releases from the candidate manifest. |
| NVCF CLI checks | `nvcf/.agents/skills/nvcf-self-managed-cli/SKILL.md` | same | Run post-upgrade NVCF status, function, or registration checks when needed. |
| LLS | `nvcf/.agents/skills/nvcf-lls-install/SKILL.md` | same | Upgrade/validate LLS when streaming media ingress is in scope. |
| GXCache | `caches/.agents/skills/nvcf-gxcache/SKILL.md` | same | Upgrade/validate GXCache when shader cache is in scope. |
| OVDC or OV Content Cache | `caches/.agents/skills/caches-ovdc-deploy/SKILL.md`, `caches/.agents/skills/caches-ovcontentcache-deploy/SKILL.md` | same | Upgrade/validate cache services only when selected. |
| Storage APIs | `storage/.agents/skills/ovstorage/SKILL.md` | same | Upgrade/validate storage APIs only when selected. |

## Upgrade Sequence

1. Confirm CSP, account/subscription, region/location, cluster name, manifests,
   target registry, and whether mutation is authorized.
2. Capture baseline state: pods, PVCs, StatefulSets, Helm releases, and current
   image versions for installed namespaces in scope.
3. Compare current and candidate manifests. Classify changes by owner:
   NVCF control plane, NVCF compute plane, LLS, caches, storage, or validation
   artifact only.
4. Resolve NVCF docs alignment for any NVCF version change and block Apply on
   unsupported or undocumented migration risk unless accepted by the operator.
5. Mirror changed artifacts into the CSP-native registry. For NVCF stack-version
   upgrades using a private registry, verify the full candidate
   `nvcf-self-managed-stack` and `nvcf-compute-plane-stack` artifact sets unless
   another component is explicitly in scope.
6. Run the NVCF in-place upgrade child skill when NVCF manifest entries
   changed. It owns Cassandra, OpenBao, NATS, service, compute-plane, rollback,
   and image-drift details.
7. Upgrade auxiliary services, caches, or storage only when their installed
   component versions are in scope and their artifacts are mirrored. For
   LLS/TURN, render with the exact post-renderer used for apply and run the child
   skill's route-contract gate before mutation and again against live state.
8. Run validation at the level requested by the operator: control-plane health,
   NVCF CLI status, function readiness, protocol-specific LLS/TURN routing, or
   full streaming playback.

Stop after any failed gate. Report the failed phase, owner skill, failing
evidence, and the next safe recovery action. Do not continue to later component
upgrades after a stateful dependency failure.

## Recovery And Rollback

Before Apply, inventory rollback materials for each component that may be
mutated and show the impact of anything unavailable:

- Previous manifest and any rendered values used by the current deployment.
- Helm release names, namespaces, and revision history for in-scope releases.
- Previous image and chart artifacts retained in the target registry.
- Backup or snapshot recommendation and operator-reported status for
  data-bearing StatefulSets.
- The validation checks that must pass after rollback.

Missing backup or snapshot evidence alone does not block Apply. It can make
data restore unavailable and force a roll-forward recovery, which must be shown
in the impact summary before the operator authorizes Apply.

If an upgrade fails, stop at the failing phase and choose the narrowest recovery
path:

- For a single failed stateless release, use `helm rollback` for that release
  or re-apply the previous manifest values for that component.
- For multiple changed releases, restore the previous manifest and apply only
  the affected release group.
- For Cassandra or other data migrations, do not assume Helm rollback is
  sufficient. Restore from backup or roll forward according to the owning
  component's documented recovery path.
- After recovery, verify pod readiness, Helm status, running image drift against
  the expected manifest, and the requested smoke tests.

## Stateful Gates

Before applying changes to Cassandra, OpenBao, NATS, or any cache/storage
StatefulSet:

- Verify current pod readiness, PVC binding, PDBs, and Helm history.
- Recommend an appropriate backup or snapshot for every data-bearing
  StatefulSet and record the operator-reported status and rollback consequence.
  Mark workloads without persistent data or PVCs `not applicable`. Do not pause
  Apply solely because the status is `planned`, `skipped`, or `unknown`.
- Render and diff the component by itself.
- Stop on immutable StatefulSet field changes unless the owning child skill
  documents a safe preservation method.
- Validate rollout and service health before moving to the next phase.

## Streaming Route Gates

For every upgraded LLS/TURN or other non-HTTP streaming endpoint, use the owning
child skill to validate this complete path:

`advertised endpoint -> provider listener -> Service port ->
targetPort/EndpointSlice port -> effective process listener`

- Capture the baseline route and render the candidate route with the exact Helm
  values and post-renderer before Apply. Stop if the candidate targets a port
  with no matching listener or changes plaintext/TLS semantics unexpectedly.
- Determine the listener from supported runtime configuration or listener
  evidence. Do not treat an environment variable, `containerPort`, Service port
  name, or healthy HTTP allocation endpoint as listener proof.
- After rollout, require Ready endpoints and the child skill's application-level
  probe through the Service path. Validate the advertised public endpoint from
  an approved network source; otherwise mark only that external check deferred
  with owner and required source path.
- Report control/health, relay/data-plane, TLS, and end-to-end media validation
  separately. Plain STUN reachability does not establish TLS, UDP/DTLS, relay
  allocation, or forced TURN-only video unless those paths were exercised.

Do not complete the component phase on a route mismatch even when pods and Helm
releases are Ready.

## Final Report

Return:

- Candidate manifest version, generated timestamp, and source.
- NVCF upgrade doc or release notes used for the selected version path.
- Target CSP, cluster, registry, and repository path.
- Components changed and owner skill for each phase.
- Registry readiness result.
- Phases applied, skipped, or blocked.
- Stateful backup/snapshot recommendations, operator-reported status, and
  rollback limitations.
- Running image drift result against the candidate manifest.
- For upgraded streaming routes, the rendered and live route contract,
  control-health result, protocol-specific data-plane result, external
  validation source/result, security mode, and any untested media modes.
- Remaining old images, if any, and whether they are live workloads or completed
  hook jobs.
- Rollback artifacts kept for the operator.
