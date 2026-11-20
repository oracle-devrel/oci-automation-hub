# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
from __future__ import annotations

import logging
from pathlib import Path

from .context import CleanupContext
from .executor import execute_plan
from . import runtime
from .planner import build_plan, write_plan_files
from .registry import load_registry


def main() -> int:
    args = runtime.parse_args()
    runtime.require_oci_sdk()

    run_id = runtime.utc_timestamp()
    compartment_short = runtime.sanitize_label(runtime.short_ocid(args.compartment_id))
    region_label = runtime.sanitize_label(args.region)
    run_base = f"delete_compartment_{compartment_short}_{region_label}_{run_id}"
    output_dir = Path(args.output_dir).expanduser().resolve()
    log_path = output_dir / f"{run_base}.log"
    plan_json_path = output_dir / f"{run_base}.plan.json"
    plan_text_path = output_dir / f"{run_base}.plan.txt"
    logger = runtime.setup_logging(log_path, args.debug)
    runtime.configure_retry_behavior(args, logger)

    artifact_paths = [log_path, plan_json_path, plan_text_path]
    config = None
    signer = None

    try:
        logger.info("Starting compartment cleanup run")
        logger.info("Compartment OCID: %s", args.compartment_id)
        logger.info("Region: %s", args.region)
        logger.info("Auth mode: %s", args.auth)
        config, signer = runtime.auth_config_and_signer(args)
        compartment_label = runtime.get_compartment_label(args.compartment_id, config, signer, logger)
        logger.info("Compartment label: %s", compartment_label)

        default_query = f"query all resources where compartmentId = '{args.compartment_id}'"
        search_query = args.search_query or default_query
        resources = runtime.discover_compartment_resources(
            compartment_id=args.compartment_id,
            query=args.search_query,
            limit=args.page_limit,
            config=config,
            signer=signer,
            include_terminal=args.include_terminal_states,
            logger=logger,
        )
        registry = load_registry()
        plan = build_plan(
            resources,
            include_terminal=args.include_terminal_states,
            skip_oke_workers=args.skip_oke_worker_instances,
            logger=logger,
            registry=registry,
        )
        write_plan_files(plan_json_path, plan_text_path, plan, args, search_query)
        logger.info("Dry-run plan JSON: %s", plan_json_path)
        logger.info("Dry-run plan text: %s", plan_text_path)
        logger.info("Run log: %s", log_path)
        runtime.log_resource_manager_backup_dry_run(args, logger)

        if not args.execute:
            if args.dry_run_only:
                logger.info("Dry-run-only mode requested; no deletion will be attempted")
            else:
                logger.info("Default dry-run mode; pass --execute to allow the confirmation prompt")
            return 0

        if runtime.prompt_for_delete(plan.resources, logger):
            if not runtime.create_resource_manager_backup_before_deletion(
                args=args,
                config=config,
                signer=signer,
                compartment_label=compartment_label,
                run_id=run_id,
                logger=logger,
            ):
                return 1
            context = CleanupContext(
                config=config,
                signer=signer,
                logger=logger,
                object_namespace=args.log_bucket_namespace,
                sleep_between_phases=args.between_phases_sleep,
                delete_wait_timeout_seconds=args.delete_wait_timeout_seconds,
                delete_wait_interval_seconds=args.delete_wait_interval_seconds,
            )
            execute_plan(plan, context)
            runtime.report_remaining_resources_after_deletion(
                compartment_id=args.compartment_id,
                query=args.search_query,
                limit=args.page_limit,
                config=config,
                signer=signer,
                timeout_seconds=args.post_delete_verification_timeout_seconds,
                interval_seconds=args.post_delete_verification_interval_seconds,
                logger=logger,
            )
        return 0
    finally:
        for handler in logging.getLogger("oci_compartment_cleaner").handlers:
            handler.flush()
        if config is not None:
            runtime.upload_artifacts_to_bucket(
                paths=[path for path in artifact_paths if path.exists()],
                bucket_name=args.log_bucket_name,
                namespace=args.log_bucket_namespace,
                object_prefix=args.log_object_prefix,
                config=config,
                signer=signer,
                logger=logger,
            )
