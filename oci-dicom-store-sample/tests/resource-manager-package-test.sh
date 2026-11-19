#!/usr/bin/env bash

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/oci-dicom-rm-test.XXXXXX")"
trap 'rm -rf "${temporary_dir}"' EXIT

printf '%s\n' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE9jaURpY29tVGVzdFB1YmxpY0tleQ test' \
  >"${temporary_dir}/test.pub"
"${project_dir}/scripts/package-resource-manager.sh" \
  "${temporary_dir}/stack.zip" \
  "${temporary_dir}/test.pub" >/dev/null

unzip -q "${temporary_dir}/stack.zip" -d "${temporary_dir}/stack"
test -f "${temporary_dir}/stack/sso.tf"
test -x "${temporary_dir}/stack/scripts/manage-oci-custom-claim.sh"
test -f "${temporary_dir}/stack/templates/stack.yaml.tftpl"

# Reuse the already initialized provider cache so this archive validation is
# deterministic and does not access Terraform Registry.
ln -s "${project_dir}/terraform/.terraform" "${temporary_dir}/stack/.terraform"
terraform -chdir="${temporary_dir}/stack" validate >/dev/null

printf 'Resource Manager package contains and validates the complete Terraform module.\n'
