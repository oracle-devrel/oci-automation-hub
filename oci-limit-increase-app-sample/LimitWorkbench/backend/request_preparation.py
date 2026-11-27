# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

"""Technical request checks and export only. This module never submits to OCI."""
from __future__ import annotations

import copy
import io
import json
import math
import shlex
import threading
import time
import zipfile
from decimal import Decimal, InvalidOperation
from uuid import uuid4

from .documents import DocumentError, digest, encode_json, utc_now, validate_draft
from .oci_access import OciError, OciManager


def canonical(value) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False)


def fingerprint(value) -> str:
    return digest(canonical(value).encode())


def identity(draft):
    return [{"id": item["id"], "mapping": {k: (item.get("mapping_override") or item["catalog_mapping"]).get(k)
                                           for k in ("service", "limit_name", "mapping_status")},
             "ads": [a["ad_index"] for a in item["ad_requests"]]} for item in draft["items"]]


def intent(draft):
    """Fields affecting the exact reviewed request; timestamps/history are not intent."""
    return {"id": draft["id"], "title": draft["title"], "justification": draft["justification"],
            "items": [{**row, "requested_total": item["requested_total"], "requested_unit": item["requested_unit"],
                       "ad_requests": item["ad_requests"], "needs_review": item.get("requested_values_need_review", False)}
                      for row, item in zip(identity(draft), draft["items"])],
            "answers": draft.get("request_answers", {})}


def question_signature(question):
    return canonical(question)


def questionnaire_identity(data):
    return [{k: target[k] for k in ("key", "scope_type", "availability_domain", "definition", "questions")}
            for target in data["targets"]]


def answer_response(question: dict, value):
    """Return the SDK's string response and a validation error, if any."""
    kind = question.get("question-type")
    if kind not in {"TEXT", "NUMBER", "RADIO", "CHECKBOX"}:
        return None, f"Unsupported question type: {kind}."
    empty = value is None or value == [] or isinstance(value, str) and not value.strip()
    if empty:
        return (None, "An answer is required.") if question.get("is-required") else (None, None)
    if kind == "CHECKBOX":
        options = question.get("options") or {}
        if not options or not isinstance(value, list) or any(not isinstance(v, str) for v in value):
            return None, "Select the available checkbox options."
        if len(set(value)) != len(value) or any(v not in options for v in value):
            return None, "Select only available checkbox option IDs, without duplicates."
        return canonical(value), None
    if not isinstance(value, str) or len(value) > 10000:
        return None, "Answer must be text of at most 10,000 characters."
    if kind == "NUMBER":
        try:
            if not Decimal(value.strip()).is_finite():
                raise InvalidOperation
        except InvalidOperation:
            return None, "Enter a finite number."
    if kind == "RADIO" and value not in (question.get("options") or {}):
        return None, "Select an available option."
    return value, None


def normalize_questions(values, service, limit):
    if not isinstance(values, list):
        raise OciError("OCI questionnaire response was not a list.")
    result, seen = [], set()
    for value in values:
        if not isinstance(value, dict) or not isinstance(value.get("id"), str) or not value["id"]:
            raise OciError("OCI returned a question without a valid ID.")
        if value["id"] in seen:
            raise OciError("OCI returned duplicate question IDs for this limit.")
        if value.get("service") not in (None, "", service) or value.get("limit-name") not in (None, "", limit):
            raise OciError("OCI returned questionnaire fields for a different service/limit.")
        options = value.get("options") or {}
        if not isinstance(options, dict) or any(not isinstance(k, str) or not isinstance(v, str) for k, v in options.items()):
            raise OciError("OCI returned unsupported question options.")
        if type(value.get("is-required")) is not bool:
            raise OciError("OCI returned an unsupported required-question flag.")
        if value.get("question-text") is not None and not isinstance(value["question-text"], str):
            raise OciError("OCI returned an unsupported question label.")
        question = copy.deepcopy(value)
        question.update({"question-text": value.get("question-text") or value["id"],
                         "question-type": value.get("question-type") or "UNKNOWN",
                         "options": options, "is-required": value.get("is-required") is True})
        result.append(question)
        seen.add(value["id"])
    return sorted(result, key=lambda question: question["id"])


