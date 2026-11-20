#!/usr/bin/env bash

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
terraform_dir="${project_dir}/terraform"
source "${project_dir}/scripts/ssh-trust.sh"
private_key="${BASTION_SSH_PRIVATE_KEY_FILE:-}"
auto_approve=false
backup_id=""
restored_db_id=""
backup_name=""
restore_name=""
temporary_dir=""
bastion_ip=""
compartment_id=""

usage() {
  cat <<'USAGE'
Usage: scripts/restore-drill.sh --private-key PATH [--auto-approve]

Creates an on-demand OCI PostgreSQL backup, provisions a one-node temporary
database system from it, validates restored Orthanc/Keycloak tables through
the bastion, and deletes both temporary resources. This incurs temporary OCI
database and backup charges and can take more than an hour.
USAGE
}

while (($#)); do
  case "$1" in
    --private-key) private_key="${2:-}"; shift ;;
    --auto-approve) auto_approve=true ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

[[ -f "${private_key}" ]] || { printf 'Private key not found: %s\n' "${private_key}" >&2; exit 2; }
for command_name in terraform oci jq ssh scp grep sed; do
  command -v "${command_name}" >/dev/null 2>&1 || {
    printf 'Required command is missing: %s\n' "${command_name}" >&2
    exit 1
  }
done

context="$(terraform -chdir="${terraform_dir}" output -json acceptance_context)"
summary="$(terraform -chdir="${terraform_dir}" output -json deployment_summary)"
bastion_ip="$(jq -r '.bastion_public_ip' <<<"${summary}")"
deployment_name="$(jq -r '.name' <<<"${summary}")"
db_username="$(terraform -chdir="${terraform_dir}" output -raw postgres_username)"
db_password="$(terraform -chdir="${terraform_dir}" output -raw postgres_password)"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/oci-dicom-restore.XXXXXX")"
oci_dicom_prepare_ssh_trust "${terraform_dir}"

oci_args=(--region "$(jq -r '.region' <<<"${context}")")
case "$(jq -r '.auth' <<<"${context}")" in
  APIKey) oci_args+=(--profile "$(jq -r '.profile' <<<"${context}")" --auth api_key) ;;
  SecurityToken) oci_args+=(--profile "$(jq -r '.profile' <<<"${context}")" --auth security_token) ;;
  InstancePrincipal) oci_args+=(--auth instance_principal) ;;
  ResourcePrincipal) oci_args+=(--auth resource_principal) ;;
  OKEWorkloadIdentity) oci_args+=(--auth oke_workload_identity) ;;
  *) printf 'Unsupported OCI authentication mode.\n' >&2; exit 1 ;;
esac

lookup_backup_id() {
  oci "${oci_args[@]}" psql backup-collection list-backups \
    --compartment-id "${compartment_id}" --display-name "${backup_name}" --all |
    jq -er --arg name "${backup_name}" '
      [.data.items[]? |
       select(."display-name" == $name and
              (.id | type == "string") and
              (.id | startswith("ocid1.postgresqlbackup.")) and
              ."lifecycle-state" != "DELETED") |
       .id] | if length == 1 then .[0] else empty end'
}

lookup_restored_db_id() {
  oci "${oci_args[@]}" psql db-system-collection list-db-systems \
    --compartment-id "${compartment_id}" --display-name "${restore_name}" --all |
    jq -er --arg name "${restore_name}" '
      [.data.items[]? |
       select(."display-name" == $name and
              (.id | type == "string") and
              (.id | startswith("ocid1.postgresqldbsystem.")) and
              ."lifecycle-state" != "DELETED") |
       .id] | if length == 1 then .[0] else empty end'
}

discover_resource_id() {
  local lookup_function="$1"
  local discovered_id=""
  for _ in $(seq 1 24); do
    discovered_id="$(${lookup_function} 2>/dev/null || true)"
    if [[ -n "${discovered_id}" ]]; then
      printf '%s\n' "${discovered_id}"
      return 0
    fi
    sleep 5
  done
  return 1
}

