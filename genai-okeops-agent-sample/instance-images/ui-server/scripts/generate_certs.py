# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import subprocess
from pathlib import Path
from urllib.parse import urlparse


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_ENV_FILE = ROOT / ".env"
DEFAULT_ENV_EXAMPLE = ROOT / ".env.example"
DEFAULT_CERT_DIR = ROOT / "certs"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate local self-signed TLS certs for the container.")
    parser.add_argument("--base-url", default="https://localhost:8000")
    parser.add_argument("--cert-dir", default=str(DEFAULT_CERT_DIR))
    parser.add_argument("--cert-name", default="app")
    parser.add_argument("--days", type=int, default=365)
    parser.add_argument("--env-file", default=str(DEFAULT_ENV_FILE))
    parser.add_argument("--overwrite", action="store_true")
    return parser.parse_args()


def hostname_from_url(base_url: str) -> str:
    parsed = urlparse(base_url)
    if not parsed.scheme or not parsed.hostname:
        raise SystemExit("base URL must include scheme and host, for example https://localhost:8000")
    return parsed.hostname


def san_for_host(hostname: str) -> str:
    entries = ["DNS:localhost", "IP:127.0.0.1"]
    if hostname not in {"localhost", "127.0.0.1"}:
        prefix = "IP" if hostname.replace(".", "").isdigit() else "DNS"
        entries.append(f"{prefix}:{hostname}")
    return ",".join(dict.fromkeys(entries))


def read_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.exists():
        return values
    for line in path.read_text(encoding="utf-8").splitlines():
        clean = line.strip()
        if not clean or clean.startswith("#") or "=" not in clean:
            continue
        key, value = clean.split("=", 1)
        values[key.strip()] = value.strip().strip('"').strip("'")
    return values


def write_env(path: Path, values: dict[str, str]) -> None:
    if not path.exists() and DEFAULT_ENV_EXAMPLE.exists():
        path.write_text(DEFAULT_ENV_EXAMPLE.read_text(encoding="utf-8"), encoding="utf-8")

    existing = path.read_text(encoding="utf-8").splitlines() if path.exists() else []
    updates = {
        "APP_BASE_URL": values["APP_BASE_URL"],
        "APP_TLS_CERT_FILE": values["APP_TLS_CERT_FILE"],
        "APP_TLS_KEY_FILE": values["APP_TLS_KEY_FILE"],
        "AUTH_COOKIE_SECURE": values["AUTH_COOKIE_SECURE"],
    }
    seen: set[str] = set()
    output: list[str] = []

    for line in existing:
        clean = line.strip()
        if clean and not clean.startswith("#") and "=" in clean:
            key = clean.split("=", 1)[0].strip()
            if key in updates:
                output.append(f"{key}={updates[key]}")
                seen.add(key)
                continue
        output.append(line)

    for key, value in updates.items():
        if key not in seen:
            output.append(f"{key}={value}")

    path.write_text("\n".join(output).rstrip() + "\n", encoding="utf-8")


def main() -> int:
    args = parse_args()
    base_url = args.base_url.rstrip("/")
    hostname = hostname_from_url(base_url)
    cert_dir = Path(args.cert_dir)
    cert_dir.mkdir(parents=True, exist_ok=True)

    cert_path = cert_dir / f"{args.cert_name}.crt"
    key_path = cert_dir / f"{args.cert_name}.key"
    if cert_path.exists() and key_path.exists() and not args.overwrite:
        print(f"Using existing certs in {cert_dir}")
    else:
        subprocess.run(
            [
                "openssl",
                "req",
                "-x509",
                "-newkey",
                "rsa:2048",
                "-sha256",
                "-days",
                str(args.days),
                "-nodes",
                "-keyout",
                str(key_path),
                "-out",
                str(cert_path),
                "-subj",
                f"/CN={hostname}",
                "-addext",
                f"subjectAltName={san_for_host(hostname)}",
            ],
            check=True,
        )
        key_path.chmod(0o600)
        print(f"Generated {cert_path}")
        print(f"Generated {key_path}")

    write_env(
        Path(args.env_file),
        {
            "APP_BASE_URL": base_url,
            "APP_TLS_CERT_FILE": "/app/certs/app.crt",
            "APP_TLS_KEY_FILE": "/app/certs/app.key",
            "AUTH_COOKIE_SECURE": "true" if base_url.startswith("https://") else "false",
        },
    )
    print(f"Updated {args.env_file}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
