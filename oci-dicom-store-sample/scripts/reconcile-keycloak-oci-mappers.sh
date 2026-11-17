#!/usr/bin/env bash

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
terraform_dir="${project_dir}/terraform"
check_only=false
umask 077

if [[ "${1:-}" == "--check" ]]; then
  check_only=true
  shift
fi
[[ $# -eq 0 ]] || {
  printf 'Usage: reconcile-keycloak-oci-mappers.sh [--check]\n' >&2
  exit 2
}

for command_name in curl jq terraform; do
  command -v "${command_name}" >/dev/null 2>&1 || {
    printf 'Required command is missing: %s\n' "${command_name}" >&2
    exit 1
  }
done

keycloak_url="$(terraform -chdir="${terraform_dir}" output -raw keycloak_endpoint)"
admin_username="$(terraform -chdir="${terraform_dir}" output -raw keycloak_admin_username)"
admin_password="$(terraform -chdir="${terraform_dir}" output -raw keycloak_admin_password)"
desired_realm="$(terraform -chdir="${terraform_dir}" output -json keycloak_reconciliation)"
realm_name="$(jq -er '.realm' <<<"${desired_realm}")"

temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/oci-dicom-keycloak-reconcile.XXXXXX")"
trap 'rm -rf "${temporary_dir}"' EXIT

admin_token="$(curl -fsS \
  -X POST \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode 'grant_type=password' \
  --data-urlencode 'client_id=admin-cli' \
  --data-urlencode "username=${admin_username}" \
  --data-urlencode "password=${admin_password}" \
  "${keycloak_url}/realms/master/protocol/openid-connect/token" | \
  jq -er '.access_token')"
unset admin_password

api_root="${keycloak_url}/admin/realms/${realm_name}"
request_number=0

urlencode() {
  jq -rn --arg value "$1" '$value | @uri'
}

request() {
  local method="$1"
  local path="$2"
  local body_file="${3:-}"
  local response_file
  local status
  local curl_args=(
    --silent
    --show-error
    --output "${temporary_dir}/unused"
    --write-out '%{http_code}'
    -X "${method}"
    -H "Authorization: Bearer ${admin_token}"
  )

  request_number=$((request_number + 1))
  response_file="$(mktemp "${temporary_dir}/response-${request_number}.XXXXXX")"
  curl_args[3]="${response_file}"
  if [[ -n "${body_file}" ]]; then
    curl_args+=(
      -H 'Content-Type: application/json'
      --data-binary "@${body_file}"
    )
  fi
  status="$(curl "${curl_args[@]}" "${api_root}${path}")"
  if [[ "${status}" != "200" && "${status}" != "201" && "${status}" != "204" ]]; then
    printf 'Keycloak Admin API %s %s returned HTTP %s.\n' \
      "${method}" "${path}" "${status}" >&2
    jq . "${response_file}" >&2 2>/dev/null || true
    exit 1
  fi
  cat "${response_file}"
}

reconcile_realm() {
  local actual_file="${temporary_dir}/realm-actual.json"
  local desired_settings_file="${temporary_dir}/realm-settings.json"
  local merged_file="${temporary_dir}/realm-merged.json"

  request GET '' >"${actual_file}"
  jq 'del(.roles, .clients, .users, .identityProviders, .identityProviderMappers)' \
    <<<"${desired_realm}" >"${desired_settings_file}"
  jq -s '.[0] * .[1]' "${actual_file}" "${desired_settings_file}" >"${merged_file}"
  request PUT '' "${merged_file}" >/dev/null
}

reconcile_roles() {
  local actual_roles
  local role_name
  local role_path
  local desired_role
  local role_file="${temporary_dir}/role.json"

  actual_roles="$(request GET '/roles')"
  while IFS= read -r desired_role; do
    role_name="$(jq -er '.name' <<<"${desired_role}")"
    role_path="$(urlencode "${role_name}")"
    jq . <<<"${desired_role}" >"${role_file}"
    if jq -e --arg name "${role_name}" 'any(.[]; .name == $name)' \
      <<<"${actual_roles}" >/dev/null; then
      request PUT "/roles/${role_path}" "${role_file}" >/dev/null
    else
      request POST '/roles' "${role_file}" >/dev/null
    fi
  done < <(jq -c '.roles.realm[]' <<<"${desired_realm}")

  while IFS= read -r role_name; do
    [[ -n "${role_name}" ]] || continue
    role_path="$(urlencode "${role_name}")"
    request DELETE "/roles/${role_path}" >/dev/null
  done < <(jq -r --argjson desired "$(jq '.roles.realm' <<<"${desired_realm}")" '
    .[]
    | .name as $name
    | select($name | startswith("tenant-"))
    | select(($desired | any(.[]; .name == $name)) | not)
    | .name
  ' <<<"${actual_roles}")
}

reconcile_client() {
  local desired_client
  local desired_client_file="${temporary_dir}/client-desired.json"
  local actual_clients
  local client_id
  local actual_client_file="${temporary_dir}/client-actual.json"
  local merged_client_file="${temporary_dir}/client-merged.json"
  local desired_mappers
  local actual_mappers
  local mapper
  local mapper_name
  local mapper_id
  local mapper_file="${temporary_dir}/client-mapper.json"

  desired_client="$(jq -ec '.clients | if length == 1 then .[0] else error("expected one managed client") end' <<<"${desired_realm}")"
  jq 'del(.protocolMappers)' <<<"${desired_client}" >"${desired_client_file}"
  actual_clients="$(request GET '/clients?clientId=orthanc')"
  client_id="$(jq -er '
    if length == 0 then ""
    elif length == 1 then .[0].id
    else error("more than one orthanc client exists")
    end
  ' <<<"${actual_clients}")"
  if [[ -z "${client_id}" ]]; then
    request POST '/clients' "${desired_client_file}" >/dev/null
    actual_clients="$(request GET '/clients?clientId=orthanc')"
    client_id="$(jq -er 'if length == 1 then .[0].id else error("expected one orthanc client") end' <<<"${actual_clients}")"
  else
    request GET "/clients/${client_id}" >"${actual_client_file}"
    jq -s '.[0] * .[1]' "${actual_client_file}" "${desired_client_file}" >"${merged_client_file}"
    request PUT "/clients/${client_id}" "${merged_client_file}" >/dev/null
  fi

  desired_mappers="$(jq -ec '.protocolMappers // []' <<<"${desired_client}")"
  actual_mappers="$(request GET "/clients/${client_id}/protocol-mappers/models")"
  while IFS= read -r mapper; do
    mapper_name="$(jq -er '.name' <<<"${mapper}")"
    mapper_id="$(jq -er --arg name "${mapper_name}" '
      [.[] | select(.name == $name)]
      | if length == 0 then ""
        elif length == 1 then .[0].id
        else error("duplicate managed client mapper")
        end
    ' <<<"${actual_mappers}")"
    if [[ -n "${mapper_id}" ]]; then
      jq --arg id "${mapper_id}" '. + {id: $id}' <<<"${mapper}" >"${mapper_file}"
      request PUT "/clients/${client_id}/protocol-mappers/models/${mapper_id}" "${mapper_file}" >/dev/null
    else
      jq . <<<"${mapper}" >"${mapper_file}"
      request POST "/clients/${client_id}/protocol-mappers/models" "${mapper_file}" >/dev/null
    fi
  done < <(jq -c '.[]' <<<"${desired_mappers}")

  while IFS= read -r mapper_id; do
    [[ -n "${mapper_id}" ]] || continue
    request DELETE "/clients/${client_id}/protocol-mappers/models/${mapper_id}" >/dev/null
  done < <(jq -r --argjson desired "${desired_mappers}" '
    .[]
    | .name as $name
    | select($name == "account audience")
    | select(($desired | any(.[]; .name == $name)) | not)
    | .id
  ' <<<"${actual_mappers}")
}

reconcile_users() {
  local desired_users
  local desired_user
  local username
  local encoded_username
  local users
  local user_id
  local user_file="${temporary_dir}/user.json"
  local existing_user_file="${temporary_dir}/user-existing.json"
  local merged_user_file="${temporary_dir}/user-merged.json"
  local password_file="${temporary_dir}/password.json"
  local actual_roles
  local desired_roles
  local role_name
  local role_json
  local roles_file="${temporary_dir}/user-roles.json"

  desired_users="$(jq -ec '.users' <<<"${desired_realm}")"
  while IFS= read -r desired_user; do
    username="$(jq -er '.username' <<<"${desired_user}")"
    encoded_username="$(urlencode "${username}")"
    users="$(request GET "/users?username=${encoded_username}&exact=true")"
    jq 'del(.credentials, .realmRoles)' <<<"${desired_user}" >"${user_file}"
    user_id="$(jq -er '
      if length == 0 then ""
      elif length == 1 then .[0].id
      else error("more than one managed username exists")
      end
    ' <<<"${users}")"
    if [[ -z "${user_id}" ]]; then
      request POST '/users' "${user_file}" >/dev/null
      users="$(request GET "/users?username=${encoded_username}&exact=true")"
      user_id="$(jq -er 'if length == 1 then .[0].id else error("expected one managed user") end' <<<"${users}")"
    else
      jq '.[0]' <<<"${users}" >"${existing_user_file}"
      jq -s '.[0] * .[1]' "${existing_user_file}" "${user_file}" >"${merged_user_file}"
      request PUT "/users/${user_id}" "${merged_user_file}" >/dev/null
    fi

    jq -e '.credentials | length == 1' <<<"${desired_user}" >/dev/null
    jq '.credentials[0]' <<<"${desired_user}" >"${password_file}"
    request PUT "/users/${user_id}/reset-password" "${password_file}" >/dev/null

    desired_roles="$(jq -ec '.realmRoles' <<<"${desired_user}")"
    actual_roles="$(request GET "/users/${user_id}/role-mappings/realm")"
    while IFS= read -r role_name; do
      role_json="$(request GET "/roles/$(urlencode "${role_name}")")"
      jq -n --argjson role "${role_json}" '[$role]' >"${roles_file}"
      request POST "/users/${user_id}/role-mappings/realm" "${roles_file}" >/dev/null
    done < <(jq -r '.[]' <<<"${desired_roles}")

    jq --argjson desired "${desired_roles}" '[
      .[]
      | select((.name | startswith("orthanc-")) or (.name | startswith("tenant-")))
      | select(.name as $name | $desired | index($name) | not)
    ]' <<<"${actual_roles}" >"${roles_file}"
    if [[ "$(jq 'length' "${roles_file}")" != "0" ]]; then
      request DELETE "/users/${user_id}/role-mappings/realm" "${roles_file}" >/dev/null
    fi
  done < <(jq -c '.[]' <<<"${desired_users}")

  while IFS=$'\t' read -r user_id username; do
    [[ -n "${user_id}" ]] || continue
    request DELETE "/users/${user_id}" >/dev/null
    printf 'Removed stale stack-managed Keycloak user %s.\n' "${username}"
  done < <(request GET '/users?max=1000' | jq -r --argjson desired "${desired_users}" '
    .[]
    | select(
        (.email | type == "string" and endswith("@local.invalid")) or
        (.attributes["oci-dicom-managed"] == ["true"])
      )
    | .username as $name
    | select(($desired | any(.[]; .username == $name)) | not)
    | [.id, .username]
    | @tsv
  ')
}

reconcile_identity_provider() {
  local desired_idps
  local desired_mappers
  local actual_idps
  local desired_idp
  local idp_file="${temporary_dir}/identity-provider.json"
  local actual_idp_file="${temporary_dir}/identity-provider-actual.json"
  local actual_mappers
  local desired_mapper
  local mapper_name
  local mapper_id
  local mapper_file="${temporary_dir}/identity-provider-mapper.json"

  desired_idps="$(jq -ec '.identityProviders // []' <<<"${desired_realm}")"
  desired_mappers="$(jq -ec '.identityProviderMappers // []' <<<"${desired_realm}")"
  actual_idps="$(request GET '/identity-provider/instances')"
  if [[ "$(jq 'length' <<<"${desired_idps}")" == "0" ]]; then
    if jq -e 'any(.[]; .alias == "oci")' <<<"${actual_idps}" >/dev/null; then
      request DELETE '/identity-provider/instances/oci' >/dev/null
    fi
    return
  fi

  desired_idp="$(jq -ec 'if length == 1 then .[0] else error("expected one identity provider") end' <<<"${desired_idps}")"
  if jq -e 'any(.[]; .alias == "oci")' <<<"${actual_idps}" >/dev/null; then
    request GET '/identity-provider/instances/oci' >"${actual_idp_file}"
    jq -n --slurpfile actual "${actual_idp_file}" --argjson desired "${desired_idp}" '
      $actual[0] as $existing
      | ($existing * $desired)
      | .config = ($existing.config * $desired.config)
    ' >"${idp_file}"
    request PUT '/identity-provider/instances/oci' "${idp_file}" >/dev/null
  else
    jq . <<<"${desired_idp}" >"${idp_file}"
    request POST '/identity-provider/instances' "${idp_file}" >/dev/null
  fi

  actual_mappers="$(request GET '/identity-provider/instances/oci/mappers')"
  while IFS= read -r desired_mapper; do
    mapper_name="$(jq -er '.name' <<<"${desired_mapper}")"
    mapper_id="$(jq -er --arg name "${mapper_name}" '
      [.[] | select(.name == $name)]
      | if length == 0 then ""
        elif length == 1 then .[0].id
        else error("duplicate managed identity-provider mapper")
        end
    ' <<<"${actual_mappers}")"
    if [[ -n "${mapper_id}" ]]; then
      jq --arg id "${mapper_id}" '. + {id: $id}' <<<"${desired_mapper}" >"${mapper_file}"
      request PUT "/identity-provider/instances/oci/mappers/${mapper_id}" "${mapper_file}" >/dev/null
    else
      jq . <<<"${desired_mapper}" >"${mapper_file}"
      request POST '/identity-provider/instances/oci/mappers' "${mapper_file}" >/dev/null
    fi
  done < <(jq -c '.[]' <<<"${desired_mappers}")

  while IFS= read -r mapper_id; do
    [[ -n "${mapper_id}" ]] || continue
    request DELETE "/identity-provider/instances/oci/mappers/${mapper_id}" >/dev/null
  done < <(jq -r --argjson desired "${desired_mappers}" '
    .[]
    | .name as $name
    | select($name | startswith("OCI "))
    | select(($desired | any(.[]; .name == $name)) | not)
    | .id
  ' <<<"${actual_mappers}")
}

verify_configuration() {
  local actual_realm
  local desired_settings
  local actual_roles
  local desired_client
  local clients
  local client_id
  local actual_client
  local actual_client_mappers
  local desired_users
  local desired_user
  local username
  local users
  local user_id
  local actual_user_roles
  local desired_idps
  local actual_idps
  local actual_idp
  local actual_idp_mappers

  actual_realm="$(request GET '')"
  desired_settings="$(jq 'del(.roles, .clients, .users, .identityProviders, .identityProviderMappers)' <<<"${desired_realm}")"
  jq -e --argjson desired "${desired_settings}" 'contains($desired)' <<<"${actual_realm}" >/dev/null || {
    printf 'Keycloak realm settings do not match Terraform.\n' >&2
    return 1
  }

  actual_roles="$(request GET '/roles')"
  jq -e --argjson desired "$(jq '.roles.realm' <<<"${desired_realm}")" '
    [.[] | .name] as $actual_names
    | [$desired[] | .name] as $desired_names
    | (($desired_names - $actual_names) | length == 0)
    and (([$actual_names[] | select(startswith("tenant-"))] - $desired_names) | length == 0)
  ' <<<"${actual_roles}" >/dev/null || {
    printf 'Keycloak realm roles do not match Terraform.\n' >&2
    return 1
  }

  desired_client="$(jq -ec '.clients[0]' <<<"${desired_realm}")"
  clients="$(request GET '/clients?clientId=orthanc')"
  client_id="$(jq -er 'if length == 1 then .[0].id else error("expected one orthanc client") end' <<<"${clients}")"
  actual_client="$(request GET "/clients/${client_id}")"
  jq -e --argjson desired "$(jq 'del(.protocolMappers)' <<<"${desired_client}")" \
    'contains($desired)' <<<"${actual_client}" >/dev/null || {
    printf 'Keycloak Orthanc client does not match Terraform.\n' >&2
    return 1
  }
  actual_client_mappers="$(request GET "/clients/${client_id}/protocol-mappers/models")"
  jq -e --argjson desired "$(jq '.protocolMappers // []' <<<"${desired_client}")" '
    . as $actual
    | $desired
    | all(.[]; . as $expected | $actual | any(.[];
        .name == $expected.name and .protocolMapper == $expected.protocolMapper))
  ' <<<"${actual_client_mappers}" >/dev/null || {
    printf 'Keycloak Orthanc client mappers do not match Terraform.\n' >&2
    return 1
  }

  desired_users="$(jq -ec '.users' <<<"${desired_realm}")"
  while IFS= read -r desired_user; do
    username="$(jq -er '.username' <<<"${desired_user}")"
    users="$(request GET "/users?username=$(urlencode "${username}")&exact=true")"
    user_id="$(jq -er 'if length == 1 then .[0].id else error("expected one managed user") end' <<<"${users}")"
    jq -e --argjson desired "$(jq 'del(.credentials, .realmRoles)' <<<"${desired_user}")" \
      '.[0] | contains($desired)' <<<"${users}" >/dev/null || {
      printf 'Keycloak user %s does not match Terraform.\n' "${username}" >&2
      return 1
    }
    actual_user_roles="$(request GET "/users/${user_id}/role-mappings/realm")"
    jq -e --argjson desired "$(jq '.realmRoles' <<<"${desired_user}")" '
      [.[] | .name] as $actual_names
      | (($desired - $actual_names) | length == 0)
    ' <<<"${actual_user_roles}" >/dev/null || {
      printf 'Keycloak user %s role mappings do not match Terraform.\n' "${username}" >&2
      return 1
    }
  done < <(jq -c '.[]' <<<"${desired_users}")

  desired_idps="$(jq -ec '.identityProviders // []' <<<"${desired_realm}")"
  actual_idps="$(request GET '/identity-provider/instances')"
  if [[ "$(jq 'length' <<<"${desired_idps}")" == "0" ]]; then
    jq -e 'any(.[]; .alias == "oci") | not' <<<"${actual_idps}" >/dev/null || {
      printf 'Keycloak OCI identity provider exists while SSO is disabled.\n' >&2
      return 1
    }
  else
    actual_idp="$(request GET '/identity-provider/instances/oci')"
    # Keycloak masks a persisted client secret in Admin API responses, so its
    # read-back value cannot equal the secret Terraform supplied. Verify that
    # a value is present, then compare every non-secret provider setting.
    jq -e --argjson desired "$(jq '.[0] | del(.config.clientSecret)' <<<"${desired_idps}")" '
      (.config.clientSecret | type == "string" and length > 0) and
      (del(.config.clientSecret) | contains($desired))
    ' <<<"${actual_idp}" >/dev/null || {
      printf 'Keycloak OCI identity provider does not match Terraform.\n' >&2
      return 1
    }
    actual_idp_mappers="$(request GET '/identity-provider/instances/oci/mappers')"
    jq -e --argjson desired "$(jq '.identityProviderMappers // []' <<<"${desired_realm}")" '
      . as $actual
      | $desired
      | all(.[]; . as $expected | $actual | any(.[];
          .name == $expected.name and
          .identityProviderMapper == $expected.identityProviderMapper and
          .config == $expected.config))
    ' <<<"${actual_idp_mappers}" >/dev/null || {
      printf 'Keycloak OCI identity-provider mappers do not match Terraform.\n' >&2
      return 1
    }
  fi
}

if [[ "${check_only}" == false ]]; then
  reconcile_realm
  reconcile_roles
  reconcile_client
  reconcile_users
  reconcile_identity_provider
fi

verify_configuration
if [[ "${check_only}" == true ]]; then
  printf 'OK  Keycloak realm, roles, client, users, and identity provider match Terraform.\n'
else
  printf 'Reconciled Keycloak realm, roles, client, users, and identity provider.\n'
fi