def snapshot(connection, region, draft):
    """Read a fresh target snapshot. Failures remain blockers, never empty success."""
    targets, issues, definitions, values, questionnaires = [], [], {}, {}, {}

    def fetched(cache, key, operation):
        if key not in cache:
            try:
                cache[key] = operation()
            except (OciError, DocumentError) as exc:
                cache[key] = exc
        if isinstance(cache[key], Exception):
            raise cache[key]
        return cache[key]

    def issue(item, message, field="mapping", ad_index=None):
        issues.append({"item_id": item["id"], "field": field, "ad_index": ad_index, "message": message})

    with connection.lock:
        if connection.cancelled.is_set():
            raise OciError("Connection closed. Reconnect and prepare again.")
        services = {s["name"] for s in connection.services(region, refresh=True)}
        ads = None
        for item in draft["items"]:
            mapping = item.get("mapping_override") or item["catalog_mapping"]
            service, limit = mapping.get("service"), mapping.get("limit_name")
            if not service or not limit or mapping.get("mapping_status") not in {"direct", "unit_conversion"}:
                issue(item, "Resolve and review this service/limit mapping, or remove the item.")
                continue
            if service not in services:
                issue(item, "Service was not returned by OCI for this region.")
                continue
            try:
                service_definitions = fetched(definitions, service, lambda: connection.gateway.definitions(connection.tenancy, region, service))
                definition = next((d for d in service_definitions if d["name"] == limit), None)
                if definition is None:
                    issue(item, "Limit was not returned for the selected service.")
                    continue
                if definition.get("is-eligible-for-limit-increase") is not True:
                    issue(item, "OCI does not explicitly mark this limit as eligible for increase.", "eligibility")
                scope = definition.get("scope-type")
                if scope == "AD":
                    if ads is None:
                        ads = connection.ads(region, refresh=True)
                    if not ads:
                        issue(item, "No ADs were returned. Refresh OCI data before preparing the request.", "scope")
                        continue
                    if not item["ad_requests"]:
                        issue(item, "Add requested AD rows by refreshing OCI data first.", "scope")
                    placements = []
                    for row in item["ad_requests"]:
                        index = row["ad_index"]
                        if index < 1 or index > len(ads):
                            issue(item, f"AD {index} is not present in this region. Refresh OCI data to reconcile AD rows.", "scope", index)
                        else:
                            placements.append((index, ads[index - 1]["name"]))
                elif scope in {"REGION", "GLOBAL"}:
                    placements = [(None, None)]
                else:
                    issue(item, "Unsupported or missing OCI scope.", "scope")
                    continue
                service_values = fetched(values, service, lambda: connection.gateway.values(connection.tenancy, region, service))
                pair = (service, limit)
                questions = fetched(questionnaires, pair, lambda: normalize_questions(connection.gateway.questions(connection.tenancy, region, service, limit), service, limit))
                for index, name in placements:
                    matching = [v for v in service_values if v.get("name") == limit and v.get("scope-type") == scope
                                and (scope != "AD" or v.get("availability-domain") == name)]
                    allowed = matching[0].get("value") if len(matching) == 1 else None
                    targets.append({"key": f"{item['id']}:{'ad:' + str(index) if index else 'regional'}",
                                    "item_id": item["id"], "sku": item["sku"], "service": service,
                                    "limit_name": limit, "scope_type": scope, "ad_index": index,
                                    "availability_domain": name, "allowed": allowed,
                                    "definition": copy.deepcopy(definition), "questions": copy.deepcopy(questions)})
            except (OciError, DocumentError) as exc:
                issue(item, str(exc), "discovery")
        if connection.cancelled.is_set():
            raise OciError("Connection closed. Preparation was discarded.")
    return {"targets": targets, "issues": issues, "collected_at": utc_now()}


