#!/usr/bin/env python3

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

"""Optional OCI discovery and user-only Terraform deploy/destroy handoffs."""

import argparse
import configparser
import getpass
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import warnings

ROOT = Path(__file__).resolve().parents[4]
CONFIG = Path.home() / ".oci" / "config"
WINDOWS = sys.platform == "win32"
DESTROY_DUMMY_VALUES = {name: "destroy-unused" for name in
                        ("nvidia_api_key", "ocir_auth_token", "ocir_username")}

# Paths are passed through the environment, never interpolated into PowerShell.
# Replace access rules while preserving ownership and audit settings.
WINDOWS_ACL_SCRIPT = r"""
$ErrorActionPreference = 'Stop'
$failureCode = 21
try {
    $path = $env:SWITCHYARD_PRIVATE_PATH
    $item = Get-Item -LiteralPath $path -Force
    if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        throw 'Private paths cannot be reparse points.'
    }
    $failureCode = 22
    $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    if ($item.PSIsContainer) {
        $acl = Get-Acl -LiteralPath $path
        $inheritance = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
    } else {
        $acl = Get-Acl -LiteralPath $path
        $inheritance = [System.Security.AccessControl.InheritanceFlags]::None
    }
    $acl.SetAccessRuleProtection($true, $false)
    # Remove all explicit access rules after disabling inheritance.
    $rulesToRemove = @($acl.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]))
    foreach ($existingRule in $rulesToRemove) {
        $acl.RemoveAccessRuleSpecific($existingRule)
    }
    $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
        $sid, [System.Security.AccessControl.FileSystemRights]::FullControl,
        $inheritance, [System.Security.AccessControl.PropagationFlags]::None,
        [System.Security.AccessControl.AccessControlType]::Allow)
    $acl.AddAccessRule($rule)
    $failureCode = 23
    # Persist only modified access rules. Set-Acl can also attempt to write
    # audit settings on directories and require SeSecurityPrivilege.
    $item.SetAccessControl($acl)
    $failureCode = 24
    $actual = Get-Acl -LiteralPath $path
    $rules = @($actual.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
    if (!$actual.AreAccessRulesProtected -or $rules.Count -ne 1 -or
        $rules[0].IdentityReference.Value -ne $sid.Value -or
        $rules[0].AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow -or
        $rules[0].FileSystemRights -ne [System.Security.AccessControl.FileSystemRights]::FullControl) {
        throw 'Private ACL verification failed.'
    }
    exit 0
} catch {
    exit $failureCode
}
"""


class DeploymentError(Exception):
    """A safe user-facing error without raw command output or secret values."""


def clean_environment():
    return {key: value for key, value in os.environ.items()
            if not key.upper().startswith(("TF_", "OCI_"))}


def find_command(name):
    executable = shutil.which(name)
    # Windows may run batch wrappers through cmd.exe despite shell=False.
    # OCI remains optional: use a native executable or the manual workflow.
    if WINDOWS and executable and Path(executable).suffix.lower() in (".cmd", ".bat"):
        return None
    return executable


def windows_powershell():
    system_root = os.environ.get("SystemRoot", r"C:\Windows")
    executable = Path(system_root) / "System32/WindowsPowerShell/v1.0/powershell.exe"
    if not executable.is_file():
        raise DeploymentError("Windows PowerShell is required to protect private files with ACLs.")
    return str(executable)


