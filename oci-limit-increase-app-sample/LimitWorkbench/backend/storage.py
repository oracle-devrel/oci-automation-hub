# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

"""Atomic JSON storage with explicit optimistic concurrency, no database."""
from __future__ import annotations

import os
import copy
import tempfile
import threading
from pathlib import Path
from uuid import UUID, uuid4

from .documents import DocumentError, digest, encode_json, parse_json, utc_now, validate_draft


class SaveConflict(Exception):
    def __init__(self, message: str, current: dict | None):
        super().__init__(message)
        self.current = current


def saved_summary(data: bytes) -> dict:
    """Describe the exact bytes checked for concurrency without returning the BOM."""
    try:
        saved = parse_json(data)
        title = saved.get("title")
        updated_at = saved.get("updated_at")
    except DocumentError:
        title, updated_at = None, None
    return {"revision": digest(data),
            "title": title if isinstance(title, str) else "Unreadable saved draft",
            "updated_at": updated_at if isinstance(updated_at, str) else None}


class DraftStore:
    def __init__(self, directory: Path, submissions=None):
        self.directory = directory.expanduser().resolve()
        self.lock = threading.Lock()
        self.submissions = submissions

    def with_history(self, draft):
        return self.submissions.merge(draft) if self.submissions else draft

    def path(self, identifier: str) -> Path:
        try:
            canonical = str(UUID(identifier))
        except (ValueError, TypeError, AttributeError) as exc:
            raise DocumentError("Invalid draft ID.") from exc
        return self.directory / f"{canonical}.json"

    def read(self, identifier: str) -> dict:
        data = self.path(identifier).read_bytes()
        return {"draft": self.with_history(validate_draft(parse_json(data))), "revision": digest(data), **self.location(identifier)}

    def location(self, identifier: str) -> dict:
        """Machine-local response metadata only; never added to a portable draft."""
        path = self.path(identifier)
        return {"file_path": str(path), "file_name": path.name}

    def import_context(self, draft: dict) -> dict:
        """Reconnect an unchanged portable copy to its local saved revision.

        Saving updates updated_at even without a content edit. That timestamp
        alone must not make an otherwise identical export conflict on import.
        The actual on-disk revision is still checked at the subsequent save.
        """
        try:
            data = self.path(draft["id"]).read_bytes()
        except FileNotFoundError:
            return {"revision": None, "local_conflict": None}
        summary = saved_summary(data)
        try:
            saved = self.with_history(validate_draft(parse_json(data)))
        except DocumentError:
            return {"revision": None, "local_conflict": summary}
        imported_content = {key: value for key, value in draft.items() if key != "updated_at"}
        saved_content = {key: value for key, value in saved.items() if key != "updated_at"}
        if imported_content == saved_content:
            return {"revision": summary["revision"], "local_conflict": None}
        return {"revision": None, "local_conflict": summary}

    def save_copy(self, draft: dict) -> dict:
        validate_draft(draft)
        copied = copy.deepcopy(self.with_history(draft))
        copied["copied_from_draft_id"] = draft["id"]
        copied["id"] = str(uuid4())
        copied["created_at"] = copied["updated_at"] = utc_now()
        # Retain historical requests, but a new draft identity has no current validation.
        for record in copied["validation_records"]:
            if isinstance(record, dict):
                record["valid_for_current_content"] = False
        return self.save(copied, expected_revision=None)

    def list(self) -> dict:
        items, errors = [], []
        if self.directory.exists():
            for path in self.directory.glob("*.json"):
                try:
                    draft = validate_draft(parse_json(path.read_bytes()))
                    items.append({"id": draft["id"], "title": draft["title"],
                                  "updated_at": draft["updated_at"], "item_count": len(draft["items"])})
                except (OSError, DocumentError) as exc:
                    errors.append({"filename": path.name, "message": str(exc)})
        return {"items": sorted(items, key=lambda d: d["updated_at"], reverse=True), "errors": errors}

    def save(self, draft: dict, expected_revision: str | None) -> dict:
        validate_draft(draft)
        draft = self.with_history(draft)
        data = encode_json(draft)
        path = self.path(draft["id"])
        with self.lock:
            self.directory.mkdir(parents=True, exist_ok=True)
            current_data = path.read_bytes() if path.exists() else None
            current = digest(current_data) if current_data is not None else None
            if current != expected_revision:
                raise SaveConflict(
                    "A different version of this draft is saved locally. Your edits are still open. "
                    "Choose Save as new draft to keep both versions, or Replace saved draft to update it.",
                    saved_summary(current_data) if current_data is not None else None,
                )
            name = None
            try:
                with tempfile.NamedTemporaryFile(dir=self.directory, suffix=".tmp", delete=False) as file:
                    name = file.name
                    file.write(data)
                    file.flush()
                    os.fsync(file.fileno())
                os.replace(name, path)
            finally:
                if name and os.path.exists(name):
                    os.unlink(name)
        return {"draft": draft, "revision": digest(data), **self.location(draft["id"])}
