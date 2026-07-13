---
name: nvcf-lls-install
description: Use for installing, planning, or debugging NVCF LLS across self-managed Kubernetes environments. Trigger on explicit NVCF LLS, gdn-streaming, streaming-proxy, TURN, LLS WebRTC ingress, UDP 5004 media ingress, TCP 3478 TURN ingress, or LLS provider adaptation for Kubernetes clusters. Do not use for unrelated generic streaming media work.
version: "1.0.0"
author: nvcf-auxiliary-services
tags: [nvcf, lls, helm, kubernetes, streaming-proxy, turn, udp, tcp]
tools: [Shell, Read, Write]
---

<!-- SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved. -->
<!-- SPDX-License-Identifier: CC-BY-4.0 AND Apache-2.0 -->

# NVCF LLS

Run commands from the repo root; artifact paths below are repo-root relative.

LLS is the UDP/WebRTC edge for NVCF streaming functions. The HTTP/gRPC gateway cannot carry UDP media, so LLS uses a dedicated `streaming-proxy` pod plus provider-specific public UDP 5004 ingress. With the `gdn-streaming` 3.x chart, downstreams may also enable `turn-service` for TCP TURN on public TCP 3478.

Before any command that touches registry auth, use a downstream auth helper, workload identity, or secret-manager-backed login. Never print, echo, decode, grep, or `kubectl get -o yaml` secret material, and do not place local secret material directly in generated commands.

Local tools used by this skill: `kubectl`, `helm`, `python3`, `sed`, `awk`, `grep`, `curl`, `nc`. Provider notes may require provider CLIs, `docker`, or registry-specific helpers.

## When To Use

Use for LLS install/debug on self-managed NVCF clusters: `gdn-streaming`, public UDP 5004 ingress, optional TCP TURN 3478, `streaming-proxy` or `turn-service` rollout/image/zone/WebRTC failures, or provider-specific adaptation. Prepare the NVCF control plane and NVCA through the upstream `nvcf-self-managed-installation` flow first. LLS requires `nvcf-backend`; media validation requires a real streaming function and WebRTC client.

## TL;DR

1. Confirm `nvcf-backend` exists and NVCA/control-plane prerequisites are installed.
2. Open `providers/kubernetes.md`; use the Kubernetes workflow first, then apply only the provider notes needed for the target cluster.
3. Choose the `streaming-proxy` image source and, when TCP TURN is enabled, the `turn` image source: direct registry pull with a safe pull secret, or provider registry mirror with equivalent pull permission.
4. Render provider-specific chart values for image, zone/topology, node selection, `env.lbDns`, `env.lbPort=5004`, `replicaCount`, resources, and optional `tcpTurn`.
5. Authenticate Helm to the selected chart registry; for the default NVCR `LLS_CHART_REF`, use the downstream auth helper, then install chart `gdn-streaming` v`3.0.0`.
6. Expose UDP 5004 through the provider's LoadBalancer or equivalent UDP ingress. If `tcpTurn.enabled=true`, also expose public TCP 3478 to the `turn-service` backend.
7. Verify pod readiness, services, `nvcf-sbs` ExternalName, external UDP reachability, and optional TCP TURN reachability. Real success requires a WebRTC client and a streaming function.

## Instructions

1. Confirm `nvcf-backend`, NVCA/control-plane prerequisites, and a real streaming function for final media validation.
2. Use `providers/kubernetes.md` for the target cluster and choose the UDP ingress pattern that matches the provider.
3. Render chart values for image source, zone/topology, node selection, `env.lbDns`, `env.lbPort=5004`, replicas, resources, and optional `tcpTurn`.
4. Install `gdn-streaming` v`3.0.0` with safe registry authentication.
5. Verify `streaming-proxy` readiness, optional `turn-service` readiness, `nvcf-sbs` ExternalName, public UDP 5004 reachability, optional TCP 3478 reachability, and a WebRTC client session.

## Error Handling

Classify the symptom before reinstalling the chart:

| Symptom | First checks | Action |
|---|---|---|
| `streaming-proxy` is Pending or rollout times out | `kubectl describe pod -n gdn-streaming -l app=streaming-proxy`; inspect node labels, zone labels, taints, allocatable CPU, and memory. | Fix the provider node pool or lower test-only resources. Do not delete ReplicaSets directly. |
| Public UDP endpoint has no address or unhealthy backends | Use `providers/kubernetes.md`; inspect Service or LB events, backend targets, and health probe settings. | Fix the provider LoadBalancer, security rule, health probe, or target registration. Re-run only the failed ingress step when possible. |
| TCP TURN endpoint has no address or unhealthy backends | If `tcpTurn.enabled=true`, check `turn-service` rollout, provider TCP 3478 ingress, backend target, and `/v1/turn/health` health probe behavior. | Fix only the downstream TCP ingress or rendered `tcpTurn` values; do not add provider load-balancer logic to this shared skill. |
| WebRTC signaling succeeds but media or ICE fails | Confirm `env.lbDns`, public UDP 5004 reachability, optional TCP 3478 TURN reachability, provider firewall rules, and a real WebRTC client. | Use provider-specific UDP/TCP guidance from `providers/kubernetes.md` (Service type, endpoint targeting, health-probe behavior, traffic policy, and provider security posture all live there). |
| Worker or `niclls` logs show SBS connection failures | `kubectl get svc nvcf-sbs -n nvcf-backend`; inspect the selected provider path for `externalService` requirements. | Repair the NVCF control plane/NVCA first, then rerun the LLS Helm upgrade with the provider's `nvcf-sbs` settings. |
| Image pull fails | `kubectl describe pod -n gdn-streaming -l app=streaming-proxy`; verify image repository, tag, mirror, and pull identity without printing secrets. | Fix the provider registry mirror or pull identity. Do not rotate or expose NGC keys as the first response. |

## Example

Use `providers/kubernetes.md` for runnable install, ingress, verification, and
cleanup commands. Keep CSP-specific load balancers, firewall/security objects,
IAM/workload identity, and registry mirror automation in downstream artifacts.

## Provider Adaptation

Keep this distinction explicit:

- Provider-neutral: chart version, `streaming-proxy` role, optional `turn-service` role, `nvcf-backend` namespace dependency, UDP 5004, optional TCP 3478 TURN, `env.lbDns`, `env.lbPort`, `tcpTurn.*` values shape, resources, and end-to-end media validation.
- Provider-specific: frontend address or LoadBalancer allocation, service annotations, health-probe behavior, source CIDR enforcement, registry mirror/pull secret, node labels, zone labels, and network policy.

Do not copy frontend address, provider role, CNI, registry, identity, storage, or service-annotation assumptions across providers. Recreate the equivalent provider decisions, then render a cluster-specific values file and UDP ingress before installing.

## Provider Paths

Use the generic workflow above for provider-neutral planning, then open the Kubernetes provider path for concrete commands, values contracts, and provider adaptation notes. Kubernetes providers share the same chart workflow; only registry, storage/network, identity, and LoadBalancer details differ.

| Provider | Path | Status |
|---|---|---|
| Kubernetes | `providers/kubernetes.md` | Provider-neutral Helm install and verification flow with Kubernetes adaptation notes. |

The provider file may reference downstream-owned manifests, scripts, generated env files, and provider resources. Do not apply assumptions from one provider to another without adapting those dependencies.

The provider file documents the expected values shape, but concrete values files are downstream-owned artifacts. Do not treat any provider values file as a provider-neutral default.
