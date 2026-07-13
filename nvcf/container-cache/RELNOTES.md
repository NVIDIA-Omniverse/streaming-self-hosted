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
# NVCF Proxy Cache Release Notes

#version 0.25.20
Allow TLS 1.2 on the upstream connection for the HuggingFace Xet CAS host (cas-server.xethub.hf.co), which only negotiates TLS 1.2 and was returning 502 under the TLS 1.3-only upstream policy.

#version 0.25.19
Route the HuggingFace Xet CAS host (cas-server.xethub.hf.co) through a cache-bypass server block and stop the log_by_lua arithmetic error on retried upstreams.

#version 0.25.17
OV sbom work

#version 0.25.16
https://jirasw.nvidia.com/browse/NVCF-9561

#version 0.25.15
Fix lua errors in container-cache logs

#version 0.25.14
https://nvbugspro.nvidia.com/bug/5979011

#version 0.25.13
https://jirasw.nvidia.com/browse/NVCF-9180

#version 0.25.12
https://jirasw.nvidia.com/browse/NVCF-9019

#version 0.25.11
https://jirasw.nvidia.com/browse/NVCF-2386

#version 0.25.10
https://jirasw.nvidia.com/browse/NVCF-8807

#version 0.25.7-0.25.9
https://nvbugspro.nvidia.com/bug/5693476

#version 0.25.6
https://jirasw.nvidia.com/browse/NVCF-7821

#version 0.25.4
https://jirasw.nvidia.com/browse/NVCF-7989

#version 0.25.3
https://nvbugspro.nvidia.com/bug/5661378

#version 0.25.2
https://nvbugspro.nvidia.com/bug/5661378

#version 0.25.1
https://nvbugspro.nvidia.com/bug/5661378

#version 0.25.0
https://jirasw.nvidia.com/browse/NVCF-7704

# version 0.24.0
https://jirasw.nvidia.com/browse/NVCF-7544

# version 0.23.0
https://jirasw.nvidia.com/browse/NVCF-7473

# version 0.22.0
https://jirasw.nvidia.com/browse/NVCF-6956

# version 0.21.0
1. Remove unbound dependency
## Upgrade Instructions
None

# version 0.20.0
1. BYOC-SIM packaging
## Upgrade Instructions

None
# version 0.19.0
1. https://jirasw.nvidia.com/browse/NVCF-5670
## Upgrade Instructions
None

# version 0.18.0
1. https://jirasw.nvidia.com/browse/NVCF-4700
2. https://jirasw.nvidia.com/browse/NVCF-4632
3. https://jirasw.nvidia.com/browse/NVCF-5560 - Automatically configure containerd config.toml for container-cache
## Upgrade Instructions
The following configuration needs to be added to all Forge (AZ*) deployments

nucleus:
  enabled: true

# version 0.17.0
1. https://jirasw.nvidia.com/browse/NVCF-4025

## Upgrade Instructions
None

# version 0.16.0
1. https://nvbugspro.nvidia.com/bug/5190231
2. https://nvbugspro.nvidia.com/bug/5154038
3. https://jirasw.nvidia.com/browse/NVCF-2182

## Upgrade Instructions
None

# version 0.15.0
1. [OMPE-36465](https://jirasw.nvidia.com/browse/OMPE-36465) - Log the `ETag` of the object and whether the HTTP `Authorization` header was specified. Fix JSON syntax.
2. https://jirasw.nvidia.com/browse/NVCF-2604 - OTEL integration
3. https://nvbugspro.nvidia.com/bug/5108024 - [NVCF][Cluster Validation][az28] Cosmos Video Curator test pipeline failed due to fail to write data to s3
4. [OMPE-37543](https://jirasw.nvidia.com/browse/OMPE-37543) - No Access Checks when `Cache-Control: no-cache` is present.
5. [OMPE-28867]/[NVCF-2182] Adding Nucleus specific LFT proxy cache and service
6. [OMPE-36697] Adding logging to proxy-cache on the Omniverse side

## Upgrade Instructions:
```
Configuration Changes:
1. Add the following to values-*.yaml under images:
   collector: nvcr.io/nv-ngc-devops/opentelemetry-collector-contrib:0.112.0
   2. Add the following section to vaules-*.yaml
      traces:
       # Enable tracing
       enabled: false
        # OpenTelemetry-Collector configuration.
       collector:
        # OpenTelemetry endpoint to send traces to.
            endpoint: "prod.otel.nvidia.com:8282"
    
```

# Version 0.14.0
1. https://nvbugspro.nvidia.com/bug/5062467 - Retry all errors atleast once.

## Upgrade Instructions:
None

# Version 0.13.0
1. https://nvbugspro.nvidia.com/bug/5062467 - Storage failures due to proxy cache causes function errors

## Upgrade Instructions:
None

# Version 0.12.0
1. https://jirasw.nvidia.com/browse/NVCFSRE-3029 - Publish a `proxy_cache_instance_info` gauge metric to expose chart version for dashboarding

## Upgrade Instructions:
None

# Version 0.11.0
1. https://nvbugspro.nvidia.com/bug/5054765 - Set client_max_body_size to 0. Set proxy_request_buffering off.

# Upgrade Instructions:
None

# Version 0.10.0
1. Use `min_free` instead of `max_size` in nginx.conf's `proxy_cache` directive to ensure safe utilization of available disk space
and adjust value files accordingly for all clusters. This is part of alert review, https://jirasw.nvidia.com/browse/NVCFSRE-1928.

# Upgrade Instructions:
None

# Version 0.9.0
1. https://nvbugspro.nvidia.com/bug/5025641 - nvcf-container-cache container update to v1.1.23. 
Adjusted slice_range and http_range processing.

# Upgrade Instructions:
None

# Version 0.8.0
1. https://jirasw.nvidia.com/browse/OMPE-31483 - nvcf-container-cache container update to v1.1.22
2. https://nvbugspro.nvidia.com/bug/5023141 - cache refresh when data in S3 is different from data in cache.

# Upgrade Instructions:
None

# Version 0.7.0
1. https://nvbugspro.nvidia.com/bug/5008002 - Adjust certificate validity time to account for clock skew between pods. 

# Upgrade Instructions:
None
