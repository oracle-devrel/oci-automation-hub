#!/usr/bin/env bash

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/configure-bastion.sh [--private-key PATH] [--user USER]

Configures the deployed bastion with Ansible. The private key must match
the public key at ssh_public_key_path. It can also be supplied with
BASTION_SSH_PRIVATE_KEY_FILE. The default SSH user is opc.
USAGE
}

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
terraform_dir="${project_dir}/terraform"
source "${project_dir}/scripts/ssh-trust.sh"
private_key="${BASTION_SSH_PRIVATE_KEY_FILE:-}"
ssh_user="opc"
umask 077

while (($#)); do
  case "$1" in
    --private-key)
      [[ $# -ge 2 ]] || { printf '%s\n' '--private-key requires a path' >&2; exit 2; }
      private_key="$2"
      shift
      ;;
    --user)
      [[ $# -ge 2 ]] || { printf '%s\n' '--user requires a value' >&2; exit 2; }
      ssh_user="$2"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

for command_name in terraform jq ansible-playbook ssh; do
  command -v "${command_name}" >/dev/null 2>&1 || {
    printf 'Required command is missing: %s\n' "${command_name}" >&2
    exit 1
  }
done

[[ -n "${private_key}" ]] || {
  printf 'Set BASTION_SSH_PRIVATE_KEY_FILE or pass --private-key.\n' >&2
  exit 2
}
[[ -f "${private_key}" ]] || {
  printf 'SSH private key does not exist: %s\n' "${private_key}" >&2
  exit 2
}

private_key="$(cd "$(dirname "${private_key}")" && pwd)/$(basename "${private_key}")"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/oci-dicom-ansible.XXXXXX")"
trap 'rm -rf "${temporary_dir}"' EXIT
chmod 700 "${temporary_dir}"

bastion_ip="$(terraform -chdir="${terraform_dir}" output -raw bastion_public_ip)"
oci_dicom_prepare_ssh_trust "${terraform_dir}"
printf -v ssh_common_args '%q ' "${OCI_DICOM_SSH_TRUST_OPTIONS[@]}"
inventory_file="${temporary_dir}/inventory.json"
variables_file="${temporary_dir}/variables.json"
outputs_file="${temporary_dir}/terraform-outputs.json"

jq -n \
  --arg host "${bastion_ip}" \
  --arg user "${ssh_user}" \
  --arg key "${private_key}" \
  --arg ssh_common_args "${ssh_common_args% }" \
  '{
    all: {
      children: {
        bastion: {
          hosts: {
            "dicom-bastion": {
              ansible_host: $host,
              ansible_user: $user,
              ansible_ssh_private_key_file: $key,
              ansible_ssh_common_args: $ssh_common_args
            }
          }
        }
      }
    }
  }' >"${inventory_file}"

terraform -chdir="${terraform_dir}" output -json >"${outputs_file}"
jq \
  '{
    deployment_name: .deployment_summary.value.name,
    region: .deployment_summary.value.region,
    api_endpoint: .api_endpoint.value,
    dicomweb_endpoint: .dicomweb_endpoint.value,
    private_orthanc_endpoint: .private_orthanc_endpoint.value,
    private_ingest_endpoint: (.fastconnect_private_ingest_endpoint.value // ""),
    private_ingest_certificate: (.fastconnect_private_ingest_certificate.value // ""),
    oke_cluster_id: .oke_cluster_id.value,
    oke_kubernetes_version: .deployment_summary.value.oke_kubernetes_version,
    bastion_kubectl_arch: .deployment_summary.value.bastion_kubectl_arch,
    orthanc_username: .orthanc_username.value,
    orthanc_password: .orthanc_password.value,
    postgres_host: .deployment_summary.value.postgres_private_ip,
    postgres_username: .postgres_username.value,
    postgres_password: .postgres_password.value,
    object_storage_namespace: .deployment_summary.value.namespace,
    object_storage_bucket: .deployment_summary.value.bucket_name
  }' "${outputs_file}" >"${variables_file}"

ANSIBLE_CONFIG="${project_dir}/ansible/ansible.cfg" \
  ansible-playbook \
    -i "${inventory_file}" \
    "${project_dir}/ansible/playbooks/bastion.yml" \
    --extra-vars "@${variables_file}"

printf '\nBastion configured. Connect with:\n'
printf 'ssh -i %q %q@%q\n' "${private_key}" "${ssh_user}" "${bastion_ip}"
printf 'Then run: sudo /usr/local/sbin/dicom-status\n'
