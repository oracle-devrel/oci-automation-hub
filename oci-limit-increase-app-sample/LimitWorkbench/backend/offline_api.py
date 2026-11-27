# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

from fastapi import APIRouter, File, Form, HTTPException, UploadFile
from pydantic import BaseModel

from .documents import MAX_DOCUMENT_BYTES, DocumentError, parse_json
from .offline_catalog import OfflineCatalog
from .oci_access import OciError, OciManager


class Selection(BaseModel):
    service: str
    limit_name: str
    revision: str


class Generate(BaseModel):
    connection_id: str
    region: str
    revision: str
    confirm_replace: bool = False


def offline_router(catalog: OfflineCatalog, manager: OciManager):
    router = APIRouter(prefix="/api/offline-oci")

    @router.get("/catalog")
    def catalog_info():
        snapshot = catalog.read()
        return {**catalog.info(snapshot), "services": snapshot["services"]["data"]}

    @router.get("/definitions")
    def definitions(service: str):
        snapshot = catalog.read()
        return {"revision": snapshot["revision"], "metadata": snapshot["definitions"].get("metadata", {}),
                "items": [d for d in snapshot["definitions"]["data"] if d["service-name"] == service]}

    @router.post("/review-mapping")
    def review(body: Selection):
        return {"mapping": catalog.mapping(body.service, body.limit_name, body.revision)}

    @router.post("/prepare-draft")
    def prepare(draft: dict):
        return {"draft": catalog.prepare(draft)}

    @router.post("/import")
    async def import_files(services: UploadFile = File(...), definitions: UploadFile = File(...),
                           revision: str = Form(...), confirm_replace: bool = Form(False)):
        if not confirm_replace:
            raise DocumentError("Confirm replacement of the offline catalog files.")
        async def read(file):
            payload = await file.read(MAX_DOCUMENT_BYTES + 1)
            return parse_json(payload)
        service_doc, definition_doc = await read(services), await read(definitions)
        try:
            return catalog.replace(service_doc, definition_doc, revision)
        except OSError as exc:
            raise HTTPException(500, "Cannot replace offline catalogs. Check write permissions; previous files are backed up in .catalog-backups.") from exc

    @router.post("/generate")
    def generate(body: Generate):
        if not body.confirm_replace:
            raise DocumentError("Confirm generation and replacement of both offline catalog files.")
        connection = manager.get(body.connection_id, body.region)
        # No cached/partial lists: both paginated calls must succeed before any write.
        with connection.lock:
            if connection.cancelled.is_set():
                raise OciError("Connection closed. Catalogs were not replaced.")
            services = connection.gateway.services(connection.tenancy, body.region)
            definitions = connection.gateway.definitions(connection.tenancy, body.region, None)
            if connection.cancelled.is_set():
                raise OciError("Connection closed. Catalogs were not replaced.")
        try:
            return catalog.replace({"data": services}, {"data": definitions}, body.revision, body.region)
        except OSError as exc:
            raise HTTPException(500, "Cannot replace offline catalogs. Check write permissions; previous files are backed up in .catalog-backups.") from exc

    return router
