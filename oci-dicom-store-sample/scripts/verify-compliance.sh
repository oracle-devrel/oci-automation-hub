#!/usr/bin/env bash

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
terraform_dir="${project_dir}/terraform"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/oci-dicom-compliance.XXXXXX")"
declare -a cleanup_studies=()
admin_token=""

cleanup() {
  if [[ -n "${admin_token}" ]]; then
    api_endpoint="$(terraform -chdir="${terraform_dir}" output -raw api_endpoint 2>/dev/null || true)"
    if ((${#cleanup_studies[@]} > 0)); then
      for study_id in "${cleanup_studies[@]}"; do
        curl --silent --show-error -H "Authorization: Bearer ${admin_token}" \
          -X DELETE "${api_endpoint}/studies/${study_id}" >/dev/null || true
      done
    fi
  fi
  rm -rf "${temporary_dir}"
}
trap cleanup EXIT

for command_name in terraform curl jq oci grep; do
  command -v "${command_name}" >/dev/null 2>&1 || {
    printf 'Required command is missing: %s\n' "${command_name}" >&2
    exit 1
  }
done

api_endpoint="$(terraform -chdir="${terraform_dir}" output -raw api_endpoint)"
dicomweb_endpoint="$(terraform -chdir="${terraform_dir}" output -raw dicomweb_endpoint)"
keycloak_endpoint="$(terraform -chdir="${terraform_dir}" output -raw keycloak_endpoint)"
admin_username="$(terraform -chdir="${terraform_dir}" output -raw orthanc_username)"
admin_password="$(terraform -chdir="${terraform_dir}" output -raw orthanc_password)"
tenant_credentials="$(terraform -chdir="${terraform_dir}" output -json tenant_test_credentials)"
tenant_authorization="$(terraform -chdir="${terraform_dir}" output -json tenant_authorization)"
acceptance_context="$(terraform -chdir="${terraform_dir}" output -json acceptance_context)"

tenant_keys=()
while IFS= read -r tenant_key; do
  tenant_keys+=("${tenant_key}")
done < <(jq -r 'keys[]' <<<"${tenant_credentials}")
if ((${#tenant_keys[@]} < 2)); then
  printf '%s\n' \
    'The compliance test requires two synthetic tenant users.' \
    'Set enable_tenant_test_users = true, apply, and rerun this target.' >&2
  exit 2
fi
tenant_a="${tenant_keys[0]}"
tenant_b="${tenant_keys[1]}"

get_token() {
  local username="$1"
  local password="$2"
  curl --fail --silent --show-error --retry 5 --retry-all-errors \
    --connect-timeout 15 --max-time 180 \
    -X POST -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode 'client_id=orthanc' \
    --data-urlencode 'grant_type=password' \
    --data-urlencode "username=${username}" \
    --data-urlencode "password=${password}" \
    "${keycloak_endpoint}/realms/orthanc/protocol/openid-connect/token" |
    jq -er '.access_token'
}

admin_token="$(get_token "${admin_username}" "${admin_password}")"
tenant_a_token="$(get_token \
  "$(jq -r --arg tenant "${tenant_a}" '.[$tenant].username' <<<"${tenant_credentials}")" \
  "$(jq -r --arg tenant "${tenant_a}" '.[$tenant].password' <<<"${tenant_credentials}")")"
tenant_b_token="$(get_token \
  "$(jq -r --arg tenant "${tenant_b}" '.[$tenant].username' <<<"${tenant_credentials}")" \
  "$(jq -r --arg tenant "${tenant_b}" '.[$tenant].password' <<<"${tenant_credentials}")")"
printf 'OK  OIDC tokens: administrator, %s, %s\n' "${tenant_a}" "${tenant_b}"

metadata_a="$("${project_dir}/scripts/generate-test-dicom.py" \
  "${temporary_dir}/${tenant_a}.dcm" --patient-id "SYNTHETIC-$(tr '[:lower:]' '[:upper:]' <<<"${tenant_a}")")"
metadata_b="$("${project_dir}/scripts/generate-test-dicom.py" \
  "${temporary_dir}/${tenant_b}.dcm" --patient-id "SYNTHETIC-$(tr '[:lower:]' '[:upper:]' <<<"${tenant_b}")")"

stow() {
  local token="$1"
  local dicom_file="$2"
  local result_file="$3"
  local boundary="oci-dicom-$(date +%s)-${RANDOM}"
  local body_file="${result_file}.body"
  {
    printf -- '--%s\r\n' "${boundary}"
    printf 'Content-Type: application/dicom\r\n\r\n'
    command cat "${dicom_file}"
    printf '\r\n--%s--\r\n' "${boundary}"
  } >"${body_file}"
  curl --fail --silent --show-error --connect-timeout 15 --max-time 300 \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: multipart/related; type=application/dicom; boundary=${boundary}" \
    --data-binary "@${body_file}" \
    --output "${result_file}" \
    "${dicomweb_endpoint}/studies"
}

stow "${tenant_a_token}" "${temporary_dir}/${tenant_a}.dcm" "${temporary_dir}/${tenant_a}-stow.json"
stow "${tenant_b_token}" "${temporary_dir}/${tenant_b}.dcm" "${temporary_dir}/${tenant_b}-stow.json"
printf 'OK  DICOMweb STOW-RS: synthetic studies uploaded by tenant-scoped users\n'

find_study() {
  local study_uid="$1"
  local result=""
  for _ in $(seq 1 30); do
    result="$(curl --fail --silent --show-error \
      -H "Authorization: Bearer ${admin_token}" \
      -H 'Content-Type: application/json' \
      --data "$(jq -nc --arg uid "${study_uid}" '{Level:"Study",Query:{StudyInstanceUID:$uid}}')" \
      "${api_endpoint}/tools/find")"
    if [[ "$(jq 'length' <<<"${result}")" == "1" ]]; then
      jq -er '.[0]' <<<"${result}"
      return 0
    fi
    sleep 2
  done
  printf 'Study %s did not become visible to the classifier.\n' "${study_uid}" >&2
  return 1
}

study_uid_a="$(jq -r '.StudyInstanceUID' <<<"${metadata_a}")"
study_uid_b="$(jq -r '.StudyInstanceUID' <<<"${metadata_b}")"
study_id_a="$(find_study "${study_uid_a}")"
study_id_b="$(find_study "${study_uid_b}")"
cleanup_studies+=("${study_id_a}" "${study_id_b}")

qido_contains() {
  local token="$1"
  local study_uid="$2"
  local result_file="$3"
  local status
  status="$(curl --silent --show-error --output "${result_file}" --write-out '%{http_code}' \
    -H "Authorization: Bearer ${token}" \
    -H 'Accept: application/dicom+json' \
    --get --data-urlencode "StudyInstanceUID=${study_uid}" \
    "${dicomweb_endpoint}/studies")"
  [[ "${status}" == "200" ]] || return 1
  jq -e --arg uid "${study_uid}" \
    'any(.[]?; .["0020000D"].Value[0] == $uid)' "${result_file}" >/dev/null
}

wait_for_qido() {
  local token="$1"
  local study_uid="$2"
  local result_file="$3"
  for _ in $(seq 1 45); do
    if qido_contains "${token}" "${study_uid}" "${result_file}"; then
      return 0
    fi
    sleep 2
  done
  printf 'Timed out waiting for tenant QIDO visibility for %s. Last response: %s\n' \
    "${study_uid}" "$(command cat "${result_file}" 2>/dev/null || true)" >&2
  return 1
}

if qido_contains "${tenant_a_token}" "${study_uid_a}" "${temporary_dir}/quarantine.json"; then
  printf 'Tenant %s saw an unclassified study; quarantine isolation failed.\n' "${tenant_a}" >&2
  exit 1
fi
printf 'OK  Quarantine: an unlabeled upload is hidden from its tenant\n'

"${project_dir}/scripts/classify-study.sh" --tenant "${tenant_a}" --study-id "${study_id_a}"
"${project_dir}/scripts/classify-study.sh" --tenant "${tenant_b}" --study-id "${study_id_b}"

wait_for_qido "${tenant_a_token}" "${study_uid_a}" "${temporary_dir}/qido-a.json"
wait_for_qido "${tenant_b_token}" "${study_uid_b}" "${temporary_dir}/qido-b.json"
if qido_contains "${tenant_a_token}" "${study_uid_b}" "${temporary_dir}/qido-cross.json"; then
  printf 'Tenant %s discovered tenant %s study through QIDO-RS.\n' "${tenant_a}" "${tenant_b}" >&2
  exit 1
fi
printf 'OK  DICOMweb QIDO-RS: positive visibility and cross-tenant concealment\n'

viewer_token_json="$(curl --fail --silent --show-error \
  -X PUT \
  -H "Authorization: Bearer ${tenant_a_token}" \
  -H 'Content-Type: application/json' \
  --data "$(jq -nc \
    --arg orthanc_id "${study_id_a}" \
    --arg dicom_uid "${study_uid_a}" \
    '{
      Type: "viewer-instant-link",
      ValidityDuration: 300,
      Resources: [{OrthancId: $orthanc_id, DicomUid: $dicom_uid, Level: "study"}]
    }')" \
  "${api_endpoint}/auth/tokens/viewer-instant-link")"
viewer_token="$(jq -er '.Token' <<<"${viewer_token_json}")"
qido_contains "${viewer_token}" "${study_uid_a}" "${temporary_dir}/viewer-qido-a.json"
if qido_contains "${viewer_token}" "${study_uid_b}" "${temporary_dir}/viewer-qido-cross.json"; then
  printf 'A study-scoped viewer token discovered tenant %s study.\n' "${tenant_b}" >&2
  exit 1
fi
printf 'OK  Stone/OHIF viewer token: Keycloak user can open only the authorized study\n'

wado_path() {
  local metadata="$1"
  printf '%s/studies/%s/series/%s/instances/%s' \
    "${dicomweb_endpoint}" \
    "$(jq -r '.StudyInstanceUID' <<<"${metadata}")" \
    "$(jq -r '.SeriesInstanceUID' <<<"${metadata}")" \
    "$(jq -r '.SOPInstanceUID' <<<"${metadata}")"
}
wado_a="$(wado_path "${metadata_a}")"
wado_b="$(wado_path "${metadata_b}")"
status="$(curl --silent --show-error --output "${temporary_dir}/wado-a.bin" --write-out '%{http_code}' \
  -H "Authorization: Bearer ${viewer_token}" \
  -H 'Accept: multipart/related; type="application/dicom"' "${wado_a}")"
[[ "${status}" == "200" ]] || { printf 'Expected WADO-RS 200, got %s.\n' "${status}" >&2; exit 1; }
grep -a -q 'DICM' "${temporary_dir}/wado-a.bin" || {
  printf 'WADO-RS response did not contain a DICOM Part 10 payload.\n' >&2
  exit 1
}
cross_status="$(curl --silent --show-error --output "${temporary_dir}/wado-cross.json" --write-out '%{http_code}' \
  -H "Authorization: Bearer ${viewer_token}" \
  -H 'Accept: multipart/related; type="application/dicom"' "${wado_b}")"
[[ "${cross_status}" == "403" || "${cross_status}" == "404" ]] || {
  printf 'Cross-tenant WADO-RS returned %s instead of 403/404.\n' "${cross_status}" >&2
  exit 1
}
printf 'OK  DICOMweb WADO-RS: study-scoped viewer retrieval and cross-tenant denial\n'

audit_json="$(curl --fail --silent --show-error \
  -H "Authorization: Bearer ${admin_token}" "${api_endpoint}/auth/audit-logs")"
jq -e 'type == "array" or type == "object"' <<<"${audit_json}" >/dev/null
grep -qE 'added-label|uploaded-instance' <<<"${audit_json}" || {
  printf 'Orthanc audit endpoint returned no upload/classification event.\n' >&2
  exit 1
}
printf 'OK  Orthanc audit events: upload/classification activity persisted in PostgreSQL\n'

oci_args=(--region "$(jq -r '.region' <<<"${acceptance_context}")")
case "$(jq -r '.auth' <<<"${acceptance_context}")" in
  APIKey) oci_args+=(--profile "$(jq -r '.profile' <<<"${acceptance_context}")" --auth api_key) ;;
  SecurityToken) oci_args+=(--profile "$(jq -r '.profile' <<<"${acceptance_context}")" --auth security_token) ;;
  InstancePrincipal) oci_args+=(--auth instance_principal) ;;
  ResourcePrincipal) oci_args+=(--auth resource_principal) ;;
  OKEWorkloadIdentity) oci_args+=(--auth oke_workload_identity) ;;
  *) printf 'Unsupported OCI authentication mode.\n' >&2; exit 1 ;;
