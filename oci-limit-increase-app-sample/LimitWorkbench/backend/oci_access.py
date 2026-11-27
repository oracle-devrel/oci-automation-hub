# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

"""OCI access. Configuration is loaded only on an explicit connection."""
from __future__ import annotations

import configparser
import copy
import re
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from uuid import uuid4

from .documents import DocumentError, utc_now


class OciError(Exception):
    pass


class SubmissionError(OciError):
    def __init__(self, message, rejected=False, request_id=None):
        super().__init__(message)
        self.rejected = rejected
        self.request_id = request_id


def config_profiles(filename: str) -> dict:
    path = Path(filename or "~/.oci/config").expanduser().resolve()
    parser = configparser.ConfigParser(interpolation=None)
    try:
        with path.open(encoding="utf-8-sig") as file:
            parser.read_file(file)
    except (OSError, configparser.Error, UnicodeError) as exc:
        raise DocumentError("Cannot read the OCI config file. Check the local path and INI format.") from exc
    names = (["DEFAULT"] if parser.defaults() else []) + parser.sections()
    profiles = [{"name": name, "region": parser.get(name, "region", fallback="")}
                for name in names if parser.get(name, "tenancy", fallback="")]
    if not profiles:
        raise DocumentError("No profiles with a tenancy entry were found in that config file.")
    return {"config_file": str(path), "profiles": profiles}


def load_configuration(filename: str, profile: str) -> dict:
    import oci  # No SDK configuration or credential access during offline startup.
    path = Path(filename or "~/.oci/config").expanduser().resolve()
    try:
        raw = oci.config.from_file(file_location=str(path), profile_name=profile)
        # Limit authentication to API-key profiles for this release; no endpoints,
        # token filenames, or credentials are ever returned to the browser.
        config = {key: raw[key] for key in ("user", "tenancy", "fingerprint", "key_file", "pass_phrase", "region") if key in raw}
        if raw.get("security_token_file"):
            raise DocumentError("This connection supports API-key profiles. Security-token profiles are not implemented yet.")
        if config.get("key_file"):
            key_path = Path(config["key_file"]).expanduser()
            config["key_file"] = str(key_path if key_path.is_absolute() else path.parent / key_path)
        oci.config.validate_config(config)
        if not re.fullmatch(r"[a-z][a-z0-9-]{1,63}", config.get("region", "")):
            raise DocumentError("The selected profile needs a valid OCI region.")
        return config
    except DocumentError:
        raise
    except Exception as exc:
        # SDK/config exceptions can contain raw configuration, file contents or keys.
        raise DocumentError("Cannot load the API-key profile. Check its user, tenancy, fingerprint, key_file, region, and key passphrase if applicable.") from exc


def api_dict(value):
    """Use CLI-style field names while preserving every SDK-returned field."""
    if isinstance(value, dict):
        return {key.replace("_", "-"): copy.deepcopy(val) if key == "options" else api_dict(val) for key, val in value.items()}
    if isinstance(value, list):
        return [api_dict(val) for val in value]
    return value


