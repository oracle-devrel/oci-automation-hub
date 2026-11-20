#!/usr/bin/env bash

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
terraform_dir="${project_dir}/terraform"
source "${project_dir}/scripts/ssh-trust.sh"
private_key="${BASTION_SSH_PRIVATE_KEY_FILE:-}"

usage() {
  cat <<'USAGE'
Usage: scripts/failure-test.sh --private-key PATH

Deletes one Orthanc pod, continuously probes QIDO-RS through API Gateway, and
waits for Kubernetes to replace the pod. No stored study or infrastructure is
deleted.
USAGE
}

while (($#)); do
  case "$1" in
    --private-key) private_key="${2:-}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

[[ -f "${private_key}" ]] || { printf 'Private key not found: %s\n' "${private_key}" >&2; exit 2; }
for command_name in terraform curl jq ssh; do
  command -v "${command_name}" >/dev/null 2>&1 || {
    printf 'Required command is missing: %s\n' "${command_name}" >&2
    exit 1
  }
done

summary="$(terraform -chdir="${terraform_dir}" output -json deployment_summary)"
replicas="$(jq -r '.orthanc_replicas' <<<"${summary}")"
((replicas >= 2)) || {
  printf 'Failure test requires orthanc_replicas >= 2; current value is %s.\n' "${replicas}" >&2
  exit 2
}
bastion_ip="$(jq -r '.bastion_public_ip' <<<"${summary}")"
namespace="$(jq -r '.name' <<<"${summary}")"
dicomweb_endpoint="$(terraform -chdir="${terraform_dir}" output -raw dicomweb_endpoint)"
keycloak_endpoint="$(terraform -chdir="${terraform_dir}" output -raw keycloak_endpoint)"
username="$(terraform -chdir="${terraform_dir}" output -raw orthanc_username)"
password="$(terraform -chdir="${terraform_dir}" output -raw orthanc_password)"
token="$(curl --fail --silent --show-error -X POST \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode 'client_id=orthanc' \
  --data-urlencode 'grant_type=password' \
  --data-urlencode "username=${username}" \
  --data-urlencode "password=${password}" \
  "${keycloak_endpoint}/realms/orthanc/protocol/openid-connect/token" |
  jq -er '.access_token')"

temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/oci-dicom-failure.XXXXXX")"
trap 'rm -rf "${temporary_dir}"' EXIT
oci_dicom_prepare_ssh_trust "${terraform_dir}"
ssh_common=(
  -i "${private_key}"
  "${OCI_DICOM_SSH_TRUST_OPTIONS[@]}"
  "opc@${bastion_ip}"
)

old_pod="$(ssh "${ssh_common[@]}" "/usr/local/bin/kubectl -n '${namespace}' get pods -l app.kubernetes.io/name=orthanc -o jsonpath='{.items[0].metadata.name}'")"
[[ -n "${old_pod}" ]] || { printf 'No Orthanc pod was found.\n' >&2; exit 1; }
ssh "${ssh_common[@]}" "/usr/local/bin/kubectl -n '${namespace}' delete pod '${old_pod}' --wait=false" >/dev/null
printf 'Injected failure by deleting Orthanc pod %s.\n' "${old_pod}"

for attempt in $(seq 1 24); do
  status="$(curl --silent --show-error --output "${temporary_dir}/qido.json" --write-out '%{http_code}' \
    --connect-timeout 10 --max-time 30 \
    -H "Authorization: Bearer ${token}" \
    -H 'Accept: application/dicom+json' \
    "${dicomweb_endpoint}/studies?limit=1" || true)"
  [[ "${status}" == "200" ]] || {
    printf 'Public QIDO-RS failed with HTTP %s during pod replacement (attempt %s).\n' \
      "${status:-transport-error}" "${attempt}" >&2
    exit 1
  }
  sleep 2
done

ssh "${ssh_common[@]}" "/usr/local/bin/kubectl -n '${namespace}' rollout status deployment/orthanc --timeout=10m"
new_pods="$(ssh "${ssh_common[@]}" "/usr/local/bin/kubectl -n '${namespace}' get pods -l app.kubernetes.io/name=orthanc --field-selector=status.phase=Running -o name")"
[[ "$(wc -l <<<"${new_pods}" | tr -d ' ')" -ge "${replicas}" ]] || {
  printf 'Orthanc did not recover all %s replicas.\n' "${replicas}" >&2
  exit 1
}
grep -qv "pod/${old_pod}" <<<"${new_pods}" || {
  printf 'Kubernetes did not replace failed pod %s.\n' "${old_pod}" >&2
  exit 1
}
printf 'OK  Failure recovery: QIDO-RS stayed available and Kubernetes replaced the pod.\n'
