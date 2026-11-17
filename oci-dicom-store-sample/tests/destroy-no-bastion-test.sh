#!/usr/bin/env bash

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/oci-dicom-destroy-test.XXXXXX")"
trap 'rm -rf "${temporary_dir}"' EXIT

command_log="${temporary_dir}/commands.log"
export DESTROY_TEST_COMMAND_LOG="${command_log}"

mkdir -p "${temporary_dir}/bin"

cat >"${temporary_dir}/bin/terraform" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'terraform' >>"${DESTROY_TEST_COMMAND_LOG}"
printf ' %q' "$@" >>"${DESTROY_TEST_COMMAND_LOG}"
printf '\n' >>"${DESTROY_TEST_COMMAND_LOG}"
if [[ "$1" == "show" ]]; then
  cat <<'JSON'
{"variables":{"oci_auth":{"value":"APIKey"},"oci_profile":{"value":"DEFAULT"},"region":{"value":"eu-frankfurt-1"}},"resource_changes":[]}
JSON
fi
STUB

cat >"${temporary_dir}/bin/ssh" <<'STUB'
#!/usr/bin/env bash
printf 'ssh must not be called during destroy\n' >&2
exit 99
STUB

cat >"${temporary_dir}/bin/oci" <<'STUB'
#!/usr/bin/env bash
printf 'OCI CLI must not be called when no OCI pre-cleanup resource exists\n' >&2
exit 98
STUB

chmod 0700 "${temporary_dir}/bin/terraform" \
  "${temporary_dir}/bin/ssh" \
  "${temporary_dir}/bin/oci"

PATH="${temporary_dir}/bin:${PATH}" \
  BASTION_SSH_PRIVATE_KEY_FILE=/does/not/exist \
  "${project_dir}/scripts/destroy.sh" --auto-approve

expected_commands_pattern=$'terraform init\nterraform plan -destroy -out=*\nterraform show -json *\nterraform destroy -auto-approve'
actual_commands="$(<"${command_log}")"

[[ "${actual_commands}" == ${expected_commands_pattern} ]] || {
  printf 'Unexpected destroy command sequence:\n%s\n' "${actual_commands}" >&2
  exit 1
}

printf 'Destroy path is independent of bastion SSH and skips OCI cleanup when unnecessary.\n'