class SdkGateway:
    def __init__(self, config: dict):
        import oci
        self.oci = oci
        self.config = config
        self.clients = {}

    def client(self, kind: str, region: str):
        key = (kind, region)
        if key not in self.clients:
            cls = {"identity": self.oci.identity.IdentityClient, "limits": self.oci.limits.LimitsClient,
                   "limits_increase": self.oci.limits_increase.LimitsIncreaseClient}[kind]
            self.clients[key] = cls({**self.config, "region": region}, timeout=(5, 20),
                                    retry_strategy=self.oci.retry.RetryStrategyBuilder(max_attempts=2).get_retry_strategy())
        return self.clients[key]

    def call(self, kind, region, operation, paginated=True, **kwargs):
        try:
            method = getattr(self.client(kind, region), operation)
            response = self.oci.pagination.list_call_get_all_results(method, **kwargs) if paginated else method(**kwargs)
            return api_dict(self.oci.util.to_dict(response.data))
        except Exception as exc:
            if isinstance(exc, self.oci.exceptions.ServiceError):
                code = re.sub(r"[^a-zA-Z0-9_-]", "", str(exc.code))[:100]
                request_id = re.sub(r"[^a-zA-Z0-9_/-]", "", str(exc.request_id or ""))[:150]
                raise OciError(f"OCI {operation} failed (HTTP {exc.status}, {code}). Request ID: {request_id or 'unavailable'}. Check permissions, region, and service support.") from exc
            raise OciError(f"OCI {operation} could not complete. Check credentials, network access, and timeouts.") from exc

    def services(self, tenancy, region):
        return self.call("limits", region, "list_services", compartment_id=tenancy)

    def tenancy_info(self, tenancy, region):
        return self.call("identity", region, "get_tenancy", paginated=False, tenancy_id=tenancy)

    def regions(self, tenancy, region):
        return self.call("identity", region, "list_region_subscriptions", tenancy_id=tenancy)

    def ads(self, tenancy, region):
        return self.call("identity", region, "list_availability_domains", compartment_id=tenancy)

    def definitions(self, tenancy, region, service):
        filters = {"service_name": service} if service is not None else {}
        return self.call("limits", region, "list_limit_definitions", compartment_id=tenancy, **filters)

    def values(self, tenancy, region, service):
        return self.call("limits", region, "list_limit_values", compartment_id=tenancy, service_name=service)

    def availability(self, tenancy, region, service, limit, ad):
        kwargs = {"availability_domain": ad} if ad else {}
        return self.call("limits", region, "get_resource_availability", paginated=False,
                         compartment_id=tenancy, service_name=service, limit_name=limit, **kwargs)

    def questions(self, tenancy, region, service, limit):
        return self.call("limits_increase", region, "list_limits_increase_questions",
                         compartment_id=tenancy, service_name=service, limit_name=limit)

    def request_status(self, region, ocid):
        return self.call("limits_increase", region, "get_limits_increase_request", paginated=False,
                         limits_increase_request_id=ocid)

    def submit(self, region, payload, retry_token, request_id):
        """Only the confirmed submission workflow may call this write operation."""
        models = self.oci.limits_increase.models
        details = models.CreateLimitsIncreaseRequestDetails(
            display_name=payload["displayName"], compartment_id=payload["compartmentId"],
            justification=payload["justification"], limits_increase_item_requests=[
                models.CreateLimitsIncreaseItemRequestDetails(
                    service_name=item["serviceName"], limit_name=item["limitName"], region=item["region"],
                    scope=item.get("scope"), value=item["value"], questionnaire_response=[
                        models.LimitsIncreaseItemQuestionRequest(id=q["id"], question_response=q["questionResponse"])
                        for q in item["questionnaireResponse"]]) for item in payload["limitsIncreaseItemRequests"]])
        try:
            response = self.client("limits_increase", region).create_limits_increase_request(
                details, opc_retry_token=retry_token, opc_request_id=request_id,
                retry_strategy=self.oci.retry.NoneRetryStrategy())
            data = api_dict(self.oci.util.to_dict(response.data))
            return {"ocid": data.get("id"), "oci_status": data.get("lifecycle-state"),
                    "opc_request_id": response.headers.get("opc-request-id"), "response": data}
        except Exception as exc:
            if isinstance(exc, self.oci.exceptions.ServiceError):
                code = re.sub(r"[^a-zA-Z0-9_-]", "", str(exc.code))[:100]
                identifier = re.sub(r"[^a-zA-Z0-9_/-]", "", str(exc.request_id or ""))[:150]
                raise SubmissionError(f"OCI submission returned HTTP {exc.status} ({code}).",
                                      rejected=exc.status in {400, 401, 403, 404, 405, 422},
                                      request_id=identifier or None) from exc
            raise SubmissionError("OCI submission did not return a usable response. The outcome is unknown.") from exc


class Connection:
    def __init__(self, config: dict, filename: str, profile: str, gateway):
        self.id = str(uuid4())
        self.tenancy = config["tenancy"]
        self.tenancy_name = None
        self.region = config["region"]
        self.filename = filename
        self.profile = profile
        self.gateway = gateway
        self.regions = [self.region]
        self.warnings = []
        self.cache = {}
        self.lock = threading.RLock()
        self.cancelled = threading.Event()
        self.touched = time.monotonic()

    def cached(self, key: tuple, fetch, refresh=False):
        # SDK clients are serialized per connection; cache keys include region.
        with self.lock:
            if self.cancelled.is_set():
                raise OciError("OCI connection was closed. Connect again.")
            entry = self.cache.get(key)
            if refresh or entry is None or time.monotonic() - entry[0] > 900:
                value = fetch()
                self.cache[key] = (time.monotonic(), value)
            return copy.deepcopy(self.cache[key][1])

    def services(self, region, refresh=False):
        return self.cached(("services", region), lambda: self.gateway.services(self.tenancy, region), refresh)

    def definitions(self, region, service, refresh=False):
        if service not in {entry["name"] for entry in self.services(region, refresh)}:
            raise DocumentError("Select a service returned by OCI for this region.")
        return self.cached(("definitions", region, service),
                           lambda: self.gateway.definitions(self.tenancy, region, service), refresh)

    def ads(self, region, refresh=False):
        ads = self.cached(("ads", region), lambda: self.gateway.ads(self.tenancy, region), refresh)
        def order(ad):
            match = re.search(r"AD-(\d+)$", ad["name"], re.IGNORECASE)
            return (int(match.group(1)) if match else 9999, ad["name"])
        return sorted(ads, key=order)

    def context(self):
        return {"id": self.id, "config_file": self.filename, "profile": self.profile,
                "tenancy": self.tenancy, "tenancy_name": self.tenancy_name, "region": self.region,
                "regions": self.regions, "warnings": self.warnings}


