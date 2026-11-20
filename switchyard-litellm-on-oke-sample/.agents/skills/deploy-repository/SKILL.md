---
name: deploy-repository
description: Prepare deployment or destruction of this repository's OCI resources with optional OCI CLI discovery and a user-only Terraform handoff. Use for "Deploy this repository", "Deploy the application", "Clean up the resources", "Run terraform destroy", or "Remove all the created resources".
---

# Deploy or destroy this repository

Use this skill from the repository root. Codex discovers nonsecret settings;
the user exits Codex before entering secrets and running Terraform changes.
**Never execute the `run` subcommand yourself**, for either deployment or cleanup.
Never read signing key contents, environment values, secret files, Terraform state,
plan JSON, saved plans, or Kubernetes secrets into tool output.

## 1. Check Terraform first

On native Windows, first read [Windows workflow](references/windows.md) and follow
its PowerShell prerequisite check. Use the detected Python launcher instead of
`python3` in all examples below. On macOS/Linux, the first deployment command is:

```sh
python3 .agents/skills/deploy-repository/scripts/deploy.py preflight
```

If Python is unavailable, check `command -v terraform` before other discovery and
provide Python 3 installation instructions. Preflight checks Terraform installation
and its minimum version from `provider.tf` before detecting optional OCI CLI.

If Terraform is missing, ask whether Codex should install it or the user will handle
installation. Install only after explicit authorization, using official HashiCorp
instructions for the detected platform/package manager. Do not invent installation
commands. Otherwise pause until the user reports completion, then recheck. Resolve
an unsupported/broken Terraform installation the same way.

**OCI CLI is useful but optional. Never require its installation.** Python 3 is
required for the helpers; use manual OCI settings when OCI CLI is absent.

## 2. Reuse context, then collect missing settings

Select `deploy` for deployment requests and `destroy` for resource cleanup requests.
Before asking for input, reuse settings explicitly supplied by the user or verified
through discovery for the same deployment: tenancy OCID, compartment OCID, canonical
region, authentication mode/profile, user OCID, fingerprint, signing key path, and
OCIR username (deploy only). Reuse a discovered username only for the same tenancy
and authentication user; a user-supplied registry username takes precedence.
Examples, placeholders, test fixtures, and unsubmitted defaults are not selections.
If several deployments are in context, ask only which target to use. Ask for a
replacement only when a known value is ambiguous or no longer usable locally.

With fresh context, follow the discovery/manual-entry flow below. Collect only
missing values. If all required settings are already known, skip discovery and
input questions and proceed to the handoff after prerequisite checks.

For **destroy**, never discover or ask for an OCIR username, NVIDIA key, or OCIR auth token and
never offer token creation. The helper supplies `destroy-unused` for all three
application inputs. Working OCI authentication is still required; an encrypted
signing key may still require a passphrase in the user's private terminal.

Cleanup requires the original Terraform state: use the same checkout, backend, and
active Terraform workspace as deployment. Reusing OCIDs does not reconstruct state
or select a workspace. Describe the operation as destroying resources tracked by
that state, not deleting everything in the compartment. Do not switch workspaces,
import discovered resources, or delete resources independently of Terraform. If
the user reports missing state, explain that it must be recovered before cleanup.

### Authentication and discovery

With OCI CLI installed, list profiles without exposing credentials:

```sh
python3 .agents/skills/deploy-repository/scripts/deploy.py profiles
```

Reuse the selected profile from context; otherwise select the sole profile or use
a selection question for multiple profiles. Do not
dump `~/.oci/config` or silently substitute DEFAULT. The helper returns only names,
tenancy/user OCIDs, and regions. An unreadable/malformed file needs correction or
explicit authentication.

Without `~/.oci/config`, collect any missing tenancy OCID, user OCID, API signing key
fingerprint, and private key **path** through individual text fields. If an initial API region
is missing, obtain region choices from official documentation and collect it in
the combined target form below; use that selection for the first OCI call.
Do not request the region separately before the combined form.
Use `--auth-mode explicit` with
`--tenancy-ocid`, `--user-ocid`, `--fingerprint`, `--private-key-path`, and `--region`.
The path must identify an existing local file. Never request its contents or a
passphrase in chat.

Without OCI CLI, use explicit authentication and collect missing values individually:

