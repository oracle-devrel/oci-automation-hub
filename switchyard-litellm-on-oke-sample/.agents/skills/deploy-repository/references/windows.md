# Native Windows workflow

Use Windows 10/11 with Windows PowerShell 5.1 or PowerShell 7 and Python 3.10+.
WSL, Git Bash, Docker, and local Helm/kubectl are not required. Remote Bash, Docker,
Helm, and kubectl commands execute on the Linux operator through Terraform.

## Prerequisites

The first command checks Terraform before Python or OCI discovery:

```powershell
Get-Command terraform -CommandType Application -ErrorAction SilentlyContinue
```

If missing, ask whether Codex should install Terraform or the user will install
it separately, exactly as in the main skill. Verify official HashiCorp installation
instructions before an authorized installation. Do not assume winget or Chocolatey
is installed. Reopen the terminal if needed for PATH changes, then recheck.

Find a working Python 3.10+ interpreter: try `py -3 --version`, then
`python --version` if the launcher is unavailable. Require an actual version result,
not a Microsoft Store alias. If neither works, provide Python installation guidance.
Use the confirmed launcher consistently, for example:

```powershell
py -3 .agents/skills/deploy-repository/scripts/deploy.py preflight
```

Replace `py -3` with `python` when that is the installed interpreter. Preflight
checks the Terraform version and reports optional OCI CLI and platform information.
Native executables must be on PATH. Batch-only `.cmd`/`.bat` wrappers are not used
for dynamic commands because Windows can invoke them through cmd.exe; OCI discovery
can always use the manual workflow instead.

## Paths and handoff

`Path.home()` finds `.oci\config` under the current Windows user's home directory.
Use Windows key paths, such as `'C:\Users\Alice\.oci\api_key.pem'`, including
single quotes around values containing spaces. Never paste key contents or tokens.
PowerShell single-quoted literals escape an apostrophe by doubling it. Do not use
POSIX backslash escaping, `command -v`, or backslash line continuations. Produce
single-line commands with real selected values rather than literal angle brackets.

Run the main skill's `handoff` subcommand using the confirmed Python launcher. For
cleanup include `--operation destroy` and omit `--ocir-username`. It
returns a PowerShell command beginning with `&` and the quoted actual interpreter
path. The call operator is necessary when that executable path contains spaces.
Tell the user to exit Codex, open their own PowerShell terminal in the repository,
and run that command. Secret prompts use hidden console input; failure to hide
input stops the helper.

For deployment, run the main skill's `ocir-username` discovery with the confirmed
Python launcher and selected authentication settings before asking for a username.
The helper parses OCI JSON in Python; PowerShell command substitution and `jq`
are unnecessary. Pass the discovered value to `handoff --ocir-username`, or use
manual entry when discovery is unavailable or cannot resolve the complete login.

For cleanup, reuse the deployment settings from context and ask only for missing
values. No NVIDIA/OCIR application credentials are collected; only an optional
signing key passphrase may be needed. The user reviews a saved destroy plan and
types `destroy` to apply it, using the original checkout, backend, and workspace.

For deployment, the OCIR token creation command remains user-only. Use one line and quoted concrete
values, including `--profile` when using a nondefault profile. Without OCI CLI,
direct the user to OCI Console token generation. Never execute token creation.

## Private files

Use a dedicated personal checkout on local NTFS. Before prompting for secrets, the
helper uses built-in Windows PowerShell and the filesystem `SetAccessControl` API to replace the checkout's DACL
with a protected ACL granting FullControl to the current user, preserving ownership
and audit settings, with inheritance for
new files/directories. This changes other users' access to that checkout. State and
generated key files also receive protected ACLs. Explain this behavior before the
handoff. If ACL application or verification fails, stop; do not silently continue,
change execution policy, or substitute `chmod`. Administrator accounts can still
take ownership, just as root can on Unix; this is not isolation from future Codex
sessions under the same account.

The ACL subprocess removes inherited `PSModulePath` so Windows PowerShell 5.1 can
load its own built-in modules when Python was launched from PowerShell 7. This
changes only the child process environment. Failures report the stage and an exit
code (21: inspect path, 22: build ACL, 23: apply ACL, 24: verify ACL), without exposing
raw diagnostics or credential values.

References: [Python on Windows](https://docs.python.org/3/using/windows.html),
[Set-Acl](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.security/set-acl?view=powershell-5.1),
[PowerShell module paths](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_psmodulepath#starting-windows-powershell-from-powershell-7),
[subprocess security](https://docs.python.org/3/library/subprocess.html#security-considerations).
