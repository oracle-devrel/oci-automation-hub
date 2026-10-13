#!/usr/bin/env bash

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

set -euo pipefail

PACKER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_DIR="$(cd "${PACKER_DIR}/.." && pwd)"

usage() {
  cat <<'USAGE'
Usage:
  build-from-image-ocid.sh <base-image-ocid> [image-name]

Environment overrides:
  OCI_PROFILE                  OCI CLI/Packer profile. Default: DEFAULT
  OCI_REGION                   OCI region. Default: us-ashburn-1
  PACKER_TENANCY_OCID          Optional tenancy OCID used to discover availability domains.
  PACKER_COMPARTMENT_OCID      Builder/image compartment. Defaults to terraform output project_compartment_id.
  PACKER_IMAGE_COMPARTMENT_OCID Image target compartment. Defaults to PACKER_COMPARTMENT_OCID.
  PACKER_SUBNET_OCID           Builder subnet. Defaults to subnet named oke-optimization-image-builder.
  PACKER_AVAILABILITY_DOMAIN   Builder AD. Defaults to the first AD returned by OCI.
  PACKER_SSH_PUBLIC_KEY_PATH   SSH public key path. Default: $HOME/.ssh/id_rsa.pub
  PACKER_SSH_PRIVATE_KEY_PATH  SSH private key path. Default: $HOME/.ssh/id_rsa
  KUBERNETES_VERSION           Tag value. Default: v1.35.2
  PACKER_VALIDATE_ONLY         Set to true to validate instead of build.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

BASE_IMAGE_OCID="${1:-}"
if [[ -z "${BASE_IMAGE_OCID}" ]]; then
  usage
  exit 1
fi

PROFILE="${OCI_PROFILE:-DEFAULT}"
REGION="${OCI_REGION:-us-ashburn-1}"
TENANCY_OCID="${PACKER_TENANCY_OCID:-}"
K8S_VERSION="${KUBERNETES_VERSION:-v1.35.2}"
K8S_VERSION_SLUG="${K8S_VERSION#v}"
K8S_VERSION_SLUG="${K8S_VERSION_SLUG//./-}"
SSH_PUBLIC_KEY_PATH="${PACKER_SSH_PUBLIC_KEY_PATH:-${HOME}/.ssh/id_rsa.pub}"
SSH_PRIVATE_KEY_PATH="${PACKER_SSH_PRIVATE_KEY_PATH:-${HOME}/.ssh/id_rsa}"

if [[ -n "${PACKER_COMPARTMENT_OCID:-}" ]]; then
  COMPARTMENT_OCID="${PACKER_COMPARTMENT_OCID}"
else
  COMPARTMENT_OCID="$(terraform -chdir="${PROJECT_DIR}" output -raw project_compartment_id)"
fi

IMAGE_COMPARTMENT_OCID="${PACKER_IMAGE_COMPARTMENT_OCID:-${COMPARTMENT_OCID}}"

if [[ -n "${PACKER_SUBNET_OCID:-}" ]]; then
  SUBNET_OCID="${PACKER_SUBNET_OCID}"
else
  SUBNET_OCID="$(oci network subnet list \
    --compartment-id "${COMPARTMENT_OCID}" \
    --display-name "oke-optimization-image-builder" \
    --profile "${PROFILE}" \
    --region "${REGION}" \
    --query 'data[0].id' \
    --raw-output)"
fi

if [[ -n "${PACKER_AVAILABILITY_DOMAIN:-}" ]]; then
  AVAILABILITY_DOMAIN="${PACKER_AVAILABILITY_DOMAIN}"
else
  AD_COMPARTMENT_OCID="${TENANCY_OCID:-${COMPARTMENT_OCID}}"
  AVAILABILITY_DOMAIN="$(oci iam availability-domain list \
    --compartment-id "${AD_COMPARTMENT_OCID}" \
    --profile "${PROFILE}" \
    --region "${REGION}" \
    --query 'data[0].name' \
    --raw-output)"
fi

BASE_IMAGE_NAME="$(oci compute image get \
  --image-id "${BASE_IMAGE_OCID}" \
  --profile "${PROFILE}" \
  --region "${REGION}" \
  --query 'data."display-name"' \
  --raw-output 2>/dev/null || true)"
BASE_IMAGE_NAME="${BASE_IMAGE_NAME:-unknown}"

DEFAULT_IMAGE_NAME="oke-optimized-ol8-oke-${K8S_VERSION_SLUG}-fast-start-packer-$(date +%Y%m%d%H%M%S)"
IMAGE_NAME="${2:-${DEFAULT_IMAGE_NAME}}"

VAR_FILE="$(mktemp "${PACKER_DIR}/local.auto.XXXXXX.pkrvars.hcl")"
trap 'rm -f "${VAR_FILE}"' EXIT

cat > "${VAR_FILE}" <<VARS
base_image_ocid        = "${BASE_IMAGE_OCID}"
base_image_name        = "${BASE_IMAGE_NAME}"
region                 = "${REGION}"
oci_profile            = "${PROFILE}"
compartment_ocid       = "${COMPARTMENT_OCID}"
image_compartment_ocid = "${IMAGE_COMPARTMENT_OCID}"
availability_domain    = "${AVAILABILITY_DOMAIN}"
subnet_ocid            = "${SUBNET_OCID}"
image_name             = "${IMAGE_NAME}"
kubernetes_version     = "${K8S_VERSION}"
ssh_public_key_path    = "${SSH_PUBLIC_KEY_PATH}"
ssh_private_key_path   = "${SSH_PRIVATE_KEY_PATH}"
VARS

echo "Base image: ${BASE_IMAGE_NAME} (${BASE_IMAGE_OCID})"
echo "Image name: ${IMAGE_NAME}"
echo "Compartment: ${COMPARTMENT_OCID}"
echo "Image compartment: ${IMAGE_COMPARTMENT_OCID}"
echo "Availability domain: ${AVAILABILITY_DOMAIN}"
echo "Subnet: ${SUBNET_OCID}"

packer init "${PACKER_DIR}"

if [[ "${PACKER_VALIDATE_ONLY:-false}" == "true" ]]; then
  packer validate -var-file="${VAR_FILE}" "${PACKER_DIR}"
else
  packer build -var-file="${VAR_FILE}" "${PACKER_DIR}"
fi
