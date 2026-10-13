# Isolated LLS validation

Use this reference when testing a second LLS release on a shared cluster.
Confirm the scope of the test and active workloads first. Keep diagnostic
namespace, node pool, ingress, credentials and OpenBao data separate from the
existing deployment. Provider automation remains downstream-owned.

## Certificate hook isolation

GDN chart 3.0.0 hardcodes the certificate hook Job and Secret to `vault-system`
and points the Job at shared OpenBao. Helm 3 post-renderers do not process
hooks. Changing the release namespace or post-rendering ordinary resources
does not isolate the certificate write.

For a diagnostic installation, use a temporary chart copy with the hook
namespace and OpenBao address changed to the disposable instance. Preserve
the original command and image when testing that hook. Inspect the complete
Helm render, including hook resources and cross-namespace Services, before
installation. Record those isolation changes as test limitations.

Set `vault.hashicorp.com/service` on the diagnostic TURN pod as well as the
OpenBao address in its agent ConfigMap; the injector's `VAULT_ADDR` can otherwise
still select shared OpenBao. Check the injected address and JWT role/audience
against the disposable instance. Use separate test HMAC and certificate data.

Use a hostname-matching certificate and explicit client trust for a private CA.
Retain hook completion, image digest and certificate-hash receipts, and verify
the served hostname and chain. Do not export certificate/private-key values or
raw hook logs. Never overwrite a shared certificate for an isolated test.

## Node lifecycle and evidence

Use an owned test node pool whose labels, taints and ingress permissions survive
replacement. Check rendered node selectors and tolerations for both workloads.
If adapting a controller's webhooks, add the test namespace restriction while
preserving existing opt-in selectors; replacing them can invoke disabled hooks.
For AWS, follow the [Load Balancer Controller installation guidance](https://docs.aws.amazon.com/eks/latest/userguide/lbc-helm.html)
and [TargetGroupBinding reference](https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/guide/targetgroupbinding/targetgroupbinding/).
Reuse a suitable existing controller; do not install a competing controller.

Capture automatic registration of a new node, then check for other workloads
before draining only the owned test node. Verify replacement pod and target
health, old-target deregistration, and TLS after replacement. A controlled
rolling test does not establish sudden-failure recovery or uninterrupted media.
Report public TLS, internal TLS and actual TURN/media checks separately; a
handshake or healthy target is not proof of allocation or streaming.

Remove user-created diagnostic target bindings while their controller is
available, then remove only the diagnostic resources. For controller-generated
bindings, follow the owning Service/Ingress lifecycle instead. Verify the
original workloads, certificates, listeners and nodes against the baseline.
