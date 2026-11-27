# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

from __future__ import annotations

import os
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any

from fastapi import FastAPI, File, HTTPException, Query, Request, UploadFile
from fastapi.responses import JSONResponse, Response
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

from .documents import (MAX_DOCUMENT_BYTES, DocumentError, catalog_from_bytes, create_draft,
                        digest, encode_json, parse_bom, parse_json, utc_now, validate_draft)
from .storage import DraftStore, SaveConflict
from .oci_access import OciError, OciManager
from .oci_api import router_for
from .offline_catalog import OfflineCatalog
from .offline_api import offline_router
from .request_preparation import RequestPreparation
from .preparation_api import preparation_router
from .submission_storage import SubmissionJournal
from .submission import SubmissionWorkflow
from .submission_api import submission_router
from .sku_catalog import CatalogConflict, SkuCatalog
from .sku_catalog_api import sku_catalog_router
from .paths import app_directory, resource_directory
from .version import VERSION

ROOT = app_directory()


def default_data_directory() -> Path:
    if os.name == "nt":
        return Path(os.environ.get("LOCALAPPDATA", Path.home() / "AppData" / "Local")) / "OCILimitWorkbench"
    return Path.home() / ".local" / "share" / "oci-limit-workbench"


class SaveInput(BaseModel):
    draft: dict[str, Any]
    expected_revision: str | None = None


async def read_upload(upload: UploadFile) -> bytes:
    data = await upload.read(MAX_DOCUMENT_BYTES + 1)
    if len(data) > MAX_DOCUMENT_BYTES:
        raise DocumentError("Uploaded document exceeds 32 MB.")
    return data