def secure_path(path):
    if path.is_symlink():
        raise DeploymentError("Private paths must not be symbolic links.")
    if not WINDOWS:
        path.chmod(0o700 if path.is_dir() else 0o600)
        return
    # Python may inherit PowerShell 7's module paths. Windows PowerShell 5.1
    # cannot load those modules, even with -NoProfile. Let it rebuild its defaults.
    env = {key: value for key, value in clean_environment().items()
           if key.upper() != "PSMODULEPATH"}
    # Keep the final path component intact so PowerShell can reject junctions.
    env["SWITCHYARD_PRIVATE_PATH"] = str(path.absolute())
    try:
        proc = subprocess.run([windows_powershell(), "-NoProfile", "-NonInteractive",
                               "-Command", WINDOWS_ACL_SCRIPT], capture_output=True,
                              text=True, env=env, timeout=60)
        if proc.returncode:
            stage = {21: "reading the target", 22: "building permissions",
                     23: "applying permissions", 24: "verifying permissions"}.get(
                         proc.returncode, "starting the ACL command")
            raise DeploymentError(
                "Cannot enforce private Windows ACLs while " + stage +
                " (exit code " + str(proc.returncode) + "). "
                "Use a dedicated checkout on a local NTFS volume owned by your account.")
    except (OSError, subprocess.TimeoutExpired):
        raise DeploymentError("Cannot protect private Windows files; no deployment should proceed.") from None


def prepare_private_paths(root):
    # Windows has no Unix umask protection for newly created Terraform state.
    # Restrict this dedicated checkout before any secret-bearing process runs.
    if WINDOWS:
        secure_path(root)
    private = root / "private"
    private.mkdir(mode=0o700, exist_ok=True)
    secure_path(private)
    protect_artifacts(root)


def terraform_status(root=ROOT):
    match = re.search(r'required_version\s*=\s*">=\s*(\d+\.\d+\.\d+)"',
                      (root / "provider.tf").read_text())
    if not match:
        raise DeploymentError("Cannot determine Terraform minimum version from provider.tf.")
    minimum = tuple(map(int, match[1].split(".")))
    executable = find_command("terraform")
    status = {"installed": executable is not None, "minimum_version": match[1], "supported": False}
    if executable:
        try:
            proc = subprocess.run([executable, "version", "-json"], capture_output=True,
                                  text=True, encoding="utf-8", errors="replace",
                                  env=clean_environment(), timeout=30)
            version = json.loads(proc.stdout)["terraform_version"]
            parsed = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)(?:\+.*)?", version)
            status.update(version=version, supported=bool(proc.returncode == 0 and parsed and
                          tuple(map(int, parsed.groups())) >= minimum))
        except (OSError, ValueError, KeyError, subprocess.TimeoutExpired):
            status["error"] = "Terraform version check failed."
    return status


def preflight(root=ROOT):
    terraform = terraform_status(root)  # Terraform must be checked first.
    return {"terraform": terraform, "oci_cli_available": find_command("oci") is not None,
            "python_version": ".".join(map(str, sys.version_info[:3])),
            "platform": sys.platform, "handoff_shell": "powershell" if WINDOWS else "posix"}


def read_profiles(path=None):
    path = CONFIG if path is None else path
    if not path.exists():
        return []
    parser = configparser.ConfigParser(interpolation=None)
    try:
        with path.open(encoding="utf-8-sig") as stream:
            parser.read_file(stream)
        names = (["DEFAULT"] if parser.defaults() else []) + parser.sections()
        return [{"name": name, "tenancy_ocid": parser[name].get("tenancy", "").strip(),
                 "user_ocid": parser[name].get("user", "").strip(),
                 "region": parser[name].get("region", "").strip()} for name in names]
    except (OSError, configparser.Error, UnicodeError):
        raise DeploymentError("Cannot read OCI configuration; correct it or use explicit authentication.") from None


def profile_details(args):
    for profile in read_profiles():
        if profile["name"] == args.profile:
            return profile
    raise DeploymentError("Selected OCI profile is unavailable; select a profile or use explicit authentication.")


def require_ocid(value, kind):
    if not value or not re.fullmatch(r"ocid1\." + kind + r"\.[A-Za-z0-9._-]+", value):
        raise DeploymentError("A valid " + kind + " OCID is required.")
    return value