delete_and_wait() {
  local resource_type="$1"
  local resource_id="$2"
  local id_option="$3"
  local timeout_seconds="$4"
  local error_file="${temporary_dir}/${resource_type}-delete-error.log"
  local deadline=$((SECONDS + timeout_seconds))
  local resource_json
  local lifecycle_state

  if ! oci "${oci_args[@]}" psql "${resource_type}" delete \
    "${id_option}" "${resource_id}" --force >/dev/null 2>"${error_file}"; then
    if grep -Eq '(^|[^0-9])404([^0-9]|$)|NotAuthorizedOrNotFound|not found' "${error_file}"; then
      return 0
    fi
    printf 'Unable to request deletion of %s %s:\n' \
      "${resource_type}" "${resource_id}" >&2
    sed -n '1,20p' "${error_file}" >&2
    return 1
  fi

  while ((SECONDS < deadline)); do
    if resource_json="$(oci "${oci_args[@]}" psql "${resource_type}" get \
      "${id_option}" "${resource_id}" 2>"${error_file}")"; then
      lifecycle_state="$(jq -r '.data."lifecycle-state" // "UNKNOWN"' <<<"${resource_json}")"
      case "${lifecycle_state}" in
        DELETED) return 0 ;;
        FAILED)
          printf '%s %s entered FAILED while deleting.\n' \
            "${resource_type}" "${resource_id}" >&2
          return 1
          ;;
      esac
    elif grep -Eq '(^|[^0-9])404([^0-9]|$)|NotAuthorizedOrNotFound|not found' "${error_file}"; then
      return 0
    else
      printf 'Unable to verify deletion of %s %s:\n' \
        "${resource_type}" "${resource_id}" >&2
      sed -n '1,20p' "${error_file}" >&2
      return 1
    fi
    sleep 30
  done
  printf 'Timed out after %s seconds waiting for %s %s deletion.\n' \
    "${timeout_seconds}" "${resource_type}" "${resource_id}" >&2
  return 1
}

cleanup() {
  cleanup_status=0
  if [[ -z "${restored_db_id}" && -n "${restore_name}" ]]; then
    restored_db_id="$(discover_resource_id lookup_restored_db_id || true)"
  fi
  if [[ -n "${restored_db_id}" ]]; then
    printf 'Deleting temporary restored database %s...\n' "${restored_db_id}"
    delete_and_wait db-system "${restored_db_id}" --db-system-id 7200 || cleanup_status=1
  fi
  if [[ -z "${backup_id}" && -n "${backup_name}" ]]; then
    backup_id="$(discover_resource_id lookup_backup_id || true)"
  fi
  if [[ -n "${backup_id}" ]]; then
    printf 'Deleting temporary backup %s...\n' "${backup_id}"
    delete_and_wait backup "${backup_id}" --backup-id 3600 || cleanup_status=1
  fi
  [[ -z "${temporary_dir}" ]] || rm -rf "${temporary_dir}"
  return "${cleanup_status}"
}
trap cleanup EXIT

if [[ "${auto_approve}" != true ]]; then
  printf '%s\n' \
    'This drill creates a billable manual backup and temporary one-node PostgreSQL system.' \
    'Both resources are deleted automatically after validation.'
  read -r -p 'Type restore-drill to continue: ' confirmation
  [[ "${confirmation}" == "restore-drill" ]] || { printf 'Restore drill cancelled.\n'; exit 1; }
fi

compartment_id="$(jq -r '.compartment_id' <<<"${context}")"
source_db_id="$(jq -r '.postgres_id' <<<"${context}")"
timestamp="$(date -u +%Y%m%d%H%M%S)"
backup_name="${deployment_name}-restore-drill-${timestamp}"
printf 'Creating on-demand backup %s...\n' "${backup_name}"
oci "${oci_args[@]}" psql backup create \
  --compartment-id "${compartment_id}" \
  --db-system-id "${source_db_id}" \
  --display-name "${backup_name}" \
  --retention-period 1 >/dev/null
backup_id="$(discover_resource_id lookup_backup_id)" || {
  printf 'OCI did not publish the OCID for backup %s.\n' "${backup_name}" >&2
  exit 1
}
backup_state=""
for _ in $(seq 1 240); do
  backup_state="$(oci "${oci_args[@]}" psql backup get --backup-id "${backup_id}" |
    jq -r '.data."lifecycle-state"')"
  case "${backup_state}" in
    ACTIVE) break ;;
    FAILED|DELETED) break ;;
  esac
  sleep 30
done
[[ "${backup_state}" == "ACTIVE" ]] || {
  printf 'Backup %s ended in state %s.\n' "${backup_id}" "${backup_state}" >&2
  exit 1
}
printf 'Backup is ACTIVE: %s\n' "${backup_id}"

