# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
"""Resource Manager backup stack and confirmation prompts."""

from __future__ import annotations

from .runtime_core import *
from .resource_manager_backup import ResourceManagerBackupOptions, create_compartment_backup_stack

def prompt_for_delete(resources: list[ResourceRecord], logger: logging.Logger) -> bool:
    if not resources:
        logger.info("No resources planned for deletion; nothing to confirm")
        return False
    print()
    print(f"Dry-run completed. {len(resources)} resources are planned for deletion.")
    print("Type DELETE to continue with actual deletion, or anything else to stop.")
    answer = input("Continue? ").strip()
    if answer == "DELETE":
        logger.info("User confirmed deletion")
        return True
    logger.info("User did not confirm deletion; stopping after dry run")
    return False


def log_resource_manager_backup_dry_run(args: argparse.Namespace, logger: logging.Logger) -> None:
    if args.skip_rm_backup_stack:
        logger.info(
            "Resource Manager backup stack is explicitly skipped by --skip-rm-backup-stack"
        )
        return
    if args.rm_backup_stack_compartment_id:
        stack_region = args.rm_backup_stack_region or args.region
        services = (
            ", ".join(parse_csv_values(args.rm_backup_services_to_discover))
            or "all supported services"
        )
        if args.rm_backup_stack_compartment_id == args.compartment_id:
            logger.info(
                "Resource Manager backup stack is enabled, but the configured stack compartment "
                "matches the target cleanup compartment; deletion will stop before resource deletes"
            )
            return
        logger.info(
            "Resource Manager backup stack is configured for creation after DELETE confirmation: "
            "stack_compartment=%s stack_region=%s services=%s",
            args.rm_backup_stack_compartment_id,
            stack_region,
            services,
        )
        return
    logger.info(
        "Resource Manager backup stack is enabled by default for deletion; "
        "--rm-backup-stack-compartment-id is required unless --skip-rm-backup-stack is supplied"
    )


def continue_after_resource_manager_backup_failure(
    args: argparse.Namespace,
    logger: logging.Logger,
) -> bool:
    action = args.rm_backup_failure_action
    if action == "continue":
        logger.warning(
            "Resource Manager backup failed; continuing because --rm-backup-failure-action=continue"
        )
        return True
    if action == "stop":
        logger.error(
            "Resource Manager backup failed; stopping before deletion because --rm-backup-failure-action=stop"
        )
        return False

    print()
    print("Resource Manager backup stack creation failed.")
    print("Type DELETE_WITHOUT_BACKUP to continue deletion anyway, or anything else to stop.")
    answer = input("Continue without Resource Manager backup? ").strip()
    if answer == "DELETE_WITHOUT_BACKUP":
        logger.warning("User confirmed deletion without a Resource Manager backup stack")
        return True
    logger.info("User stopped after Resource Manager backup failure")
    return False


def create_resource_manager_backup_before_deletion(
    args: argparse.Namespace,
    config: dict[str, Any],
    signer: Any,
    compartment_label: str,
    run_id: str,
    logger: logging.Logger,
) -> bool:
    if args.skip_rm_backup_stack:
        logger.warning(
            "Skipping Resource Manager backup stack creation because --skip-rm-backup-stack was supplied"
        )
        return True

    if not args.rm_backup_stack_compartment_id:
        logger.error(
            "Resource Manager backup stack is enabled by default; pass "
            "--rm-backup-stack-compartment-id with a different compartment OCID, "
            "or pass --skip-rm-backup-stack to delete without creating this stack"
        )
        print()
        print(
            "Deletion stopped: --rm-backup-stack-compartment-id is required unless "
            "--skip-rm-backup-stack is supplied."
        )
        return False

    if args.rm_backup_stack_compartment_id == args.compartment_id:
        logger.error(
            "Resource Manager backup stack compartment must be different from the target cleanup compartment"
        )
        print()
        print(
            "Deletion stopped: --rm-backup-stack-compartment-id must be different "
            "from --compartment-id."
        )
        return False

    options = ResourceManagerBackupOptions(
        source_compartment_id=args.compartment_id,
        source_region=args.region,
        stack_compartment_id=args.rm_backup_stack_compartment_id,
        stack_region=args.rm_backup_stack_region or args.region,
        source_compartment_label=compartment_label,
        services_to_discover=parse_csv_values(args.rm_backup_services_to_discover),
        wait_seconds=args.rm_backup_wait_seconds,
        wait_interval_seconds=args.rm_backup_wait_interval_seconds,
        run_id=run_id,
    )

    try:
        result = create_compartment_backup_stack(
            options=options,
            config=config,
            signer=signer,
            logger=logger,
            call_oci_func=call_oci,
        )
    except Exception as exc:
        logger.exception("Resource Manager backup stack creation failed: %s", exc)
        return continue_after_resource_manager_backup_failure(args, logger)

    logger.info(
        "Resource Manager backup stack ready: name=%s id=%s compartment=%s region=%s state=%s work_request=%s",
        result.stack_name,
        result.stack_id,
        result.stack_compartment_id,
        result.stack_region,
        result.lifecycle_state or "unknown",
        result.opc_work_request_id or "-",
    )
    print()
    print(
        "Resource Manager backup stack ready: "
        f"{result.stack_name} ({result.stack_id}) in {result.stack_region}"
    )
    return True
