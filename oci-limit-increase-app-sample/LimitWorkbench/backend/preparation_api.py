# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

from fastapi import APIRouter
from fastapi.responses import Response
from pydantic import BaseModel

from .request_preparation import RequestPreparation


class PrepareIn(BaseModel):
    connection_id: str
    region: str
    draft: dict


class ValidateIn(PrepareIn):
    preparation_id: str


class ExportIn(PrepareIn):
    validation_id: str


def preparation_router(workflow: RequestPreparation):
    router = APIRouter(prefix="/api/request-preparation")

    @router.post("/prepare")
    def prepare(body: PrepareIn):
        return workflow.prepare(body.draft, body.connection_id, body.region)

    @router.post("/validate")
    def validate(body: ValidateIn):
        return workflow.validate(body.draft, body.connection_id, body.region, body.preparation_id)

    @router.post("/export")
    def export(body: ExportIn):
        data = workflow.export(body.draft, body.connection_id, body.region, body.validation_id)
        return Response(data, media_type="application/zip", headers={"Content-Disposition": 'attachment; filename="oci-limit-request.zip"'})

    return router
