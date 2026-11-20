#!/usr/bin/env bash

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
terraform_dir="${project_dir}/terraform"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/oci-dicom-ha-test.XXXXXX")"
trap 'rm -rf "${temporary_dir}"' EXIT

validation_public_key="${temporary_dir}/validation.pub"
printf '%s\n' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE9jaURpY29tVGVzdFB1YmxpY0tleQ test' \
  >"${validation_public_key}"

assert_rejected() {
  local override="$1"
  local expected_message="$2"
  local log_file="${temporary_dir}/$(tr '=.' '__' <<<"${override}").log"

  terraform -chdir="${terraform_dir}" console \
    -no-color \
    -state="${temporary_dir}/terraform.tfstate" \
    -var-file=terraform.tfvars.example \
    -var="ssh_public_key_path=${validation_public_key}" \
    -var="${override}" <<<'true' >"${log_file}" 2>&1 || true
  grep -Fq 'Error: Invalid value for variable' "${log_file}" || {
    printf 'Terraform unexpectedly accepted %s.\n' "${override}" >&2
    exit 1
  }
  grep -Fq "${expected_message}" "${log_file}" || {
    printf 'Terraform rejected %s for an unexpected reason:\n' "${override}" >&2
    sed -n '1,30p' "${log_file}" >&2
    exit 1
  }
}

assert_rejected \
  'orthanc_replicas=1' \
  'orthanc_replicas must be between 2 and 6'
assert_rejected \
  'postgres_instances=1' \
  'postgres_instances must be between 2 and 8'

grep -Fq 'instance_count              = var.postgres_instances' \
  "${terraform_dir}/database.tf"
grep -Fq 'provisioned = length(oci_psql_db_system.orthanc.instances)' \
  "${terraform_dir}/outputs.tf"

printf 'HA topology requires at least two Orthanc pods and two OCI PostgreSQL nodes.\n'
