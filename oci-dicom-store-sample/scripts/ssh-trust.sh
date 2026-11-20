#!/usr/bin/env bash

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/


# Shared trust-on-first-use configuration for the stack bastion.  The host key
# is pinned to the instance OCID, rather than its reusable public IP address.
oci_dicom_prepare_ssh_trust() {
  local terraform_dir="$1"
  local bastion_id
  local trust_dir

  bastion_id="$(terraform -chdir="${terraform_dir}" output -json resource_ocids | jq -er '.bastion')"
  trust_dir="${OCI_DICOM_SSH_TRUST_DIR:-${HOME}/.ssh}"
  OCI_DICOM_KNOWN_HOSTS_FILE="${OCI_DICOM_KNOWN_HOSTS_FILE:-${trust_dir}/oci-dicom-known-hosts}"
  OCI_DICOM_SSH_HOST_ALIAS="oci-dicom-${bastion_id}"

  trust_dir="$(dirname "${OCI_DICOM_KNOWN_HOSTS_FILE}")"
  if [[ ! -d "${trust_dir}" ]]; then
    mkdir -p "${trust_dir}"
    chmod 700 "${trust_dir}"
  fi
  touch "${OCI_DICOM_KNOWN_HOSTS_FILE}"
  chmod 600 "${OCI_DICOM_KNOWN_HOSTS_FILE}"

  OCI_DICOM_SSH_TRUST_OPTIONS=(
    -o StrictHostKeyChecking=accept-new
    -o "UserKnownHostsFile=${OCI_DICOM_KNOWN_HOSTS_FILE}"
    -o "HostKeyAlias=${OCI_DICOM_SSH_HOST_ALIAS}"
  )
}
