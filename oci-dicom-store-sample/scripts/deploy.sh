#!/usr/bin/env bash

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/deploy.sh [--auto-approve | --plan-only] [terraform arguments...]

Creates a reviewed Terraform plan and, unless --plan-only is used, applies it.
Pass --auto-approve for non-interactive automation.
USAGE
}

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
terraform_dir="${project_dir}/terraform"
plan_file="${terraform_dir}/dicom.tfplan"
mode="interactive"
terraform_args=()

while (($#)); do
  case "$1" in
    --auto-approve)
      mode="auto"
      ;;
    --plan-only)
      mode="plan"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      terraform_args+=("$1")
      ;;
  esac
  shift
done

for command_name in terraform jq curl; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    printf 'Required command is missing: %s\n' "${command_name}" >&2
    exit 1
  fi
done

if [[ ! -f "${terraform_dir}/terraform.tfvars" ]] &&
   [[ -z "${TF_VAR_tenancy_id:-}" || -z "${TF_VAR_compartment_id:-}" ]]; then
  printf 'Create terraform/terraform.tfvars from terraform/terraform.tfvars.example or export required TF_VAR_* values.\n' >&2
  exit 1
fi

cd "${terraform_dir}"
terraform fmt -check -recursive
terraform init
terraform validate
if ((${#terraform_args[@]})); then
  terraform plan -out="${plan_file}" "${terraform_args[@]}"
else
  terraform plan -out="${plan_file}"
fi

plan_json="$(terraform show -json "${plan_file}")"
managed_user_creates="$(
  jq '[
    .resource_changes[]?
    | select(.type == "oci_identity_user")
    | select(.change.actions | index("create"))
  ] | length' <<<"${plan_json}"
)"

customer_secret_key_creates="$({
  jq '[
    .resource_changes[]?
    | select(.type == "oci_identity_customer_secret_key")
    | select(.change.actions == ["create"])
  ] | length' <<<"${plan_json}"
})"

if [[ "${managed_user_creates}" != "0" ]]; then
  printf '%s\n' \
    'The Terraform plan unexpectedly creates an OCI IAM user.' \
    'Storage must use the existing user selected by storage_user_email.' >&2
  exit 1
fi

if [[ "${customer_secret_key_creates}" != "0" ]]; then
  existing_customer_secret_keys="$(jq -er \
    '.planned_values.outputs.storage_customer_secret_key_capacity.value.existing' \
    <<<"${plan_json}")"
  if ((existing_customer_secret_keys >= 2)); then
    printf '%s\n' \
      'The selected existing OCI user already has the maximum two Customer Secret Keys.' \
      'Delete an unused key or set create_storage_customer_secret_key=false and supply an existing key.' >&2
    exit 1
  fi
fi

if [[ "${mode}" == "plan" ]]; then
  printf 'Plan saved to %s\n' "${plan_file}"
  exit 0
fi

if [[ "${mode}" == "auto" ]]; then
  terraform apply -auto-approve "${plan_file}"
else
  terraform apply "${plan_file}"
fi

deployment_summary="$(terraform output -json deployment_summary)"
postgres_nodes="$(jq -er '.postgres_nodes' <<<"${deployment_summary}")"
postgres_configured="$(jq -er '.configured' <<<"${postgres_nodes}")"
postgres_provisioned="$(jq -er '.provisioned' <<<"${postgres_nodes}")"
postgres_active="$(jq -er '.active' <<<"${postgres_nodes}")"
if ((postgres_configured < 2 || postgres_provisioned < 2 || postgres_active < 2)); then
  printf 'PostgreSQL HA validation failed: configured=%s, provisioned=%s, active=%s.\n' \
    "${postgres_configured}" "${postgres_provisioned}" "${postgres_active}" >&2
  exit 1
fi
printf 'PostgreSQL HA ready: %s active nodes across %s availability domain(s).\n' \
  "${postgres_active}" \
  "$(jq -r '.availability_domains | length' <<<"${postgres_nodes}")"

"${project_dir}/scripts/wait-for-storage-credentials.sh"

jq . <<<"${deployment_summary}"

if [[ -n "${BASTION_SSH_PRIVATE_KEY_FILE:-}" ]]; then
  printf '\nConfiguring the operator bastion with Ansible...\n'
  "${project_dir}/scripts/configure-bastion.sh" \
    --private-key "${BASTION_SSH_PRIVATE_KEY_FILE}"
  printf '\nDeploying Orthanc and Keycloak to private OKE...\n'
  "${project_dir}/scripts/deploy-oke.sh" \
    --private-key "${BASTION_SSH_PRIVATE_KEY_FILE}"
else
  printf '\nInfrastructure created. Configure the bastion and deploy OKE with:\n'
  printf 'scripts/configure-bastion.sh --private-key /path/to/private/key\n'
  printf 'scripts/deploy-oke.sh --private-key /path/to/private/key\n'
fi

printf '\nRun scripts/verify.sh to check the deployed control plane and DICOM APIs.\n'
