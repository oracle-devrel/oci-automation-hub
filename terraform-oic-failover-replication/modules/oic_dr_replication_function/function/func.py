import base64
import json
import logging
import os
import re
import uuid
from datetime import datetime, timezone
from urllib.error import HTTPError
from urllib.parse import quote, urlencode, urljoin, urlparse
from urllib.request import Request, urlopen

import oci
from fdk import response


LOGGER = logging.getLogger()
INTEGRATIONS_PATH = "/ic/api/integration/v1/integrations"
PROJECTS_PATH = "/ic/api/integration/v1/projects"
MAX_REDIRECTS = 3


def redirect_url(url, location):
    """Return a permitted OIC redirect target.

    Oracle Integration can return a 307 while moving a project archive request
    to its design-time endpoint.  Unlike GET, urllib does not follow a 307 for
    POST requests, because the method and body must be retained explicitly.
    """
    target = urljoin(url, location)
    parsed = urlparse(target)
    if parsed.scheme != "https" or not parsed.hostname or not parsed.hostname.endswith(".oraclecloud.com"):
        raise RuntimeError(f"Refusing redirect from {url} to {target}")
    return target


def request(
    url,
    method="GET",
    token=None,
    body=None,
    content_type="application/json",
    accept_type="application/json",
):
    headers = {"Accept": accept_type}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if body is not None:
        headers["Content-Type"] = content_type

    for redirect_count in range(MAX_REDIRECTS + 1):
        try:
            with urlopen(Request(url, data=body, headers=headers, method=method), timeout=120) as result:
                return result.read()
        except HTTPError as error:
            location = error.headers.get("Location")
            if error.code in (307, 308) and location and redirect_count < MAX_REDIRECTS:
                redirected_url = redirect_url(url, location)
                LOGGER.info("Following %s redirect for %s from %s to %s", error.code, method, url, redirected_url)
                url = redirected_url
                continue
            detail = error.read().decode("utf-8", errors="replace")
            redirect_hint = f" Location: {location}" if location else ""
            raise RuntimeError(f"{method} {url} returned {error.code}:{redirect_hint} {detail}") from error


def bearer_token(prefix):
    endpoint = os.environ["IDCS_ENDPOINT"] + "/oauth2/v1/token"
    client_id = os.environ[f"{prefix}_CLIENT_ID"]
    client_secret = os.environ[f"{prefix}_CLIENT_SECRET"]
    credentials = base64.b64encode(f"{client_id}:{client_secret}".encode()).decode()
    body = urlencode({"grant_type": "client_credentials", "scope": os.environ[f"{prefix}_SCOPE"]}).encode()
    token_request = Request(endpoint, data=body, method="POST")
    token_request.add_header("Accept", "application/json")
    token_request.add_header("Content-Type", "application/x-www-form-urlencoded")
    token_request.add_header("Authorization", f"Basic {credentials}")
    with urlopen(token_request, timeout=60) as result:
        return json.loads(result.read())["access_token"]


def list_resources(base_url, token, path):
    resources = []
    offset = 0
    while True:
        raw = request(f"{base_url}{path}?limit=100&offset={offset}", token=token)
        page = json.loads(raw)
        items = page.get("items", page if isinstance(page, list) else [])
        resources.extend(items)
        has_more = page.get("hasMore", False) if isinstance(page, dict) else False
        if len(items) < 100 or not has_more:
            return resources
        offset += len(items)


def list_integrations(base_url, token):
    return list_resources(base_url, token, INTEGRATIONS_PATH)


def list_projects(base_url, token):
    return list_resources(base_url, token, PROJECTS_PATH)


def integration_id(integration):
    identifier = integration.get("id")
    if not identifier:
        raise RuntimeError(f"Integration list item has no id: {integration}")
    return identifier


def project_id(project):
    identifier = project.get("id")
    if not identifier:
        raise RuntimeError(f"Project list item has no id: {project}")
    return identifier


def deactivate_then_delete(base_url, token, integration):
    identifier = integration_id(integration)
    encoded_id = quote(identifier, safe="")
    # OIC refuses to delete active versions. Deactivation is idempotent for an
    # already inactive version and is deliberately performed before every delete.
    request(
        f"{base_url}{INTEGRATIONS_PATH}/{encoded_id}",
        method="POST",
        token=token,
        body=json.dumps({"status": "CONFIGURED"}).encode(),
    )
    request(f"{base_url}{INTEGRATIONS_PATH}/{encoded_id}", method="DELETE", token=token)


def deactivate_then_delete_project(base_url, token, project):
    identifier = project_id(project)
    encoded_id = quote(identifier, safe="")
    project_integrations_path = f"{PROJECTS_PATH}/{encoded_id}/integrations"

    # A project cannot be deleted while one of its integrations is active or
    # locked, so deactivate and delete its integration versions first.
    for integration in list_resources(base_url, token, project_integrations_path):
        integration_identifier = quote(integration_id(integration), safe="")
        request(
            f"{base_url}{project_integrations_path}/{integration_identifier}",
            method="POST",
            token=token,
            body=json.dumps({"status": "CONFIGURED"}).encode(),
        )
        request(
            f"{base_url}{project_integrations_path}/{integration_identifier}",
            method="DELETE",
            token=token,
        )
    request(f"{base_url}{PROJECTS_PATH}/{encoded_id}", method="DELETE", token=token)


