# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

"""Single app-provided SKU catalog and isolated, explicitly saved editor sessions."""
from __future__ import annotations

import copy
import os
import re
import tempfile
import threading
from collections import Counter
from contextlib import contextmanager
from pathlib import Path
from uuid import uuid4

from .documents import DocumentError, STATUSES, catalog_from_bytes, digest, encode_json, utc_now


class CatalogConflict(DocumentError):
    pass


@contextmanager
def catalog_file_lock(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a+b") as file:
        if os.name == "nt":
            import msvcrt
            if file.seek(0, os.SEEK_END) == 0:
                file.write(b"\0"); file.flush()
            file.seek(0)
            try:
                msvcrt.locking(file.fileno(), msvcrt.LK_NBLCK, 1)
            except OSError as exc:
                raise CatalogConflict("Another catalog save is in progress. Try again after it finishes.") from exc
            try:
                yield
            finally:
                file.seek(0); msvcrt.locking(file.fileno(), msvcrt.LK_UNLCK, 1)
        else:
            import fcntl
            try:
                fcntl.flock(file, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as exc:
                raise CatalogConflict("Another catalog save is in progress. Try again after it finishes.") from exc
            try:
                yield
            finally:
                fcntl.flock(file, fcntl.LOCK_UN)


class SkuCatalog:
    def __init__(self, path: Path, offline, manager):
        self.path = path
        self.offline = offline
        self.manager = manager
        self.sessions = {}
        self.lock = threading.RLock()

    def read(self):
        try:
            payload = self.path.read_bytes()
        except OSError as exc:
            raise DocumentError(f"Cannot read {self.path.name}. Place a valid oci_sku_limit_catalog.json in the app folder, then reload. Existing drafts can still be opened.") from exc
        return payload, catalog_from_bytes(payload)

    def session(self, identifier, version=None):
        session = self.sessions.get(identifier)
        if session is None:
            raise DocumentError("Catalog editor session is unavailable (the server may have restarted). Reload from disk; only saved catalog changes survive a restart.")
        if version is not None and session["version"] != version:
            raise CatalogConflict("The working copy changed. Export it to preserve applied edits, then reload before continuing.")
        return session

    def view(self, identifier):
        with self.lock:
            return {**copy.deepcopy(self.session(identifier)), "session_id": identifier, "path": str(self.path)}

    def open(self, previous=None):
        with self.lock:
            payload, catalog = self.read()
            if previous:
                self.sessions.pop(previous, None)
            if len(self.sessions) >= 16:
                clean = next((key for key, value in self.sessions.items() if not value["dirty"]), None)
                if clean:
                    del self.sessions[clean]
                else:
                    raise DocumentError("Too many unsaved catalog sessions. Save/export your work before restarting the app.")
            identifier = str(uuid4())
            self.sessions[identifier] = {"catalog": catalog, "revision": digest(payload), "version": 0, "dirty": False}
            return self.view(identifier)

    def changed(self, session, catalog, sku, action, before=None):
        stamp = utc_now()
        statistics = catalog.setdefault("statistics", {})
        history = catalog.setdefault("catalog_edit_history", [])
        if not isinstance(statistics, dict) or not isinstance(history, list):
            raise DocumentError("Catalog statistics must be an object and catalog_edit_history must be a list. No edits were applied.")
        statistics["unique_sku_count"] = len(catalog["skus"])
        statistics["mapping_status_counts"] = dict(Counter(r["oci_limit_mapping"]["mapping_status"] for r in catalog["skus"].values()))
        catalog["updated_at_utc"] = stamp
        history.append({"at_utc": stamp, "sku": sku, "action": action, "before": before,
                        "after": copy.deepcopy(catalog["skus"][sku]["oci_limit_mapping"])})
        catalog_from_bytes(encode_json(catalog))  # Size/contract checks before changing the session.
        session.update(catalog=catalog, version=session["version"] + 1, dirty=True)

    def add(self, identifier, version, sku, product):
        with self.lock:
            session = self.session(identifier, version)
            if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", sku):
                raise DocumentError("SKU must be an exact identifier using letters, digits, dots, underscores or hyphens, without spaces.")
            if sku in session["catalog"]["skus"]:
                raise DocumentError("This exact SKU already exists. Select it to edit its mapping.")
            if not product["child_product_name"].strip():
                raise DocumentError("Enter a product name for the new SKU.")
            catalog = copy.deepcopy(session["catalog"])
            catalog["skus"][sku] = {**product, "child_product_number": sku, "source_row": "",
                                     "created_at_utc": utc_now(), "oci_limit_mapping": {
                                         "service": None, "limit_name": None, "mapping_status": "service_unresolved",
                                         "confidence": "low", "rationale": "Added manually; mapping requires review.", "candidate_limits": []}}
            self.changed(session, catalog, sku, "add_sku")
            return self.view(identifier)

    def apply(self, identifier, version, sku, mapping, source, revision=None, connection_id=None, region=None):
        with self.lock:
            session = self.session(identifier, version)
            if sku not in session["catalog"]["skus"]:
                raise DocumentError("Select an existing SKU.")
            catalog = copy.deepcopy(session["catalog"])
            original = catalog["skus"][sku]["oci_limit_mapping"]
            service, limit, status = mapping["service"], mapping["limit_name"], mapping["mapping_status"]
            if status not in STATUSES or mapping["confidence"] not in {"high", "medium", "low"}:
                raise DocumentError("Choose a supported mapping status and confidence.")
            if limit and (not service or status not in {"direct", "unit_conversion", "needs_review"}):
                raise DocumentError("A selected limit requires a service and direct, unit_conversion, or needs_review status.")
            if status in {"direct", "unit_conversion"} and (not service or not limit):
                raise DocumentError("Reviewed mappings require both a service and a limit.")
            if status == "service_unresolved" and service:
                raise DocumentError("Clear the service for service_unresolved, or choose another status.")
            if status == "no_limit_definition" and not service:
                raise DocumentError("no_limit_definition requires a known service.")
            same = service == original.get("service") and limit == original.get("limit_name")
            definition = None
            if source == "existing":
                if (not same or status in {"direct", "unit_conversion"} and status != original["mapping_status"]):
                    raise DocumentError("Select an offline or live definition before changing or approving a service/limit mapping.")
            elif service and source == "offline":
                snapshot = self.offline.read()
                if revision != snapshot["revision"]:
                    raise CatalogConflict("Offline definitions changed. Reload the mapping choices and review again.")
                if service not in {s["name"] for s in snapshot["services"]["data"]}:
                    raise DocumentError("Choose a service from the offline catalog.")
                definition = self.offline.definition(snapshot, service, limit) if limit else None
            elif service and source == "live":
                if not connection_id or not region:
                    raise DocumentError("Select a live OCI connection and region.")
                connection = self.manager.get(connection_id, region)
                with connection.lock:
                    definitions = connection.definitions(region, service)
                    definition = next((d for d in definitions if d["name"] == limit), None) if limit else None
            elif source not in {"offline", "live"}:
                raise DocumentError("Choose an existing, offline, or live mapping source.")
            if limit and source != "existing" and definition is None:
                raise DocumentError("The limit must belong to the selected service's definitions.")
            before = copy.deepcopy(original)
            # Drop obsolete, known definition fields on remapping; preserve unknown extensions.
            if not same or definition is not None:
                for key in ("definition", "scope_type", "scope-type", "is-eligible-for-limit-increase", "is-deprecated", "are-quotas-supported"):
                    original.pop(key, None)
            original.update(mapping)
            previous_metadata = original.get("manual_selection", {})
            if not isinstance(previous_metadata, dict):
                raise DocumentError("manual_selection must be an object; no edits were applied.")
            metadata = {**previous_metadata, "selected_at_utc": utc_now(), "selection_source": source}
            if definition:
                metadata["limit_description"] = definition.get("description", "")
                original["scope_type"] = definition.get("scope-type")
            elif not same:
                metadata["limit_description"] = ""
            # No profile/config, tenancy, live values or raw OCI response is added.
            original["manual_selection"] = metadata
            self.changed(session, catalog, sku, "apply_mapping", before)
            return self.view(identifier)

    def export(self, identifier):
        with self.lock:
            return encode_json(self.session(identifier)["catalog"])

    def save(self, identifier, version):
        with self.lock:
            session = self.session(identifier, version)
            backup_dir = self.path.parent / ".catalog-backups"
            temp_name = None
            try:
                with catalog_file_lock(backup_dir / "sku-catalog.lock"):
                    current, _ = self.read()
                    if digest(current) != session["revision"]:
                        raise CatalogConflict("The app catalog was changed or replaced outside this working copy. Export your applied edits, then reload from disk. Nothing was overwritten.")
                    if not session["dirty"]:
                        return {**self.view(identifier), "backup": None}
                    payload = encode_json(session["catalog"])
                    backup = backup_dir / f"oci_sku_limit_catalog-{uuid4()}.json"
                    with backup.open("xb") as file:
                        file.write(current); file.flush(); os.fsync(file.fileno())
                    with tempfile.NamedTemporaryFile(dir=self.path.parent, suffix=".tmp", delete=False) as file:
                        temp_name = file.name
                        file.write(payload); file.flush(); os.fsync(file.fileno())
                    if self.path.read_bytes() != current:
                        raise CatalogConflict("The app catalog changed during Save. Export your applied edits and reload; nothing was overwritten.")
                    os.replace(temp_name, self.path)
                    session.update(revision=digest(payload), dirty=False, version=session["version"] + 1)
                    return {**self.view(identifier), "backup": str(backup)}
            except OSError as exc:
                raise DocumentError("Cannot save the SKU catalog or its backup. Check app-folder permissions and disk space. Your working copy remains available for Export.") from exc
            finally:
                if temp_name and os.path.exists(temp_name):
                    os.unlink(temp_name)