def enrichment_item(connection: Connection, region: str, item: dict, values_cache: dict, usage_cache: dict) -> dict:
    mapping = item.get("mapping_override") or item.get("catalog_mapping", {})
    service, limit = mapping.get("service"), mapping.get("limit_name")
    result = {"item_id": item["id"], "service": service, "limit_name": limit,
              "definition": None, "rows": [], "status": "mapping_required", "message": "Choose a service and limit."}
    status = mapping.get("mapping_status")
    if status in {"no_direct_limit", "no_limit_definition", "service_unresolved"}:
        result.update(status="not_mapped", message="No approved comparable limit. Choose a live mapping if appropriate.")
        return result
    if not service or not limit:
        return result
    if status not in {"direct", "unit_conversion"}:
        result.update(status="review_required", message="Review and confirm a live service/limit mapping before comparing values.")
        return result
    try:
        definitions = connection.definitions(region, service)
        definition = next((d for d in definitions if d["name"] == limit), None)
        if definition is None:
            result.update(status="review_required", message="The mapped limit was not returned for this service/region. Choose a live definition.")
            return result
        result["definition"] = definition
        scope = definition.get("scope-type")
        if scope not in {"AD", "REGION", "GLOBAL"}:
            raise OciError("OCI returned an unknown scope. Review the complete definition.")
        placements = [(i, ad["name"]) for i, ad in enumerate(connection.ads(region), 1)] if scope == "AD" else [(None, None)]
        if not placements:
            raise OciError("No availability domains were returned for this region.")
        # Values refresh once per service in each job, not once per SKU.
        if service not in values_cache:
            with connection.lock:
                try:
                    values_cache[service] = connection.gateway.values(connection.tenancy, region, service)
                except OciError as exc:
                    values_cache[service] = exc
        if isinstance(values_cache[service], OciError):
            raise values_cache[service]
        for index, ad in placements:
            matches = [v for v in values_cache[service] if v.get("name") == limit
                       and v.get("scope-type") == scope and (scope != "AD" or v.get("availability-domain") == ad)]
            value = matches[0] if len(matches) == 1 else None
            row = {"ad_index": index, "availability_domain": ad,
                   "allowed": value.get("value") if value else None, "used": None, "available": None,
                   "usage_status": "unsupported", "message": "", "raw_limit_value": value,
                   "raw_availability": None, "percent_used": None, "criticality": "unknown"}
            if not matches:
                row["message"] = "No allowed value returned for this scope."
            elif len(matches) > 1:
                row["message"] = "Multiple values returned for this scope; no value was chosen automatically."
            if definition.get("is-resource-availability-supported") is True:
                key = (service, limit, ad)
                if key not in usage_cache:
                    with connection.lock:
                        try:
                            usage_cache[key] = connection.gateway.availability(connection.tenancy, region, service, limit, ad)
                        except OciError as exc:
                            usage_cache[key] = exc
                usage = usage_cache[key]
                if isinstance(usage, OciError):
                    row.update(usage_status="unavailable", message=(row["message"] + " " + str(usage)).strip())
                else:
                    used = usage.get("fractional-usage") if usage.get("fractional-usage") is not None else usage.get("used")
                    available = usage.get("fractional-availability") if usage.get("fractional-availability") is not None else usage.get("available")
                    row.update(used=used, available=available, usage_status="ok", raw_availability=usage)
            elif definition.get("is-resource-availability-supported") is not False:
                row["usage_status"] = "unknown"
            if isinstance(row["allowed"], (int, float)) and row["allowed"] > 0 and isinstance(row["used"], (int, float)):
                percent = row["used"] / row["allowed"] * 100
                row.update(percent_used=percent, criticality="critical" if percent >= 98 else "warning" if percent >= 90 else "normal")
            result["rows"].append(row)
        result.update(status="ok", message="")
        if definition.get("is-eligible-for-limit-increase") is False:
            result["message"] = "OCI marks this limit as ineligible for increase. Values are shown for reference."
    except (OciError, DocumentError) as exc:
        result.update(status="error", message=str(exc))
    return result