def create_app(data_directory: Path | None = None, catalog_path: Path | None = None,
               oci_manager: OciManager | None = None, offline_catalog_dir: Path | None = None) -> FastAPI:
    manager = oci_manager or OciManager()

    @asynccontextmanager
    async def lifespan(app):
        yield
        manager.close()

    app = FastAPI(title="OCI Limit Workbench", version=VERSION, lifespan=lifespan)
    app.include_router(router_for(manager))
    preparation = RequestPreparation(manager)
    app.include_router(preparation_router(preparation))
    offline = OfflineCatalog(offline_catalog_dir or Path(os.environ.get("LIMIT_APP_OFFLINE_CATALOG_DIR", ROOT)))
    app.include_router(offline_router(offline, manager))
    directory = (data_directory or Path(os.environ.get("LIMIT_APP_DATA_DIR", default_data_directory()))).expanduser().resolve()
    submissions = SubmissionJournal(directory / "submissions")
    store = DraftStore(directory, submissions=submissions)
    app.include_router(submission_router(SubmissionWorkflow(preparation, store, submissions)))
    source_catalog = catalog_path or ROOT / "oci_sku_limit_catalog.json"
    sku_catalog = SkuCatalog(source_catalog, offline, manager)
    app.state.sku_catalog = sku_catalog
    app.include_router(sku_catalog_router(sku_catalog))

    @app.middleware("http")
    async def local_requests(request: Request, call_next):
        # Loopback service only. No CORS middleware or cross-origin write access.
        host = request.url.hostname
        if host not in {"localhost", "127.0.0.1", "::1", "testserver"}:
            return JSONResponse({"detail": "Use the local application address."}, status_code=403)
        if request.method not in {"GET", "HEAD", "OPTIONS"}:
            origin = request.headers.get("origin")
            if origin and origin != f"{request.url.scheme}://{request.url.netloc}":
                return JSONResponse({"detail": "Cross-origin writes are not allowed."}, status_code=403)
            if request.headers.get("x-app-request") != "local-workbench":
                return JSONResponse({"detail": "Missing application request header."}, status_code=403)
        try:
            too_large = int(request.headers.get("content-length", "0")) > MAX_DOCUMENT_BYTES + 1024 * 1024
        except ValueError:
            return JSONResponse({"detail": "Invalid request length."}, status_code=400)
        if too_large:
            return JSONResponse({"detail": "Request exceeds 33 MB."}, status_code=413)
        response = await call_next(request)
        response.headers["X-Content-Type-Options"] = "nosniff"
        return response

    @app.exception_handler(DocumentError)
    async def document_error(request, exc):
        return JSONResponse({"detail": str(exc)}, status_code=422)

    @app.exception_handler(CatalogConflict)
    async def catalog_conflict(request, exc):
        return JSONResponse({"detail": str(exc)}, status_code=409)

    @app.exception_handler(OciError)
    async def oci_error(request, exc):
        return JSONResponse({"detail": str(exc)}, status_code=502)

    @app.exception_handler(SaveConflict)
    async def conflict(request, exc):
        return JSONResponse({"detail": str(exc), "conflict": exc.current}, status_code=409)

    @app.get("/api/health")
    def health():
        return {"status": "ok", "application": "oci-limit-workbench", "mode": "offline-first", "version": VERSION}

    @app.get("/api/settings")
    def settings():
        return {"data_directory": str(store.directory), "default_catalog": source_catalog.name,
                "catalog_directory": str(source_catalog.parent),
                "catalog_available": source_catalog.is_file(), "oci_enabled": True}

    @app.get("/api/catalog")
    def catalog(query: str = "", page: int = Query(1, ge=1), page_size: int = Query(30, ge=1, le=100)):
        if not source_catalog.is_file():
            raise HTTPException(404, "The app SKU catalog is missing. Place oci_sku_limit_catalog.json in the app folder.")
        data = catalog_from_bytes(source_catalog.read_bytes())
        term = query.strip().lower()
        records = []
        for sku, record in data["skus"].items():
            mapping = record["oci_limit_mapping"]
            search = " ".join(str(v or "") for v in (sku, record.get("child_product_name"),
                             mapping.get("service"), mapping.get("limit_name"), mapping.get("mapping_status")))
            if term in search.lower():
                records.append({"sku": sku, "description": record.get("child_product_name", ""), "mapping": mapping})
        return {"filename": source_catalog.name, "total": len(records),
                "items": records[(page - 1) * page_size:page * page_size]}

    @app.get("/api/bom-template")
    def bom_template():
        content = ("SKU,Scenario/Product Description,Qty,Metric,Unit List Price,Monthly Consumption ($)\r\n"
                   "B91961,Block Volume Storage,200,GB / Month,0.0255,5.10\r\n")
        return Response(content, media_type="text/csv", headers={"Content-Disposition": 'attachment; filename="BOM-template.csv"'})

    @app.post("/api/drafts/from-bom")
    async def from_bom(request: Request, bom: UploadFile = File(...)):
        if "catalog" in await request.form():
            raise DocumentError("Per-BOM catalog upload is no longer supported. Replace oci_sku_limit_catalog.json in the app folder to adopt another catalog.")
        bom_document = parse_bom(await read_upload(bom), bom.filename or "")
        catalog_payload, catalog_document = sku_catalog.read()
        draft = create_draft(bom_document, catalog_document, source_catalog.name, digest(catalog_payload))
        return {"draft": offline.prepare(draft), "revision": None, **store.location(draft["id"])}

    @app.post("/api/drafts/import")
    async def import_draft(file: UploadFile = File(...)):
        draft = store.with_history(validate_draft(parse_json(await read_upload(file))))
        # Import never writes or silently overwrites a saved document.
        return {"draft": draft, **store.import_context(draft), **store.location(draft["id"])}

    @app.get("/api/drafts")
    def list_drafts():
        return store.list()

    @app.get("/api/drafts/{identifier}")
    def open_draft(identifier: str):
        try:
            return store.read(identifier)
        except FileNotFoundError as exc:
            raise HTTPException(404, "Saved draft not found.") from exc

    @app.post("/api/drafts/save")
    def save_draft(body: SaveInput):
        validate_draft(body.draft)
        body.draft["updated_at"] = utc_now()
        try:
            return store.save(body.draft, body.expected_revision)
        except OSError as exc:
            raise HTTPException(500, "Cannot save to the configured draft folder. Check its permissions and available space.") from exc

    @app.post("/api/drafts/export")
    def export_draft(body: SaveInput):
        draft = store.with_history(validate_draft(body.draft))
        return Response(encode_json(draft), media_type="application/json",
                        headers={"Content-Disposition": f'attachment; filename="draft-{draft["id"]}.json"'})

    @app.post("/api/drafts/save-copy")
    def save_copy(body: SaveInput):
        try:
            return store.save_copy(body.draft)
        except OSError as exc:
            raise HTTPException(500, "Cannot save to the configured draft folder. Check its permissions and available space.") from exc

    frontend = resource_directory() / "frontend" / "dist"
    if frontend.is_dir():
        app.mount("/", StaticFiles(directory=frontend, html=True), name="frontend")
    else:
        @app.get("/")
        def frontend_missing():
            return Response("Frontend not built. Run npm ci and npm run build in frontend/.", status_code=503)
    return app
