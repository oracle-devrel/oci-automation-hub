# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

"""Source checkout entry point for the same launcher used by frozen releases."""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
from backend.launcher import main
from scripts.install_support import check_startup


if __name__ == "__main__":
    try:
        check_startup(ROOT)
    except (RuntimeError, OSError) as exc:
        raise SystemExit(str(exc))
    main()
