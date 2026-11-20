#!/usr/bin/env bash

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/deploy-oke.sh [--private-key PATH] [--user USER]

Renders the sensitive OKE manifest from Terraform outputs, transfers it over
SSH to the configured bastion, applies it to the private OKE cluster, waits for
the workloads and internal NLB, and removes both temporary manifest copies.
USAGE
}

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
terraform_dir="${project_dir}/terraform"
source "${project_dir}/scripts/ssh-trust.sh"
private_key="${BASTION_SSH_PRIVATE_KEY_FILE:-}"
ssh_user="opc"
umask 077

while (($#)); do
  case "$1" in
    --private-key)
      [[ $# -ge 2 ]] || { printf '%s\n' '--private-key requires a path' >&2; exit 2; }
      private_key="$2"
      shift
      ;;
    --user)
      [[ $# -ge 2 ]] || { printf '%s\n' '--user requires a value' >&2; exit 2; }
      ssh_user="$2"
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

for command_name in terraform jq ssh scp; do
  command -v "${command_name}" >/dev/null 2>&1 || {
    printf 'Required command is missing: %s\n' "${command_name}" >&2
    exit 1
  }
done

[[ -n "${private_key}" ]] || {
  printf 'Set BASTION_SSH_PRIVATE_KEY_FILE or pass --private-key.\n' >&2
  exit 2
}
[[ -f "${private_key}" ]] || {
  printf 'SSH private key does not exist: %s\n' "${private_key}" >&2
  exit 2
}

private_key="$(cd "$(dirname "${private_key}")" && pwd)/$(basename "${private_key}")"
deployment_summary="$(terraform -chdir="${terraform_dir}" output -json deployment_summary)"
bastion_ip="$(jq -er '.bastion_public_ip' <<<"${deployment_summary}")"
namespace="$(jq -er '.name' <<<"${deployment_summary}")"
expected_nlb_ip="$(jq -er '.nlb_private_ip' <<<"${deployment_summary}")"
expected_orthanc_replicas="$(jq -er '.orthanc_replicas' <<<"${deployment_summary}")"
calico_profile="$(jq -er '.calico_profile' <<<"${deployment_summary}")"
calico_source_dir="${project_dir}/kubernetes/calico/${calico_profile}"
[[ -f "${calico_source_dir}/kustomization.yaml" ]] || {
  printf 'No Calico policy-only profile for Kubernetes minor %s.\n' "${calico_profile}" >&2
  exit 1
}
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/oci-dicom-oke.XXXXXX")"
manifest_file="${temporary_dir}/stack.yaml"
remote_manifest="/tmp/oci-dicom-stack-${namespace}.yaml"
remote_calico_dir="/tmp/oci-dicom-calico-${namespace}"
oci_dicom_prepare_ssh_trust "${terraform_dir}"

cleanup() {
  ssh \
    -i "${private_key}" \
    "${OCI_DICOM_SSH_TRUST_OPTIONS[@]}" \
    "${ssh_user}@${bastion_ip}" \
    "rm -f '${remote_manifest}'; rm -rf '${remote_calico_dir}'" >/dev/null 2>&1 || true
  rm -rf "${temporary_dir}"
}
trap cleanup EXIT

terraform -chdir="${terraform_dir}" output -raw oke_manifest >"${manifest_file}"
chmod 600 "${manifest_file}"

ssh \
  -i "${private_key}" \
  "${OCI_DICOM_SSH_TRUST_OPTIONS[@]}" \
  "${ssh_user}@${bastion_ip}" \
  "rm -rf '${remote_calico_dir}'; mkdir -m 700 -p '${remote_calico_dir}/${calico_profile}' '${remote_calico_dir}/policy-only'"

scp \
  -i "${private_key}" \
  "${OCI_DICOM_SSH_TRUST_OPTIONS[@]}" \
  "${project_dir}/kubernetes/calico/policy-only/kustomization.yaml" \
  "${ssh_user}@${bastion_ip}:${remote_calico_dir}/policy-only/kustomization.yaml"

scp \
  -i "${private_key}" \
  "${OCI_DICOM_SSH_TRUST_OPTIONS[@]}" \
  "${calico_source_dir}/kustomization.yaml" \
  "${ssh_user}@${bastion_ip}:${remote_calico_dir}/${calico_profile}/kustomization.yaml"

scp \
  -i "${private_key}" \
  "${OCI_DICOM_SSH_TRUST_OPTIONS[@]}" \
  "${manifest_file}" \
  "${ssh_user}@${bastion_ip}:${remote_manifest}"

ssh \
  -i "${private_key}" \
  "${OCI_DICOM_SSH_TRUST_OPTIONS[@]}" \
  "${ssh_user}@${bastion_ip}" \
  bash -s -- "${remote_manifest}" "${namespace}" "${expected_nlb_ip}" "${remote_calico_dir}" "${calico_profile}" "${expected_orthanc_replicas}" <<'REMOTE'
set -euo pipefail
manifest_file="$1"
namespace="$2"
expected_nlb_ip="$3"
calico_dir="$4"
calico_profile="$5"
expected_orthanc_replicas="$6"

/usr/local/bin/kubectl apply -k "${calico_dir}/${calico_profile}"
/usr/local/bin/kubectl -n kube-system rollout status \
  daemonset/calico-node \
  --timeout=15m
/usr/local/bin/kubectl -n kube-system rollout status \
  deployment/calico-kube-controllers \
  --timeout=15m
rm -rf "${calico_dir}"

chmod 600 "${manifest_file}"
bootstrap_job="$(awk '
  $1 == "kind:" && $2 == "Job" { in_job = 1; next }
  in_job && $1 == "name:" { print $2; exit }
' "${manifest_file}")"
[[ "${bootstrap_job}" =~ ^keycloak-database-bootstrap-[a-f0-9]{12}$ ]] || {
  printf 'Unable to identify the Keycloak bootstrap Job in %s.\n' \
    "${manifest_file}" >&2
  exit 1
}

if /usr/local/bin/kubectl -n "${namespace}" get \
  "job/${bootstrap_job}" >/dev/null 2>&1; then
  bootstrap_complete="$(
    /usr/local/bin/kubectl -n "${namespace}" get \
      "job/${bootstrap_job}" \
      --output=jsonpath='{.status.succeeded}'
  )"
  if [[ "${bootstrap_complete}" != "1" ]]; then
    /usr/local/bin/kubectl -n "${namespace}" delete \
      "job/${bootstrap_job}" \
      --wait=true
  fi
fi

/usr/local/bin/kubectl apply -f "${manifest_file}"
rm -f "${manifest_file}"

/usr/local/bin/kubectl -n "${namespace}" wait \
  --for=condition=complete \
  "job/${bootstrap_job}" \
  --timeout=15m

while IFS= read -r stale_job; do
  [[ "${stale_job}" == "job.batch/${bootstrap_job}" ]] && continue
  /usr/local/bin/kubectl -n "${namespace}" delete \
    "${stale_job}" \
    --ignore-not-found \
    --wait=false
done < <(
  /usr/local/bin/kubectl -n "${namespace}" get jobs \
    --selector=app.kubernetes.io/name=keycloak-database-bootstrap \
    --output=name
)

for deployment in keycloak orthanc-auth-service orthanc dicom-gateway; do
  /usr/local/bin/kubectl -n "${namespace}" rollout status \
    "deployment/${deployment}" \
    --timeout=20m
done

orthanc_status="$(
  /usr/local/bin/kubectl -n "${namespace}" get deployment orthanc \
    --output=jsonpath='{.status.updatedReplicas} {.status.readyReplicas} {.status.availableReplicas}'
)"
read -r orthanc_updated orthanc_ready orthanc_available <<<"${orthanc_status}"
if [[ "${orthanc_updated}" != "${expected_orthanc_replicas}" ||
      "${orthanc_ready}" != "${expected_orthanc_replicas}" ||
      "${orthanc_available}" != "${expected_orthanc_replicas}" ]]; then
  printf 'Orthanc replica validation failed: expected=%s, updated=%s, ready=%s, available=%s.\n' \
    "${expected_orthanc_replicas}" "${orthanc_updated:-0}" \
    "${orthanc_ready:-0}" "${orthanc_available:-0}" >&2
  exit 1
fi
orthanc_node_count="$(
  /usr/local/bin/kubectl -n "${namespace}" get pods \
    --selector=app.kubernetes.io/name=orthanc \
    --field-selector=status.phase=Running \
    --output=jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' |
    sort -u | sed '/^$/d' | wc -l | tr -d ' '
)"
if ((orthanc_node_count < 2)); then
  printf 'Orthanc replicas are running on only %s worker node(s); expected at least 2.\n' \
    "${orthanc_node_count}" >&2
  exit 1
fi
printf 'Orthanc HA ready: %s replicas across %s worker nodes.\n' \
  "${orthanc_available}" "${orthanc_node_count}"

for attempt in $(seq 1 60); do
  actual_nlb_ip="$(
    /usr/local/bin/kubectl -n "${namespace}" get service dicom-gateway \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true
  )"
  if [[ "${actual_nlb_ip}" == "${expected_nlb_ip}" ]]; then
    printf 'OKE internal NLB is ready at %s.\n' "${actual_nlb_ip}"
    break
  fi
  if [[ -n "${actual_nlb_ip}" ]]; then
    printf 'Waiting for reserved NLB IP %s (controller currently reports %s)...\n' \
      "${expected_nlb_ip}" "${actual_nlb_ip}"
  fi
  sleep 10
