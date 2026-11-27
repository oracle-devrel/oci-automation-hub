REM Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
REM The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

@echo off
setlocal
if not exist "%~dp0.venv\Scripts\python.exe" goto missing_setup
"%~dp0.venv\Scripts\python.exe" "%~dp0scripts\run_app.py" %*
exit /b %errorlevel%
:missing_setup
echo App environment not found. Run setup.cmd first.
exit /b 1
