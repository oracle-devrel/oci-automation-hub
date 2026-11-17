#!/usr/bin/env bash

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/verify-fastconnect.sh [--control-plane-only] [--dicom FILE]

Checks the FastConnect virtual-circuit state and, unless control-plane-only is
selected, tests the TLS private Orthanc/DICOMweb endpoint from the current
FastConnect-connected network. --dicom uploads one non-production instance
without the API Gateway 20 MB request limit.
USAGE
}

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
terraform_dir="${project_dir}/terraform"
control_plane_only="false"
dicom_file=""
umask 077

while (($#)); do
  case "$1" in
    --control-plane-only)
      control_plane_only="true"
      ;;
    --dicom)
      [[ $# -ge 2 ]] || { printf '%s\n' '--dicom requires a file path' >&2; exit 2; }
      dicom_file="$2"
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

for command_name in terraform jq oci curl; do
  command -v "${command_name}" >/dev/null 2>&1 || {
    printf 'Required command is missing: %s\n' "${command_name}" >&2
    exit 1
  }
done

fastconnect_output="$(terraform -chdir="${terraform_dir}" output -json fastconnect_status)"
acceptance_context="$(terraform -chdir="${terraform_dir}" output -json acceptance_context)"
oci_args=(--region "$(jq -er '.region' <<<"${acceptance_context}")")
case "$(jq -er '.auth' <<<"${acceptance_context}")" in
  APIKey) oci_args+=(--profile "$(jq -er '.profile' <<<"${acceptance_context}")" --auth api_key) ;;
  SecurityToken) oci_args+=(--profile "$(jq -er '.profile' <<<"${acceptance_context}")" --auth security_token) ;;
  InstancePrincipal) oci_args+=(--auth instance_principal) ;;
  ResourcePrincipal) oci_args+=(--auth resource_principal) ;;
  OKEWorkloadIdentity) oci_args+=(--auth oke_workload_identity) ;;
  *) printf 'Unsupported OCI authentication mode.\n' >&2; exit 1 ;;
esac
virtual_circuit_id="$(jq -r '.virtual_circuit_id // empty' <<<"${fastconnect_output}")"
[[ -n "${virtual_circuit_id}" ]] || {
  printf 'FastConnect is not enabled in this Terraform state.\n' >&2
  exit 1
}

virtual_circuit_json="$(oci "${oci_args[@]}" network virtual-circuit get \
  --virtual-circuit-id "${virtual_circuit_id}" \
  --output json)"

jq -r '
  .data |
  "Virtual circuit: \(.id)\n" +
  "Lifecycle: \(.["lifecycle-state"])\n" +
  "Provider: \(.["provider-state"])\n" +
  "BGP IPv4: \(.["bgp-session-state"])"
' <<<"${virtual_circuit_json}"

if ! jq -e '
  .data."lifecycle-state" == "PROVISIONED" and
  .data."provider-state" == "ACTIVE" and
  .data."bgp-session-state" == "UP"
' <<<"${virtual_circuit_json}" >/dev/null; then
  printf 'FastConnect is not operational yet; provider activation and BGP must be complete.\n' >&2
  exit 1
fi

if [[ "${control_plane_only}" == "true" ]]; then
  exit 0
fi

endpoint="$(terraform -chdir="${terraform_dir}" output -raw fastconnect_private_ingest_endpoint)"
username="$(terraform -chdir="${terraform_dir}" output -raw orthanc_username)"
password="$(terraform -chdir="${terraform_dir}" output -raw orthanc_password)"
certificate_file="$(mktemp "${TMPDIR:-/tmp}/oci-dicom-fastconnect-ca.XXXXXX")"
trap 'rm -f "${certificate_file}"' EXIT
terraform -chdir="${terraform_dir}" output -raw fastconnect_private_ingest_certificate >"${certificate_file}"

private_base="${endpoint%/orthanc}"
token_json="$(
  curl \
    --fail \
    --silent \
    --show-error \
    --retry 5 \
    --retry-all-errors \
    --connect-timeout 15 \
    --max-time 180 \
    --cacert "${certificate_file}" \
    -X POST \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode 'client_id=orthanc' \
    --data-urlencode 'grant_type=password' \
    --data-urlencode "username=${username}" \
    --data-urlencode "password=${password}" \
    "${private_base}/keycloak/realms/orthanc/protocol/openid-connect/token"
)"
access_token="$(jq -r '.access_token // empty' <<<"${token_json}")"
[[ -n "${access_token}" ]] || {
  printf 'Unable to obtain an Orthanc OIDC token over FastConnect.\n' >&2
  exit 1
}

private_curl() {
  curl \
    --fail \
    --silent \
    --show-error \
    --retry 5 \
    --retry-all-errors \
    --connect-timeout 15 \
    --max-time 1800 \
    --cacert "${certificate_file}" \
    -H "Authorization: Bearer ${access_token}" \
    "$@"
}

if ! system_json="$(private_curl "${endpoint}/system")"; then
  printf 'Private endpoint is unreachable. Run this command from a host whose route traverses FastConnect.\n' >&2
  exit 1
fi
jq -e '.Name and .Version' <<<"${system_json}" >/dev/null
printf 'OK  Private Orthanc TLS: %s (%s)\n' \
  "$(jq -r '.Name' <<<"${system_json}")" \
  "$(jq -r '.Version' <<<"${system_json}")"

studies_json="$(private_curl \
  -H 'Accept: application/dicom+json' \
  "${endpoint}/dicom-web/studies?limit=1")"
jq -e 'type == "array"' <<<"${studies_json}" >/dev/null
printf 'OK  Private DICOMweb QIDO-RS\n'

if [[ -n "${dicom_file}" ]]; then
  [[ -f "${dicom_file}" ]] || {
    printf 'DICOM file not found: %s\n' "${dicom_file}" >&2
    exit 1
  }
  upload_json="$(private_curl \
    -X POST \
    -H 'Content-Type: application/dicom' \
    --data-binary "@${dicom_file}" \
    "${endpoint}/instances")"
  jq -e '.ID or .ParentStudy' <<<"${upload_json}" >/dev/null
  printf 'OK  Private DICOM upload: %s\n' \
    "$(jq -r '.ID // .ParentStudy' <<<"${upload_json}")"
fi

printf 'FastConnect verification completed successfully.\n'