def build_payload(draft, prepared, tenancy, region):
    """The single canonical API payload consumed by preview, CLI, and SDK submission."""
    errors = copy.deepcopy(prepared["issues"])
    items = {item["id"]: item for item in draft["items"]}
    answers = draft.get("request_answers", {})
    if not isinstance(answers, dict):
        raise DocumentError("request_answers must be an object.")
    for field in ("title", "justification"):
        if not draft[field].strip():
            errors.append({"item_id": None, "field": field, "message": f"Enter a {field}."})
    if not items:
        errors.append({"item_id": None, "field": "items", "message": "The draft has no request items."})
    payload_items, seen = [], set()
    for target in prepared["targets"]:
        item = items[target["item_id"]]
        def error(message, field="requested_total"):
            errors.append({"item_id": item["id"], "target_key": target["key"], "ad_index": target["ad_index"], "field": field, "message": message})
        value = item["requested_total"] if target["ad_index"] is None else next(a["requested_total"] for a in item["ad_requests"] if a["ad_index"] == target["ad_index"])
        valid_number = type(value) in (int, float) and math.isfinite(value) and value > 0 and float(value).is_integer()
        if not valid_number:
            error("Requested total must be a positive integer; OCI request values are integers.")
        allowed = target["allowed"]
        if type(allowed) not in (int, float) or not math.isfinite(allowed) or allowed < 0:
            error("A single current allowed limit could not be verified.", "allowed")
        elif valid_number and value <= allowed:
            error(f"Requested total must exceed the current allowed limit ({allowed}).")
        if item.get("requested_values_need_review"):
            error("Confirm the requested quantities and units on the Request items tab after changing the mapping.", "unit")
        key = (target["service"], target["limit_name"], region, target["availability_domain"])
        if key in seen:
            error("Duplicate service/limit/region/AD target. Keep one reviewed total; values are not summed.", "duplicate")
        seen.add(key)
        selected = answers.get(target["key"], {})
        if not isinstance(selected, dict):
            error("Answers for this target must be an object.", "answers")
            selected = {}
        responses = []
        known = {q["id"] for q in target["questions"]}
        if set(selected) - known:
            error("Answers contain question IDs absent from the current questionnaire. Prepare again.", "answers")
        for question in target["questions"]:
            response, problem = answer_response(question, selected.get(question["id"]))
            if problem:
                error(f"{question['question-text']}: {problem}", "answers")
            elif response is not None:
                responses.append({"id": question["id"], "questionResponse": response})
        payload_item = {"serviceName": target["service"], "limitName": target["limit_name"],
                        "region": region, "value": int(value) if valid_number else value,
                        "questionnaireResponse": responses}
        if target["availability_domain"]:
            payload_item["scope"] = target["availability_domain"]
        payload_items.append(payload_item)
    if not payload_items:
        errors.append({"item_id": None, "field": "items", "message": "No complete request targets could be prepared."})
    payload = {"displayName": draft["title"], "compartmentId": tenancy, "justification": draft["justification"],
               "limitsIncreaseItemRequests": payload_items}
    return {"payload": payload, "payload_hash": fingerprint(payload), "issues": errors, "valid": not errors}


def portable_questions(prepared):
    return {target["key"]: {"item_id": target["item_id"], "sku": target["sku"], "service": target["service"],
                            "limit_name": target["limit_name"], "ad_index": target["ad_index"],
                            "questions": target["questions"], "fetched_at": prepared["collected_at"]}
            for target in prepared["targets"]}


