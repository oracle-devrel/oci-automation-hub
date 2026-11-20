#!/usr/bin/env bash

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/oci-dicom-storage-ready-test.XXXXXX")"
trap 'rm -rf "${temporary_dir}"' EXIT
mkdir -p "${temporary_dir}/bin"

cat >"${temporary_dir}/bin/terraform" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"output -json storage_credentials"*) printf '%s\n' '{"access_key":"external-access","secret_key":"external-secret","managed":false}' ;;
  *"output -json acceptance_context"*) printf '%s\n' '{"region":"eu-frankfurt-1"}' ;;
  *"output -raw s3_compatibility_endpoint"*) printf '%s\n' 'https://namespace.compat.objectstorage.eu-frankfurt-1.oci.customer-oci.com' ;;
  *"output -json deployment_summary"*) printf '%s\n' '{"bucket_name":"dicom-test"}' ;;
  *) exit 1 ;;
esac
STUB
cat >"${temporary_dir}/bin/curl" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == "--help all" ]]; then
  printf '%s\n' '  --aws-sigv4'
  exit 0
fi
printf '%s\n' "$*" >"${STORAGE_CURL_LOG}"
while (($#)); do
  if [[ "$1" == "--config" ]]; then
    shift
    cp "$1" "${STORAGE_CREDENTIAL_LOG}"
  fi
  shift
done
printf '200'
STUB
chmod 700 "${temporary_dir}/bin/terraform" "${temporary_dir}/bin/curl"

PATH="${temporary_dir}/bin:${PATH}" \
STORAGE_CURL_LOG="${temporary_dir}/curl.log" \
STORAGE_CREDENTIAL_LOG="${temporary_dir}/credential.log" \
  "${project_dir}/scripts/wait-for-storage-credentials.sh" >"${temporary_dir}/output.log"

grep -Fq 'externally managed S3 credential' "${temporary_dir}/output.log"
grep -Fq -- '--aws-sigv4 aws:amz:eu-frankfurt-1:s3' "${temporary_dir}/curl.log"
grep -Fq 'external-access:external-secret' "${temporary_dir}/credential.log"

printf 'Externally managed S3 credentials receive a signed readiness check.\n'
