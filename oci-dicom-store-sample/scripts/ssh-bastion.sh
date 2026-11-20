#!/usr/bin/env bash

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
terraform_dir="${project_dir}/terraform"
source "${project_dir}/scripts/ssh-trust.sh"
private_key="${BASTION_SSH_PRIVATE_KEY_FILE:-}"

if [[ "${1:-}" == "--private-key" ]]; then
  [[ $# -ge 2 ]] || { printf '%s\n' '--private-key requires a path' >&2; exit 2; }
  private_key="$2"
  shift 2
fi

[[ -n "${private_key}" && -f "${private_key}" ]] || {
  printf 'Set BASTION_SSH_PRIVATE_KEY_FILE or pass --private-key PATH.\n' >&2
  exit 2
}

bastion_ip="$(terraform -chdir="${terraform_dir}" output -raw bastion_public_ip)"
oci_dicom_prepare_ssh_trust "${terraform_dir}"

ssh \
  -i "${private_key}" \
  "${OCI_DICOM_SSH_TRUST_OPTIONS[@]}" \
  opc@"${bastion_ip}" \
  "$@"