def archive_object_name(integration):
    identifier = integration_id(integration)
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    safe_identifier = re.sub(r"[^A-Za-z0-9._-]+", "-", identifier).strip("-")
    return f"exports/{timestamp}/{safe_identifier}-{timestamp}.iar"


def project_archive_object_name(project):
    identifier = project_id(project)
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    safe_identifier = re.sub(r"[^A-Za-z0-9._-]+", "-", identifier).strip("-")
    return f"exports/projects/{timestamp}/{safe_identifier}-{timestamp}.car"


def multipart_archive(archive, filename):
    boundary = f"----oic-dr-{uuid.uuid4().hex}"
    body = b"".join(
        [
            f"--{boundary}\r\n".encode(),
            f'Content-Disposition: form-data; name="file"; filename="{filename}"\r\n'.encode(),
            b"Content-Type: application/octet-stream\r\n\r\n",
            archive,
            b"\r\n",
            f"--{boundary}\r\n".encode(),
            b'Content-Disposition: form-data; name="type"\r\n\r\n',
            b"application/octet-stream\r\n",
            f"--{boundary}--\r\n".encode(),
        ]
    )
    return body, f"multipart/form-data; boundary={boundary}"


def copy_integration(primary_url, primary_token, secondary_url, secondary_token, object_storage, integration):
    identifier = quote(integration_id(integration), safe="")
    archive = request(
        f"{primary_url}{INTEGRATIONS_PATH}/{identifier}/archive",
        token=primary_token,
        accept_type="application/octet-stream",
    )
    object_name = archive_object_name(integration)
    object_storage.put_object(
        os.environ["OBJECT_STORAGE_NAMESPACE"],
        os.environ["OBJECT_STORAGE_BUCKET"],
        object_name,
        archive,
    )
    stored_archive = object_storage.get_object(
        os.environ["OBJECT_STORAGE_NAMESPACE"],
        os.environ["OBJECT_STORAGE_BUCKET"],
        object_name,
    ).data.content
    import_body, content_type = multipart_archive(stored_archive, f"{integration_id(integration)}.iar")
    request(
        f"{secondary_url}{INTEGRATIONS_PATH}/archive",
        method="POST",
        token=secondary_token,
        body=import_body,
        content_type=content_type,
    )
    return object_name


def copy_project(primary_url, primary_token, secondary_url, secondary_token, object_storage, project):
    identifier = quote(project_id(project), safe="")
    archive = request(
        f"{primary_url}{PROJECTS_PATH}/{identifier}/archive",
        method="POST",
        token=primary_token,
        body=json.dumps(project).encode(),
        accept_type="application/octet-stream",
    )
    object_name = project_archive_object_name(project)
    object_storage.put_object(
        os.environ["OBJECT_STORAGE_NAMESPACE"],
        os.environ["OBJECT_STORAGE_BUCKET"],
        object_name,
        archive,
    )
    stored_archive = object_storage.get_object(
        os.environ["OBJECT_STORAGE_NAMESPACE"],
        os.environ["OBJECT_STORAGE_BUCKET"],
        object_name,
    ).data.content
    import_body, content_type = multipart_archive(stored_archive, f"{project_id(project)}.car")
    request(
        f"{secondary_url}{PROJECTS_PATH}/archive",
        method="POST",
        token=secondary_token,
        body=import_body,
        content_type=content_type,
    )
    return object_name


def handler(ctx, data=None):
    primary_url = os.environ["PRIMARY_OIC_URL"]
    secondary_url = os.environ["SECONDARY_OIC_URL"]
    object_storage = oci.object_storage.ObjectStorageClient(
        config={}, signer=oci.auth.signers.get_resource_principals_signer()
    )
    primary_token = bearer_token("PRIMARY")
    secondary_token = bearer_token("SECONDARY")

    # The order is intentional: list primary, list secondary, clear secondary,
    # then export each primary archive to Object Storage and import it into the
    # secondary instance from the stored object.
    primary_integrations = list_integrations(primary_url, primary_token)
    secondary_integrations = list_integrations(secondary_url, secondary_token)
    primary_projects = list_projects(primary_url, primary_token)
    secondary_projects = list_projects(secondary_url, secondary_token)

    for integration in secondary_integrations:
        deactivate_then_delete(secondary_url, secondary_token, integration)
    for project in secondary_projects:
        deactivate_then_delete_project(secondary_url, secondary_token, project)
    archived_objects = []
    for integration in primary_integrations:
        archived_objects.append(
            copy_integration(primary_url, primary_token, secondary_url, secondary_token, object_storage, integration)
        )
    project_archive_objects = []
    for project in primary_projects:
        project_archive_objects.append(
            copy_project(primary_url, primary_token, secondary_url, secondary_token, object_storage, project)
        )

    summary = {
        "primary_integrations": len(primary_integrations),
        "secondary_integrations_deleted": len(secondary_integrations),
        "integrations_imported": len(primary_integrations),
        "archive_objects": archived_objects,
        "primary_projects": len(primary_projects),
        "secondary_projects_deleted": len(secondary_projects),
        "projects_imported": len(primary_projects),
        "project_archive_objects": project_archive_objects,
    }
    LOGGER.info("OIC DR replication completed: %s", summary)
    return response.Response(ctx, response_data=json.dumps(summary), headers={"Content-Type": "application/json"})