done

if [[ "${actual_nlb_ip}" != "${expected_nlb_ip}" ]]; then
  /usr/local/bin/kubectl -n "${namespace}" describe service dicom-gateway >&2
  printf 'OKE internal NLB did not acquire reserved IP %s within 10 minutes.\n' "${expected_nlb_ip}" >&2
  exit 1
fi

if /usr/local/bin/kubectl -n "${namespace}" get service dicom-large-upload >/dev/null 2>&1; then
  expected_upload_ip="$(/usr/local/bin/kubectl -n "${namespace}" get service dicom-large-upload -o go-template='{{index .metadata.annotations "oci.oraclecloud.com/reserved-ips"}}')"
  for attempt in $(seq 1 60); do
    upload_ips="$(/usr/local/bin/kubectl -n "${namespace}" get service dicom-large-upload -o jsonpath='{.status.loadBalancer.ingress[*].ip}')"
    if [[ " ${upload_ips} " == *" ${expected_upload_ip} "* ]]; then
      printf 'Large-upload HTTPS NLB is ready at %s.\n' "${expected_upload_ip}"
      exit 0
    fi
    sleep 10
  done
  /usr/local/bin/kubectl -n "${namespace}" describe service dicom-large-upload >&2
  printf 'Large-upload NLB did not acquire its reserved IP within 10 minutes.\n' >&2
  exit 1
fi
REMOTE

"${project_dir}/scripts/reconcile-keycloak-oci-mappers.sh"

printf 'OKE Orthanc, authorization service, Keycloak, and NLB deployment completed.\n'
