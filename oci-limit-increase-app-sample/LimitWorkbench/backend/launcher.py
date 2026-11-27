# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

"""Shared source/frozen launcher. Normal startup never loads OCI credentials."""
import argparse
import io
import json
import os
import platform
import socket
import sys
import threading
import time
import webbrowser
from pathlib import Path

from .paths import app_directory, resource_directory
from .version import VERSION


def self_test():
    """Check bundled imports/resources without loading config or connecting anywhere."""
    def denied(*args, **kwargs):
        raise RuntimeError("Network access is prohibited during package self-test")
    socket.socket.connect = denied
    import certifi
    import oci
    import openpyxl
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    from .documents import parse_bom
    from .main import create_app
    from .oci_access import SdkGateway
    for client, methods in ((oci.identity.IdentityClient, ["list_availability_domains", "get_tenancy"]),
                            (oci.limits.LimitsClient, ["list_services", "list_limit_definitions", "list_limit_values"]),
                            (oci.limits_increase.LimitsIncreaseClient, ["list_limits_increase_questions", "create_limits_increase_request", "get_limits_increase_request"])):
        assert all(callable(getattr(client, method)) for method in methods)
    item = oci.limits_increase.models.CreateLimitsIncreaseItemRequestDetails(service_name="compute", limit_name="test-limit", region="test-region", value=1)
    assert oci.util.to_dict(item)["value"] == 1
    assert (resource_directory() / "frontend" / "dist" / "index.html").is_file()
    assert Path(certifi.where()).is_file()
    if getattr(sys, 'frozen', False):
        assert Path(certifi.where()).resolve().is_relative_to(resource_directory().resolve())
    # Exercise native crypto/client initialization with a disposable in-memory key.
    # No real config is read; all connections are still prohibited above.
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    pem = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()).decode()
    gateway = SdkGateway({'user': 'ocid1.user.oc1..fixture', 'tenancy': 'ocid1.tenancy.oc1..fixture',
                          'fingerprint': ':'.join(['00'] * 16), 'key_content': pem, 'region': 'us-ashburn-1'})
    for kind in ('identity', 'limits', 'limits_increase'):
        gateway.client(kind, 'us-ashburn-1')
    workbook = openpyxl.Workbook(); workbook.active.title = 'BOM'
    workbook.active.append(['SKU', 'Scenario/Product Description', 'Qty', 'Metric'])
    workbook.active.append(['TEST', 'Synthetic', 1, 'Each'])
    stream = io.BytesIO(); workbook.save(stream)
    assert parse_bom(stream.getvalue(), 'synthetic.xlsx')['rows'][0]['values']['SKU'] == 'TEST'
    assert create_app is not None and SdkGateway is not None and openpyxl.__version__
    print(json.dumps({"status": "ok", "version": VERSION, "architecture": platform.machine(),
                      "oci_sdk": oci.__version__, "app_directory": str(app_directory()),
                      "resources": str(resource_directory()), "network": "prohibited"}))


def main():
    parser = argparse.ArgumentParser(description="Start OCI Limit Workbench locally")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--data-dir", type=Path, help="Local draft and submission journal folder")
    parser.add_argument("--offline-catalog-dir", type=Path, help="Offline service/definition folder (default: app folder)")
    parser.add_argument("--no-browser", action="store_true")
    parser.add_argument("--self-test", action="store_true", help="Verify bundled dependencies without credentials/network")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    if not (resource_directory() / "frontend" / "dist" / "index.html").is_file():
        parser.error("Prebuilt UI is missing. Re-extract the release, or run npm ci and npm run build in frontend/ for a source checkout.")
    if args.data_dir:
        os.environ["LIMIT_APP_DATA_DIR"] = str(args.data_dir.expanduser().resolve())
    if args.offline_catalog_dir:
        os.environ["LIMIT_APP_OFFLINE_CATALOG_DIR"] = str(args.offline_catalog_dir.expanduser().resolve())
    import uvicorn
    from .main import create_app
    server = uvicorn.Server(uvicorn.Config(create_app(), host="127.0.0.1", port=args.port, workers=1))
    address = f"http://127.0.0.1:{args.port}"

    def open_when_ready():
        for _ in range(100):
            if server.should_exit:
                return
            if server.started:
                print(f"Open {address}", flush=True)
                if not args.no_browser:
                    webbrowser.open(address)
                return
            time.sleep(0.1)

    threading.Thread(target=open_when_ready, daemon=True).start()
    try:
        server.run()
    except KeyboardInterrupt:
        pass
