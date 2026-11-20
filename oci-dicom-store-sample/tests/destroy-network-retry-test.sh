#!/usr/bin/env bash

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/oci-dicom-destroy-retry-test.XXXXXX")"
trap 'rm -rf "${temporary_dir}"' EXIT

command_log="${temporary_dir}/commands.log"
attempt_file="${temporary_dir}/plan-attempts"
export DESTROY_TEST_COMMAND_LOG="${command_log}"
export DESTROY_TEST_ATTEMPT_FILE="${attempt_file}"
export DESTROY_TEST_MODE="transient"
printf '0\n' >"${attempt_file}"
mkdir -p "${temporary_dir}/bin"

cat >"${temporary_dir}/bin/terraform" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'terraform' >>"${DESTROY_TEST_COMMAND_LOG}"
printf ' %q' "$@" >>"${DESTROY_TEST_COMMAND_LOG}"
printf '\n' >>"${DESTROY_TEST_COMMAND_LOG}"

if [[ "$1" == "plan" ]]; then
  attempt="$(( $(<"${DESTROY_TEST_ATTEMPT_FILE}") + 1 ))"
  printf '%s\n' "${attempt}" >"${DESTROY_TEST_ATTEMPT_FILE}"
  if [[ "${DESTROY_TEST_MODE}" == "transient" && "${attempt}" -lt 3 ]]; then
    printf '%s\n' 'Error: Get "https://logging.eu-frankfurt-1.oci.oraclecloud.com": dial tcp: lookup logging.eu-frankfurt-1.oci.oraclecloud.com: no such host' >&2
    exit 1
  elif [[ "${DESTROY_TEST_MODE}" == "hard" ]]; then
    printf '%s\n' 'Error: invalid Terraform configuration' >&2
    exit 1
  fi
elif [[ "$1" == "show" ]]; then
  cat <<'JSON'
{"variables":{"oci_auth":{"value":"APIKey"},"oci_profile":{"value":"DEFAULT"},"region":{"value":"eu-frankfurt-1"}},"resource_changes":[]}
JSON
fi
STUB

cat >"${temporary_dir}/bin/sleep" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'sleep %s\n' "$1" >>"${DESTROY_TEST_COMMAND_LOG}"
STUB

chmod 0700 "${temporary_dir}/bin/terraform" "${temporary_dir}/bin/sleep"

PATH="${temporary_dir}/bin:${PATH}" \
  TERRAFORM_NETWORK_RETRY_ATTEMPTS=4 \
  TERRAFORM_NETWORK_RETRY_DELAY_SECONDS=1 \
  "${project_dir}/scripts/destroy.sh" --auto-approve

[[ "$(grep -Fc 'terraform plan -destroy' "${command_log}")" == "3" ]]
[[ "$(grep -Ec '^sleep ' "${command_log}")" == "2" ]]
[[ "$(grep -Fc 'terraform destroy -auto-approve' "${command_log}")" == "1" ]]

: >"${command_log}"
printf '0\n' >"${attempt_file}"
export DESTROY_TEST_MODE="hard"

if PATH="${temporary_dir}/bin:${PATH}" \
  TERRAFORM_NETWORK_RETRY_ATTEMPTS=4 \
  TERRAFORM_NETWORK_RETRY_DELAY_SECONDS=1 \
  "${project_dir}/scripts/destroy.sh" --auto-approve >/dev/null 2>&1; then
  printf 'A non-network Terraform error was unexpectedly retried or ignored.\n' >&2
  exit 1
fi

[[ "$(grep -Fc 'terraform plan -destroy' "${command_log}")" == "1" ]]
[[ "$(grep -Ec '^sleep ' "${command_log}" || true)" == "0" ]]

printf 'Destroy retries transient OCI DNS failures and fails fast for Terraform configuration errors.\n'
