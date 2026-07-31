# cnpg-infra

Local-first admin tooling for managing settings, teams, and CODEOWNERS
across every repository in the [`cloudnative-pg`](https://github.com/cloudnative-pg)
GitHub organization.

## Philosophy: laptop, not CI

Every script here assumes a human, locally-authenticated `gh` session with
real org-admin scope (`admin:org`, `repo`, `read:org`). None of this runs
from GitHub Actions or any other CI pipeline, on purpose: keeping org-admin
credentials on an admin's laptop instead of in a pipeline secret means a
compromised workflow or a malicious PR never has a path to org-wide admin
access. The tradeoff is that these changes don't happen automatically —
an admin has to actually run them — which is the point, not a limitation.

## Getting started

1. Create an empty directory and clone this repo as a sibling of every
   other `cloudnative-pg` repo you'll manage (or into a fresh empty
   directory — the next step populates it):

   ```sh
   mkdir cnpg.io && cd cnpg.io
   git clone https://github.com/cloudnative-pg/cnpg-infra.git
   ```

2. Authenticate `gh` with sufficient scope:

   ```sh
   gh auth login
   gh auth refresh -h github.com -s admin:org
   ```

3. From inside `cnpg-infra/`, run the bootstrap script. It checks you're
   an active member of the `admins` team, then clones every repo listed in
   `managed-repos.yaml` that isn't already a sibling directory (existing
   clones are left completely untouched):

   ```sh
   cd cnpg-infra
   ./scripts/bootstrap.sh
   ```

The admin-team check is a fail-fast sanity check, not the real security
boundary — GitHub's own API authorization is what actually stops a
non-admin from doing anything privileged. It just avoids a confusing
half-completed run before that happens.

## What's here

**Generated files — do not hand-edit, re-run the script that owns them:**

| File | Rebuilt by | Contents |
|---|---|---|
| `managed-repos.yaml` | `update-managed-repos.sh` | Every non-archived `cloudnative-pg/*` repo cloned as a sibling of `cnpg-infra`, with its `origin` remote verified |
| `teams.yaml` | `update-teams.sh` | Live GitHub team roster (org owners, org members, each team's members) — deliberately does NOT track per-repo access; see the policy files below for that |

**Hand-maintained policy files — the desired state the scripts below check/enforce against:**

| File | Scope |
|---|---|
| `repo-policy.yaml` | Per-repo exceptions to the settings baseline (e.g. a repo whose content is machine-published and so doesn't need a PR-review gate; a repo that needs a stricter-than-default review count) |
| `componentowners-policy.yaml` | Per-repo CODEOWNERS content — both the catch-all `*` rule and any path-scoped rules, each as teams + users |
| `org-policy.yaml` | Rules that apply identically to every repo (e.g. which teams get `admin` everywhere), so they don't need repeating per-repo |

**Scripts (all in `scripts/`, YAML config stays in the repo root):**

| Script | Effect |
|---|---|
| `scripts/bootstrap.sh` | Checks admin-team membership, clones any managed repo missing as a sibling |
| `scripts/update-managed-repos.sh` | Rebuilds `managed-repos.yaml` from live GitHub state |
| `scripts/update-teams.sh` | Rebuilds `teams.yaml` from live GitHub state |
| `scripts/check-repo-settings.sh [repo]` | Read-only audit of repo settings (branch protection, teams, collaborators, security features) against the policy files and the GitHub-API-checkable subset of the [OSPS Baseline checklist](https://baseline.openssf.org/versions/2026-02-19-checklist.md) → `repo-settings-report.md` |
| `scripts/fix-repo-settings.sh <repo> [--apply]` | Remediates one repo against the policy files. **Defaults to dry-run** — always review the diff before re-running with `--apply`. Only ever raises settings, never lowers an existing stricter one |

## Conventions

Same as every other repo in the org — DCO sign-off, Conventional Commits,
`Assisted-by:` trailer for material AI assistance (see
[governance/AI_POLICY.md](https://github.com/cloudnative-pg/governance/blob/main/AI_POLICY.md)).
