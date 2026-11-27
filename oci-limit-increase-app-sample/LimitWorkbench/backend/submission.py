# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

"""Explicit, confirmed OCI writes backed by a durable attempt journal."""
from __future__ import annotations

import copy
from uuid import uuid4

from .documents import DocumentError, utc_now, validate_draft
from .oci_access import OciError, SubmissionError
from .request_preparation import build_payload, fingerprint, intent, questionnaire_identity, snapshot


class SubmissionWorkflow:
    def __init__(self, preparation, drafts, journal):
        self.preparation = preparation
        self.drafts = drafts
        self.journal = journal

    def refresh_status(self, record_id, connection_id):
        """Explicit read-only OCI refresh; original submission facts never change."""
        try:
            with self.journal.exclusive():
                record = next((r for r in self.journal.records() if r["id"] == record_id), None)
                if record is None:
                    raise DocumentError("Submission record not found in this machine's journal. Refresh currently supports locally recorded submissions, not imported-only or CLI requests.")
                if record["status"] != "submitted" or not record.get("ocid"):
                    raise DocumentError("This attempt has no confirmed OCI request OCID to refresh. Unknown-outcome reconciliation is a separate action and is not implemented yet.")
                region = record["target"]["region"]
                connection = self.preparation.manager.get(connection_id, region)
                if connection.tenancy != record["target"]["tenancy"]:
                    raise DocumentError("Connect to the submission's recorded tenancy before refreshing its OCI status.")
                with connection.lock:
                    if connection.cancelled.is_set():
                        raise OciError("Connection closed. Connect again before refreshing status.")
                    response = connection.gateway.request_status(region, record["ocid"])
                    if connection.cancelled.is_set():
                        raise OciError("Connection closed. The status refresh was discarded.")
                if (not isinstance(response, dict) or response.get("id") != record["ocid"]
                        or response.get("compartment-id") != connection.tenancy):
                    raise OciError("OCI returned details for a different request or tenancy. The recorded status was not changed.")
                state = response.get("lifecycle-state")
                if not isinstance(state, str) or not state.strip():
                    raise OciError("OCI returned no usable request status. The previous status and last-checked time were preserved.")
                checked_at = utc_now()
                record.update(latest_oci_status=state, status_checked_at=checked_at,
                              status_response=copy.deepcopy(response))
                record.setdefault("status_history", []).append({"checked_at": checked_at, "oci_status": state})
                self.journal.write(record)
                return {"record": record}
        except OSError as exc:
            raise DocumentError("Cannot read or save the local status record. Check the draft folder's permissions and available space, then reload local submission records. No OCI request was changed.") from exc

    def submit(self, draft, connection_id, region, validation_id, expected_revision,
               confirmed_tenancy, confirmed_payload_hash):
        draft = validate_draft(copy.deepcopy(draft))
        connection = self.preparation.manager.get(connection_id, region)
        if region != connection.region:
            raise DocumentError("Direct submission uses the selected OCI profile's region. Select that region and prepare/validate again, or use CLI export.")
        if confirmed_tenancy != connection.tenancy:
            raise DocumentError("The confirmed tenancy differs from the connected tenancy.")
        target = {"tenancy": connection.tenancy, "region": region}
        input_hash = fingerprint(intent(draft))
        try:
            with self.journal.exclusive():
                records = self.journal.records()
                for previous in records:
                    if (previous["validation_id"] == validation_id and previous["draft_id"] == draft["id"]
                            and previous["target"] == target and previous["input_hash"] == input_hash
                            and previous["payload_hash"] == confirmed_payload_hash):
                        # Replayed browser request returns the durable result, never another OCI call.
                        return {"record": previous, "replayed": True, "storage_warning": None}
                validated = self.preparation.validated_record(draft, connection_id, region, validation_id)
                if confirmed_payload_hash != validated["payload_hash"]:
                    raise DocumentError("The confirmed payload differs from the validated request. Review it again.")
                for previous in records:
                    same_payload = previous["payload_hash"] == validated["payload_hash"]
                    same_draft_target = previous["draft_id"] == draft["id"] and previous["target"] == target
                    if previous["status"] in {"sending", "unknown"} and (same_payload or same_draft_target):
                        raise DocumentError("A previous submission has an unknown or in-progress outcome. Check OCI before any further submission; reconciliation is not yet available in the app.")
                    if previous["status"] == "submitted" and same_payload:
                        raise DocumentError(f"This exact payload was already submitted ({previous.get('ocid')}). No new request was sent.")
                try:
                    saved = self.drafts.read(draft["id"])
                except FileNotFoundError as exc:
                    raise DocumentError("Save the draft locally before submitting.") from exc
                if not expected_revision or saved["revision"] != expected_revision or fingerprint(intent(saved["draft"])) != input_hash:
                    raise DocumentError("Save the current draft and resolve any local save conflict before submitting.")
                with connection.lock:
                    current = snapshot(connection, region, draft)
                    preview = build_payload(draft, current, connection.tenancy, region)
                    changed = questionnaire_identity(current) != questionnaire_identity(validated["snapshot"])
                    if changed or not preview["valid"] or preview["payload_hash"] != validated["payload_hash"]:
                        self.preparation._invalidate(draft["id"], connection_id)
                        raise DocumentError("OCI data or request checks changed. Nothing was submitted. Prepare and validate again. "
                                            + " ".join(issue["message"] for issue in preview["issues"])[:2000])
                    if connection.cancelled.is_set():
                        raise DocumentError("Connection closed. Nothing was submitted.")
                    # Read-only checks can take time or overlap another tab's revalidation.
                    # The original authorization must still be current before journaling/sending.
                    self.preparation.validated_record(draft, connection_id, region, validation_id)
                    identifier = str(uuid4())
                    record = {"id": identifier, "draft_id": draft["id"], "validation_id": validation_id,
                              "source": "app_sdk", "target": target, "profile": connection.profile,
                              "input_hash": input_hash, "payload_hash": validated["payload_hash"],
                              "payload": copy.deepcopy(validated["payload"]), "created_at": utc_now(),
                              "updated_at": utc_now(), "status": "sending", "ocid": None, "oci_status": None,
                              "retry_token": str(uuid4()), "client_request_id": str(uuid4()),
                              "message": "Submission started. If interrupted, its outcome is unknown; do not submit again blindly."}
                    # Failure here prevents the network write. A crash afterward leaves a blocking record.
                    self.journal.write(record)
                    try:
                        result = connection.gateway.submit(region, copy.deepcopy(record["payload"]),
                                                           record["retry_token"], record["client_request_id"])
                        if not isinstance(result.get("ocid"), str) or not result["ocid"].startswith("ocid1."):
                            raise SubmissionError("OCI did not return a usable request OCID. The outcome is unknown.")
                        record.update(status="submitted", ocid=result["ocid"], oci_status=result.get("oci_status"),
                                      opc_request_id=result.get("opc_request_id"), response=result.get("response"),
                                      message="OCI returned a request OCID. Submission is not approval of the requested limits.")
                    except SubmissionError as exc:
                        record.update(status="rejected" if exc.rejected else "unknown", message=str(exc),
                                      opc_request_id=exc.request_id)
                    except Exception:
                        # Never expose raw SDK/config/network exceptions or assume that no write occurred.
                        record.update(status="unknown", message="No usable submission response was received. Check OCI before submitting again.")
                    record["updated_at"] = utc_now()
                    warning = None
                    try:
                        self.journal.write(record)
                    except (OSError, ValueError, TypeError):
                        warning = "The outcome could not be saved locally. Download this submission record now and keep its OCID. The persisted attempt remains blocked; do not resubmit."
                    return {"record": record, "replayed": False, "storage_warning": warning}
        except OSError as exc:
            raise DocumentError("Cannot safely access the submission journal or saved draft. Check the draft folder's permissions and available space, then inspect local submission records before retrying.") from exc
