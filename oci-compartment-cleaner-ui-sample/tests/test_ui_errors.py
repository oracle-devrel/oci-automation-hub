# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

from cleaner_ui.oci_selection import OciSelectionError
from cleaner_ui.ui_errors import profile_refresh_error


class FakeOciError(Exception):
    code = "NotAuthenticated"
    message = "The supplied authentication information is not valid for this request."


def test_profile_refresh_error_shows_code_and_compact_detail() -> None:
    error = OciSelectionError("Region lookup", FakeOciError())

    message = profile_refresh_error(error)

    assert "Error code: NotAuthenticated" in message
    assert "authentication information" in message
    assert "Choose another profile" in message
