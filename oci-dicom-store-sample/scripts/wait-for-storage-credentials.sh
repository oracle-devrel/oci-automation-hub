#!/usr/bin/env bash

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
terraform_dir="${project_dir}/terraform"
timeout_seconds="${STORAGE_CREDENTIAL_TIMEOUT_SECONDS:-1200}"
retry_seconds="${STORAGE_CREDENTIAL_RETRY_SECONDS:-15}"

for command_name in terraform jq curl grep; do
  command -v "${command_name}" >/dev/null 2>&1 || {
    printf 'Required command is missing: %s\n' "${command_name}" >&2
    exit 1
  }
done

curl --help all 2>/dev/null | grep -Fq -- '--aws-sigv4' || {
  printf 'curl must support --aws-sigv4 for the Object Storage readiness check.\n' >&2
  exit 1
}

[[ "${timeout_seconds}" =~ ^[1-9][0-9]*$ ]] || {
  printf 'STORAGE_CREDENTIAL_TIMEOUT_SECONDS must be a positive integer.\n' >&2
  exit 2
}
[[ "${retry_seconds}" =~ ^[1-9][0-9]*$ ]] || {
  printf 'STORAGE_CREDENTIAL_RETRY_SECONDS must be a positive integer.\n' >&2
  exit 2
}

credential_json="$(terraform -chdir="${terraform_dir}" output -json storage_credentials)" || {
  printf 'Unable to read the Object Storage credentials from Terraform outputs.\n' >&2
  exit 1
}
credential_source="$(jq -r 'if .managed then "stack-managed" else "externally managed" end' <<<"${credential_json}")"

region="$(terraform -chdir="${terraform_dir}" output -json acceptance_context | jq -er '.region')"
endpoint="$(terraform -chdir="${terraform_dir}" output -raw s3_compatibility_endpoint)"
bucket_name="$(terraform -chdir="${terraform_dir}" output -json deployment_summary | jq -er '.bucket_name')"
access_key="$(jq -r '.access_key' <<<"${credential_json}")"
secret_key="$(jq -r '.secret_key' <<<"${credential_json}")"

umask 077
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/oci-dicom-storage-ready.XXXXXX")"
curl_config="${temporary_dir}/curl.conf"
response_file="${temporary_dir}/response.xml"
cleanup() {
  rm -rf "${temporary_dir}"
}
trap cleanup EXIT

# A curl config avoids exposing the secret in the process command line.
printf 'user = "%s:%s"\n' "${access_key}" "${secret_key}" >"${curl_config}"
unset access_key secret_key credential_json

printf 'Waiting for the %s S3 credential and bucket policy to reach OCI Object Storage...\n' \
  "${credential_source}"
deadline=$((SECONDS + timeout_seconds))
attempt=0
last_http_code="none"
last_error="no response"

while ((SECONDS < deadline)); do
  attempt=$((attempt + 1))
  if http_code="$(curl \
    --config "${curl_config}" \
    --silent \
    --show-error \
    --output "${response_file}" \
    --write-out '%{http_code}' \
    --connect-timeout 15 \
    --max-time 60 \
    --aws-sigv4 "aws:amz:${region}:s3" \
    "${endpoint}/${bucket_name}?list-type=2&max-keys=1")"; then
    last_http_code="${http_code}"
    if [[ "${http_code}" == "200" ]]; then
      printf 'Object Storage accepted the stack credential after %s attempt(s).\n' "${attempt}"
      exit 0
    fi
    error_code="$(sed -n 's:.*<Code>\([^<]*\)</Code>.*:\1:p' "${response_file}" | head -1)"
    error_message="$(sed -n 's:.*<Message>\([^<]*\)</Message>.*:\1:p' "${response_file}" | head -1)"
    last_error="${error_code:-unknown}: ${error_message:-request rejected}"
  else
    last_http_code="transport-error"
    last_error="curl could not reach the S3 compatibility endpoint"
  fi

  if ((SECONDS + retry_seconds >= deadline)); then
    break
  fi
  sleep "${retry_seconds}"
done

printf 'Object Storage did not accept the stack credential within %s seconds (HTTP %s, %s).\n' \
  "${timeout_seconds}" "${last_http_code}" "${last_error}" >&2
exit 1
