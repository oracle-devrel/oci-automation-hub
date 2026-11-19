# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

"""Cleaner artifact discovery and incremental, bounded log reading."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class RunArtifacts:
    log_path: Path | None
    plan_json_path: Path | None
    plan_text_path: Path | None


@dataclass(frozen=True)
class AuditArtifacts:
    log_path: Path | None
    json_path: Path | None
    text_path: Path | None


def find_artifacts(run_directory: Path) -> RunArtifacts:
    """Find the cleaner's expected output files in one dedicated run directory."""
    return RunArtifacts(
        log_path=_newest(run_directory, "*.log"),
        plan_json_path=_newest(run_directory, "*.plan.json"),
        plan_text_path=_newest(run_directory, "*.plan.txt"),
    )


def find_audit_artifacts(run_directory: Path) -> AuditArtifacts:
    """Find the standalone audit's expected reports in its dedicated directory."""
    return AuditArtifacts(
        log_path=_newest(run_directory, "network_usage_audit_*.log"),
        json_path=_newest(run_directory, "network_usage_audit_*.json"),
        text_path=_newest(run_directory, "network_usage_audit_*.txt"),
    )


def read_new_text(path: Path | None, offset: int) -> tuple[str, int]:
    """Read text appended after offset, returning text and the next offset."""
    if path is None or not path.is_file():
        return "", offset
    with path.open(encoding="utf-8", errors="replace") as artifact:
        artifact.seek(offset)
        text = artifact.read()
        return text, artifact.tell()


def _newest(directory: Path, pattern: str) -> Path | None:
    matches = [path for path in directory.glob(pattern) if path.is_file()]
    return max(matches, key=lambda path: path.stat().st_mtime, default=None)
