# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
import os
import random
from itertools import cycle

from locust import HttpUser, constant, task


VERIFY_TLS = os.environ.get("LOCUST_VERIFY_TLS", "false").lower() == "true"
CONNECT_TIMEOUT_S = float(os.environ.get("LOCUST_CONNECT_TIMEOUT_S", "8"))
READ_TIMEOUT_S = float(os.environ.get("LOCUST_READ_TIMEOUT_S", "15"))
WAIT_TIME_S = float(os.environ.get("LOCUST_WAIT_TIME_S", "1.0"))
MODE = os.environ.get("LOCUST_MODE", "cps").lower()
HEALTH_PATH = os.environ.get("LOCUST_HEALTH_PATH", "/healthz")
THROUGHPUT_PATH = os.environ.get("LOCUST_THROUGHPUT_PATH", "/payload_100k")
TARGETS = [
    target.strip()
    for target in os.environ.get("LOCUST_TARGETS", "").split(",")
    if target.strip()
]


class FlbBenchmarkUser(HttpUser):
    host = os.environ.get("LOCUST_DEFAULT_HOST", "https://127.0.0.1")
    wait_time = constant(WAIT_TIME_S)

    def on_start(self):
        self._targets = None
        if TARGETS:
            offset = random.randrange(len(TARGETS))
            ordered_targets = TARGETS[offset:] + TARGETS[:offset]
            self._targets = cycle(ordered_targets)

    def _next_base(self):
        if self._targets:
            return next(self._targets)
        return self.host

    @task
    def request(self):
        path = HEALTH_PATH if MODE == "cps" else THROUGHPUT_PATH
        base = self._next_base()
        url = f"{base.rstrip('/')}{path}"
        headers = {"Connection": "close"} if MODE == "cps" else {}
        self.client.get(
            url,
            headers=headers,
            verify=VERIFY_TLS,
            timeout=(CONNECT_TIMEOUT_S, READ_TIMEOUT_S),
            name=f"{MODE}{path}",
        )
