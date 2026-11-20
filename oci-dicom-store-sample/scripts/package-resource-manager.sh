#!/usr/bin/env bash

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
terraform_dir="${project_dir}/terraform"
invocation_dir="$(pwd)"
output_file="${1:-${project_dir}/oci-dicom-resource-manager.zip}"
public_key_file="${2:-${SSH_PUBLIC_KEY_PATH:-${HOME}/.ssh/id_rsa.pub}}"

command -v zip >/dev/null 2>&1 || { printf 'zip is required\n' >&2; exit 1; }

if [[ "${output_file}" != /* ]]; then
  output_file="${invocation_dir}/${output_file}"
fi
if [[ "${public_key_file}" == "~/"* ]]; then
  public_key_file="${HOME}/${public_key_file#\~/}"
elif [[ "${public_key_file}" != /* ]]; then
  public_key_file="${invocation_dir}/${public_key_file}"
fi

if [[ -e "${output_file}" ]]; then
  printf 'Refusing to overwrite existing archive: %s\n' "${output_file}" >&2
  exit 1
fi
if [[ ! -f "${public_key_file}" ]]; then
  printf 'SSH public key does not exist: %s\n' "${public_key_file}" >&2
  exit 1
fi
if ! awk '
  NR == 1 && $1 ~ /^(ssh-(rsa|ed25519)|ecdsa-sha2-nistp(256|384|521))$/ {
    valid = 1
  }
  END { exit(valid ? 0 : 1) }
' "${public_key_file}"; then
  printf 'SSH public key is not valid OpenSSH public-key data: %s\n' "${public_key_file}" >&2
  exit 1
fi

staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/oci-dicom-resource-manager.XXXXXX")"
trap 'rm -rf "${staging_dir}"' EXIT
mkdir -p "${staging_dir}/bastion" "${staging_dir}/scripts" "${staging_dir}/templates"

terraform_files=(
  .terraform.lock.hcl
  versions.tf
  variables.tf
  data.tf
  locals.tf
  networking.tf
  identity.tf
  sso.tf
  storage.tf
  database.tf
  oke.tf
  api_gateway.tf
  observability.tf
  bastion.tf
  fastconnect.tf
  large_upload.tf
  outputs.tf
)
for terraform_file in "${terraform_files[@]}"; do
  cp "${terraform_dir}/${terraform_file}" "${staging_dir}/${terraform_file}"
done
cp \
  "${terraform_dir}/bastion/cloud-init.yaml.tftpl" \
  "${staging_dir}/bastion/cloud-init.yaml.tftpl"
cp \
  "${terraform_dir}/templates/stack.yaml.tftpl" \
  "${staging_dir}/templates/stack.yaml.tftpl"
cp \
  "${project_dir}/scripts/manage-oci-custom-claim.sh" \
  "${staging_dir}/scripts/manage-oci-custom-claim.sh"
chmod 700 "${staging_dir}/scripts/manage-oci-custom-claim.sh"
cp "${public_key_file}" "${staging_dir}/bastion.pub"
printf 'ssh_public_key_path = "bastion.pub"\n' \
  >"${staging_dir}/ssh-public-key.auto.tfvars"

cd "${staging_dir}"
zip -q -r "${output_file}" .

printf 'OCI Resource Manager stack archive: %s\n' "${output_file}"
printf 'Embedded SSH public key: %s (private key not included)\n' "${public_key_file}"