def authentication(args):
    env = clean_environment()
    env["OCI_CLI_AUTH"] = "api_key"
    if args.auth_mode == "profile":
        profile_details(args)
        return ["--config-file", str(CONFIG), "--profile", args.profile], env
    require_ocid(args.tenancy_ocid, "tenancy")
    require_ocid(args.user_ocid, "user")
    if not args.fingerprint or not re.fullmatch(r"(?:[0-9a-fA-F]{2}:){15}[0-9a-fA-F]{2}", args.fingerprint):
        raise DeploymentError("An API signing key fingerprint is required.")
    if not args.private_key_path or not Path(args.private_key_path).expanduser().is_file():
        raise DeploymentError("The private key path must point to an existing local file.")
    if not args.region:
        raise DeploymentError("An initial API region is required for explicit authentication.")
    env.update(OCI_CLI_TENANCY=args.tenancy_ocid, OCI_CLI_USER=args.user_ocid,
               OCI_CLI_FINGERPRINT=args.fingerprint,
               OCI_CLI_KEY_FILE=str(Path(args.private_key_path).expanduser().resolve()),
               OCI_CLI_REGION=args.region)
    return [], env


def oci(args, command, raw=False):
    executable = find_command("oci")
    if not executable:
        raise DeploymentError("OCI CLI is optional and unavailable; enter OCI settings manually.")
    options, env = authentication(args)
    try:
        proc = subprocess.run([executable, *options, *command], env=env,
                              capture_output=True, text=True, encoding="utf-8",
                              errors="replace", timeout=120)
        if proc.returncode:
            raise DeploymentError("OCI discovery failed; check authentication/permissions or enter settings manually. Do not share raw logs.")
        return proc.stdout.strip() if raw else json.loads(proc.stdout)
    except (OSError, ValueError, subprocess.TimeoutExpired):
        raise DeploymentError("OCI discovery failed; enter settings manually or correct OCI CLI setup.") from None


def tenancy(args):
    try:
        value = oci(args, ["iam", "compartment", "list", "--include-root", "--all", "--query",
                          'data[?"compartment-id" == `null`].id | [0]', "--raw-output"], raw=True)
        return {"tenancy_ocid": require_ocid(value, "tenancy"), "source": "oci_cli"}
    except DeploymentError:
        if args.auth_mode == "profile":
            value = profile_details(args)["tenancy_ocid"]
            return {"tenancy_ocid": require_ocid(value, "tenancy"), "source": "profile"}
        raise


def compartments(args):
    require_ocid(args.tenancy_ocid, "tenancy")
    response = oci(args, ["iam", "compartment", "list", "--compartment-id", args.tenancy_ocid,
                          "--compartment-id-in-subtree", "true", "--name", args.name,
                          "--all", "--output", "json"])
    matches = [{"name": item["name"], "id": item["id"], "parent_ocid": item.get("compartment-id")}
               for item in response["data"]
               if item.get("lifecycle-state") == "ACTIVE" and item.get("name") == args.name]
    return {"matches": matches, "requires_selection": len(matches) > 1}


def regions(args):
    response = oci(args, ["iam", "region", "list", "--output", "json"])
    return {"regions": [{"name": item["name"], "key": item.get("key")}
                        for item in response["data"]]}


def ocir_username(args):
    """Discover the registry login for the selected authentication user."""
    tenancy_ocid = require_ocid(args.tenancy_ocid, "tenancy")
    user_ocid = require_ocid(
        profile_details(args)["user_ocid"] if args.auth_mode == "profile" else args.user_ocid,
        "user",
    )
    namespace_response = oci(args, ["os", "ns", "get", "--compartment-id", tenancy_ocid,
                                    "--output", "json"])
    user_response = oci(args, ["iam", "user", "get", "--user-id", user_ocid,
                               "--output", "json"])
    namespace = namespace_response.get("data") if isinstance(namespace_response, dict) else None
    user = user_response.get("data") if isinstance(user_response, dict) else None
    name = user.get("name") if isinstance(user, dict) else None
    if (not isinstance(namespace, str) or not namespace or
            any(char.isspace() or char == "/" or ord(char) < 32 or ord(char) == 127
                for char in namespace) or
            not isinstance(name, str) or not name.strip() or
            any(ord(char) < 32 or ord(char) == 127 for char in name) or
            any(not part.strip() for part in name.split("/"))):
        raise DeploymentError("OCI did not return a usable namespace and login name. Enter the complete OCIR username manually.")
    # Identity-domain users can have an external identifier without a federation
    # provider. That identifier alone does not require a domain prefix.
    if user.get("identity-provider-id") and "/" not in name:
        raise DeploymentError("OCI returned a federated user without a domain-qualified login. Enter the complete OCIR username, including its domain, manually.")
    return {"ocir_username": namespace + "/" + name, "source": "oci_cli"}