class RequestPreparation:
    def __init__(self, manager: OciManager):
        self.manager = manager
        self.sessions = {}
        self.receipts = {}
        self.lock = threading.RLock()

    def _get(self, table, identifier, connection_id):
        with self.lock:
            record = table.get(identifier)
            if not record or record["connection_id"] != connection_id or time.monotonic() - record["clock"] > 1800:
                raise DocumentError("Preparation/validation expired or the server restarted. Prepare and validate again.")
            return copy.deepcopy(record)

    def _put(self, table, identifier, record):
        with self.lock:
            if len(table) >= 32:
                del table[next(iter(table))]
            table[identifier] = record

    def _invalidate(self, draft_id, connection_id):
        with self.lock:
            for key, receipt in list(self.receipts.items()):
                if receipt["connection_id"] == connection_id and receipt["record"]["draft_id"] == draft_id:
                    del self.receipts[key]

    def prepare(self, draft, connection_id, region):
        draft = validate_draft(copy.deepcopy(draft))
        connection = self.manager.get(connection_id, region)
        self._invalidate(draft["id"], connection_id)
        prepared = snapshot(connection, region, draft)
        old_snapshots = draft.get("questionnaire_snapshots", {})
        old_answers = draft.get("request_answers", {})
        if not isinstance(old_snapshots, dict) or not isinstance(old_answers, dict):
            raise DocumentError("Questionnaire snapshots and answers must be objects.")
        current_snapshots = portable_questions(prepared)
        # A denied/failed discovery must not erase previously entered answers.
        snapshots = copy.deepcopy(old_snapshots)
        preserved = copy.deepcopy(old_answers)
        snapshots.update(current_snapshots)
        for key, current in current_snapshots.items():
            previous = old_snapshots.get(key, {})
            old_list = previous.get("questions", []) if isinstance(previous, dict) else []
            old_questions = {q["id"]: q for q in old_list if isinstance(q, dict) and isinstance(q.get("id"), str)} if isinstance(old_list, list) else {}
            values = old_answers.get(key, {})
            same_mapping = isinstance(previous, dict) and previous.get("service") == current["service"] and previous.get("limit_name") == current["limit_name"]
            preserved[key] = {q["id"]: values[q["id"]] for q in current["questions"]
                              if same_mapping and isinstance(values, dict) and q["id"] in values and old_questions.get(q["id"]) == q}
        draft["request_answers"], draft["questionnaire_snapshots"] = preserved, snapshots
        identifier = str(uuid4())
        self._put(self.sessions, identifier, {"clock": time.monotonic(), "connection_id": connection_id,
                  "region": region, "identity_hash": fingerprint(identity(draft)), "prepared": prepared})
        return {"preparation_id": identifier, "region": region, "tenancy": connection.tenancy,
                "snapshot": prepared, "questionnaire_snapshots": snapshots, "request_answers": preserved,
                "preview": build_payload(draft, prepared, connection.tenancy, region)}

    def validate(self, draft, connection_id, region, preparation_id):
        draft = validate_draft(copy.deepcopy(draft))
        connection = self.manager.get(connection_id, region)
        self._invalidate(draft["id"], connection_id)
        session = self._get(self.sessions, preparation_id, connection_id)
        if session["region"] != region or session["identity_hash"] != fingerprint(identity(draft)):
            raise DocumentError("Mappings, AD rows, or target changed. Prepare the request again.")
        current = snapshot(connection, region, draft)
        if questionnaire_identity(session["prepared"]) != questionnaire_identity(current):
            current["issues"].append({"item_id": None, "field": "preparation", "message": "OCI scope, ADs, or questionnaire changed. Prepare again and review the answers."})
        preview = build_payload(draft, current, connection.tenancy, region)
        if not preview["valid"]:
            return {**preview, "record": None, "validation_id": None}
        identifier = str(uuid4())
        record = {"id": identifier, "draft_id": draft["id"], "validated_at": utc_now(), "valid_for_current_content": True,
                  "validation_kind": "local_technical_checks", "input_hash": fingerprint(intent(draft)),
                  "payload_hash": preview["payload_hash"], "payload": preview["payload"],
                  "target": {"tenancy": connection.tenancy, "region": region}, "snapshot": current}
        self._put(self.receipts, identifier, {"clock": time.monotonic(), "connection_id": connection_id,
                  "region": region, "record": record})
        return {**preview, "record": record, "validation_id": identifier}

    def validated_record(self, draft, connection_id, region, validation_id):
        draft = validate_draft(copy.deepcopy(draft))
        connection = self.manager.get(connection_id, region)
        receipt = self._get(self.receipts, validation_id, connection_id)
        record = receipt["record"]
        if receipt["region"] != region or record["target"]["tenancy"] != connection.tenancy or record["input_hash"] != fingerprint(intent(draft)):
            raise DocumentError("The draft or target changed after validation. Validate the exact request again before export or submission.")
        return record

    def export(self, draft, connection_id, region, validation_id):
        return export_bundle(self.validated_record(draft, connection_id, region, validation_id))


