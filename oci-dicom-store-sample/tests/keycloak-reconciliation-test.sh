#!/usr/bin/env bash

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/oci-dicom-keycloak-test.XXXXXX")"
server_pid=""
cleanup() {
  if [[ -n "${server_pid}" ]]; then
    kill "${server_pid}" >/dev/null 2>&1 || true
    wait "${server_pid}" 2>/dev/null || true
  fi
  rm -rf "${temporary_dir}"
}
trap cleanup EXIT
mkdir -p "${temporary_dir}/bin"

cat >"${temporary_dir}/server.py" <<'PY'
import json
import sys
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

state = {
    "realm": {"realm": "orthanc", "enabled": False, "internal": "preserve"},
    "roles": [{"id": "role-default", "name": "default-roles-orthanc"},
              {"id": "role-stale", "name": "tenant-stale-viewer"}],
    "clients": [],
    "client_mappers": {},
    "users": [{"id": "user-stale", "username": "stale", "email": "stale@local.invalid"}],
    "user_roles": {"user-stale": []},
    "idps": [],
    "idp_mappers": [],
}
counter = {"value": 0}

def new_id(prefix):
    counter["value"] += 1
    return f"{prefix}-{counter['value']}"

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def body(self):
        length = int(self.headers.get("Content-Length", "0"))
        return json.loads(self.rfile.read(length) or b"{}")

    def reply(self, status=200, value=None):
        data = b"" if value is None else json.dumps(value).encode()
        self.send_response(status)
        if data:
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if data:
            self.wfile.write(data)

    def route(self):
        parsed = urllib.parse.urlparse(self.path)
        prefix = "/keycloak/admin/realms/orthanc"
        return parsed.path[len(prefix):], urllib.parse.parse_qs(parsed.query)

    def do_GET(self):
        if self.path == "/state":
            return self.reply(value=state)
        path, query = self.route()
        if path == "":
            return self.reply(value=state["realm"])
        if path == "/roles":
            return self.reply(value=state["roles"])
        if path.startswith("/roles/"):
            name = urllib.parse.unquote(path.split("/", 2)[2])
            return self.reply(value=next(role for role in state["roles"] if role["name"] == name))
        if path == "/clients":
            client_id = query.get("clientId", [None])[0]
            return self.reply(value=[item for item in state["clients"] if item.get("clientId") == client_id])
        if path.startswith("/clients/") and path.endswith("/protocol-mappers/models"):
            client = path.split("/")[2]
            return self.reply(value=state["client_mappers"].get(client, []))
        if path.startswith("/clients/"):
            client = path.split("/")[2]
            return self.reply(value=next(item for item in state["clients"] if item["id"] == client))
        if path == "/users":
            username = query.get("username", [None])[0]
            users = state["users"] if username is None else [item for item in state["users"] if item["username"] == username]
            return self.reply(value=users)
        if path.endswith("/role-mappings/realm"):
            user = path.split("/")[2]
            return self.reply(value=state["user_roles"].get(user, []))
        if path == "/identity-provider/instances":
            return self.reply(value=state["idps"])
        if path == "/identity-provider/instances/oci":
            item = next(item for item in state["idps"] if item["alias"] == "oci")
            value = {**item, "config": dict(item.get("config", {}))}
            if "clientSecret" in value["config"]:
                value["config"]["clientSecret"] = "**********"
            return self.reply(value=value)
        if path == "/identity-provider/instances/oci/mappers":
            return self.reply(value=state["idp_mappers"])
        self.reply(404, {"path": path})

    def do_POST(self):
        if self.path == "/keycloak/realms/master/protocol/openid-connect/token":
            return self.reply(value={"access_token": "test-token"})
        path, _ = self.route()
        body = self.body()
        if path == "/roles":
            body["id"] = new_id("role")
            state["roles"].append(body)
            return self.reply(201)
        if path == "/clients":
            body["id"] = new_id("client")
            state["clients"].append(body)
            state["client_mappers"][body["id"]] = []
            return self.reply(201)
        if path.endswith("/protocol-mappers/models") and path.startswith("/clients/"):
            client = path.split("/")[2]
            body["id"] = new_id("client-mapper")
            state["client_mappers"][client].append(body)
            return self.reply(201)
        if path == "/users":
            body["id"] = new_id("user")
            state["users"].append(body)
            state["user_roles"][body["id"]] = []
            return self.reply(201)
        if path.endswith("/role-mappings/realm"):
            user = path.split("/")[2]
            known = {item["name"] for item in state["user_roles"].get(user, [])}
            state["user_roles"].setdefault(user, []).extend(item for item in body if item["name"] not in known)
            return self.reply(204)
        if path == "/identity-provider/instances":
            body["internalId"] = new_id("idp")
            state["idps"].append(body)
            return self.reply(201)
        if path == "/identity-provider/instances/oci/mappers":
            body["id"] = new_id("idp-mapper")
            state["idp_mappers"].append(body)
            return self.reply(201)
        self.reply(404, {"path": path})

    def do_PUT(self):
        path, _ = self.route()
        body = self.body()
        if path == "":
            state["realm"] = body
            return self.reply(204)
        if path.startswith("/roles/"):
            name = urllib.parse.unquote(path.split("/", 2)[2])
            index = next(i for i, role in enumerate(state["roles"]) if role["name"] == name)
            body.setdefault("id", state["roles"][index]["id"])
            state["roles"][index] = body
            return self.reply(204)
        if path.startswith("/clients/") and "/protocol-mappers/models/" in path:
            client, mapper = path.split("/")[2], path.rsplit("/", 1)[1]
            items = state["client_mappers"][client]
            items[next(i for i, item in enumerate(items) if item["id"] == mapper)] = body
            return self.reply(204)
        if path.startswith("/clients/"):
            client = path.split("/")[2]
            state["clients"][next(i for i, item in enumerate(state["clients"]) if item["id"] == client)] = body
            return self.reply(204)
        if path.endswith("/reset-password"):
            return self.reply(204)
        if path.startswith("/users/"):
            user = path.split("/")[2]
            state["users"][next(i for i, item in enumerate(state["users"]) if item["id"] == user)] = body
            return self.reply(204)
        if path == "/identity-provider/instances/oci":
            state["idps"][next(i for i, item in enumerate(state["idps"]) if item["alias"] == "oci")] = body
            return self.reply(204)
        if "/identity-provider/instances/oci/mappers/" in path:
            mapper = path.rsplit("/", 1)[1]
            state["idp_mappers"][next(i for i, item in enumerate(state["idp_mappers"]) if item["id"] == mapper)] = body
            return self.reply(204)
        self.reply(404, {"path": path})

    def do_DELETE(self):
        path, _ = self.route()
        body = self.body()
        if path.startswith("/roles/"):
            name = urllib.parse.unquote(path.split("/", 2)[2])
            state["roles"] = [item for item in state["roles"] if item["name"] != name]
            return self.reply(204)
        if path.endswith("/role-mappings/realm"):
            user = path.split("/")[2]
            removed = {item["name"] for item in body}
            state["user_roles"][user] = [item for item in state["user_roles"][user] if item["name"] not in removed]
            return self.reply(204)
        if path.startswith("/clients/") and "/protocol-mappers/models/" in path:
            client, mapper = path.split("/")[2], path.rsplit("/", 1)[1]
            state["client_mappers"][client] = [item for item in state["client_mappers"][client] if item["id"] != mapper]
            return self.reply(204)
        if path.startswith("/users/"):
            user = path.split("/")[2]
            state["users"] = [item for item in state["users"] if item["id"] != user]
            state["user_roles"].pop(user, None)
            return self.reply(204)
        if path == "/identity-provider/instances/oci":
            state["idps"] = [item for item in state["idps"] if item["alias"] != "oci"]
            state["idp_mappers"] = []
            return self.reply(204)
        if "/identity-provider/instances/oci/mappers/" in path:
            mapper = path.rsplit("/", 1)[1]
            state["idp_mappers"] = [item for item in state["idp_mappers"] if item["id"] != mapper]
            return self.reply(204)
        self.reply(404, {"path": path})

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(sys.argv[1], "w", encoding="utf-8") as stream:
    stream.write(str(server.server_address[1]))