def reject_automatic_inputs(root):
    files = {root / "terraform.tfvars", root / "terraform.tfvars.json",
             root / "override.tf", root / "override.tf.json"}
    for pattern in ("*.auto.tfvars", "*.auto.tfvars.json", "*_override.tf", "*_override.tf.json"):
        files.update(root.glob(pattern))
    if any(path.exists() for path in files):
        raise DeploymentError("Auto-loaded tfvars/override files are present. Move them aside privately before using this helper; their values will not be read.")


def protect_artifacts(root):
    paths = [root / name for name in (".terraform.tfstate.lock.info", "private/id_rsa")]
    # Protect state and any existing backups.
    paths.extend(root.glob("terraform.tfstate*"))
    paths.extend(root.glob("terraform.tfstate.d/*/terraform.tfstate*"))
    paths.extend(root.glob("crash*.log"))
    for path in paths:
        if path.is_file():
            secure_path(path)


def terraform_environment(secrets):
    env = clean_environment()
    env.update(TF_IN_AUTOMATION="1", TF_INPUT="0")
    env.update({"TF_VAR_" + name: value for name, value in secrets.items()})
    return env


def terraform_command(executable, arguments, root, env):
    try:
        # Secret-bearing output goes directly to the user's terminal, not to Codex.
        return subprocess.run([executable, *arguments], cwd=root, env=env).returncode
    finally:
        protect_artifacts(root)


def terraform_metadata(executable, arguments, root, env):
    """Read workspace metadata, never raw state or plan contents."""
    try:
        proc = subprocess.run([executable, *arguments], cwd=root, env=env,
                              capture_output=True, text=True, encoding="utf-8",
                              errors="replace", timeout=60)
        if proc.returncode:
            raise DeploymentError("Cannot inspect Terraform workspace metadata. No plan was applied.")
        return proc.stdout
    except (OSError, subprocess.TimeoutExpired):
        raise DeploymentError("Terraform metadata inspection failed. No plan was applied.") from None


def validate_operation_inputs(args):
    if args.operation == "deploy" and not args.ocir_username:
        raise DeploymentError("Deployment requires --ocir-username. Destruction does not require an OCIR username.")


