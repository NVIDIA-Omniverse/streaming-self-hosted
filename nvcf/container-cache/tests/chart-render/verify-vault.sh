#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2023-2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Verify that vault.enabled fully gates the Vault integration, including:
#   - the projected serviceAccountToken volume,
#   - the volume mount on the nginx-proxy container,
#   - the StatefulSet pod-template Vault agent annotations,
#   - and that vault.vaultAddress is required only when vault.enabled=true.
#
# Run from anywhere: `bash tests/chart-render/verify-vault.sh`.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OFF_FILE="$(mktemp)"
ON_FILE="$(mktemp)"
ON_NO_ADDR_LOG="$(mktemp)"
trap 'rm -f "${OFF_FILE}" "${ON_FILE}" "${ON_NO_ADDR_LOG}"' EXIT

cd "${ROOT_DIR}"

# ----- Render fixtures -------------------------------------------------------

# vault.enabled=false with NO vaultAddress at all -- must succeed.
helm template c ./deploy \
  --set vault.enabled=false \
  --set vault.vaultAddress=null \
  > "${OFF_FILE}"

# vault.enabled=true with a real vaultAddress -- must succeed and emit volume.
helm template c ./deploy \
  --set vault.enabled=true \
  --set vault.vaultAddress=https://vault.example.com:443 \
  > "${ON_FILE}"

# vault.enabled=true with NO vaultAddress -- must FAIL with the required-msg.
if helm template c ./deploy \
     --set vault.enabled=true \
     --set vault.vaultAddress=null \
     > "${ON_NO_ADDR_LOG}" 2>&1
then
  echo "FAILED: vault.enabled=true without vaultAddress should fail render" >&2
  exit 1
fi
if ! grep -F -q -- 'vault.vaultAddress is required when vault.enabled=true' "${ON_NO_ADDR_LOG}"; then
  echo "FAILED: missing required-message on vault.enabled=true without vaultAddress" >&2
  cat "${ON_NO_ADDR_LOG}" >&2
  exit 1
fi

# ----- Helpers ---------------------------------------------------------------

assert_has() {
  local file="$1" needle="$2"
  if ! grep -F -q -- "${needle}" "${file}"; then
    echo "FAILED: expected pattern not found in $(basename "${file}"): ${needle}" >&2
    exit 1
  fi
}

assert_not_has() {
  local file="$1" needle="$2"
  if grep -F -q -- "${needle}" "${file}"; then
    echo "FAILED: unexpected pattern found in $(basename "${file}"): ${needle}" >&2
    exit 1
  fi
}

# ----- Assertions: vault disabled --------------------------------------------

echo "Checking vault.enabled=false render..."
# No projected SA token volume.
assert_not_has "${OFF_FILE}" 'serviceAccountToken:'
# No vault audience leaks (the values.yaml default is https://vault.example.com,
# so absence of any vault.example.com proves the audience field isn't emitted).
assert_not_has "${OFF_FILE}" 'audience: '
# No /var/run/secrets/.../serviceaccount-vault mount.
assert_not_has "${OFF_FILE}" 'mountPath: /var/run/secrets/kubernetes.io/serviceaccount-vault'
# No Vault agent annotations on the pod template.
assert_not_has "${OFF_FILE}" 'vault.hashicorp.com/agent-inject'

# ----- Assertions: vault enabled ---------------------------------------------

echo "Checking vault.enabled=true render..."
assert_has "${ON_FILE}" 'serviceAccountToken:'
assert_has "${ON_FILE}" 'audience: https://vault.example.com:443'
assert_has "${ON_FILE}" 'mountPath: /var/run/secrets/kubernetes.io/serviceaccount-vault'
assert_has "${ON_FILE}" 'vault.hashicorp.com/agent-inject'

echo "Vault gating checks passed."
