#!/usr/bin/env bash

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/oci-dicom-cleanup-test.XXXXXX")"
trap 'rm -rf "${temporary_dir}"' EXIT

command_log="${temporary_dir}/commands.log"
export DESTROY_TEST_COMMAND_LOG="${command_log}"
export DESTROY_TEST_SSO_STATE="${temporary_dir}/sso-state"
printf 'false\n' >"${DESTROY_TEST_SSO_STATE}"
mkdir -p "${temporary_dir}/bin"

cat >"${temporary_dir}/bin/terraform" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'terraform' >>"${DESTROY_TEST_COMMAND_LOG}"
printf ' %q' "$@" >>"${DESTROY_TEST_COMMAND_LOG}"
printf '\n' >>"${DESTROY_TEST_COMMAND_LOG}"
if [[ "$1" == "show" ]]; then
  cat <<'JSON'
{
  "variables": {
    "oci_auth": {
      "value": "APIKey"
    },
    "oci_profile": {
      "value": "DEFAULT"
    },
    "region": {
      "value": "eu-frankfurt-1"
    }
  },
  "resource_changes": [
    {
      "address": "oci_containerengine_cluster.orthanc",
      "change": {
        "actions": [
          "delete"
        ],
        "before": {
          "id": "ocid1.cluster.test"
        }
      }
    },
    {
      "address": "oci_containerengine_node_pool.orthanc",
      "change": {
        "actions": [
          "delete"
        ],
        "before": {
          "id": "ocid1.nodepool.test"
        }
      }
    },
    {
      "address": "oci_core_private_ip.orthanc_nlb",
      "change": {
        "actions": [
          "delete"
        ],
        "before": {
          "id": "ocid1.privateip.test",
          "ip_address": "10.42.10.10",
          "compartment_id": "ocid1.compartment.test"
        }
      }
    },
    {
      "address": "oci_identity_domains_app.orthanc_sso[0]",
      "type": "oci_identity_domains_app",
      "change": {
        "actions": [
          "delete"
        ],
        "before": {
          "id": "test-app-id",
          "idcs_endpoint": "https://identity.example.test"
        }
      }
    },
    {
      "address": "oci_identity_domains_grant.orthanc_sso[\"orthanc-admin\"]",
      "type": "oci_identity_domains_grant",
      "change": {
        "actions": [
          "delete"
        ],
        "before": {
          "id": "test-grant-id"
        }
      }
    },
    {
      "address": "oci_core_public_ip.large_upload[0]",
      "change": {
        "actions": [
          "delete"
        ],
        "before": {
          "id": "ocid1.publicip.upload",
          "ip_address": "192.0.2.20",
          "compartment_id": "ocid1.compartment.test"
        }
      }
    }
  ]
}
JSON
fi
STUB

cat >"${temporary_dir}/bin/oci" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'oci' >>"${DESTROY_TEST_COMMAND_LOG}"
printf ' %q' "$@" >>"${DESTROY_TEST_COMMAND_LOG}"
printf '\n' >>"${DESTROY_TEST_COMMAND_LOG}"

case " $* " in
  *" identity-domains app get "*)
    printf '{"data":{"active":%s}}\n' "$(<"${DESTROY_TEST_SSO_STATE}")"
    ;;
  *" identity-domains app patch "*)
    case "$*" in
      *'"value":false'*) printf 'false\n' >"${DESTROY_TEST_SSO_STATE}" ;;
      *'"value":true'*) printf 'true\n' >"${DESTROY_TEST_SSO_STATE}" ;;
    esac
    ;;
  *" nlb network-load-balancer list "*)
    printf '%s\n' '{"data":{"items":[{"id":"ocid1.nlb.test","ip-addresses":[{"ip-address":"10.42.10.10","reserved-ip":{"id":"ocid1.privateip.test"}}]},{"id":"ocid1.nlb.upload","ip-addresses":[{"ip-address":"192.0.2.20","reserved-ip":{"id":"ocid1.publicip.upload"}}]},{"id":"ocid1.nlb.unrelated","ip-addresses":[{"ip-address":"192.0.2.99"}]}]}}'
    ;;
esac
STUB

cat >"${temporary_dir}/bin/ssh" <<'STUB'
#!/usr/bin/env bash
printf 'ssh must not be called during destroy\n' >&2
exit 99
STUB

chmod 0700 "${temporary_dir}/bin/terraform" \
  "${temporary_dir}/bin/oci" \
  "${temporary_dir}/bin/ssh"

PATH="${temporary_dir}/bin:${PATH}" \
  BASTION_SSH_PRIVATE_KEY_FILE=/does/not/exist \
  "${project_dir}/scripts/destroy.sh" --auto-approve

grep -Fq 'identity-domains app get --app-id test-app-id' "${command_log}"
[[ "$(grep -Fc 'identity-domains app patch --app-id test-app-id' "${command_log}")" == "2" ]]
grep -Fq -- '-target=oci_identity_domains_grant.orthanc_sso' "${command_log}"
grep -Fq -- '-target=oci_containerengine_node_pool.orthanc' "${command_log}"
grep -Fq -- '-target=oci_containerengine_cluster.orthanc' "${command_log}"
grep -Fq 'nlb network-load-balancer list' "${command_log}"
grep -Fq 'nlb network-load-balancer delete --network-load-balancer-id ocid1.nlb.test' "${command_log}"

[[ "$(grep -Fc 'terraform destroy -auto-approve' "${command_log}")" == "3" ]]

printf 'Destroy cleanup revokes SSO grants before deactivation and removes the exact OKE-managed NLB.\n'

grep -Fq 'nlb network-load-balancer delete --network-load-balancer-id ocid1.nlb.upload' "${command_log}"
if grep -Fq 'network-load-balancer delete --network-load-balancer-id ocid1.nlb.unrelated' "${command_log}"; then
  printf 'Destroy touched an unrelated load balancer.\n' >&2
  exit 1
fi
