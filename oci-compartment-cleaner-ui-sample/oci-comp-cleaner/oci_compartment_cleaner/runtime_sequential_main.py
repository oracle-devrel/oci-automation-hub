# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

"""Compatibility entry point delegated to the manifest-driven cleaner CLI."""

from __future__ import annotations


def main() -> int:
    """Run the supported manifest-driven CLI without import-time cycles."""
    from .cli import main as cli_main

    return cli_main()


if __name__ == "__main__":
    raise SystemExit(main())
