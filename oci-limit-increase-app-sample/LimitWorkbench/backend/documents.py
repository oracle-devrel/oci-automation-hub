# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

"""Portable documents and BOM parsing, independent of HTTP and UI state."""
from __future__ import annotations

import base64
import copy
import csv
import hashlib
import io
import json
import math
import zipfile
from datetime import date, datetime, timezone
from decimal import Decimal, InvalidOperation
from pathlib import Path
from uuid import UUID, uuid4

from openpyxl import load_workbook

REQUIRED_COLUMNS = ("SKU", "Scenario/Product Description", "Qty", "Metric")
MAX_FILE_BYTES = 10 * 1024 * 1024
MAX_DOCUMENT_BYTES = 32 * 1024 * 1024
MAX_ROWS = 10000
MAX_COLUMNS = 100
MAX_NUMBER = 9007199254740991  # React/JSON must not silently round larger integers.
STATUSES = {"direct", "unit_conversion", "no_direct_limit", "needs_review",
            "no_limit_definition", "service_unresolved"}


class DocumentError(ValueError):
    pass


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def digest(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def encode_json(value: dict) -> bytes:
    return (json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + "\n").encode("utf-8")


def parse_json(payload: bytes) -> dict:
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise DocumentError(f"Duplicate JSON key: {key}")
            result[key] = value
        return result

    def reject_constant(value):
        raise DocumentError(f"Invalid JSON number: {value}")

    if len(payload) > MAX_DOCUMENT_BYTES:
        raise DocumentError("JSON document exceeds 32 MB.")
    try:
        value = json.loads(payload.decode("utf-8-sig"), object_pairs_hook=unique,
                           parse_constant=reject_constant)
    except (UnicodeError, json.JSONDecodeError, RecursionError) as exc:
        raise DocumentError("Use a valid UTF-8 JSON document.") from exc
    if not isinstance(value, dict):
        raise DocumentError("Expected a JSON object.")
    return value


def catalog_from_bytes(payload: bytes) -> dict:
    catalog = parse_json(payload)
    if catalog.get("schema_version") != "1.0" or not isinstance(catalog.get("skus"), dict):
        raise DocumentError("Catalog requires schema_version 1.0 and a skus object.")
    for sku, record in catalog["skus"].items():
        if not isinstance(record, dict) or record.get("child_product_number") != sku:
            raise DocumentError(f"Catalog key and child_product_number disagree: {sku}")
        mapping = record.get("oci_limit_mapping", {})
        if not isinstance(mapping, dict) or mapping.get("mapping_status") not in STATUSES:
            raise DocumentError(f"Invalid mapping status for {sku}.")
        for key in ("service", "limit_name"):
            if mapping.get(key) is not None and not isinstance(mapping[key], str):
                raise DocumentError(f"{sku}: {key} must be text or null.")
    return catalog


def number(value, label: str):
    if isinstance(value, bool) or value is None or str(value).strip() == "":
        raise DocumentError(f"{label}: enter a non-negative numeric quantity.")
    try:
        parsed = Decimal(str(value).strip())
    except InvalidOperation as exc:
        raise DocumentError(f"{label}: enter a non-negative numeric quantity.") from exc
    if not parsed.is_finite() or parsed < 0 or parsed > MAX_NUMBER:
        raise DocumentError(f"{label}: quantity must be finite, non-negative, and at most {MAX_NUMBER}.")
    return int(parsed) if parsed == parsed.to_integral() else float(parsed)


def cell_value(value):
    if isinstance(value, (date, datetime)):
        return value.isoformat()
    if isinstance(value, float) and not math.isfinite(value):
        raise DocumentError("Workbook contains a non-finite value.")
    return value


def parse_bom(payload: bytes, filename: str) -> dict:
    if len(payload) > MAX_FILE_BYTES:
        raise DocumentError("BOM exceeds 10 MB.")
    extension = Path(filename).suffix.lower()
    matrix, formulas = [], {}
    sheet_name = None
    if extension == ".csv":
        try:
            reader = csv.reader(io.StringIO(payload.decode("utf-8-sig"), newline=""), strict=True)
            for row in reader:
                if len(matrix) > MAX_ROWS or len(row) > MAX_COLUMNS:
                    raise DocumentError("BOM supports at most 10,000 rows and 100 columns.")
                matrix.append(row)
        except (UnicodeError, csv.Error) as exc:
            raise DocumentError("Use a UTF-8 comma-separated CSV file.") from exc
    elif extension == ".xlsx":
        books = []
        try:
            with zipfile.ZipFile(io.BytesIO(payload)) as archive:
                if sum(i.file_size for i in archive.infolist()) > 50 * 1024 * 1024:
                    raise DocumentError("Expanded workbook exceeds 50 MB.")
            formulas_book = load_workbook(io.BytesIO(payload), read_only=True, data_only=False, keep_links=False)
            books.append(formulas_book)
            values_book = load_workbook(io.BytesIO(payload), read_only=True, data_only=True, keep_links=False)
            books.append(values_book)
            if "BOM" not in formulas_book.sheetnames:
                raise DocumentError("Workbook must contain a sheet named BOM, with headers in row 1. Use the template.")
            for sheet in formulas_book:
                if sheet.max_row > MAX_ROWS + 1 or sheet.max_column > MAX_COLUMNS:
                    raise DocumentError("BOM supports at most 10,000 rows and 100 columns.")
                if sheet.title != "BOM" and any(
                    value is not None for row in sheet.iter_rows(values_only=True) for value in row
                ):
                    raise DocumentError(f"Extra data sheet {sheet.title!r}: consolidate data into the BOM sheet.")
            sheet_name = "BOM"
            for index, (raw, cached) in enumerate(zip(formulas_book["BOM"].iter_rows(),
                                                    values_book["BOM"].iter_rows()), 1):
                matrix.append([cell_value(c.value) for c in cached])
                for col, cell in enumerate(raw):
                    if cell.data_type == "f":
                        formulas[(index, col)] = cell.value
        except DocumentError:
            raise
        except Exception as exc:
            raise DocumentError("Cannot read this XLSX workbook; use a valid, unencrypted .xlsx file.") from exc
        finally:
            for book in books:
                book.close()
    else:
        raise DocumentError("Upload a .xlsx or .csv BOM.")
    if not matrix:
        raise DocumentError("BOM is empty.")
    # XLSX dimensions may include formatted empty columns; preserve any with data.
    while matrix[0] and matrix[0][-1] in (None, "") and all(
        len(row) < len(matrix[0]) or row[len(matrix[0]) - 1] in (None, "") for row in matrix[1:]
    ):
        width = len(matrix[0]) - 1
        matrix = [row[:width] for row in matrix]
    headers = [str(h).strip() if h is not None else "" for h in matrix[0]]
    if not headers or any(not h for h in headers) or len(set(headers)) != len(headers):
        raise DocumentError("Row 1: column names must be non-empty and unique.")
    missing = set(REQUIRED_COLUMNS) - set(headers)
    if missing:
        raise DocumentError("Missing columns: " + ", ".join(sorted(missing)))
    rows = []
    for row_number, row in enumerate(matrix[1:], 2):
        row_formulas = {headers[col]: formula for (n, col), formula in formulas.items()
                        if n == row_number and col < len(headers)}
        if all(v is None or str(v).strip() == "" for v in row) and not row_formulas:
            continue
        if len(row) > len(headers):
            raise DocumentError(f"Row {row_number}: more values than headers.")
        values = dict(zip(headers, row + [None] * (len(headers) - len(row))))
        source_row = {"id": str(uuid4()), "sheet": sheet_name, "row_number": row_number,
                      "values": values, "formulas": row_formulas}
        if values["SKU"] is None or str(values["SKU"]).strip() == "":
            # Headings/totals are source data, not product rows. Retain their
            # values and formulas, but do not validate their product fields.
            rows.append({**source_row, "skip_reason": "empty_sku"})
            continue
        for required in REQUIRED_COLUMNS:
            if values[required] is None or str(values[required]).strip() == "":
                raise DocumentError(f"Row {row_number}, {required}: required value or saved formula result is missing.")
        number(values["Qty"], f"Row {row_number}, Qty")
        rows.append(source_row)
    if not any(row.get("skip_reason") != "empty_sku" for row in rows):
        raise DocumentError("BOM has no product rows with a non-empty SKU.")
    return {"filename": Path(filename).name, "columns": headers, "rows": rows,
            "attachment": {"encoding": "base64", "sha256": digest(payload),
                           "content": base64.b64encode(payload).decode("ascii")}}


def create_draft(bom: dict, catalog: dict, catalog_name: str, catalog_hash: str) -> dict:
    items = []
    for row in bom["rows"]:
        if row["values"].get("SKU") is None or str(row["values"]["SKU"]).strip() == "":
            continue
        sku = str(row["values"]["SKU"]).strip()
        record = copy.deepcopy(catalog["skus"].get(sku))
        mapping = copy.deepcopy(record.get("oci_limit_mapping")) if record else {
            "service": None, "limit_name": None, "mapping_status": "service_unresolved"}
        requested, unit = None, ""
        # Explicit reviewed capacity interpretation, not a generic billing-unit conversion.
        if (mapping.get("mapping_status") == "direct" and mapping.get("service") == "block-storage"
                and mapping.get("limit_name") == "total-storage-gb"
                and str(row["values"]["Metric"]).lower().replace(" ", "") in {"gb/month", "gb-month", "gb"}
                and mapping.get("scope_type", mapping.get("scope-type")) != "AD"):
            requested, unit = number(row["values"]["Qty"], "Qty"), "GB"
        items.append({"id": str(uuid4()), "source_row_ids": [row["id"]], "sku": sku,
                      "catalog_record": record, "catalog_mapping": mapping, "mapping_override": None,
                      "requested_total": requested, "requested_unit": unit, "ad_requests": []})
    now = utc_now()
    return {"schema_version": "1.0", "ad_index_base": 1, "id": str(uuid4()), "created_at": now, "updated_at": now,
            "title": Path(bom["filename"]).stem, "justification": "", "source_bom": bom,
            "catalog_reference": {"filename": Path(catalog_name).name,
                                  "schema_version": catalog["schema_version"], "sha256": catalog_hash},
            "items": items, "validation_records": [], "submission_records": []}


def validate_draft(draft: dict) -> dict:
    """Validate known structure without reconstructing/dropping extension fields."""
    if not isinstance(draft, dict) or draft.get("schema_version") != "1.0":
        raise DocumentError("Draft requires schema_version 1.0.")
    index_base = draft.get("ad_index_base", 0)
    if type(index_base) is not int or index_base not in (0, 1):
        raise DocumentError("ad_index_base must be 0 (legacy) or 1.")
    try:
        if str(UUID(draft["id"])) != draft["id"]:
            raise ValueError("Non-canonical draft ID")
        for key in ("created_at", "updated_at"):
            datetime.fromisoformat(draft[key].replace("Z", "+00:00"))
    except (KeyError, TypeError, ValueError, AttributeError) as exc:
        raise DocumentError("Draft requires a UUID id and valid creation/update timestamps.") from exc
    for key in ("title", "justification"):
        if not isinstance(draft.get(key), str):
            raise DocumentError(f"Draft {key} must be text.")
    for key in ("validation_records", "submission_records"):
        if not isinstance(draft.get(key), list):
            raise DocumentError(f"Draft {key} must be a list.")
    for key in ("request_answers", "questionnaire_snapshots"):
        if key in draft and not isinstance(draft[key], dict):
            raise DocumentError(f"Draft {key} must be an object.")
    catalog_reference = draft.get("catalog_reference")
    if not isinstance(catalog_reference, dict) or not isinstance(catalog_reference.get("filename"), str):
        raise DocumentError("Draft requires catalog_reference with a filename.")
    if any(draft.get(key) is not None for key in ("tenancy_id", "tenancy_ocid", "oci_config", "private_key", "credentials")):
        raise DocumentError("Keep tenancy context/credentials out of the draft root.")
    bom = draft.get("source_bom")
    if not isinstance(bom, dict) or not isinstance(bom.get("rows"), list) or not isinstance(bom.get("columns"), list):
        raise DocumentError("Draft requires source_bom columns and rows.")
    if not isinstance(bom.get("filename"), str) or any(not isinstance(c, str) for c in bom["columns"]):
        raise DocumentError("Source BOM filename and columns must be text.")
    rows = bom["rows"]
    if len(rows) > MAX_ROWS or any(not isinstance(r, dict) or not isinstance(r.get("id"), str)
                                 or not isinstance(r.get("values"), dict) for r in rows):
        raise DocumentError("Invalid source BOM rows.")
    ids = {r["id"] for r in rows}
    if len(ids) != len(rows):
        raise DocumentError("Source row IDs must be unique.")
    attachment = bom.get("attachment")
    if not isinstance(attachment, dict) or attachment.get("encoding") != "base64":
        raise DocumentError("Draft requires the original BOM attachment.")
    try:
        original = base64.b64decode(attachment["content"], validate=True)
    except (KeyError, ValueError, TypeError) as exc:
        raise DocumentError("Invalid BOM attachment.") from exc
    if len(original) > MAX_FILE_BYTES or digest(original) != attachment.get("sha256"):
        raise DocumentError("BOM attachment size or checksum is invalid.")
    items = draft.get("items")
    if not isinstance(items, list) or len(items) > MAX_ROWS:
        raise DocumentError("Draft items must be a list of at most 10,000 entries.")
    seen = set()
    for item in items:
        if not isinstance(item, dict) or not isinstance(item.get("id"), str) or item["id"] in seen:
            raise DocumentError("Draft item IDs must be unique strings.")
        seen.add(item["id"])
        refs = item.get("source_row_ids")
        if not isinstance(refs, list) or not refs or any(not isinstance(ref, str) or ref not in ids for ref in refs):
            raise DocumentError("Each draft item must reference existing source rows.")
        if not isinstance(item.get("sku"), str) or not isinstance(item.get("requested_unit"), str):
            raise DocumentError("Item SKU and requested unit must be text.")
        if item.get("requested_total") is not None:
            if not isinstance(item["requested_total"], (int, float)):
                raise DocumentError("Requested total must be a JSON number or null.")
            number(item["requested_total"], "Requested total")
        for name in ("catalog_mapping", "mapping_override"):
            mapping = item.get(name)
            if mapping is None and name == "mapping_override":
                continue
            if not isinstance(mapping, dict):
                raise DocumentError(f"Item {name} must be an object.")
            for field in ("service", "limit_name"):
                if mapping.get(field) is not None and not isinstance(mapping[field], str):
                    raise DocumentError(f"Mapping {field} must be text or null.")
        if not isinstance(item.get("ad_requests"), list):
            raise DocumentError("Item ad_requests must be a list.")
        ad_indexes = set()
        for ad in item["ad_requests"]:
            if (not isinstance(ad, dict) or type(ad.get("ad_index")) is not int
                    or ad["ad_index"] < index_base or ad["ad_index"] in ad_indexes):
                raise DocumentError("AD rows require unique integer indexes matching ad_index_base.")
            ad_indexes.add(ad["ad_index"])
            if ad.get("requested_total") is not None:
                if not isinstance(ad["requested_total"], (int, float)):
                    raise DocumentError("Requested AD total must be a JSON number or null.")
                number(ad["requested_total"], "Requested AD total")
    if index_base == 0:
        for item in items:
            for ad in item["ad_requests"]:
                ad["ad_index"] += 1
    draft["ad_index_base"] = 1
    return draft
