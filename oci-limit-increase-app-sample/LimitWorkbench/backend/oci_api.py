# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

from fastapi import APIRouter
from pydantic import BaseModel, Field

from .documents import DocumentError
from .oci_access import OciManager, config_profiles


class ProfilesIn(BaseModel):
    config_file: str = "~/.oci/config"


class ConnectIn(ProfilesIn):
    profile: str = "DEFAULT"


class ContextIn(BaseModel):
    connection_id: str
    region: str


class DefinitionsIn(ContextIn):
    service: str
    refresh: bool = False


class ReviewIn(DefinitionsIn):
    limit_name: str


class EnrichIn(ContextIn):
    items: list[dict] = Field(min_length=1, max_length=10000)


def router_for(manager: OciManager):
    router = APIRouter(prefix="/api/oci")

    @router.post("/profiles")
    def profiles(body: ProfilesIn):
        return config_profiles(body.config_file)

    @router.post("/connect")
    def connect(body: ConnectIn):
        return manager.connect(body.config_file, body.profile)

    @router.post("/{connection_id}/disconnect")
    def disconnect(connection_id: str):
        manager.disconnect(connection_id)
        return {"disconnected": True}

    @router.post("/services")
    def services(body: ContextIn):
        connection = manager.get(body.connection_id, body.region)
        return {"items": connection.services(body.region)}

    @router.post("/definitions")
    def definitions(body: DefinitionsIn):
        connection = manager.get(body.connection_id, body.region)
        return {"items": connection.definitions(body.region, body.service, body.refresh)}

    @router.post("/review-mapping")
    def review(body: ReviewIn):
        connection = manager.get(body.connection_id, body.region)
        definition = next((d for d in connection.definitions(body.region, body.service) if d["name"] == body.limit_name), None)
        if definition is None:
            raise DocumentError("The limit must belong to the selected service's live definitions.")
        return {"mapping": {"service": body.service, "limit_name": body.limit_name,
                            "mapping_status": "direct", "definition": definition,
                            "rationale": "Operator selected this service/limit from live OCI definitions. Review the requested value and unit separately."}}

    @router.post("/enrich")
    def enrich(body: EnrichIn):
        return manager.start_job(body.connection_id, body.region, body.items)

    @router.get("/{connection_id}/jobs/{job_id}")
    def job(connection_id: str, job_id: str):
        return manager.job(connection_id, job_id)

    return router
