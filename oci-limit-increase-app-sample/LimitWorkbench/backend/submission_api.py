# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

from typing import Literal

from fastapi import APIRouter
from pydantic import BaseModel

from .preparation_api import ExportIn


class SubmitIn(ExportIn):
    expected_revision: str
    confirmed: Literal[True]
    confirmed_tenancy: str
    confirmed_payload_hash: str


class StatusRefreshIn(BaseModel):
    connection_id: str


def submission_router(workflow):
    router = APIRouter(prefix="/api/submissions")

    @router.get("/draft/{draft_id}")
    def local_history(draft_id: str):
        workflow.drafts.path(draft_id)  # Reject malformed identifiers; this never calls OCI.
        return {"records": workflow.journal.for_draft(draft_id)}

    @router.post("")
    def submit(body: SubmitIn):
        return workflow.submit(**body.model_dump(exclude={"confirmed"}))

    @router.post("/{record_id}/refresh-status")
    def refresh_status(record_id: str, body: StatusRefreshIn):
        return workflow.refresh_status(record_id, body.connection_id)

    return router
