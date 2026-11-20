#!/usr/bin/env python3

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

"""Generate a minimal, non-production DICOM Part 10 image."""

from __future__ import annotations

import argparse
import json
import struct
import uuid
from datetime import datetime, timezone
from pathlib import Path


LONG_VALUE_REPRESENTATIONS = {"OB", "OD", "OF", "OL", "OV", "OW", "SQ", "UC", "UN", "UR", "UT"}


def uid() -> str:
    return f"2.25.{uuid.uuid4().int}"


def encode_element(group: int, element: int, vr: str, value: bytes) -> bytes:
    if len(value) % 2:
        value += b"\0" if vr == "UI" else b" "

    tag = struct.pack("<HH", group, element)
    if vr in LONG_VALUE_REPRESENTATIONS:
        header = tag + vr.encode("ascii") + b"\0\0" + struct.pack("<I", len(value))
    else:
        header = tag + vr.encode("ascii") + struct.pack("<H", len(value))
    return header + value


def text_element(group: int, element: int, vr: str, value: str) -> bytes:
    return encode_element(group, element, vr, value.encode("ascii"))


def unsigned_short(group: int, element: int, value: int) -> bytes:
    return encode_element(group, element, "US", struct.pack("<H", value))


def build_dicom(
    *,
    patient_id: str | None = None,
    study_uid: str | None = None,
    series_uid: str | None = None,
    instance_uid: str | None = None,
) -> tuple[bytes, dict[str, str]]:
    sop_class_uid = "1.2.840.10008.5.1.4.1.1.7"
    transfer_syntax_uid = "1.2.840.10008.1.2.1"
    implementation_uid = "1.2.826.0.1.3680043.10.543.1"
    study_uid = study_uid or uid()
    series_uid = series_uid or uid()
    instance_uid = instance_uid or uid()
    patient_id = patient_id or f"CODEX-{uuid.uuid4().hex[:12].upper()}"
    now = datetime.now(timezone.utc)

    file_meta = b"".join(
        [
            encode_element(0x0002, 0x0001, "OB", b"\0\1"),
            text_element(0x0002, 0x0002, "UI", sop_class_uid),
            text_element(0x0002, 0x0003, "UI", instance_uid),
            text_element(0x0002, 0x0010, "UI", transfer_syntax_uid),
            text_element(0x0002, 0x0012, "UI", implementation_uid),
            text_element(0x0002, 0x0013, "SH", "CODEX_OCI_DICOM"),
        ]
    )
    file_meta_group_length = encode_element(
        0x0002,
        0x0000,
        "UL",
        struct.pack("<I", len(file_meta)),
    )

    dataset = b"".join(
        [
            text_element(0x0008, 0x0016, "UI", sop_class_uid),
            text_element(0x0008, 0x0018, "UI", instance_uid),
            text_element(0x0008, 0x0020, "DA", now.strftime("%Y%m%d")),
            text_element(0x0008, 0x0030, "TM", now.strftime("%H%M%S")),
            text_element(0x0008, 0x0060, "CS", "OT"),
            text_element(0x0008, 0x0064, "CS", "SYN"),
            text_element(0x0008, 0x1030, "LO", "OCI DICOM deployment verification"),
            text_element(0x0010, 0x0010, "PN", "CODEX^SYNTHETIC"),
            text_element(0x0010, 0x0020, "LO", patient_id),
            text_element(0x0020, 0x000D, "UI", study_uid),
            text_element(0x0020, 0x000E, "UI", series_uid),
            text_element(0x0020, 0x0011, "IS", "1"),
            text_element(0x0020, 0x0013, "IS", "1"),
            unsigned_short(0x0028, 0x0002, 1),
            text_element(0x0028, 0x0004, "CS", "MONOCHROME2"),
            unsigned_short(0x0028, 0x0010, 1),
            unsigned_short(0x0028, 0x0011, 1),
            unsigned_short(0x0028, 0x0100, 8),
            unsigned_short(0x0028, 0x0101, 8),
            unsigned_short(0x0028, 0x0102, 7),
            unsigned_short(0x0028, 0x0103, 0),
            encode_element(0x7FE0, 0x0010, "OB", b"\0\0"),
        ]
    )

    payload = (b"\0" * 128) + b"DICM" + file_meta_group_length + file_meta + dataset
    metadata = {
        "PatientID": patient_id,
        "StudyInstanceUID": study_uid,
        "SeriesInstanceUID": series_uid,
        "SOPInstanceUID": instance_uid,
    }
    return payload, metadata


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Generate a minimal synthetic DICOM file for deployment verification."
    )
    parser.add_argument("output", type=Path, help="Destination .dcm file")
    parser.add_argument("--patient-id", help="Synthetic Patient ID to embed")
    parser.add_argument("--study-uid", help="Study Instance UID to embed")
    parser.add_argument("--series-uid", help="Series Instance UID to embed")
    parser.add_argument("--instance-uid", help="SOP Instance UID to embed")
    args = parser.parse_args()
    payload, metadata = build_dicom(
        patient_id=args.patient_id,
        study_uid=args.study_uid,
        series_uid=args.series_uid,
        instance_uid=args.instance_uid,
    )
    args.output.write_bytes(payload)
    print(json.dumps(metadata, sort_keys=True))


if __name__ == "__main__":
    main()