- Tenancy OCID (OCI Console tenancy details).
- User OCID (OCI Console user details).
- Fingerprint (the user's API Keys) and corresponding local private key path.

Skip OCI discovery subcommands in that manual workflow. Do not install another SDK
as a workaround. Explain that compartment-name lookup is unavailable; region
choices come from official documentation instead. Use the same compartment,
region form below in either workflow, adding an unresolved OCIR username only for deploy. In manual mode, its
compartment text field requests the compartment OCID from OCI Console.

### Optional OCI CLI discovery

Use `--profile <chosen-profile>` on each command, or the explicit authentication
arguments above:

```sh
python3 .agents/skills/deploy-repository/scripts/deploy.py tenancy <auth-arguments>
python3 .agents/skills/deploy-repository/scripts/deploy.py compartments <auth-arguments> --tenancy-ocid <tenancy-ocid> --name <compartment-name>
python3 .agents/skills/deploy-repository/scripts/deploy.py regions <auth-arguments>
```

The tenancy command first uses the user's include-root query and then falls back to
the selected profile's tenancy field. If neither works, ask for tenancy OCID.

If OCI discovery fails, offer manual entry or let the user correct OCI permissions
and setup. Do not expose raw error output. For encrypted signing keys that require
a passphrase, use manual settings and collect the passphrase privately later.

### Discover the OCIR username for deployment

If deploying and the OCIR username is unresolved, use OCI CLI discovery as soon as
the selected authentication settings and tenancy OCID are available:

```sh
python3 .agents/skills/deploy-repository/scripts/deploy.py ocir-username <auth-arguments> --tenancy-ocid <tenancy-ocid>
```

The helper reads the tenancy's Object Storage namespace with `oci os ns get` and
the selected user's login with `oci iam user get`. Profile authentication uses the
user OCID from the selected profile; explicit authentication uses `--user-ocid`.
It returns only `ocir_username` and `source`, with no `jq` or additional dependencies.
Use the resolved username in the handoff without asking the user to re-enter or
confirm it. Keep any domain prefix returned in the login name, as required by
[Oracle's OCIR login formats](https://docs.oracle.com/en-us/iaas/Content/Functions/Tasks/functionslogintoocir.htm).
An `external-identifier` alone does not require a domain prefix: when there is no
`identity-provider-id`, use the returned IAM login unchanged, even if an external
identifier is present. Do not ask the user for a domain in that case.

Ask for the complete username only if OCI CLI is unavailable, discovery fails, or
an explicit `identity-provider-id` is present but the login has no domain prefix.
Do not guess a domain prefix or a username-discovery failure; use the helper's
actual result to decide whether manual entry is needed.
If authentication is waiting for an initial region or other input, defer the
username question: collect those settings first, then attempt discovery. This
also applies to explicit authentication without an OCI config file. Skip this
discovery when the user has supplied a registry username, including one for a
different registry identity. Do not cache the result on disk.

### Combined target form

If the region is missing, prepare region choices **before** the input request. Call
the `regions` helper when OCI CLI authentication is ready. Otherwise retrieve the
current region identifiers from Oracle's
[Regions and Availability Domains documentation](https://docs.oracle.com/en-us/iaas/Content/General/Concepts/regions.htm),
using the table for the tenancy's realm. Put the selected profile's region first
when it is in the retrieved list and label it `<region-id> (profile setting)`;
sort the remaining identifiers alphabetically. Do not substitute a hardcoded
shortlist or treat a preselected profile setting as a submitted answer.

Set `compartmentPrompt` to `Target compartment name` for OCI CLI lookup, or
`Target compartment OCID` for manual mode. Set `regionOptions` to the retrieved
region labels. Set `needsManualOcirUsername` only when the deployment username is
unresolved and CLI discovery is unavailable or has failed; leave it false while
discovery is waiting for authentication settings. Build the questions:

```javascript
const questions = [
  { title: compartmentPrompt },
  { title: "Target region", options: regionOptions }
];
if (operation === "deploy" && needsManualOcirUsername) {
  questions.push({ title: "Complete OCIR username, including namespace/domain. Do not enter tokens or keys." });
}
```

Omit fields already resolved from context or discovery, then send all remaining
fields in **one** input-tool call as `{ questions }`. Do not send an empty request.
Destroy has at most the compartment and region fields; deploy adds the OCIR
username only when manual entry is needed.
If region sources are unavailable, explain the
limitation and use a free-text region identifier field in that same request
rather than inventing options. A documented region list does not confirm tenancy
subscription to every listed region.

After submission, resolve the compartment name with the `compartments` helper.
For multiple active matches, ask a follow-up selection identifying each by name,
parent OCID, and compartment OCID; never choose the first silently. For zero
matches, ask only for a corrected name or a compartment OCID from OCI Console.
Preserve the other submitted answers during these follow-ups.

Map the selected region label to its canonical identifier before passing it to a
helper. Resolve custom responses against the retrieved identifiers and ask only
for a corrected region if ambiguous or unrecognized. Accept the complete OCIR
username for deployment after trimming outer whitespace; do not infer it from an email address.
If username discovery was deferred for missing authentication settings, run it
now and ask a follow-up username question only if discovery fails.
These fields collect identifiers only. Secret input remains in the user-only
terminal handoff below.

## 3. User-only handoff

Present the operation, selected authentication mode/profile, tenancy, compartment,
and region. Include OCIR username only for deploy. Tell the user to **exit Codex
before entering secrets or executing the generated command**.
Do not ask for NVIDIA keys, OCIR auth tokens, or signing key passphrases in chat or
tool input, and do not instruct users to export them before launching Codex.

Only for **deploy**, if the user has no OCIR auth token, provide this command for them to run themselves
after exiting Codex, substituting their user OCID and a meaningful description:

```sh
oci iam auth-token create --user-id <his-user-id> --description "<some-message>"
```

**Neither Codex nor the helper may execute token creation.** It creates a credential
and prints its value. Tell the user to keep that result private and never paste it
into chat. The `profiles` output provides the user OCID, or ask if it is missing.
For a nondefault profile include `--profile <chosen-profile>` in this user-only
command. Without OCI CLI/configuration, use OCI Console user details > Auth Tokens
> Generate Token instead; OCI CLI remains optional.

Generate the exact handoff command with the helper, using only nonsecret settings:

```sh
python3 .agents/skills/deploy-repository/scripts/deploy.py handoff --profile <profile> --tenancy-ocid <tenancy-ocid> --compartment-ocid <compartment-ocid> --region <region> --ocir-username <ocir-username>
```

For cleanup, generate the handoff with:

```sh
python3 .agents/skills/deploy-repository/scripts/deploy.py handoff --operation destroy --profile <profile> --tenancy-ocid <tenancy-ocid> --compartment-ocid <compartment-ocid> --region <region>
```

`--operation` defaults to `deploy`, preserving existing deployment commands. The
returned cleanup command includes `run --operation destroy` and no OCIR username.

For manual authentication replace `--profile` with `--auth-mode explicit` and add
the user OCID, fingerprint, and private key path arguments. Quote all values using
the current shell's escaping rules. Add `--key-needs-passphrase` if necessary. Never
add secrets. The helper returns a command using the current Python executable,
with PowerShell literals on Windows and POSIX quoting on macOS/Linux. Give that
returned `run` command to the user; never execute it yourself. It supports paths
and profile/user names containing spaces or apostrophes. On Windows target
PowerShell 5.1 or 7, not cmd.exe or Git Bash.

The helper runs init/validate and displays the operation, target settings, working
directory, and active workspace. For deploy it collects application secrets with
hidden input. For destroy it supplies dummy application values without prompts.
Any required signing key passphrase remains hidden and private in either mode.

It saves and displays the actual Terraform plan locally. Destroy uses
`terraform plan -destroy`; the user must type `destroy` before the helper applies
that exact saved plan with `terraform apply`. Deploy still requires `apply`.
This preserves Terraform plan approval for both operations. Never substitute a
bare `terraform destroy`, an automatically approved apply, or a newly generated
plan after approval. On an empty/no-change destroy plan, report that the active
state has nothing to destroy; do not claim the compartment is empty.

## 4. Results and artifacts

Helm and kubectl already run through the Terraform modules. Do not add independent
Helm deployments or invent kubectl commands. The helper reports status locally. For
failures ask for a description or deliberately redacted diagnostic, not raw logs,
state, plan JSON, token output, or environment dumps. Do not automatically retry an
apply after failure; resources may have been partially created or destroyed.

Temporary saved plans are removed; state, state backups, and generated SSH keys remain sensitive
local artifacts. Exiting Codex keeps private execution out of this conversation,
but does not prevent a later session with filesystem access from reading files.
Do not claim enforced isolation or restart Codex with exported secrets.
