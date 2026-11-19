#!/usr/bin/env bash

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/oci-dicom-tenant-config-test.XXXXXX")"
trap 'rm -rf "${temporary_dir}"' EXIT
validation_public_key="${temporary_dir}/validation.pub"
printf '%s\n' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE9jaURpY29tVGVzdFB1YmxpY0tleQ test' \
  >"${validation_public_key}"
permissions="$({
  terraform -chdir="${project_dir}/terraform" console \
    -state="${temporary_dir}/terraform.tfstate" \
    -var-file=terraform.tfvars.example \
    -var="ssh_public_key_path=${validation_public_key}" \
    <<<'jsonencode(local.orthanc_role_permissions)'
} | jq -r)"

jq -e '
  ."available-labels" == ["tenant-hospital-a", "tenant-hospital-b"] and
  .roles."tenant-hospital-a-viewer"."authorized-labels" == ["tenant-hospital-a"] and
  .roles."tenant-hospital-b-viewer"."authorized-labels" == ["tenant-hospital-b"] and
  .roles."tenant-hospital-a-editor"."authorized-labels" == ["tenant-hospital-a"] and
  (.roles."tenant-hospital-a-editor".permissions | index("edit-labels") | not) and
  .roles."orthanc-admin"."authorized-labels" == ["*"]
' <<<"${permissions}" >/dev/null

printf 'Tenant roles are label-scoped and only the platform administrator is global.\n'