esac

namespace="$(jq -r '.namespace' <<<"${acceptance_context}")"
bucket_name="$(jq -r '.bucket_name' <<<"${acceptance_context}")"
bucket_json="$(oci "${oci_args[@]}" os bucket get \
  --namespace-name "${namespace}" --bucket-name "${bucket_name}")"
jq -e '.data."public-access-type" == "NoPublicAccess" and .data.versioning == "Enabled"' \
  <<<"${bucket_json}" >/dev/null
object_count="$(oci "${oci_args[@]}" os object list \
  --namespace-name "${namespace}" --bucket-name "${bucket_name}" --all |
  jq '.data | length')"
((object_count > 0)) || { printf 'No Orthanc image objects were found in Object Storage.\n' >&2; exit 1; }
if [[ "$(jq -r '.data."kms-key-id" // empty' <<<"${bucket_json}")" == "" ]]; then
  printf 'OK  Encrypted durable storage: private/versioned bucket, Oracle-managed encryption key, %s objects\n' "${object_count}"
else
  printf 'OK  Encrypted durable storage: private/versioned bucket, customer-managed KMS key, %s objects\n' "${object_count}"
fi

postgres_json="$(oci "${oci_args[@]}" psql db-system get \
  --db-system-id "$(jq -r '.postgres_id' <<<"${acceptance_context}")")"
jq -e '
  .data."storage-details"."is-regionally-durable" == true and
  .data."management-policy"."backup-policy".kind == "DAILY" and
  (.data."management-policy"."backup-policy"."retention-days" > 0)
' <<<"${postgres_json}" >/dev/null
printf 'OK  PostgreSQL: regionally durable index and daily retained backups configured\n'

printf 'Compliance verification completed successfully with synthetic data only.\n'
