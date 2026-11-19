# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

import sys
from pathlib import Path

CLEANER_ROOT = Path(__file__).resolve().parents[1] / "oci-comp-cleaner"
sys.path.insert(0, str(CLEANER_ROOT))

from oci_compartment_cleaner.registry import load_registry  # noqa: E402


def test_data_safe_user_assessment_uses_verified_data_safe_methods() -> None:
    handler = load_registry().match_type("DataSafeUserAssessment")

    assert handler.action == "dynamic_delete"
    assert handler.client_class == "DataSafeClient"
    assert handler.method == "delete_user_assessment"
    assert handler.wait_method == "get_user_assessment"
    assert handler.wait_id_parameter == "user_assessment_id"


def test_data_safe_security_assessment_uses_verified_data_safe_methods() -> None:
    handler = load_registry().match_type("DataSafeSecurityAssessment")

    assert handler.action == "dynamic_delete"
    assert handler.client_class == "DataSafeClient"
    assert handler.method == "delete_security_assessment"
    assert handler.wait_method == "get_security_assessment"
    assert handler.wait_id_parameter == "security_assessment_id"