server.serve_forever()
PY

cat >"${temporary_dir}/desired.json" <<'JSON'
{
  "realm":"orthanc","displayName":"Orthanc","enabled":true,"eventsEnabled":true,
  "roles":{"realm":[{"name":"orthanc-admin","composite":false,"clientRole":false},{"name":"tenant-a-viewer","composite":false,"clientRole":false}]},
  "clients":[{"clientId":"orthanc","enabled":true,"protocol":"openid-connect","publicClient":true,"redirectUris":["https://example.invalid/orthanc/*"],"protocolMappers":[{"name":"account audience","protocol":"openid-connect","protocolMapper":"oidc-audience-mapper","config":{"included.client.audience":"account"}}]}],
  "users":[{"username":"orthanc-admin","firstName":"Orthanc","lastName":"Administrator","email":"orthanc-admin@local.invalid","enabled":true,"emailVerified":true,"attributes":{"oci-dicom-managed":["true"]},"realmRoles":["orthanc-admin"],"requiredActions":[],"credentials":[{"type":"password","value":"secret","temporary":false}]}],
  "identityProviders":[{"alias":"oci","displayName":"OCI IAM SSO","providerId":"oidc","enabled":true,"config":{"defaultScope":"openid profile group","clientSecret":"idp-secret"}}],
  "identityProviderMappers":[{"name":"OCI Administrators","identityProviderAlias":"oci","identityProviderMapper":"oidc-advanced-group-idp-mapper","config":{"claim":"groups","claim.value":"Admins","role":"orthanc-admin","syncMode":"FORCE"}}]
}
JSON

