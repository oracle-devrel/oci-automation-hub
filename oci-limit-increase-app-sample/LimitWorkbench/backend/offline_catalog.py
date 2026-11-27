# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

"""External OCI definitions, independent of SKU mappings and credentials."""
from __future__ import annotations

import copy
import os
import tempfile
import threading
from pathlib import Path
from uuid import uuid4

from .documents import DocumentError, digest, encode_json, parse_json, utc_now, validate_draft

SERVICES = "oci_services.json"
DEFINITIONS = "oci_limit_definitions.json"


def validate_pair(services: dict, definitions: dict):
    for name, document in ((SERVICES, services), (DEFINITIONS, definitions)):
        if not isinstance(document.get("data"), list):
            raise DocumentError(f"{name} must have a data array, as exported by OCI CLI.")
        if not isinstance(document.get("metadata", {}), dict):
            raise DocumentError(f"{name}: metadata must be an object.")
    service_names = set()
    for service in services["data"]:
        if not isinstance(service, dict) or not isinstance(service.get("name"), str) or not service["name"].strip():
            raise DocumentError("Every service requires a name.")
        if service["name"] in service_names:
            raise DocumentError(f"Duplicate service: {service['name']}")
        service_names.add(service["name"])
    keys = set()
    for definition in definitions["data"]:
        if (not isinstance(definition, dict) or not isinstance(definition.get("name"), str)
                or not isinstance(definition.get("service-name"), str)
                or not definition["name"].strip() or definition.get("service-name") not in service_names):
            raise DocumentError("Each definition needs a name and a service-name present in the service catalog.")
        key = (definition["service-name"], definition["name"])
        if key in keys:
            raise DocumentError(f"Duplicate limit definition: {key[0]}/{key[1]}")
        keys.add(key)
        if definition.get("scope-type") not in {"AD", "REGION", "GLOBAL"}:
            raise DocumentError(f"{definition['name']}: scope-type must be AD, REGION, or GLOBAL.")
    versions = [doc.get("metadata", {}).get("generation_id") for doc in (services, definitions)]
    if any(versions) and versions[0] != versions[1]:
        raise DocumentError("Catalog files belong to different generations. Import or generate a matching pair.")


class OfflineCatalog:
    def __init__(self, directory: Path):
        self.directory = directory
        self.lock = threading.RLock()

    def read(self) -> dict:
        with self.lock:
            if not (self.directory / SERVICES).exists() and not (self.directory / DEFINITIONS).exists():
                # No placeholder files are created during reads/startup.
                return {"services": {"data": []}, "definitions": {"data": []}, "revision": "missing"}
            try:
                raw_services = (self.directory / SERVICES).read_bytes()
                raw_definitions = (self.directory / DEFINITIONS).read_bytes()
            except OSError as exc:
                raise DocumentError("Offline catalog files are missing or unreadable. Import or generate both files.") from exc
            services, definitions = parse_json(raw_services), parse_json(raw_definitions)
            validate_pair(services, definitions)
            return {"services": services, "definitions": definitions,
                    "revision": digest(raw_services + b"\n---\n" + raw_definitions)}

    def info(self, snapshot=None) -> dict:
        snapshot = snapshot or self.read()
        return {"revision": snapshot["revision"], "directory": str(self.directory),
                "service_count": len(snapshot["services"]["data"]),
                "definition_count": len(snapshot["definitions"]["data"]),
                "metadata": snapshot["definitions"].get("metadata", {}),
                "initialized": bool(snapshot["definitions"]["data"])}

    def definition(self, snapshot: dict, service: str, limit: str):
        return next((d for d in snapshot["definitions"]["data"]
                     if d["service-name"] == service and d["name"] == limit), None)

    def mapping(self, service: str, limit: str, expected_revision: str) -> dict:
        snapshot = self.read()
        if snapshot["revision"] != expected_revision:
            raise DocumentError("Offline catalog changed. Reload its definitions before selecting a mapping.")
        definition = self.definition(snapshot, service, limit)
        if definition is None:
            raise DocumentError("Choose a definition belonging to the selected offline service.")
        return {"service": service, "limit_name": limit, "mapping_status": "direct",
                "definition": copy.deepcopy(definition),
                "source": {"kind": "offline_catalog", "revision": snapshot["revision"],
                           "metadata": copy.deepcopy(snapshot["definitions"].get("metadata", {}))},
                "rationale": "Operator selected a definition from the offline catalog. Target-tenancy eligibility, units, and values still require live verification."}

    def prepare(self, draft: dict) -> dict:
        """Add known definition metadata and initial rows; do not remap SKU suggestions."""
        draft = validate_draft(copy.deepcopy(draft))
        try:
            snapshot = self.read()
        except DocumentError:
            snapshot = None  # Missing optional definitions must not block offline BOM work.
        for item in draft["items"]:
            mapping = item.get("mapping_override") or item["catalog_mapping"]
            definition = mapping.get("definition")
            if definition is None and snapshot:
                definition = self.definition(snapshot, mapping.get("service"), mapping.get("limit_name"))
                if definition:
                    item["offline_definition"] = copy.deepcopy(definition)
                    item["offline_catalog_revision"] = snapshot["revision"]
            definition = definition or item.get("offline_definition") or mapping
            if definition.get("scope-type", definition.get("scope_type")) == "AD" and not item.get("ad_rows_initialized"):
                if not item["ad_requests"]:
                    item["ad_requests"] = [{"ad_index": i, "requested_total": None} for i in (1, 2, 3)]
                item["ad_rows_initialized"] = True
        return draft

    @staticmethod
    def atomic_write(path: Path, data: bytes):
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(dir=path.parent, delete=False, suffix=".tmp") as file:
                temporary = file.name
                file.write(data)
                file.flush()
                os.fsync(file.fileno())
            os.replace(temporary, path)
        finally:
            if temporary and os.path.exists(temporary):
                os.unlink(temporary)

    def replace(self, services: dict, definitions: dict, expected_revision: str, source_region=None) -> dict:
        services, definitions = copy.deepcopy(services), copy.deepcopy(definitions)
        validate_pair(services, definitions)
        if not services["data"] or not definitions["data"]:
            raise DocumentError("Refusing to replace the catalog with an empty snapshot.")
        with self.lock:
            current = self.read()
            if current["revision"] != expected_revision:
                raise DocumentError("Offline catalog changed since you opened it. Reload before replacing it.")
            generation = str(uuid4())
            for document in (services, definitions):
                metadata = document.setdefault("metadata", {})
                metadata.update(generation_id=generation, schema_version="1.0", status="ready", installed_at=utc_now())
                if source_region is not None:
                    metadata.update(generated_at=utc_now(), source_region=source_region)
            old = {name: (self.directory / name).read_bytes() if (self.directory / name).exists() else None for name in (SERVICES, DEFINITIONS)}
            backup = self.directory / ".catalog-backups" / generation
            self.directory.mkdir(parents=True, exist_ok=True)
            if any(data is not None for data in old.values()):
                backup.mkdir(parents=True)
            for name, data in old.items():
                if data is not None:
                    self.atomic_write(backup / name, data)
            try:
                self.atomic_write(self.directory / SERVICES, encode_json(services))
                self.atomic_write(self.directory / DEFINITIONS, encode_json(definitions))
            except OSError:
                for name, data in old.items():
                    if data is None:
                        (self.directory / name).unlink(missing_ok=True)
                    else:
                        self.atomic_write(self.directory / name, data)
                raise
            return {**self.info(), "backup_directory": str(backup) if backup.exists() else None}
