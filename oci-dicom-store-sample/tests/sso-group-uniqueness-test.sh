#!/usr/bin/env bash

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/oci-dicom-sso-groups-test.XXXXXX")"
trap 'rm -rf "${temporary_dir}"' EXIT
validation_public_key="${temporary_dir}/validation.pub"
printf '%s\n' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE9jaURpY29tVGVzdFB1YmxpY0tleQ test' \
  >"${validation_public_key}"

local_unique="$({
  terraform -chdir="${project_dir}/terraform" console \
    -no-color \
    -state="${temporary_dir}/terraform.tfstate" \
    -var-file=terraform.tfvars.example \
    -var="ssh_public_key_path=${validation_public_key}" \
    <<<'length(distinct([for group_name in ["Same", "Same", "Editors", "Administrators"] : lower(trimspace(group_name))])) == 4'
} | tr -d '\r' | tail -n 1)"
[[ "${local_unique}" == "false" ]] || {
  printf 'Expected local duplicate-name check to be false; got: %q\n' \
    "${local_unique}" >&2
  exit 1
}
grep -Fq 'unique, trimmed 3-160 character group names' \
  "${project_dir}/terraform/variables.tf"

global_unique="$({
  terraform -chdir="${project_dir}/terraform" console \
    -no-color \
    -state="${temporary_dir}/global.tfstate" \
    -var-file=terraform.tfvars.example \
    -var="ssh_public_key_path=${validation_public_key}" \
    -var='oci_identity_domain_sso={identity_domain_id="ocid1.domain.oc1..test",group_names={orthanc-viewer="Hospital A - Orthanc Viewers",orthanc-uploader="Uploaders",orthanc-editor="Editors",orthanc-admin="Administrators"}}' \
    <<<'length(distinct([for group_name in values(local.oci_sso_role_labels) : lower(trimspace(group_name))])) == length(local.oci_sso_role_labels)'
} | tr -d '\r' | tail -n 1)"
[[ "${global_unique}" == "false" ]] || {
  printf 'Expected platform/tenant collision check to be false; got: %q\n' \
    "${global_unique}" >&2
  exit 1
}

printf 'OCI SSO group names reject both local and platform/tenant collisions.\n'