cat >"${temporary_dir}/bin/terraform" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"output -raw keycloak_endpoint"*) printf 'http://127.0.0.1:%s/keycloak\n' "${KEYCLOAK_TEST_PORT}" ;;
  *"output -raw keycloak_admin_username"*) printf '%s\n' 'keycloak-admin' ;;
  *"output -raw keycloak_admin_password"*) printf '%s\n' 'bootstrap-secret' ;;
  *"output -json keycloak_reconciliation"*) cat "${KEYCLOAK_DESIRED_FILE}" ;;
  *) exit 1 ;;
esac
STUB
chmod 700 "${temporary_dir}/bin/terraform"

python3 "${temporary_dir}/server.py" "${temporary_dir}/port" &
server_pid=$!
for _ in $(seq 1 200); do
  [[ -s "${temporary_dir}/port" ]] && break
  kill -0 "${server_pid}" 2>/dev/null || {
    printf 'Mock Keycloak server stopped before becoming ready.\n' >&2
    exit 1
  }
  sleep 0.1
done
[[ -s "${temporary_dir}/port" ]] || {
  printf 'Mock Keycloak server did not become ready.\n' >&2
  exit 1
}
port="$(cat "${temporary_dir}/port")"

test_env=(
  PATH="${temporary_dir}/bin:${PATH}"
  KEYCLOAK_TEST_PORT="${port}"
  KEYCLOAK_DESIRED_FILE="${temporary_dir}/desired.json"
)
env "${test_env[@]}" "${project_dir}/scripts/reconcile-keycloak-oci-mappers.sh" >/dev/null
env "${test_env[@]}" "${project_dir}/scripts/reconcile-keycloak-oci-mappers.sh" --check >/dev/null
curl -fsS "http://127.0.0.1:${port}/state" | jq -e \
  '.idps[0].config.clientSecret == "idp-secret"' >/dev/null

jq '
  .roles.realm = [.roles.realm[] | select(.name == "orthanc-admin")] |
  .users[0].username = "replacement-admin" |
  .users[0].email = "replacement-admin@local.invalid" |
  .clients[0].redirectUris = ["https://changed.invalid/orthanc/*"] |
  .clients[0].protocolMappers = [] |
  .identityProviders = [] |
  .identityProviderMappers = []
' "${temporary_dir}/desired.json" >"${temporary_dir}/desired-updated.json"
test_env[2]="KEYCLOAK_DESIRED_FILE=${temporary_dir}/desired-updated.json"
env "${test_env[@]}" "${project_dir}/scripts/reconcile-keycloak-oci-mappers.sh" >/dev/null
env "${test_env[@]}" "${project_dir}/scripts/reconcile-keycloak-oci-mappers.sh" --check >/dev/null

curl -fsS "http://127.0.0.1:${port}/state" | jq -e '
  ([.roles[].name] | index("tenant-a-viewer") | not) and
  ([.roles[].name] | index("tenant-stale-viewer") | not) and
  ([.users[].username] == ["replacement-admin"]) and
  (.clients[0].redirectUris == ["https://changed.invalid/orthanc/*"]) and
  ([.client_mappers[]] == [[]]) and
  (.idps == []) and (.idp_mappers == [])
' >/dev/null

printf 'Keycloak day-two reconciliation converges additions, changes, removals, and SSO disablement.\n'
