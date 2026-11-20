# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
from __future__ import annotations

import dataclasses


@dataclasses.dataclass(frozen=True)
class DeleteOutcome:
    accepted: bool
    message: str = ""