def execute_terraform(args, secrets, root=ROOT):
    validate_operation_inputs(args)
    destroying = args.operation == "destroy"
    executable = find_command("terraform")
    inputs = dict(secrets)
    if destroying:
        inputs.update(DESTROY_DUMMY_VALUES)
    env = terraform_environment(inputs)
    values = {"oci_auth_mode": args.auth_mode, "tenancy_ocid": args.tenancy_ocid,
              "compartment_ocid": args.compartment_ocid, "compartment_id": args.compartment_ocid,
              "region": args.region}
    if not destroying:
        values["ocir_username"] = args.ocir_username
    if args.auth_mode == "profile":
        values["oci_config_profile"] = args.profile
    else:
        values.update(oci_user_ocid=args.user_ocid, oci_fingerprint=args.fingerprint,
                      oci_private_key_path=str(Path(args.private_key_path).expanduser().resolve()))
    variable_args = [arg for name, value in values.items() for arg in ("-var", name + "=" + value)]
    old_umask = os.umask(0o077)
    try:
        prepare_private_paths(root)
        private = root / "private"
        for arguments in (["init", "-input=false", "-no-color"], ["validate", "-no-color"]):
            if terraform_command(executable, arguments, root, env):
                raise DeploymentError("Terraform initialization or validation failed. Review diagnostics privately.")
        workspace = terraform_metadata(executable, ["workspace", "show"], root, env).strip()
        if not workspace or len(workspace.splitlines()) != 1:
            raise DeploymentError("Cannot determine the active Terraform workspace. No plan was applied.")
        print("Operation: " + args.operation + "\nDirectory: " + str(root) +
              "\nWorkspace: " + workspace + "\nTenancy: " + args.tenancy_ocid +
              "\nCompartment: " + args.compartment_ocid + "\nRegion: " + args.region)
        if destroying:
            print("Destruction follows the resources recorded in this workspace's Terraform state.")
        with tempfile.TemporaryDirectory(prefix=args.operation + "-", dir=private) as directory:
            secure_path(Path(directory))
            plan = str(Path(directory) / (args.operation + ".tfplan"))
            plan_args = ["plan", "-input=false", "-no-color", "-detailed-exitcode", "-out=" + plan]
            if destroying:
                plan_args.append("-destroy")
            code = terraform_command(executable, [*plan_args, *variable_args], root, env)
            if code == 0:
                print("Nothing to destroy in the active Terraform state/workspace." if destroying else
                      "No changes required; nothing was applied.")
                return
            if code != 2:
                raise DeploymentError("Terraform planning failed. Nothing was applied.")
            confirmation = "destroy" if destroying else "apply"
            prompt = "Review the plan above. Type " + confirmation + " to " + args.operation + " this exact plan: "
            if input(prompt).strip() != confirmation:
                print("Destruction cancelled; no destroy plan was applied." if destroying else
                      "Deployment cancelled; nothing was applied.")
                return
            if terraform_command(executable, ["apply", "-input=false", "-no-color", plan], root, env):
                change = "destroyed" if destroying else "created"
                raise DeploymentError("Terraform apply failed; resources may be partially " + change +
                                      ". Review diagnostics privately before retrying.")
            print(("Destruction" if destroying else "Deployment") +
                  " completed. Keep state, backups, keys, and diagnostics private.")
    finally:
        os.umask(old_umask)


def private_input(prompt):
    # getpass otherwise falls back to echoed input when terminal control fails.
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("error", getpass.GetPassWarning)
            return getpass.getpass(prompt)
    except getpass.GetPassWarning:
        raise DeploymentError("Hidden terminal input is unavailable; no secrets were collected.") from None


def run_private(args, root=ROOT):
    if not sys.stdin.isatty() or not sys.stdout.isatty():
        raise DeploymentError("Run this command yourself in an interactive terminal after exiting Codex.")
    if WINDOWS:
        print("Use a dedicated checkout: this run restricts its Windows ACLs to your current account, including inheritance for new state files.")
    if input("Have you exited Codex? Type yes to continue privately: ").strip() != "yes":
        raise DeploymentError("Exit Codex before entering secrets or running Terraform changes.")
    validate_operation_inputs(args)
    if not terraform_status(root)["supported"]:
        raise DeploymentError("Install a supported Terraform version before running Terraform changes.")
    reject_automatic_inputs(root)
    authentication(args)  # Validates metadata without invoking OCI CLI.
    require_ocid(args.tenancy_ocid, "tenancy")
    require_ocid(args.compartment_ocid, "compartment")
    if not args.region:
        raise DeploymentError("The target region is required.")
    prepare_private_paths(root)  # Fail closed on ACL errors before requesting secrets.
    secrets = {}
    try:
        prompts = () if args.operation == "destroy" else (
            ("nvidia_api_key", "NVIDIA API key: "), ("ocir_auth_token", "OCIR auth token: "))
        for name, prompt in prompts:
            value = private_input(prompt)
            if not value.strip():
                raise DeploymentError("Secret input cannot be empty. No deployment was started.")
            secrets[name] = value
        if args.key_needs_passphrase:
            secrets["oci_private_key_password"] = private_input("API signing key passphrase: ")
            if not secrets["oci_private_key_password"]:
                raise DeploymentError("Signing key passphrase cannot be empty.")
        execute_terraform(args, secrets, root)
    finally:
        secrets.clear()


