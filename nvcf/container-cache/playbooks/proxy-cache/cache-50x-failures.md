<!--
SPDX-FileCopyrightText: Copyright (c) 2023-2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
SPDX-License-Identifier: Apache-2.0

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
-->
# 50x cache failures

Follow this runbook to remediate and investigate issues leading to cache failures with HTTP 50x error codes.

## Disable the cache on the cluster

The best way to disable the cache right now is to change on the fly the unbound configuration and prevent further redirects to the cache.

This **does not work** in `az27` due to the enforcement of argocd sync, so if we need to change something there, escalate to DGXC so they can disable it.

The change can be done quickly by running:

```
kubectl get cm -n dns-proxy nvcf-unbound-config \
  | sed -r '/.*local-(zone|data):.*s3.*/d' \
  | kubectl apply -f -
```

This will disable the configuration for all `s3` buckets using the cache, without requiring functions are restarted. 
After you're sure the configmap looks ok, you can run:

```
kubectl rollout restart statefulset -n dns-proxy nvcf-unbound
```

Which will restart the UnboundDNS pods. The cache should now be disabled and you will get time for further debugging of 
the issue. Do note some function may have unacceptable performance with the cache disabled (due to slow loading of assets 
on repeated loads) so this is *not* a panacea.

If you can use logs to determine quickly the requests impacted relate only to a single zone (ex: for a specific S3 bucket)
 is impacted, you may as well just remove the `local-zone` and `local-data` lines for that zone from the server configmap 
 (`dns-proxy`/`nvcf-unbound-config`) and execute a `rollout restart` of the unbound statefulset as above instead of 
 deleting them all.

# OVC2 Forward Proxy failures

```https://lft-nvcf-proxy-cache.container-caching.svc.cluster.local:443 not found```
The above error might indicate that your cluster doesn't have the latest proxy-cache version install, where this endpoint exists.
Verify that the version is 0.15.0 or more here https://nvcf-grafana.thanos.nvidiangn.net/d/fec8riwppfgu8f/proxy-cache-version-tracking?orgId=1

```upstream SSL certificate verify error: (20:unable to get local issuer certificate) while SSL handshaking to upstream```
If the above happens, verify that the Nucleus Connection (AKA Bridge) has been setup using the Root CA used by NVCF.
For example see https://jirasw.nvidia.com/browse/KAZD-8103

```upstream SSL certificate does not match "bridge.bridge-az24-dev1.bridge.az.cloud.omniverse.nvidia.com" while SSL handshaking to upstream```
The above error means that you are going to the Nucleus-Connection directly and not to the Nucleus Server with a Nucleus Connection redirect.
