# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

from typing import Literal

from fastapi import APIRouter
from fastapi.responses import Response
from pydantic import BaseModel, Field


class OpenIn(BaseModel):
    previous_session: str | None = None


class VersionIn(BaseModel):
    version: int = Field(ge=0)


class Product(BaseModel):
    child_product_name: str = Field(max_length=2000)
    top_category: str = Field(default="", max_length=500)
    product_coarse_grain: str = Field(default="", max_length=500)
    product_category: str = Field(default="", max_length=500)
    usage_unit_of_measure: str = Field(default="", max_length=500)


class AddIn(VersionIn):
    sku: str
    product: Product


class MappingIn(BaseModel):
    service: str | None = Field(default=None, max_length=500)
    limit_name: str | None = Field(default=None, max_length=500)
    mapping_status: str
    confidence: str
    rationale: str = Field(default="", max_length=10000)


class ApplyIn(VersionIn):
    sku: str
    mapping: MappingIn
    source: Literal["existing", "offline", "live"]
    revision: str | None = None
    connection_id: str | None = None
    region: str | None = None


def sku_catalog_router(editor):
    router = APIRouter(prefix="/api/sku-catalog")

    @router.post("/open")
    def open_editor(body: OpenIn):
        return editor.open(body.previous_session)

    @router.get("/{identifier}")
    def working_copy(identifier: str):
        return editor.view(identifier)

    @router.post("/{identifier}/apply")
    def apply(identifier: str, body: ApplyIn):
        return editor.apply(identifier, **body.model_dump())

    @router.post("/{identifier}/add")
    def add(identifier: str, body: AddIn):
        return editor.add(identifier, **body.model_dump())

    @router.post("/{identifier}/save")
    def save(identifier: str, body: VersionIn):
        return editor.save(identifier, body.version)

    @router.get("/{identifier}/export")
    def export(identifier: str):
        return Response(editor.export(identifier), media_type="application/json",
                        headers={"Content-Disposition": 'attachment; filename="oci_sku_limit_catalog.json"'})

    return router
