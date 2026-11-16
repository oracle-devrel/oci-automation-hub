#!/usr/bin/env bash

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: manage-oci-custom-claim.sh ensure|check|delete

Required environment variables:
  OCI_IDENTITY_DOMAIN_URL   Identity Domains base URL
  OCI_CUSTOM_CLAIM_NAME     Unique custom claim name
  OCI_CUSTOM_CLAIM_SCOPE    OAuth scope FQS associated with the claim

Optional environment variables:
  OCI_CLI_PROFILE           OCI CLI profile (default: DEFAULT)
  OCI_CLI_AUTH              OCI CLI auth mode (default: api_key)
USAGE
}

[[ $# -eq 1 ]] || { usage >&2; exit 2; }
action="$1"
[[ "${action}" == "ensure" || "${action}" == "check" || "${action}" == "delete" ]] || {
  usage >&2
  exit 2
}

for command_name in jq oci; do
  command -v "${command_name}" >/dev/null 2>&1 || {
    printf 'Required command is missing: %s\n' "${command_name}" >&2
    exit 1
  }
done

domain_url="${OCI_IDENTITY_DOMAIN_URL:?Set OCI_IDENTITY_DOMAIN_URL}"
claim_name="${OCI_CUSTOM_CLAIM_NAME:?Set OCI_CUSTOM_CLAIM_NAME}"
claim_scope="${OCI_CUSTOM_CLAIM_SCOPE:?Set OCI_CUSTOM_CLAIM_SCOPE}"
oci_profile="${OCI_CLI_PROFILE:-DEFAULT}"
oci_auth="${OCI_CLI_AUTH:-api_key}"

[[ "${domain_url}" == https://* ]] || {
  printf 'OCI_IDENTITY_DOMAIN_URL must use HTTPS.\n' >&2
  exit 2
}
[[ "${claim_name}" =~ ^[A-Za-z][A-Za-z0-9_]{2,127}$ ]] || {
  printf 'OCI_CUSTOM_CLAIM_NAME contains unsupported characters.\n' >&2
  exit 2
}
[[ "${claim_scope}" == https://* || "${claim_scope}" == http://* ]] || {
  printf 'OCI_CUSTOM_CLAIM_SCOPE must be a fully qualified scope.\n' >&2
  exit 2
}

domain_url="${domain_url%/}"
case "${oci_auth}" in
  api_key|security_token)
    oci_args=(--profile "${oci_profile}" --auth "${oci_auth}")
    ;;
  instance_principal|resource_principal|oke_workload_identity)
    oci_args=(--auth "${oci_auth}")
    ;;
  *)
    printf 'Unsupported OCI_CLI_AUTH value: %s\n' "${oci_auth}" >&2
    exit 2
    ;;
esac

raw_request() {
  oci raw-request "${oci_args[@]}" "$@"
}

filter="$(jq -rn --arg value "name eq \"${claim_name}\"" '$value | @uri')"
list_response="$(raw_request \
  --http-method GET \
  --target-uri "${domain_url}/admin/v1/CustomClaims?filter=${filter}")"

jq -e '.status == "200 OK"' <<<"${list_response}" >/dev/null || {
  jq '{status, data}' <<<"${list_response}" >&2
  exit 1
}

claim_count="$(jq --arg name "${claim_name}" \
  '[.data.Resources[]? | select(.name == $name)] | length' \
  <<<"${list_response}")"
[[ "${claim_count}" -le 1 ]] || {
  printf 'More than one OCI custom claim is named %s.\n' "${claim_name}" >&2
  exit 1
}

claim_id="$(jq -r --arg name "${claim_name}" \
  '.data.Resources[]? | select(.name == $name) | .id' \
  <<<"${list_response}")"

claim_matches_expected() {
  jq -e \
    --arg name "${claim_name}" \
    --arg scope "${claim_scope}" \
    '
      .data.Resources[]? |
      select(.name == $name) |
      .value == "$user.groups.*.display" and
      .expression == true and
      .mode == "always" and
      .tokenType == "IT" and
      .allScopes == false and
      (.scopes | index($scope))
    ' <<<"${list_response}" >/dev/null
}

if [[ "${action}" == "check" ]]; then
  [[ -n "${claim_id}" ]] && claim_matches_expected || {
    printf 'OCI custom claim %s is absent or incorrectly configured.\n' \
      "${claim_name}" >&2
    exit 1
  }
  printf 'OK  OCI custom claim: %s\n' "${claim_name}"
  exit 0
fi

if [[ "${action}" == "delete" ]]; then
  if [[ -z "${claim_id}" ]]; then
    printf 'OCI custom claim %s is already absent.\n' "${claim_name}"
    exit 0
  fi

  delete_response="$(raw_request \
    --http-method DELETE \
    --target-uri "${domain_url}/admin/v1/CustomClaims/${claim_id}")"
  jq -e '.status == "204 No Content" or .status == "200 OK"' \
    <<<"${delete_response}" >/dev/null || {
    jq '{status, data}' <<<"${delete_response}" >&2
    exit 1
  }
  printf 'Deleted OCI custom claim %s.\n' "${claim_name}"
  exit 0
fi

request_file="$(mktemp "${TMPDIR:-/tmp}/oci-dicom-custom-claim.XXXXXX")"
trap 'rm -f "${request_file}"' EXIT
jq -n \
  --arg name "${claim_name}" \
  --arg scope "${claim_scope}" \
  '{
    schemas: ["urn:ietf:params:scim:schemas:oracle:idcs:CustomClaim"],
    name: $name,
    value: "$user.groups.*.display",
    expression: true,
    mode: "always",
    tokenType: "IT",
    allScopes: false,
    scopes: [$scope]
  }' >"${request_file}"

if [[ -z "${claim_id}" ]]; then
  write_response="$(raw_request \
    --http-method POST \
    --target-uri "${domain_url}/admin/v1/CustomClaims" \
    --request-body "file://${request_file}")"
  expected_status="201 Created"
  operation="Created"
else
  write_response="$(raw_request \
    --http-method PUT \
    --target-uri "${domain_url}/admin/v1/CustomClaims/${claim_id}" \
    --request-body "file://${request_file}")"
  expected_status="200 OK"
  operation="Reconciled"
fi

jq -e --arg status "${expected_status}" \
  '.status == $status and
   .data.name == $name and
   .data.value == "$user.groups.*.display" and
   .data.expression == true and
   .data.mode == "always" and
   .data.tokenType == "IT" and
   .data.allScopes == false and
   (.data.scopes | index($scope))' \
  --arg name "${claim_name}" \
  --arg scope "${claim_scope}" \
  <<<"${write_response}" >/dev/null || {
  jq '{status, data}' <<<"${write_response}" >&2
  exit 1
}

printf '%s OCI custom claim %s for scope %s.\n' \
  "${operation}" "${claim_name}" "${claim_scope}"
