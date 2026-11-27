# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

"""Local submission journal, separate from editable portable draft content."""
from __future__ import annotations

import copy
import os
import tempfile
from contextlib import contextmanager
from pathlib import Path
from uuid import UUID

from .documents import DocumentError, encode_json, parse_json


class SubmissionJournal:
    def __init__(self, directory: Path):
        self.directory = directory

    @contextmanager
    def exclusive(self):
        """OS lock survives tabs/processes; process exit releases it, not history."""
        self.directory.mkdir(parents=True, exist_ok=True)
        with (self.directory / "submission.lock").open("a+b") as lock:
            if os.name == "nt":
                import msvcrt
                if lock.seek(0, os.SEEK_END) == 0:
                    lock.write(b"\0"); lock.flush()
                lock.seek(0)
                try:
                    msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
                except OSError as exc:
                    raise DocumentError("Another submission is in progress. Reload local submission records before trying again.") from exc
                try:
                    yield
                finally:
                    lock.seek(0)
                    msvcrt.locking(lock.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                import fcntl
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError as exc:
                    raise DocumentError("Another submission is in progress. Reload local submission records before trying again.") from exc
                try:
                    yield
                finally:
                    fcntl.flock(lock, fcntl.LOCK_UN)

    def records(self):
        result = []
        if self.directory.exists():
            for path in sorted(self.directory.glob("*.json")):
                try:
                    record = parse_json(path.read_bytes())
                    if (not isinstance(record.get("target"), dict)
                            or any(not isinstance(record.get(key), str) for key in
                                   ("id", "draft_id", "validation_id", "payload_hash", "input_hash", "status"))
                            or record["status"] not in {"sending", "submitted", "unknown", "rejected"}):
                        raise ValueError()
                    result.append(record)
                except (OSError, DocumentError, ValueError, AttributeError) as exc:
                    raise DocumentError("Cannot read the local submission journal. Restore its backup before submitting; duplicate protection must remain available.") from exc
        return sorted(result, key=lambda record: record.get("created_at", ""))

    def for_draft(self, draft_id):
        return [record for record in self.records() if record["draft_id"] == draft_id]

    def merge(self, draft):
        """Local authoritative history wins over edited/imported copies of it."""
        result = copy.deepcopy(draft)
        referenced = {r.get("id") for r in draft["submission_records"]
                      if isinstance(r, dict) and isinstance(r.get("id"), str)}
        records = [r for r in self.records() if r["draft_id"] == draft["id"] or r["id"] in referenced]
        ids = {record["id"] for record in records}
        result["submission_records"] = [r for r in draft["submission_records"]
                                         if not isinstance(r, dict) or r.get("id") not in ids] + records
        return result

    def write(self, record):
        path = self.directory / f"{UUID(record['id'])}.json"
        name = None
        try:
            with tempfile.NamedTemporaryFile(dir=self.directory, suffix=".tmp", delete=False) as file:
                name = file.name
                file.write(encode_json(record)); file.flush(); os.fsync(file.fileno())
            os.replace(name, path)
            # Make the directory entry durable as well as the file contents.
            if os.name != "nt":
                fd = os.open(self.directory, os.O_RDONLY)
                try:
                    os.fsync(fd)
                finally:
                    os.close(fd)
        finally:
            if name and os.path.exists(name):
                os.unlink(name)
