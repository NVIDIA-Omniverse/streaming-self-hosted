#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2023-2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT_FILE="$(mktemp)"
trap 'rm -f "${OUT_FILE}"' EXIT

cd "${ROOT_DIR}"

helm template nvcf-container-cache ./deploy > "${OUT_FILE}"

assert_has() {
  local needle="$1"
  if ! grep -F -q -- "${needle}" "${OUT_FILE}"; then
    echo "FAILED: expected pattern not found: ${needle}" >&2
    exit 1
  fi
  return 0
}

assert_not_has() {
  local needle="$1"
  if grep -F -q -- "${needle}" "${OUT_FILE}"; then
    echo "FAILED: unexpected pattern found: ${needle}" >&2
    exit 1
  fi
  return 0
}

assert_before() {
  local first="$1"
  local second="$2"
  local line_first line_second
  line_first=$(grep -n -F -- "${first}" "${OUT_FILE}" | head -1 | cut -d: -f1)
  line_second=$(grep -n -F -- "${second}" "${OUT_FILE}" | head -1 | cut -d: -f1)
  if [[ -z "${line_first}" || -z "${line_second}" ]]; then
    echo "FAILED: one or both patterns not found: '${first}' / '${second}'" >&2
    exit 1
  fi
  if [[ "${line_first}" -ge "${line_second}" ]]; then
    echo "FAILED: '${first}' (line ${line_first}) must appear before '${second}' (line ${line_second})" >&2
    exit 1
  fi
  return 0
}

echo "Checking path-style S3 server block is present..."
assert_has 'nvcf-proxy-cache-s3-path'
assert_has 'server_name ~^s3(\.(?<bucket_region>[^\.]+))?\.amazonaws\.com$'

echo "Checking path-style server block appears before virtual-hosted block..."
# nginx picks the first matching server_name; path-style must come first.
# Use the full quoted identifiers to avoid the path-style string matching the virtual-hosted check.
assert_before '"nvcf-proxy-cache-s3-path"' '"nvcf-proxy-cache-s3"'

echo 'Checking path-style cache key includes bucket extracted from URI path...'
assert_has 'proxy_cache_key $bucket_region|$s3_path_bucket|$request_method|$uri|'

echo 'Checking $s3_path_bucket extraction from URI...'
assert_has 'local bucket = string.match(uri, "^/([^/]+)")'

echo "Checking bypass_cache logic covers root, bucket-root, and bucket-level ops..."
# GET / and GET /?... bypass
assert_has 'if uri == "/" or string.find(uri, "^/%?") then'
# /bucket/ and /bucket/?... bypass (no object key)
assert_has 'if rest == "/" or string.find(rest, "^/%?") then'

echo "Checking SigV4 params are in the strip list for path-style filtered_args..."
assert_has 'X-Amz-Security-Token'
assert_has 'X-Amz-SignedHeaders'
assert_has 'X-Amz-Algorithm'
assert_has 'X-Amz-Credential'
assert_has 'X-Amz-Date'
assert_has 'X-Amz-Expires'
assert_has 'X-Amz-Signature'

echo "Checking allowlist-based bypass covers response-content-* params..."
assert_has 'response-content-type'
assert_has 'response-content-disposition'

echo "Checking proxy_no_cache is set in both path-style and virtual-hosted blocks..."
# proxy_no_cache ensures non-cacheable responses are not written to disk.
# Count occurrences: must appear in both server blocks.
count=$(grep -c 'proxy_no_cache \$disable_cache' "${OUT_FILE}" || true)
if [[ "${count}" -lt 2 ]]; then
  echo "FAILED: proxy_no_cache \$disable_cache expected in both server blocks, found ${count}" >&2
  exit 1
fi

echo "Checking virtual-hosted block still present and unmodified on key fields..."
assert_has 'nvcf-proxy-cache-s3'
assert_has 'server_name ~^(?<bucket_name>[^\.]+)(\.s3(\.(?<bucket_region>[^\.]+))?)?\.amazonaws\.com$'
assert_has 'proxy_cache_key $bucket_region|$bucket_name|$request_method|$uri|'

echo "S3 path-style cache render checks passed."
