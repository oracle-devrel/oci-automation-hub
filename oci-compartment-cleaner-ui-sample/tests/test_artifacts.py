# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

from pathlib import Path

from cleaner_ui.artifacts import find_artifacts, find_audit_artifacts, read_new_text


def test_finds_cleaner_artifacts_and_reads_new_log_text(tmp_path: Path) -> None:
    log = tmp_path / "delete_compartment_test.log"
    plan_text = tmp_path / "delete_compartment_test.plan.txt"
    plan_json = tmp_path / "delete_compartment_test.plan.json"
    log.write_text("first line\n", encoding="utf-8")
    plan_text.write_text("plan", encoding="utf-8")
    plan_json.write_text("{}", encoding="utf-8")

    artifacts = find_artifacts(tmp_path)
    assert artifacts.log_path == log
    assert artifacts.plan_text_path == plan_text
    assert artifacts.plan_json_path == plan_json
    text, offset = read_new_text(log, 0)
    assert text == "first line\n"
    log.write_text("first line\nsecond line\n", encoding="utf-8")
    assert read_new_text(log, offset)[0] == "second line\n"


def test_finds_network_audit_artifacts(tmp_path: Path) -> None:
    log = tmp_path / "network_usage_audit_target_eu-frankfurt-1.log"
    report_json = tmp_path / "network_usage_audit_target_eu-frankfurt-1.json"
    report_text = tmp_path / "network_usage_audit_target_eu-frankfurt-1.txt"
    log.write_text("audit", encoding="utf-8")
    report_json.write_text('{"findings": []}', encoding="utf-8")
    report_text.write_text("no findings", encoding="utf-8")

    artifacts = find_audit_artifacts(tmp_path)

    assert artifacts.log_path == log
    assert artifacts.json_path == report_json
    assert artifacts.text_path == report_text
