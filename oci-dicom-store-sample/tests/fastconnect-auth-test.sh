#!/usr/bin/env bash

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/oci-dicom-fastconnect-auth-test.XXXXXX")"
trap 'rm -rf "${temporary_dir}"' EXIT
mkdir -p "${temporary_dir}/bin"

cat >"${temporary_dir}/bin/terraform" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"output -json fastconnect_status"*)
    printf '%s\n' '{"virtual_circuit_id":"ocid1.virtualcircuit.test"}' ;;
  *"output -json acceptance_context"*)
    printf '%s\n' '{"auth":"SecurityToken","profile":"TEST-PROFILE","region":"eu-frankfurt-1"}' ;;
  *) exit 1 ;;
esac
STUB
cat >"${temporary_dir}/bin/oci" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >"${FASTCONNECT_OCI_LOG}"
printf '%s\n' '{"data":{"id":"ocid1.virtualcircuit.test","lifecycle-state":"PROVISIONED","provider-state":"ACTIVE","bgp-session-state":"UP"}}'
STUB
chmod 700 "${temporary_dir}/bin/terraform" "${temporary_dir}/bin/oci"

PATH="${temporary_dir}/bin:${PATH}" \
FASTCONNECT_OCI_LOG="${temporary_dir}/oci.log" \
  "${project_dir}/scripts/verify-fastconnect.sh" --control-plane-only >/dev/null

grep -Fq -- '--region eu-frankfurt-1' "${temporary_dir}/oci.log"
grep -Fq -- '--profile TEST-PROFILE --auth security_token' "${temporary_dir}/oci.log"
grep -Fq -- 'network virtual-circuit get --virtual-circuit-id ocid1.virtualcircuit.test' \
  "${temporary_dir}/oci.log"

printf 'FastConnect verification propagates the Terraform OCI auth context.\n'
