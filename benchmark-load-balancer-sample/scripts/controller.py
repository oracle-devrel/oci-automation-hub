# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
#!/usr/bin/env python3
import argparse
import csv
import datetime as dt
import json
import math
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import time
import traceback
from collections.abc import Mapping, Sequence

SUPPORTED_MODES = {"cps", "throughput"}
ROOT = Path("/opt/flb-benchmark")
PYTHON = str(ROOT / "venv" / "bin" / "python")
LOCUSTFILE = str(ROOT / "locustfile.py")


def utc_now():
    return dt.datetime.now(dt.timezone.utc)


def iso(value):
    return value.astimezone(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def safe_label(value):
    return "".join(ch if ch.isalnum() or ch in "._-" else "_" for ch in str(value))


def _is_missing(value):
    return value is None or (isinstance(value, str) and not value.strip())


def _to_float(value):
    if _is_missing(value) or isinstance(value, bool):
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _parse_integral(value, name):
    if _is_missing(value) or isinstance(value, bool):
        raise ValueError(f"{name} must be an integer.")
    if isinstance(value, int):
        return value
    if isinstance(value, float):
        raise ValueError(f"{name} must be an integer.")
    if isinstance(value, str):
        text = value.strip()
        signless = text[1:] if text.startswith(("+", "-")) else text
        if signless.isdigit():
            return int(text)
    raise ValueError(f"{name} must be an integer.")


def _require_finite_float(run, field):
    if field not in run or _is_missing(run.get(field)):
        raise ValueError(f"Run {field} is required and must be numeric.")
    value = _to_float(run.get(field))
    if value is None:
        raise ValueError(f"Run {field} must be numeric.")
    if not math.isfinite(value):
        raise ValueError(f"Run {field} must be finite.")
    return value


def _validate_run_shape(run):
    if not isinstance(run, Mapping):
        raise ValueError("Run must be a mapping.")

    required_fields = ("mode", "scope", "target", "achieved", "failure_rate")
    for field in required_fields:
        if field not in run:
            raise ValueError(f"Run {field} is required.")

    if not isinstance(run["mode"], str) or not run["mode"].strip():
        raise ValueError("Run mode must be a non-empty string.")
    if run["mode"] not in SUPPORTED_MODES:
        raise ValueError(f"Unsupported run mode: {run['mode']}")
    if not isinstance(run["scope"], str) or not run["scope"].strip():
        raise ValueError("Run scope must be a non-empty string.")


def build_target_scopes(target_urls):
    if (
        target_urls is None
        or isinstance(target_urls, (str, bytes, Mapping))
        or not isinstance(target_urls, Sequence)
    ):
        raise ValueError("Target URLs must be a non-empty collection of strings.")

    try:
        iterator = iter(target_urls)
    except TypeError as exc:
        raise ValueError("Target URLs must be a non-empty collection of strings.") from exc

    urls = []
    for url in iterator:
        if not isinstance(url, str) or not url.strip():
            raise ValueError("Target URLs must be non-empty strings.")
        urls.append(url.strip())

    if not urls:
        raise ValueError("At least one target URL is required.")
    scopes = [{"name": "single_lb", "target_urls": [urls[0]]}]
    if len(urls) > 1:
        scopes.append({"name": "all_lbs", "target_urls": urls})
    return scopes


def compute_worker_count(policy, cpu_count, cpu_reserve, minimum, maximum):
    cpu_count = _parse_integral(cpu_count, "cpu_count")
    cpu_reserve = _parse_integral(cpu_reserve, "cpu_reserve")
    minimum = _parse_integral(minimum, "minimum")
    maximum = _parse_integral(maximum, "maximum")

    if cpu_count <= 0:
        raise ValueError("cpu_count must be greater than 0.")
    if cpu_reserve < 0:
        raise ValueError("cpu_reserve must be greater than or equal to 0.")
    if minimum <= 0:
        raise ValueError("minimum must be greater than 0.")
    if maximum <= 0:
        raise ValueError("maximum must be greater than 0.")
    if maximum < minimum:
        raise ValueError("maximum must be greater than or equal to minimum.")

    if isinstance(policy, str) and policy.strip().lower() == "auto":
        desired = cpu_count - cpu_reserve
    else:
        desired = _parse_integral(policy, "policy")
        if desired <= 0:
            raise ValueError("policy must be greater than 0.")
    return max(minimum, min(maximum, desired))


def best_stable_capacity(runs, mode, scope):
    mode = str(mode)
    if mode not in SUPPORTED_MODES:
        raise ValueError(f"Unsupported mode: {mode}")

    if not isinstance(scope, str) or not scope.strip():
        raise ValueError("scope must be a non-empty string.")

    stable = []
    for run in runs:
        _validate_run_shape(run)

        target = _require_finite_float(run, "target")
        achieved = _require_finite_float(run, "achieved")
        failure_rate = _require_finite_float(run, "failure_rate")
        if target <= 0:
            raise ValueError("Run target must be greater than 0.")
        if run["mode"] == "cps" and not target.is_integer():
            raise ValueError("Run target must be an integer for cps mode.")
        if achieved < 0:
            raise ValueError("Run achieved must be greater than or equal to 0.")
        if failure_rate < 0 or failure_rate > 1:
            raise ValueError("Run failure_rate must be between 0 and 1.")

        if run.get("mode") != mode or run.get("scope") != scope:
            continue

        target_ratio = achieved / target
        required_ratio = 0.90 if mode == "cps" else 0.85
        if failure_rate <= 0.01 and target_ratio >= required_ratio:
            stable.append({
                "target": int(target) if mode == "cps" else target,
                "achieved": achieved,
                "failure_rate": failure_rate,
            })
    return max(stable, key=lambda item: float(item["target"]), default=None)


def recommend_lbs(customer_peak, per_lb_capacity, headroom_percent):
    if any(_is_missing(value) for value in (customer_peak, per_lb_capacity, headroom_percent)):
        return None
    if any(isinstance(value, bool) for value in (customer_peak, per_lb_capacity, headroom_percent)):
        return None

    customer_peak = _to_float(customer_peak)
    per_lb_capacity = _to_float(per_lb_capacity)
    headroom_percent = _to_float(headroom_percent)
    if customer_peak is None or per_lb_capacity is None or headroom_percent is None:
        return None
    if not all(math.isfinite(value) for value in (customer_peak, per_lb_capacity, headroom_percent)):
        return None
    if customer_peak <= 0 or per_lb_capacity <= 0 or headroom_percent < 0:
        return None
    adjusted_peak = customer_peak * (1.0 + headroom_percent / 100.0)
    if not math.isfinite(adjusted_peak):
        return None
    quotient = adjusted_peak / per_lb_capacity
    if not math.isfinite(quotient):
        return None
    return int(math.ceil(quotient))


class Controller:
    def __init__(self, config_path):
        self.config_path = Path(config_path)
        self.cfg = json.loads(self.config_path.read_text(encoding="utf-8"))
        stamp = utc_now().strftime("%Y%m%dT%H%M%SZ")
        self.run_id = f"{safe_label(self.cfg.get('name_prefix', 'flb-simple'))}-{stamp}"
        self.run_root = ROOT / "results" / self.run_id
        self.run_root.mkdir(parents=True, exist_ok=True)
        self.log_path = self.run_root / "controller.log"
        self.index = {
            "run_id": self.run_id,
            "generated_at_utc": iso(utc_now()),
            "lb_count": self.cfg.get("lb_count"),
            "target_urls": self.cfg.get("target_urls", []),
            "runs": [],
        }
        self.object_client = None
        self.signer = None
        self.local_workers = []
        self.uploaded_files = {}

    def log(self, message):
        line = f"{iso(utc_now())} {message}"
        print(line, flush=True)
        with self.log_path.open("a", encoding="utf-8") as fh:
            fh.write(line + "\n")

    def write_json(self, path, data):
        path = Path(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(data, indent=2, sort_keys=True), encoding="utf-8")

    def wait_initial(self):
        seconds = int(self.cfg.get("initial_wait_seconds", 0) or 0)
        if seconds > 0:
            self.log(f"Initial wait: {seconds}s")
            time.sleep(seconds)

    def readiness(self):
        import requests

        targets = self.cfg.get("target_urls") or []
        verify = bool(self.cfg.get("locust_verify_tls", False))
        connect = float(self.cfg.get("locust_connect_timeout_seconds", 8))
        read = float(self.cfg.get("locust_read_timeout_seconds", 15))
        deadline = time.time() + 1800
        last = []
        while time.time() < deadline:
            last = []
            for target in targets:
                url = target.rstrip("/") + "/healthz"
                try:
                    response = requests.get(url, verify=verify, timeout=(connect, read))
                    ok = response.status_code == 200
                    last.append({
                        "url": url,
                        "ok": ok,
                        "status_code": response.status_code,
                    })
                except Exception as exc:
                    last.append({"url": url, "ok": False, "error": str(exc)})
            self.write_json(
                self.run_root / "readiness.json",
                {"checks": last, "checked_at_utc": iso(utc_now())},
            )
            if last and all(item.get("ok") for item in last):
                self.log(f"All {len(targets)} LB target(s) are ready.")
                return
            self.log(
                "Targets not ready yet: "
                + "; ".join(
                    f"{item['url']}={item.get('status_code', item.get('error'))}"
                    for item in last[:5]
                )
            )
            time.sleep(15)
        raise TimeoutError("Timed out waiting for LB target readiness.")

    def base_env(self, mode, target_urls):
        default_host = target_urls[0]
        env = os.environ.copy()
        env.update({
            "LOCUST_MODE": mode,
            "LOCUST_HEALTH_PATH": "/healthz",
            "LOCUST_THROUGHPUT_PATH": self.cfg.get(
                "throughput_payload_path", "/payload_100k"
            ),
            "LOCUST_VERIFY_TLS": str(
                bool(self.cfg.get("locust_verify_tls", False))
            ).lower(),
            "LOCUST_CONNECT_TIMEOUT_S": str(
                self.cfg.get("locust_connect_timeout_seconds", 8)
            ),
            "LOCUST_READ_TIMEOUT_S": str(
                self.cfg.get("locust_read_timeout_seconds", 15)
            ),
            "LOCUST_WAIT_TIME_S": str(self.cfg.get("locust_wait_time_seconds", 1.0)),
            "LOCUST_TARGETS": ",".join(target_urls),
            "LOCUST_DEFAULT_HOST": default_host,
            "PATH": f"{ROOT / 'venv' / 'bin'}:/usr/local/bin:/usr/bin:/bin",
        })
        return env

    def worker_count(self):
        cpu_count = os.cpu_count() or 1
        return compute_worker_count(
            self.cfg.get("worker_processes", "auto"),
            cpu_count,
            self.cfg.get("cpu_reserve", 1),
            self.cfg.get("min_workers", 1),
            self.cfg.get("max_workers", 16),
        )

    def start_workers(self, env, count):
        self.stop_workers()
        self.local_workers = []
        try:
            for index in range(count):
                log_path = self.run_root / f"locust-worker-{index + 1}.log"
                fh = None
                try:
                    fh = log_path.open("wb")
                    proc = subprocess.Popen(
                        [
                            PYTHON,
                            "-m",
                            "locust",
                            "-f",
                            LOCUSTFILE,
                            "--worker",
                            "--master-host",
                            "127.0.0.1",
                            "--reset-stats",
                        ],
                        stdout=fh,
                        stderr=subprocess.STDOUT,
                        env=env,
                        cwd=str(ROOT),
                    )
                    self.local_workers.append((proc, fh))
                except Exception:
                    if fh is not None and not fh.closed:
                        fh.close()
                    raise
        except Exception:
            self.stop_workers()
            raise
        self.log(f"Started {count} local Locust worker(s).")

    def stop_workers(self):
        for proc, fh in self.local_workers:
            if proc.poll() is None:
                proc.terminate()
        for proc, fh in self.local_workers:
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=10)
            fh.close()
        self.local_workers = []

    @staticmethod
    def to_float(value):
        if value is None or value == "":
            return None
        try:
            return float(str(value).replace(",", ""))
        except Exception:
            return None

    def parse_locust_stats(self, run_dir, label, hold_seconds=None):
        stats_path = run_dir / f"{label}_stats.csv"
        history_path = run_dir / f"{label}_stats_history.csv"
        result = {
            "stats_csv": str(stats_path),
            "stats_history_csv": str(history_path),
        }
        if stats_path.exists():
            rows = list(csv.DictReader(stats_path.open(newline="", encoding="utf-8")))
            selected = None
            for row in rows:
                if (row.get("Name") or "").strip().lower() in ("aggregated", "total"):
                    selected = row
            if selected is None and rows:
                selected = rows[-1]
            if selected:
                request_count = self.to_float(
                    selected.get("Request Count") or selected.get("Requests")
                )
                failures = self.to_float(
                    selected.get("Failure Count") or selected.get("Failures")
                )
                rps = self.to_float(
                    selected.get("Requests/s") or selected.get("Requests/s ")
                )
                result.update({
                    "request_count": request_count,
                    "failure_count": failures,
                    "failure_rate": (failures / request_count)
                    if request_count and failures is not None
                    else None,
                    "requests_per_second": rps,
                    "average_response_ms": self.to_float(
                        selected.get("Average Response Time")
                    ),
                    "p95_response_ms": self.to_float(selected.get("95%")),
                    "p99_response_ms": self.to_float(selected.get("99%")),
                })
        if history_path.exists():
            rows = list(csv.DictReader(history_path.open(newline="", encoding="utf-8")))
            values = []
            timed_values = []
            for row in rows:
                name = (row.get("Name") or "").strip().lower()
                if name and name not in ("aggregated", "total"):
                    continue
                value = self.to_float(
                    row.get("Requests/s") or row.get("Requests/s ")
                )
                if value is not None:
                    values.append(value)
                    timestamp = self.to_float(row.get("Timestamp"))
                    if timestamp is not None:
                        timed_values.append((timestamp, value))
            if values:
                result["history_avg_rps"] = sum(values) / len(values)
                result["history_peak_rps"] = max(values)
            if timed_values and hold_seconds:
                latest_timestamp = max(timestamp for timestamp, _ in timed_values)
                cutoff = latest_timestamp - float(hold_seconds)
                hold_values = [
                    value
                    for timestamp, value in timed_values
                    if timestamp >= cutoff
                ]
                if hold_values:
                    result["hold_avg_rps"] = sum(hold_values) / len(hold_values)
                    result["hold_peak_rps"] = max(hold_values)
                    result["hold_sample_count"] = len(hold_values)
        return result

    def run_locust(self, mode, scope, target_urls, target, users, warmup, hold):
        label = safe_label(f"{scope}_{mode}_{target}_{hold}s")
        run_dir = self.run_root / label
        run_dir.mkdir(parents=True, exist_ok=True)
        csv_prefix = run_dir / label
        html_path = run_dir / f"{label}.html"
        log_path = run_dir / f"{label}.log"
        run_time = int(warmup) + int(hold)
        spawn_rate = max(1, int(round(int(users) / max(1, int(warmup)))))
        env = self.base_env(mode, target_urls)
        workers = self.worker_count()
        cmd = [
            PYTHON,
            "-m",
            "locust",
            "-f",
            LOCUSTFILE,
            "--master",
            "--headless",
            "--master-bind-host",
            "127.0.0.1",
            "--expect-workers",
            str(workers),
            "--expect-workers-max-wait",
            "180",
            "--host",
            target_urls[0],
            "--users",
            str(int(users)),
            "--spawn-rate",
            str(spawn_rate),
            "--run-time",
            f"{run_time}s",
            "--stop-timeout",
            "30",
            "--only-summary",
            "--reset-stats",
            "--csv",
            str(csv_prefix),
            "--csv-full-history",
            "--html",
            str(html_path),
        ]
        self.log(
            f"Starting {label}: users={users} spawn_rate={spawn_rate} "
            f"workers={workers}"
        )
        start = utc_now()
        try:
            self.start_workers(env, workers)
            with log_path.open("wb") as log_fh:
                proc = subprocess.run(
                    cmd,
                    stdout=log_fh,
                    stderr=subprocess.STDOUT,
                    env=env,
                    cwd=str(ROOT),
                    check=False,
                )
        finally:
            self.stop_workers()
        end = utc_now()
        locust = self.parse_locust_stats(run_dir, label, hold_seconds=int(hold))
        achieved = locust.get("hold_avg_rps")
        if achieved is None:
            achieved = locust.get("requests_per_second")
        if achieved is None:
            achieved = locust.get("history_avg_rps")
        if achieved is None:
            achieved = 0.0
        if mode == "throughput":
            achieved = (
                float(achieved)
                * float(self.cfg.get("throughput_payload_bytes", 1))
                * 8.0
                / 1e9
            )
        failure_rate = locust.get("failure_rate")
        if failure_rate is None:
            failure_rate = 1.0
        summary = {
            "label": label,
            "scope": scope,
            "mode": mode,
            "target": target,
            "target_urls": target_urls,
            "users": int(users),
            "spawn_rate": spawn_rate,
            "workers": workers,
            "warmup_seconds": int(warmup),
            "hold_seconds": int(hold),
            "start_utc": iso(start),
            "end_utc": iso(end),
            "returncode": proc.returncode,
            "locust": locust,
            "achieved": float(achieved),
            "failure_rate": float(failure_rate),
        }
        self.write_json(run_dir / "summary.json", summary)
        self.index["runs"].append(summary)
        self.write_json(self.run_root / "index.json", self.index)
        self.upload_tree(self.run_root, best_effort=True, only_changed=True)
        return summary

    def get_object_client(self):
        if self.object_client is not None:
            return self.object_client
        import oci

        self.signer = oci.auth.signers.InstancePrincipalsSecurityTokenSigner()
        self.object_client = oci.object_storage.ObjectStorageClient(
            {"region": self.cfg.get("region")},
            signer=self.signer,
        )
        return self.object_client

    def namespace(self):
        namespace = str(self.cfg.get("results_namespace") or "").strip()
        if namespace:
            self.cfg["results_namespace"] = namespace
            return namespace
        client = self.get_object_client()
        namespace = client.get_namespace().data
        self.cfg["results_namespace"] = namespace
        self.write_json(self.run_root / "config.json", self.cfg)
        return namespace

    def upload_tree(self, root, best_effort=False, only_changed=False):
        try:
            bucket = self.cfg.get("results_bucket_name")
            if not bucket:
                raise RuntimeError("results_bucket_name is required.")
            client = self.get_object_client()
            namespace = self.namespace()
            prefix = str(self.cfg.get("results_prefix") or "").strip("/")
            for path in Path(root).rglob("*"):
                if not path.is_file():
                    continue
                rel = path.relative_to(root)
                rel_name = rel.as_posix()
                stat = path.stat()
                marker = (stat.st_size, stat.st_mtime_ns)
                if only_changed and self.uploaded_files.get(rel_name) == marker:
                    continue
                object_name = "/".join(part for part in [prefix, self.run_id, rel_name] if part)
                with path.open("rb") as fh:
                    client.put_object(namespace, bucket, object_name, fh)
                self.uploaded_files[rel_name] = marker
            self.log(f"Uploaded artifacts to bucket={bucket} prefix={prefix}/{self.run_id}")
            return True
        except Exception as exc:
            self.log(f"Artifact upload failed: {exc}")
            if best_effort:
                return False
            raise

    def recommendations(self):
        runs = []
        for run in self.index.get("runs", []):
            runs.append({
                "scope": run.get("scope"),
                "mode": run.get("mode"),
                "target": run.get("target"),
                "achieved": run.get("achieved"),
                "failure_rate": run.get("failure_rate"),
            })
        lb_count = max(1, int(self.cfg.get("lb_count") or 1))
        rec = {
            "lb_count": lb_count,
            "criteria": {
                "cps_stable_if": (
                    "failure_rate <= 1% and achieved RPS >= 90% of target"
                ),
                "throughput_stable_if": (
                    "failure_rate <= 1% and achieved Gbps >= 85% of target"
                ),
            },
            "best": {
                "single_lb_cps": best_stable_capacity(runs, "cps", "single_lb"),
                "all_lbs_cps": best_stable_capacity(runs, "cps", "all_lbs"),
                "single_lb_throughput": best_stable_capacity(
                    runs,
                    "throughput",
                    "single_lb",
                ),
                "all_lbs_throughput": best_stable_capacity(
                    runs,
                    "throughput",
                    "all_lbs",
                ),
            },
            "customer_sizing": {},
            "notes": [
                "One generator can become the bottleneck. Interpret results with "
                "generator CPU, worker count, and observed failures.",
                "Scale efficiency is all-LB achieved capacity divided by single-LB "
                "achieved capacity times LB count.",
            ],
        }
        for key, customer_key, output_key in [
            ("single_lb_cps", "customer_peak_cps", "recommended_lbs_for_cps"),
            (
                "single_lb_throughput",
                "customer_peak_gbps",
                "recommended_lbs_for_bandwidth",
            ),
        ]:
            best = rec["best"].get(key)
            if best:
                rec["customer_sizing"][output_key] = recommend_lbs(
                    self.cfg.get(customer_key),
                    best.get("achieved"),
                    self.cfg.get("sizing_headroom_percent", 30),
                )
        return rec

    def archive(self):
        archive_path = self.run_root.parent / f"{self.run_id}.tar.gz"
        with tarfile.open(archive_path, "w:gz") as tar:
            tar.add(self.run_root, arcname=self.run_id)
        shutil.move(str(archive_path), str(self.run_root / archive_path.name))

    def run_suite(self):
        self.write_json(self.run_root / "config.json", self.cfg)
        scopes = build_target_scopes(self.cfg.get("target_urls") or [])
        self.wait_initial()
        self.readiness()
        for scope in scopes:
            for tier in self.cfg.get("cps_tiers") or []:
                self.run_locust(
                    "cps",
                    scope["name"],
                    scope["target_urls"],
                    int(tier),
                    int(tier),
                    self.cfg.get("cps_warmup_seconds", 60),
                    self.cfg.get("cps_hold_seconds", 180),
                )
            payload_bytes = max(1, int(self.cfg.get("throughput_payload_bytes", 102400)))
            for gbps in self.cfg.get("throughput_targets_gbps") or []:
                users = max(1, int(round(float(gbps) * 1e9 / 8.0 / payload_bytes)))
                self.run_locust(
                    "throughput",
                    scope["name"],
                    scope["target_urls"],
                    float(gbps),
                    users,
                    self.cfg.get("throughput_warmup_seconds", 60),
                    self.cfg.get("throughput_hold_seconds", 180),
                )
        self.write_json(self.run_root / "recommendations.json", self.recommendations())
        self.write_json(self.run_root / "index.json", self.index)
        self.archive()
        self.upload_tree(self.run_root)
        self.log("Benchmark suite complete.")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", default="/opt/flb-benchmark/config.json")
    args = parser.parse_args()
    controller = Controller(args.config)
    try:
        controller.run_suite()
    except Exception as exc:
        controller.log(f"Controller failed: {exc}")
        controller.write_json(
            controller.run_root / "failure.json",
            {
                "error": str(exc),
                "traceback": traceback.format_exc(),
                "failed_at_utc": iso(utc_now()),
            },
        )
        try:
            controller.upload_tree(controller.run_root)
        except Exception:
            controller.log("Upload after failure also failed.")
        raise
    finally:
        controller.stop_workers()


if __name__ == "__main__":
    main()