class OciManager:
    def __init__(self, config_loader=load_configuration, gateway_factory=SdkGateway):
        self.config_loader = config_loader
        self.gateway_factory = gateway_factory
        self.connections = {}
        self.jobs = {}
        self.lock = threading.RLock()
        self.executor = ThreadPoolExecutor(max_workers=4, thread_name_prefix="oci-read")

    def connect(self, filename: str, profile: str):
        config = self.config_loader(filename, profile)
        connection = Connection(config, filename, profile, self.gateway_factory(config))
        services = connection.services(connection.region)
        try:
            tenancy = connection.gateway.tenancy_info(connection.tenancy, connection.region)
            if (not isinstance(tenancy, dict) or tenancy.get("id") != connection.tenancy
                    or not isinstance(tenancy.get("name"), str) or not tenancy["name"].strip()):
                raise OciError("OCI did not return a valid name for the connected tenancy.")
            connection.tenancy_name = tenancy["name"]
        except OciError as exc:
            # Name lookup is informational; lack of IAM access must not block limits work.
            connection.warnings.append(f"Tenancy name unavailable. {exc}")
        try:
            subscriptions = connection.gateway.regions(connection.tenancy, connection.region)
            connection.regions = sorted({r["region-name"] for r in subscriptions if r.get("status") == "READY"} | {connection.region})
        except OciError as exc:
            connection.warnings.append(str(exc))
        with self.lock:
            self.prune()
            if len(self.connections) >= 16:
                raise DocumentError("Too many open OCI connections. Disconnect an unused connection first.")
            self.connections[connection.id] = connection
        return {**connection.context(), "services": services}

    def prune(self):
        for identifier, connection in list(self.connections.items()):
            if time.monotonic() - connection.touched > 3600:
                self.disconnect(identifier)

    def get(self, identifier: str, region: str | None = None):
        with self.lock:
            self.prune()
            connection = self.connections.get(identifier)
            if connection is None:
                raise OciError("OCI connection expired or the server restarted. Connect again; your draft is unchanged.")
            connection.touched = time.monotonic()
            if region and region not in connection.regions:
                raise DocumentError("Choose a subscribed region from this connection.")
            return connection

    def disconnect(self, identifier: str):
        with self.lock:
            connection = self.connections.pop(identifier, None)
            if connection:
                connection.cancelled.set()
            for key, job in list(self.jobs.items()):
                if job["connection_id"] == identifier:
                    del self.jobs[key]

    def start_job(self, connection_id: str, region: str, items: list[dict]):
        connection = self.get(connection_id, region)
        if not items or len(items) > 10000:
            raise DocumentError("Enrichment requires 1 to 10,000 draft items.")
        seen = set()
        snapshots = []
        for item in items:
            mapping = item.get("mapping_override") or item.get("catalog_mapping")
            if not isinstance(item.get("id"), str) or item["id"] in seen or not isinstance(mapping, dict):
                raise DocumentError("Enrichment requires unique item IDs and mapping objects.")
            if any(mapping.get(key) is not None and not isinstance(mapping[key], str) for key in ("service", "limit_name", "mapping_status")):
                raise DocumentError("Mapping names/status must be text.")
            seen.add(item["id"])
            snapshots.append({"id": item["id"], "catalog_mapping": copy.deepcopy(mapping)})
        with self.lock:
            active = [j for j in self.jobs.values() if j["status"] in {"queued", "running"}]
            if len(active) >= 4 or any(j["connection_id"] == connection_id for j in active):
                raise DocumentError("An OCI refresh is already running. Wait for it to finish.")
            for key in list(self.jobs):
                if len(self.jobs) < 20:
                    break
                if self.jobs[key]["status"] not in {"queued", "running"}:
                    del self.jobs[key]
            job = {"id": str(uuid4()), "connection_id": connection_id, "region": region,
                   "status": "queued", "completed": 0, "total": len(items), "items": [],
                   "collected_at": None, "error": None}
            self.jobs[job["id"]] = job
            self.executor.submit(self.run_job, connection, region, snapshots, job["id"])
            return copy.deepcopy(job)

    def run_job(self, connection, region, items, job_id):
        values, usage, results = {}, {}, []
        try:
            with self.lock:
                if job_id not in self.jobs:
                    return
                self.jobs[job_id]["status"] = "running"
            for index, item in enumerate(items):
                if connection.cancelled.is_set():
                    return
                result = enrichment_item(connection, region, item, values, usage)
                results.append(result)
                with self.lock:
                    if job_id not in self.jobs:
                        return
                    self.jobs[job_id]["completed"] = index + 1
            with self.lock:
                if job_id in self.jobs:
                    self.jobs[job_id].update(status="completed", items=results, collected_at=utc_now())
        except Exception:
            with self.lock:
                if job_id in self.jobs:
                    self.jobs[job_id].update(status="failed", error="OCI refresh failed. Reconnect and retry; your draft was not modified.")

    def job(self, connection_id, job_id):
        self.get(connection_id)
        with self.lock:
            job = self.jobs.get(job_id)
            if job is None or job["connection_id"] != connection_id:
                raise DocumentError("Refresh job not found for this connection.")
            return copy.deepcopy(job)

    def close(self):
        with self.lock:
            for identifier in list(self.connections):
                self.disconnect(identifier)
        self.executor.shutdown(wait=False, cancel_futures=True)