def handoff(args, python=None, script=None, windows=None):
    """Render a command only; never collect secrets or execute Terraform."""
    validate_operation_inputs(args)
    windows = WINDOWS if windows is None else windows
    command = [python or sys.executable, script or str(Path(__file__).resolve()), "run",
               "--operation", args.operation,
               "--auth-mode", args.auth_mode, "--tenancy-ocid", args.tenancy_ocid,
               "--compartment-ocid", args.compartment_ocid, "--region", args.region]
    if args.operation == "deploy":
        command.extend(["--ocir-username", args.ocir_username])
    if args.auth_mode == "profile":
        command.extend(["--profile", args.profile])
    else:
        if not all((args.user_ocid, args.fingerprint, args.private_key_path)):
            raise DeploymentError("Explicit handoff requires user OCID, fingerprint, and private key path.")
        command.extend(["--user-ocid", args.user_ocid, "--fingerprint", args.fingerprint,
                        "--private-key-path", str(Path(args.private_key_path).expanduser().resolve())])
    if args.key_needs_passphrase:
        command.append("--key-needs-passphrase")
    if windows:
        rendered = "& " + " ".join("'" + value.replace("'", "''") + "'" for value in command)
    else:
        rendered = shlex.join(command)
    return {"shell": "powershell" if windows else "posix", "command": rendered}


def build_parser():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("preflight", help="Check Terraform first; OCI CLI is optional.")
    commands.add_parser("profiles", help="List safe profile metadata only.")
    for command in ("tenancy", "compartments", "regions", "ocir-username", "handoff", "run"):
        help_text = {"run": "USER TERMINAL ONLY", "handoff": "Render a deploy/destroy command without executing it.",
                     "ocir-username": "Discover the OCIR login for the selected authentication user."}
        sub = commands.add_parser(command, help=help_text.get(command, "Optional OCI CLI discovery."))
        sub.add_argument("--auth-mode", choices=("profile", "explicit"), default="profile")
        sub.add_argument("--profile", default="DEFAULT")
        sub.add_argument("--tenancy-ocid", required=command in ("compartments", "ocir-username", "run", "handoff"))
        sub.add_argument("--user-ocid")
        sub.add_argument("--fingerprint")
        sub.add_argument("--private-key-path")
        sub.add_argument("--region", required=command in ("run", "handoff"))
        if command == "compartments":
            sub.add_argument("--name", required=True)
        if command in ("run", "handoff"):
            sub.add_argument("--operation", choices=("deploy", "destroy"), default="deploy")
            sub.add_argument("--compartment-ocid", required=True)
            sub.add_argument("--ocir-username", help="Required for deploy; ignored for destroy.")
            sub.add_argument("--key-needs-passphrase", action="store_true")
    return parser


def main():
    args = build_parser().parse_args()
    try:
        if args.command == "run":
            run_private(args)
            return 0
        result = {"preflight": preflight, "profiles": read_profiles,
                  "tenancy": lambda: tenancy(args), "compartments": lambda: compartments(args),
                  "ocir-username": lambda: ocir_username(args),
                  "regions": lambda: regions(args), "handoff": lambda: handoff(args)}[args.command]()
        print(json.dumps(result, indent=2))
        return 0
    except (DeploymentError, OSError, KeyError, TypeError, ValueError, AttributeError) as error:
        print(str(error) if isinstance(error, DeploymentError) else
              "Deployment helper failed. Review setup privately; do not share raw diagnostics.", file=sys.stderr)
        return 1
    except (KeyboardInterrupt, EOFError):
        print("Cancelled. If apply had started, inspect state privately before retrying.", file=sys.stderr)
        return 130


if __name__ == "__main__":
    sys.exit(main())