def export_bundle(record):
    payload = record["payload"]
    region = record["target"]["region"]
    cli_input = {"compartmentId": payload["compartmentId"], "displayName": payload["displayName"],
                 "justification": payload["justification"], "items": payload["limitsIncreaseItemRequests"]}
    shell = """#!/bin/sh
set -eu
if [ "$#" -ne 3 ]; then
  echo 'Usage: sh submit.sh REGION PROFILE CONFIG_FILE' >&2
  exit 2
fi
request_region=$1
request_profile=$2
request_config=$3
case "$request_config" in
  /* | "~/"*) ;;
  *) request_config="$PWD/$request_config" ;;
esac
if [ "$request_region" != VALIDATED_REGION ]; then
  echo 'Region differs from the validated payload. Prepare and validate for that region first.' >&2
  exit 2
fi
request_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$request_dir"
oci --region "$request_region" --profile "$request_profile" --config-file "$request_config" limits-increase limits-increase-request create --from-json file://request.json
""".replace("VALIDATED_REGION", shlex.quote(region))
    powershell = """param(
  [Parameter(Mandatory=$true)][string]$OciRegion,
  [Parameter(Mandatory=$true)][string]$OciProfile,
  [Parameter(Mandatory=$true)][string]$OciConfigFile
)
$ErrorActionPreference = 'Stop'
if ($OciRegion -ne 'VALIDATED_REGION') { throw 'Region differs from the validated payload. Prepare and validate again.' }
$OciConfigFile = (Resolve-Path -LiteralPath $OciConfigFile).Path
Push-Location $PSScriptRoot
try {
  & oci --region $OciRegion --profile $OciProfile --config-file $OciConfigFile limits-increase limits-increase-request create --from-json file://request.json
  if ($LASTEXITCODE -ne 0) { throw "OCI CLI failed with exit code $LASTEXITCODE" }
} finally { Pop-Location }
""".replace("VALIDATED_REGION", region.replace("'", "''"))
    readme = ("OCI LIMIT INCREASE REQUEST\n\nRunning submit.sh or submit.ps1 submits a real request to OCI.\n"
              "The app has only exported these files; it has not submitted anything.\n\n"
              f"Validated region: {region}\nTarget tenancy: {payload['compartmentId']}\n"
              f"Canonical API payload SHA-256: {record['payload_hash']}\n\n"
              "Use an OCI CLI API-key profile authorized for this target tenancy.\n"
              "POSIX: sh submit.sh REGION PROFILE CONFIG_FILE\n"
              "PowerShell: ./submit.ps1 -OciRegion REGION -OciProfile PROFILE -OciConfigFile CONFIG_FILE\n"
              "request.json is CLI --from-json input; items.json is its --items data.\n"
              "request-api.json is the exact REST payload shown in the application preview.\n"
              "Changing payload files or target invalidates these technical checks; revalidate in the app.\n"
              "Running the command again may create another request; CLI execution is not tracked by this app.\n"
              "Local validation is not OCI approval and does not guarantee request acceptance.\n")
    archive = io.BytesIO()
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as output:
        output.writestr("request-api.json", encode_json(payload))
        output.writestr("request.json", encode_json(cli_input))
        output.writestr("items.json", json.dumps(cli_input["items"], ensure_ascii=False, indent=2, allow_nan=False))
        output.writestr("validation.json", encode_json(record))
        output.writestr("submit.sh", shell)
        output.writestr("submit.ps1", powershell)
        output.writestr("README.txt", readme)
    return archive.getvalue()
