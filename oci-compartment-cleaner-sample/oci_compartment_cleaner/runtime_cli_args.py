# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
"""Command-line argument parser."""

from __future__ import annotations

import argparse
import os

def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Dry-run, and only with --execute optionally delete, OCI resources in one compartment and region."
    )
    parser.add_argument("--compartment-id", required=True, help="Target compartment OCID.")
    parser.add_argument("--region", required=True, help="OCI region name, for example eu-frankfurt-1.")
    parser.add_argument(
        "--auth",
        choices=("config", "instance_principal", "resource_principal"),
        default="config",
        help="Authentication mode.",
    )
    parser.add_argument(
        "--config-file",
        default=os.path.expanduser("~/.oci/config"),
        help="OCI config file path when --auth config is used.",
    )
    parser.add_argument(
        "--profile",
        default="DEFAULT",
        help="OCI config profile when --auth config is used.",
    )
    parser.add_argument(
        "--output-dir",
        default="delete_runs",
        help="Local directory for the run log and dry-run plan files.",
    )
    parser.add_argument(
        "--log-bucket-name",
        help="Optional Object Storage bucket name where run artifacts are uploaded at the end.",
    )
    parser.add_argument(
        "--log-bucket-namespace",
        help="Optional Object Storage namespace for --log-bucket-name. If omitted, the script resolves it.",
    )
    parser.add_argument(
        "--log-object-prefix",
        default="compartment-delete-runs",
        help="Object name prefix for uploaded logs and plans.",
    )
    parser.add_argument(
        "--skip-rm-backup-stack",
        action="store_true",
        help=(
            "Skip the default Resource Manager backup stack creation before deletion. "
            "Without this flag, --execute requires --rm-backup-stack-compartment-id before deletion can start."
        ),
    )
    parser.add_argument(
        "--rm-backup-stack-compartment-id",
        help=(
            "Compartment OCID where the Resource Manager resource-discovery backup stack is created. "
            "Must be different from --compartment-id unless --skip-rm-backup-stack is supplied."
        ),
    )
    parser.add_argument(
        "--rm-backup-stack-region",
        help="Region where the Resource Manager backup stack is created. Defaults to --region.",
    )
    parser.add_argument(
        "--rm-backup-services-to-discover",
        help=(
            "Optional comma-separated Resource Manager services_to_discover filter. "
            "Omit to discover all supported services in the source compartment and region."
        ),
    )
    parser.add_argument(
        "--rm-backup-wait-seconds",
        type=int,
        default=1800,
        help="Maximum seconds to wait for the Resource Manager backup stack to become ACTIVE.",
    )
    parser.add_argument(
        "--rm-backup-wait-interval-seconds",
        type=int,
        default=20,
        help="Seconds between Resource Manager backup stack lifecycle checks.",
    )
    parser.add_argument(
        "--rm-backup-failure-action",
        choices=("prompt", "stop", "continue"),
        default="prompt",
        help=(
            "What to do if Resource Manager backup stack creation fails before deletion. "
            "Default is prompt for DELETE_WITHOUT_BACKUP."
        ),
    )
    parser.add_argument(
        "--search-query",
        help="Override the default resource search query. Use with care.",
    )
    parser.add_argument(
        "--page-limit",
        type=int,
        default=1000,
        help="Resource Search page size.",
    )
    execution_group = parser.add_mutually_exclusive_group()
    execution_group.add_argument(
        "--execute",
        action="store_true",
        help=(
            "After writing the dry-run plan, ask for confirmation and then perform deletion. "
            "Without this flag the script only writes the dry-run plan and exits."
        ),
    )
    execution_group.add_argument(
        "--dry-run-only",
        action="store_true",
        help="Write the dry-run plan and exit. This is also the default when --execute is not supplied.",
    )
    parser.add_argument(
        "--include-terminal-states",
        action="store_true",
        help="Include resources already in terminal/deleting states in the deletion plan.",
    )
    parser.add_argument(
        "--skip-oke-worker-instances",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Skip compute instances that look like OKE worker nodes. Enabled by default.",
    )
    parser.add_argument(
        "--between-phases-sleep",
        type=int,
        default=20,
        help="Seconds to sleep when moving between deletion priority groups.",
    )
    parser.add_argument(
        "--delete-wait-timeout-seconds",
        type=int,
        default=1200,
        help=(
            "Maximum seconds to wait for async delete completion for OKE, load balancer, "
            "network load balancer, bastion, and VCN resources. Use 0 to disable these waits."
        ),
    )
    parser.add_argument(
        "--delete-wait-interval-seconds",
        type=int,
        default=20,
        help="Seconds between async delete completion checks.",
    )
    parser.add_argument(
        "--oke-cleanup-wait-seconds",
        type=int,
        dest="delete_wait_interval_seconds",
        default=argparse.SUPPRESS,
        help=argparse.SUPPRESS,
    )
    parser.add_argument(
        "--post-delete-verification-timeout-seconds",
        type=int,
        default=120,
        help=(
            "Maximum seconds to keep rescanning after deletion when resources are still returned. "
            "Use 0 for one immediate verification scan."
        ),
    )
    parser.add_argument(
        "--post-delete-verification-interval-seconds",
        type=int,
        default=20,
        help="Seconds between post-delete verification scans.",
    )
    parser.add_argument(
        "--throttle-retry-attempts",
        type=int,
        default=8,
        help="Total attempts for explicit 429 retry handling around OCI SDK calls.",
    )
    parser.add_argument(
        "--throttle-retry-base-sleep-seconds",
        type=float,
        default=2.0,
        help="Initial sleep seconds for explicit 429 retry handling.",
    )
    parser.add_argument(
        "--throttle-retry-max-sleep-seconds",
        type=float,
        default=60.0,
        help="Maximum sleep seconds between explicit 429 retries.",
    )
    parser.add_argument(
        "--no-sdk-retry-strategy",
        action="store_true",
        help="Disable OCI SDK DEFAULT_RETRY_STRATEGY; explicit 429 retry handling remains enabled.",
    )
    parser.add_argument("--debug", action="store_true", help="Enable debug logging.")
    return parser.parse_args()
