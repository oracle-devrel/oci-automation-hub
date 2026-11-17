#!/usr/bin/env bash

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/verify.sh [--dicom /absolute/path/to/test.dcm] [--delete-after-upload]

Checks the Orthanc REST, DICOMweb, Stone, and OHIF endpoints. With --dicom, it
also uploads one non-production DICOM instance through Orthanc's REST API.

--delete-after-upload removes the uploaded instance after it has been verified.
USAGE
}

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
terraform_dir="${project_dir}/terraform"
dicom_file=""
delete_after_upload=false

while (($#)); do
  case "$1" in
    --dicom)
      [[ $# -ge 2 ]] || { printf '%s\n' '--dicom requires a file path' >&2; exit 1; }
      dicom_file="$2"
      shift
      ;;
    --delete-after-upload)
      delete_after_upload=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

if [[ "${delete_after_upload}" == true && -z "${dicom_file}" ]]; then
  printf '%s\n' '--delete-after-upload requires --dicom FILE' >&2
  exit 1
fi

api_endpoint="$(terraform -chdir="${terraform_dir}" output -raw api_endpoint)"
dicomweb_endpoint="$(terraform -chdir="${terraform_dir}" output -raw dicomweb_endpoint)"
username="$(terraform -chdir="${terraform_dir}" output -raw orthanc_username)"
password="$(terraform -chdir="${terraform_dir}" output -raw orthanc_password)"
keycloak_endpoint="$(terraform -chdir="${terraform_dir}" output -raw keycloak_endpoint)"

uploaded_instance_id=""
access_token=""
sso_cookie_jar=""
sso_authorize_response=""
cleanup() {
  if [[ "${delete_after_upload}" == true && -n "${uploaded_instance_id}" ]]; then
    curl \
      --fail \
      --silent \
      --show-error \
      --connect-timeout 15 \
      --max-time 60 \
      -H "Authorization: Bearer ${access_token}" \
      -X DELETE \
      "${api_endpoint}/instances/${uploaded_instance_id}" >/dev/null \
      || printf 'Warning: could not remove synthetic DICOM instance %s.\n' "${uploaded_instance_id}" >&2
  fi
  if [[ -n "${sso_cookie_jar}" ]]; then
    rm -f "${sso_cookie_jar}"
  fi
  if [[ -n "${sso_authorize_response}" ]]; then
    rm -f "${sso_authorize_response}"
  fi
}
trap cleanup EXIT

token_json="$(
  curl \
    --fail \
    --silent \
    --show-error \
    --retry 12 \
    --retry-all-errors \
    --connect-timeout 15 \
    --max-time 300 \
    -X POST \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode 'client_id=orthanc' \
    --data-urlencode 'grant_type=password' \
    --data-urlencode "username=${username}" \
    --data-urlencode "password=${password}" \
    "${keycloak_endpoint}/realms/orthanc/protocol/openid-connect/token"
)"
access_token="$(jq -r '.access_token // empty' <<<"${token_json}")"
[[ -n "${access_token}" ]] || {
  printf 'Keycloak did not return an access token: %s\n' \
    "$(jq -r '.error_description // .error // "unknown error"' <<<"${token_json}")" >&2
  exit 1
}
printf 'OK  Keycloak OIDC: %s\n' "${keycloak_endpoint}"

sso_json="$(terraform -chdir="${terraform_dir}" output -json oci_sso)"
if [[ "$(jq -r '.enabled' <<<"${sso_json}")" == "true" ]]; then
  sso_discovery_url="$(jq -r '.discovery_url' <<<"${sso_json}")"
  sso_domain_url="$(jq -r '.identity_domain_url' <<<"${sso_json}")"
  discovery_json="$(curl \
    --fail \
    --silent \
    --show-error \
    --retry 5 \
    --retry-all-errors \
    --connect-timeout 15 \
    --max-time 120 \
    "${sso_discovery_url}")"
  jq -e '
    .issuer and
    .authorization_endpoint and
    .token_endpoint and
    .userinfo_endpoint and
    .jwks_uri and
    (.code_challenge_methods_supported | index("S256"))
  ' <<<"${discovery_json}" >/dev/null

  sso_cookie_jar="$(mktemp "${TMPDIR:-/tmp}/oci-dicom-sso-cookies.XXXXXX")"
  sso_redirect="$(curl \
    --fail \
    --silent \
    --show-error \
    --get \
    --cookie-jar "${sso_cookie_jar}" \
    --output /dev/null \
    --write-out '%{redirect_url}' \
    --data-urlencode 'client_id=orthanc' \
    --data-urlencode "redirect_uri=${api_endpoint}/ui/app/" \
    --data-urlencode 'response_type=code' \
    --data-urlencode 'scope=openid' \
    --data-urlencode 'kc_idp_hint=oci' \
    "${keycloak_endpoint}/realms/orthanc/protocol/openid-connect/auth")"
  if [[ "${sso_redirect}" == "${keycloak_endpoint}/realms/orthanc/broker/oci/login"* ]]; then
    sso_redirect="$(curl \
      --fail \
      --silent \
      --show-error \
      --cookie "${sso_cookie_jar}" \
      --cookie-jar "${sso_cookie_jar}" \
      --output /dev/null \
      --write-out '%{redirect_url}' \
      "${sso_redirect}")"
  fi
  [[ "${sso_redirect}" == "${sso_domain_url}/oauth2/v1/authorize"* ]] || {
    printf 'Keycloak did not redirect to OCI IAM SSO. Redirect was: %s\n' \
      "${sso_redirect:-none}" >&2
    exit 1
  }
  broker_json="$(terraform -chdir="${terraform_dir}" output -json keycloak_oci_broker)"
  group_scope="$(jq -er '.default_scope | split(" ")[-1]' <<<"${broker_json}")"
  encoded_group_scope="$(jq -rn --arg scope "${group_scope}" '$scope | @uri')"
  [[ "${sso_redirect}" == *"${encoded_group_scope}"* ]] || {
    printf 'Keycloak did not request the OCI group-claim scope %s.\n' \
      "${group_scope}" >&2
    exit 1
  }

  # Reaching OCI's authorize endpoint is not sufficient: Identity Domains can
  # reject the request there when the Keycloak broker callback is not an exact
  # registered redirect URI. Exercise that request without following the login
  # redirect so verification remains non-interactive.
  sso_authorize_response="$(mktemp "${TMPDIR:-/tmp}/oci-dicom-sso-authorize.XXXXXX")"
  sso_authorize_status="$(curl \
    --silent \
    --show-error \
    --cookie "${sso_cookie_jar}" \
    --output "${sso_authorize_response}" \
    --write-out '%{http_code}' \
    --connect-timeout 15 \
    --max-time 120 \
    "${sso_redirect}")"
  if ((10#${sso_authorize_status} >= 400)); then
    sso_authorize_error="$(jq -r \
      'select(type == "object") | .error_description // .error // empty' \
      "${sso_authorize_response}" 2>/dev/null || true)"
    printf 'OCI IAM rejected the Keycloak SSO authorization request (HTTP %s): %s\n' \
      "${sso_authorize_status}" "${sso_authorize_error:-unknown error}" >&2
    exit 1
  fi
  acceptance_json="$(terraform -chdir="${terraform_dir}" output -json acceptance_context)"
  oci_cli_auth="$(jq -r '.auth' <<<"${acceptance_json}")"
  case "${oci_cli_auth}" in
    APIKey) oci_cli_auth="api_key" ;;
    SecurityToken) oci_cli_auth="security_token" ;;
    InstancePrincipal) oci_cli_auth="instance_principal" ;;
    ResourcePrincipal) oci_cli_auth="resource_principal" ;;
    OKEWorkloadIdentity) oci_cli_auth="oke_workload_identity" ;;
    *) printf 'Unsupported OCI CLI auth mode: %s\n' "${oci_cli_auth}" >&2; exit 1 ;;
  esac
  OCI_IDENTITY_DOMAIN_URL="${sso_domain_url}" \
  OCI_CUSTOM_CLAIM_NAME="$(jq -er '.claim_name' <<<"${broker_json}")" \
  OCI_CUSTOM_CLAIM_SCOPE="${group_scope}" \
  OCI_CLI_PROFILE="$(jq -r '.profile' <<<"${acceptance_json}")" \
  OCI_CLI_AUTH="${oci_cli_auth}" \
    "${project_dir}/scripts/manage-oci-custom-claim.sh" check
  printf 'OK  OCI IAM Identity Domains SSO: %s\n' "${sso_domain_url}"
