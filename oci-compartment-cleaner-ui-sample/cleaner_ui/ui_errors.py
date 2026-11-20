# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

"""Safe, compact error text for local UI status messages."""

from __future__ import annotations

from .oci_selection import OciSelectionError


def profile_refresh_error(error: Exception) -> str:
    """Describe a profile refresh failure without dumping verbose SDK details."""
    if isinstance(error, OciSelectionError):
        code = error.code
        detail = error.detail
    else:
        code = "configuration"
        detail = str(error)
    condensed_detail = " ".join(detail.split())[:180]
    return (
        f"Could not refresh this OCI profile. Error code: {code}. "
        f"Details: {condensed_detail}. Choose another profile or correct its configuration."
    )
