# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

"""Read-only OCI Identity queries for region and compartment selection."""

from __future__ import annotations

from collections.abc import Mapping

from .models import Compartment
from .validation import ValidationError


class OciSelectionError(ValidationError):
    """An OCI Identity lookup error with safe, displayable error details."""

    def __init__(self, operation: str, cause: Exception) -> None:
        self.code = str(getattr(cause, "code", getattr(cause, "status", "unknown")))
        self.detail = str(getattr(cause, "message", cause))
        super().__init__(f"{operation} failed ({self.code}): {self.detail}")


def subscribed_regions(config: Mapping[str, str]) -> list[str]:
    """Return names of regions subscribed by the selected tenancy."""
    try:
        import oci

        client = oci.identity.IdentityClient(dict(config))
        response = oci.pagination.list_call_get_all_results(
            client.list_region_subscriptions,
            config["tenancy"],
        )
    except Exception as exc:
        raise OciSelectionError("Region lookup", exc) from exc
    return sorted({item.region_name for item in response.data}, key=str.casefold)


def accessible_compartments(config: Mapping[str, str]) -> list[Compartment]:
    """Return active compartments accessible to the selected OCI profile."""
    try:
        import oci

        client = oci.identity.IdentityClient(dict(config))
        response = oci.pagination.list_call_get_all_results(
            client.list_compartments,
            config["tenancy"],
            compartment_id_in_subtree=True,
            access_level="ACCESSIBLE",
            lifecycle_state="ACTIVE",
        )
    except Exception as exc:
        raise OciSelectionError("Compartment lookup", exc) from exc

    compartments = [
        Compartment(
            id=item.id,
            name=item.name,
            parent_id=item.compartment_id,
            description=item.description,
        )
        for item in response.data
    ]
    return sorted(compartments, key=lambda item: (item.name.casefold(), item.id))


def tenancy_name(config: Mapping[str, str]) -> str:
    """Return the tenancy display name for orientation in the local UI."""
    try:
        import oci

        client = oci.identity.IdentityClient(dict(config))
        return str(client.get_tenancy(config["tenancy"]).data.name)
    except Exception as exc:
        raise OciSelectionError("Tenancy lookup", exc) from exc