fi

"${project_dir}/scripts/reconcile-keycloak-oci-mappers.sh" --check

curl_common=(
  --fail
  --silent
  --show-error
  --retry 5
  --retry-all-errors
  --connect-timeout 15
  --max-time 300
  -H
  "Authorization: Bearer ${access_token}"
)

system_json="$(curl "${curl_common[@]}" "${api_endpoint}/system")"
jq -e '.Name and .Version' <<<"${system_json}" >/dev/null
printf 'OK  Orthanc REST: %s (%s)\n' \
  "$(jq -r '.Name' <<<"${system_json}")" \
  "$(jq -r '.Version' <<<"${system_json}")"

studies_json="$(curl "${curl_common[@]}" \
  -H 'Accept: application/dicom+json' \
  "${dicomweb_endpoint}/studies?limit=1")"
jq -e 'type == "array"' <<<"${studies_json}" >/dev/null
if [[ "$(jq 'length' <<<"${studies_json}")" -gt 0 ]]; then
  jq -e --arg root "${dicomweb_endpoint}/studies/" '
    all(.[]; (."00081190".Value[0]? // "") | startswith($root))
  ' <<<"${studies_json}" >/dev/null || {
    printf 'DICOMweb QIDO-RS advertises a retrieval URL outside %s/studies/.\n' \
      "${dicomweb_endpoint}" >&2
    exit 1
  }
fi
printf 'OK  DICOMweb QIDO-RS: %s\n' "${dicomweb_endpoint}"

curl "${curl_common[@]}" --output /dev/null \
  "${api_endpoint}/stone-webviewer/index.html"
printf 'OK  Stone Web Viewer application\n'

curl "${curl_common[@]}" --output /dev/null \
  "${api_endpoint}/ohif/"
printf 'OK  OHIF application\n'

if [[ -n "${dicom_file}" ]]; then
  [[ -f "${dicom_file}" ]] || { printf 'DICOM file not found: %s\n' "${dicom_file}" >&2; exit 1; }
  file_size="$(wc -c <"${dicom_file}" | tr -d ' ')"
  if ((file_size > 20000000)); then
    printf 'Refusing upload: OCI API Gateway limits request bodies to 20 MB (%s bytes supplied).\n' "${file_size}" >&2
    exit 1
  fi
  upload_json="$(curl "${curl_common[@]}" \
    -X POST \
    -H 'Content-Type: application/dicom' \
    --data-binary "@${dicom_file}" \
    "${api_endpoint}/instances")"
  jq -e '.ID or .ParentStudy' <<<"${upload_json}" >/dev/null
  uploaded_instance_id="$(jq -r '.ID // empty' <<<"${upload_json}")"
  [[ -n "${uploaded_instance_id}" ]] || {
    printf '%s\n' 'Orthanc accepted the upload but did not return an instance ID.' >&2
    exit 1
  }
  printf 'OK  Test DICOM upload: %s\n' "${uploaded_instance_id}"

  instance_json="$(curl "${curl_common[@]}" \
    "${api_endpoint}/instances/${uploaded_instance_id}/simplified-tags")"
  jq -e '.SOPInstanceUID and .StudyInstanceUID and .SeriesInstanceUID' <<<"${instance_json}" >/dev/null
  printf 'OK  Uploaded instance lookup: %s\n' "$(jq -r '.SOPInstanceUID' <<<"${instance_json}")"

  if [[ "${delete_after_upload}" == true ]]; then
    curl "${curl_common[@]}" \
      -X DELETE \
      "${api_endpoint}/instances/${uploaded_instance_id}" >/dev/null
    printf 'OK  Synthetic DICOM cleanup: %s\n' "${uploaded_instance_id}"
    uploaded_instance_id=""
  fi
fi

printf 'Deployment verification completed successfully.\n'
