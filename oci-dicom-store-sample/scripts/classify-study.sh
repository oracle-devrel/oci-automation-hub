#!/usr/bin/env bash

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
terraform_dir="${project_dir}/terraform"
tenant=""
study_uid=""
study_id=""

usage() {
  cat <<'USAGE'
Usage: scripts/classify-study.sh --tenant TENANT (--study-uid UID | --study-id ORTHANC_ID)

Assigns exactly one configured tenant label to a study. This is a privileged
classification operation and always authenticates as the break-glass Orthanc
administrator. Arbitrary labels are rejected.
USAGE
}

while (($#)); do
  case "$1" in
    --tenant) tenant="${2:-}"; shift ;;
    --study-uid) study_uid="${2:-}"; shift ;;
    --study-id) study_id="${2:-}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

[[ -n "${tenant}" ]] || { usage >&2; exit 2; }
if [[ -n "${study_uid}" && -n "${study_id}" ]] || [[ -z "${study_uid}" && -z "${study_id}" ]]; then
  usage >&2
  exit 2
fi
for command_name in terraform curl jq; do
  command -v "${command_name}" >/dev/null 2>&1 || {
    printf 'Required command is missing: %s\n' "${command_name}" >&2
    exit 1
  }
done

authorization="$(terraform -chdir="${terraform_dir}" output -json tenant_authorization)"
label="$(jq -er --arg tenant "${tenant}" '.tenants[$tenant].label' <<<"${authorization}")" || {
  printf 'Unknown tenant %s. Configured tenants: %s\n' \
    "${tenant}" "$(jq -r '.tenants | keys | join(", ")' <<<"${authorization}")" >&2
  exit 2
}
api_endpoint="$(terraform -chdir="${terraform_dir}" output -raw api_endpoint)"
keycloak_endpoint="$(terraform -chdir="${terraform_dir}" output -raw keycloak_endpoint)"
username="$(terraform -chdir="${terraform_dir}" output -raw orthanc_username)"
password="$(terraform -chdir="${terraform_dir}" output -raw orthanc_password)"

token_json="$(curl --fail --silent --show-error --connect-timeout 15 --max-time 120 \
  -X POST -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode 'client_id=orthanc' \
  --data-urlencode 'grant_type=password' \
  --data-urlencode "username=${username}" \
  --data-urlencode "password=${password}" \
  "${keycloak_endpoint}/realms/orthanc/protocol/openid-connect/token")"
token="$(jq -er '.access_token' <<<"${token_json}")"
curl_auth=(-H "Authorization: Bearer ${token}")

if [[ -n "${study_uid}" ]]; then
  find_result="$(curl --fail --silent --show-error "${curl_auth[@]}" \
    -H 'Content-Type: application/json' \
    --data "$(jq -nc --arg uid "${study_uid}" '{Level:"Study",Query:{StudyInstanceUID:$uid}}')" \
    "${api_endpoint}/tools/find")"
  [[ "$(jq 'length' <<<"${find_result}")" == "1" ]] || {
    printf 'Expected exactly one Orthanc study for StudyInstanceUID %s; got %s.\n' \
      "${study_uid}" "$(jq 'length' <<<"${find_result}")" >&2
    exit 1
  }
  study_id="$(jq -er '.[0]' <<<"${find_result}")"
fi

existing_labels="$(curl --fail --silent --show-error "${curl_auth[@]}" \
  "${api_endpoint}/studies/${study_id}/labels")"
while IFS= read -r configured_label; do
  [[ "${configured_label}" == "${label}" ]] && continue
  if jq -e --arg label "${configured_label}" 'index($label) != null' \
    <<<"${existing_labels}" >/dev/null; then
    curl --fail --silent --show-error "${curl_auth[@]}" -X DELETE \
      "${api_endpoint}/studies/${study_id}/labels/${configured_label}" >/dev/null
  fi
done < <(jq -r '.tenants[].label' <<<"${authorization}")

if ! jq -e --arg label "${label}" 'index($label) != null' \
  <<<"${existing_labels}" >/dev/null; then
  curl --fail --silent --show-error "${curl_auth[@]}" -X PUT \
    "${api_endpoint}/studies/${study_id}/labels/${label}" >/dev/null
fi

final_labels="$(curl --fail --silent --show-error "${curl_auth[@]}" \
  "${api_endpoint}/studies/${study_id}/labels")"
configured_count="$(jq --argjson configured "$(jq '[.tenants[].label]' <<<"${authorization}")" \
  '[.[] | select(. as $label | $configured | index($label))] | length' <<<"${final_labels}")"
[[ "${configured_count}" == "1" ]] || {
  printf 'Classification invariant failed: study %s has %s configured tenant labels.\n' \
    "${study_id}" "${configured_count}" >&2
  exit 1
}
printf 'Classified Orthanc study %s as tenant %s with label %s.\n' \
  "${study_id}" "${tenant}" "${label}"
