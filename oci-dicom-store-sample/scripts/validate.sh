#!/usr/bin/env bash

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
terraform_dir="${project_dir}/terraform"
test_timeout_seconds="${VALIDATION_TEST_TIMEOUT_SECONDS:-120}"

run_test() {
  local test_script="$1"
  local test_name
  test_name="$(basename "${test_script}")"
  printf 'Running %s...\n' "${test_name}"

  if command -v timeout >/dev/null 2>&1; then
    timeout --foreground "${test_timeout_seconds}" bash "${test_script}"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout --foreground "${test_timeout_seconds}" bash "${test_script}"
  else
    bash "${test_script}"
  fi
}

printf 'Validating Terraform formatting, provider lock file, and configuration...\n'
terraform -chdir="${terraform_dir}" fmt -check -recursive
terraform -chdir="${terraform_dir}" init -backend=false -lockfile=readonly
terraform -chdir="${terraform_dir}" validate

printf 'Checking shell and JSON syntax...\n'
for script_file in "${project_dir}"/scripts/*.sh; do
  bash -n "${script_file}"
done

for json_file in "${project_dir}"/tests/fixtures/*.json; do
  jq -e . "${json_file}" >/dev/null
done

for test_script in "${project_dir}"/tests/*-test.sh; do
  run_test "${test_script}"
done

if command -v ansible-playbook >/dev/null 2>&1; then
  printf 'Checking the Ansible playbook...\n'
  ANSIBLE_CONFIG="${project_dir}/ansible/ansible.cfg" \
    ansible-playbook \
      --syntax-check \
      -i "${project_dir}/ansible/inventory/validation.yml" \
      "${project_dir}/ansible/playbooks/bastion.yml"
else
  printf 'Warning: ansible-playbook is unavailable; skipped bastion syntax check.\n' >&2
fi

printf 'Static validation passed.\n'
