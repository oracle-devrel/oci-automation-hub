# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

"""Typed values shared by UI, OCI selection, and run orchestration."""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum


@dataclass(frozen=True)
class Compartment:
    """An OCI compartment available to the selected profile."""

    id: str
    name: str
    parent_id: str | None = None
    description: str | None = None

    @property
    def label(self) -> str:
        return f"{self.name} — {self.id}"


class RunStatus(str, Enum):
    RUNNING = "running"
    SUCCEEDED = "succeeded"
    FAILED = "failed"
    CANCELLATION_REQUESTED = "cancellation_requested"
    CANCELLED = "cancelled"
    ABORTED = "aborted"
