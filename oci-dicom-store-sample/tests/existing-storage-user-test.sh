#!/usr/bin/env bash

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
identity_file="${project_dir}/terraform/identity.tf"
locals_file="${project_dir}/terraform/locals.tf"
variables_file="${project_dir}/terraform/variables.tf"
deploy_file="${project_dir}/scripts/deploy.sh"

if grep -Eq '^resource "oci_identity_user"' "${identity_file}"; then
  printf 'Storage identity must not create an OCI IAM user.\n' >&2
  exit 1
fi

grep -Fq 'data "oci_identity_users" "storage_user"' "${identity_file}"
grep -Fq 'user_id  = local.storage_user_id' "${identity_file}"
grep -Fq 'variable "storage_user_email"' "${variables_file}"
grep -Fq 'one(local.storage_user_matches).id' "${locals_file}"
grep -Fq 'type == "oci_identity_user"' "${deploy_file}"
grep -Fq 'wait-for-storage-credentials.sh' "${deploy_file}"
grep -Fq 'storage_customer_secret_key_capacity.value.existing' "${deploy_file}"
if grep -Fq 'key.display_name ==' "${identity_file}"; then
  printf 'An orphaned display name must not bypass Customer Secret Key capacity checks.\n' >&2
  exit 1
fi

printf 'Storage uses one existing OCI IAM user and guards against managed-user creation.\n'