jq -nc \
  --arg subnet "$(jq -r '.postgres_subnet_id' <<<"${context}")" \
  --argjson nsgs "$(jq '.postgres_nsg_ids' <<<"${context}")" \
  '{subnetId:$subnet,nsgIds:$nsgs}' >"${temporary_dir}/network.json"
jq -nc '{systemType:"OCI_OPTIMIZED_STORAGE",isRegionallyDurable:true}' \
  >"${temporary_dir}/storage.json"
jq -nc --arg username "${db_username}" --arg password "${db_password}" \
  '{username:$username,passwordDetails:{passwordType:"PLAIN_TEXT",password:$password}}' \
  >"${temporary_dir}/credentials.json"
chmod 600 "${temporary_dir}/credentials.json"

restore_name="${deployment_name}-restored-${timestamp}"
printf 'Creating temporary database %s from backup...\n' "${restore_name}"
oci "${oci_args[@]}" psql db-system create-db-system-backup-source-details \
  --compartment-id "${compartment_id}" \
  --credentials "file://${temporary_dir}/credentials.json" \
  --db-version "$(jq -r '.postgres_version' <<<"${context}")" \
  --display-name "${restore_name}" \
  --network-details "file://${temporary_dir}/network.json" \
  --shape "$(jq -r '.postgres_shape' <<<"${context}")" \
  --source-backup-id "${backup_id}" \
  --storage-details "file://${temporary_dir}/storage.json" \
  --system-type OCI_OPTIMIZED_STORAGE \
  --instance-count 1 \
  --instance-ocpu-count 1 \
  --instance-memory-size-in-gbs 16 >/dev/null
restored_db_id="$(discover_resource_id lookup_restored_db_id)" || {
  printf 'OCI did not publish the OCID for restored database %s.\n' "${restore_name}" >&2
  exit 1
}
restored_state=""
restored_db_json=""
for _ in $(seq 1 240); do
  restored_db_json="$(oci "${oci_args[@]}" psql db-system get --db-system-id "${restored_db_id}")"
  restored_state="$(jq -r '.data."lifecycle-state"' <<<"${restored_db_json}")"
  case "${restored_state}" in
    ACTIVE) break ;;
    FAILED|DELETED) break ;;
  esac
  sleep 30
done
[[ "${restored_state}" == "ACTIVE" ]] || {
  printf 'Restored database %s ended in state %s.\n' "${restored_db_id}" "${restored_state}" >&2
  exit 1
}
restored_ip="$(jq -er '.data."network-details"."primary-db-endpoint-private-ip"' <<<"${restored_db_json}")"

pgpass_file="${temporary_dir}/pgpass"
pgpass_password="${db_password//\\/\\\\}"
pgpass_password="${pgpass_password//:/\\:}"
printf '%s:5432:postgres:%s:%s\n' "${restored_ip}" "${db_username}" "${pgpass_password}" >"${pgpass_file}"
chmod 600 "${pgpass_file}"
remote_pgpass="/tmp/oci-dicom-restore-${timestamp}.pgpass"
ssh_common=(
  -i "${private_key}"
  "${OCI_DICOM_SSH_TRUST_OPTIONS[@]}"
)
scp "${ssh_common[@]}" "${pgpass_file}" "opc@${bastion_ip}:${remote_pgpass}"
table_count="$(ssh "${ssh_common[@]}" "opc@${bastion_ip}" \
  "chmod 600 '${remote_pgpass}'; trap 'rm -f \"${remote_pgpass}\"' EXIT; PGPASSFILE='${remote_pgpass}' PGSSLMODE=require psql -h '${restored_ip}' -U '${db_username}' -d postgres -tAc \"SELECT count(*) FROM information_schema.tables WHERE table_schema IN ('public', 'keycloak')\"")"
table_count="$(tr -d '[:space:]' <<<"${table_count}")"
[[ "${table_count}" =~ ^[0-9]+$ ]] && ((table_count > 0)) || {
  printf 'Restored database contained no Orthanc/Keycloak tables (result: %s).\n' "${table_count}" >&2
  exit 1
}

printf 'OK  Backup/restore drill: restored %s application tables into %s.\n' \
  "${table_count}" "${restored_db_id}"
printf 'Temporary backup and database will now be deleted.\n'
