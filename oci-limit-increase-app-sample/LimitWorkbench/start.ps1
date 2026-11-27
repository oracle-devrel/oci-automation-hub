# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

$ErrorActionPreference = 'Stop'
if (-not (Test-Path "$PSScriptRoot\.venv\Scripts\python.exe")) {
    Write-Error 'App environment not found. Run setup.ps1 or setup.cmd first.'
    exit 1
}
& "$PSScriptRoot\.venv\Scripts\python.exe" "$PSScriptRoot\scripts\run_app.py" @args
exit $LASTEXITCODE
