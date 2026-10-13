# Private registry authentication lifecycle

Use this reference for private image pulls, especially short-lived ECR tokens.
Keep the registry and Kubernetes distro selected by the operator. Plan/Generate
mode produces artifacts only; changing IAM, node configuration, or cluster
resources remains subject to the provider's Deploy/Recover authorization.

## Discover the effective path

- Inspect workload and CronJob pod templates, ServiceAccount pull-secret
  references, and node credential-provider configuration. Record names and
  selectors without reading or decoding Secret values.
- Identify the identity that obtains registry credentials, how it renews its
  own credentials, and which nodes/namespaces it covers. A controller being
  healthy is insufficient if its selectors exclude the consuming namespace.
- Separate platform image pulls from NVCF-managed worker registry credentials.
  Verify both when both are used. Do not assume the NVCF helper refreshes an
  arbitrary shared `ecr-pull-secret`.
- Inspect the actual configuration of an adopted cluster. Missing settings in
  a generated template alone do not prove that no external mechanism exists.

ECR authorization tokens are valid for 12 hours. Tokens already stored in a
Kubernetes Secret are not replaced when an operator refreshes AWS SSO. A new
static token or additional temporary Secret only moves the expiration problem.

## Preferred ECR path on raw EC2 nodes

Use an EC2 instance profile and the kubelet ECR credential-provider exec plugin
when supported by the selected distro. Do not assume EKS integrations exist
on raw EC2. Include every node that can run ECR-backed pods, including eligible
control-plane nodes, CPU/GPU workers, and future nodes.

Generate and validate these artifacts:

1. An instance role trusted by EC2, attached through the node provisioning
   configuration. Grant `ecr:GetAuthorizationToken` on `*`; scope
   `ecr:BatchGetImage`, `ecr:GetDownloadUrlForLayer`, and
   `ecr:BatchCheckLayerAvailability` to the required repository ARNs. Check
   repository policies separately for cross-account access. Do not grant push
   access merely to support pulls.
2. A compatible `ecr-credential-provider` binary on each eligible node. Pin its
   release and verify its checksum/provenance; do not download an unpinned
   executable or bake operator AWS credentials into the node image.
3. A kubelet credential-provider configuration matching the selected registry.
   The example below is a template: substitute the operator's registry host
   before use, and validate the API version against the selected kubelet/plugin.

   ```yaml
   apiVersion: kubelet.config.k8s.io/v1
   kind: CredentialProviderConfig
   providers:
     - name: ecr-credential-provider
       matchImages:
         - "<account-id>.dkr.ecr.<region>.amazonaws.com"
       defaultCacheDuration: "1h"
       apiVersion: credentialprovider.kubelet.k8s.io/v1
   ```

   This cache setting is a fallback; verify the plugin's returned cache duration
   and identity refresh behavior. It is not a scheduler for rotating Secrets.

4. Distro-specific activation in persistent bootstrap/join configuration. RKE2
   exposes `image-credential-provider-bin-dir` and
   `image-credential-provider-config`, with documented defaults under
   `/var/lib/rancher/credentialprovider/`. Put the binary/config at the selected
   paths and verify the effective kubelet settings. For existing nodes, plan any
   required agent/server restart one node at a time with capacity/readiness
   gates. Preserve unrelated RKE2 configuration. For other distros, use their
   supported kubelet or machine-configuration path.

The node role supplies renewable AWS credentials; the plugin obtains registry
credentials as kubelet needs them. This path does not renew Kubernetes Secrets
because it avoids relying on a static ECR token in those Secrets. Preserve
existing pull-secret paths until the provider has passed isolated pull tests.

## Managed Secret alternative

When node plugins are unavailable or the customer already uses a supported
controller, generate or verify a refresher with:

- A renewable node/workload/federated identity supported by this environment.
  Do not depend on a human SSO session or assume IRSA exists on generic
  Kubernetes. An external-secret controller needs a token generator or a
  rotating source; synchronizing the same expired token is not renewal.
- A refresh interval with retry headroom before ECR's 12-hour lifetime, for
  example hourly, and status/alerting for failed or overdue refreshes.
- Explicit coverage of every consuming namespace and the exact effective
  Secret names. Reconcile new namespaces as downstream components are added.
- RBAC restricted to the required Secret names/namespaces where possible.
  Bootstrap named Secrets separately if necessary to avoid broad create rights.
- In-place Secret updates. Do not delete/recreate a shared Secret, overwrite
  unrelated registry entries, or replace unrelated ServiceAccount references.
- A bootstrap path for the refresher's own image pull, so expiration cannot
  prevent the component responsible for renewal from starting.

A manual-only customer environment may be documented as such, but cannot pass
the durable authentication gate. Provide its refresh procedure and limitation
without presenting it as automatic renewal.

## Validation and handoff

1. Check configuration, identity permissions, refresh status, and effective
   node/namespace coverage. Record evidence without credential contents.
2. Use isolated disposable pods with `imagePullPolicy: Always` and the intended
   credential path only. A dedicated validation ServiceAccount must not inherit
   a temporary fallback pull Secret. For node providers, test without static
   pull Secrets; for refreshers, reference only the managed Secret and account
   for node/runtime credentials that could mask a failed Secret. If the path
   cannot be isolated safely, record that limitation instead of claiming the
   Secret was validated. Do not remove credentials from production workloads
   merely to perform the test.
3. Test representative CPU/GPU/other eligible node paths and namespace-scoped
   credentials. `Always` requires registry resolution even when layers are
   cached; use an uncached test image when layer-download permissions also
   need validation. Do not clear production node image caches.
4. Capture successful pulls and the provider/refresher evidence. Repeat after
   the original token's validity window, through the same intended path and
   without manually updating credentials. Keep `renewalValidation: pending`
   until that test is observed; do not wait 12 hours in the initial deployment
   or schedule a follow-up without an explicit scheduling request.
5. Report registry reachability, immediate pull success, automatic-auth
   configuration, and renewal validation separately. QA validates normal
   replacements after expiration; QA does not perform manual renewal as a
   prerequisite. Clean up only test-owned resources. Remove workaround
   references from workloads only after replacement authentication is verified.

Sources:
- [AWS ECR token lifetime](https://docs.aws.amazon.com/AmazonECR/latest/APIReference/API_AuthorizationData.html)
- [Kubelet credential providers](https://kubernetes.io/docs/tasks/administer-cluster/kubelet-credential-provider/)
- [RKE2 agent configuration](https://docs.rke2.io/reference/linux_agent_config)
- [EC2 instance-role credentials](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/instance-metadata-security-credentials.html)
