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
   `generated/managed-repos.yaml` that isn't already a sibling directory
   (existing clones are left completely untouched):

   ```sh
   cd cnpg-infra
   ./scripts/bootstrap.sh
   ```

The admin-team check is a fail-fast sanity check, not the real security
boundary — GitHub's own API authorization is what actually stops a
non-admin from doing anything privileged. It just avoids a confusing
half-completed run before that happens.

## What's here

**Generated files, in `generated/` — do not hand-edit, re-run the script that owns them:**

| File | Rebuilt by | Contents |
|---|---|---|
| `generated/managed-repos.yaml` | `scripts/update-managed-repos.sh` | Every non-archived `cloudnative-pg/*` repo cloned as a sibling of `cnpg-infra`, with its `origin` remote verified |
| `generated/teams.yaml` | `scripts/update-teams.sh` | Live GitHub team roster (org owners, org members, each team's members) — deliberately does NOT track per-repo access; see the policy files below for that |

**Hand-maintained policy files — the desired state the scripts below check/enforce against:**

| File | Scope |
|---|---|
| `repo-policy.yaml` | Per-repo exceptions to the settings baseline (e.g. a repo whose content is machine-published and so doesn't need a PR-review gate; a standalone review-count override for a repo not yet in `repo-tiers.yaml`) |
| `repo-tiers.yaml` | Every managed repo's importance class (A = critical, B = important, C = low-stakes), governance subproject, and (optionally) a desired GitHub description. Class drives the settings floor: A gets 2 required reviews + code-owner review forced on, B gets 1 + code-owner review forced on, C gets the org default (1, untouched code-owner-review setting). A repo's `description` field, if set, is pushed to GitHub whenever it drifts — the only field in any policy file here that changes something a repo already has rather than just flooring it |
| `componentowners-policy.yaml` | Per-repo CODEOWNERS content — both the catch-all `*` rule and any path-scoped rules, each as teams + users |
| `org-policy.yaml` | Rules that apply identically to every repo (e.g. which teams get `admin` everywhere), so they don't need repeating per-repo |
| `milestones-policy.yaml` | Desired "horizon" milestones (Now / Next / Later, title + description copied verbatim from `cloudnative-pg/cloudnative-pg`'s own generic triage milestones), each one's `due_offset_months` (used to compute a rolling due date, not a fixed one), and the explicit, hand-picked list of repos it should exist in |

**Scripts (all in `scripts/`, YAML config stays in the repo root):**

| Script | Effect |
|---|---|
| `scripts/bootstrap.sh` | Checks admin-team membership, clones any managed repo missing as a sibling |
| `scripts/create-new-repo.sh --name <repo> --class <A\|B\|C> --subproject <...> --description "<text>" --owners user1,user2,... [--apply]` | Onboards a brand-new repo end-to-end — see "Adding a new repo" below |
| `scripts/update-managed-repos.sh` | Rebuilds `generated/managed-repos.yaml` from live GitHub state |
| `scripts/update-teams.sh` | Rebuilds `generated/teams.yaml` from live GitHub state |
| `scripts/check-repo-settings.sh [repo]` | Read-only audit of repo settings (branch protection, teams, collaborators, security features) against the policy files and the GitHub-API-checkable subset of the [OSPS Baseline checklist](https://baseline.openssf.org/versions/2026-02-19-checklist.md) → `repo-settings-report.md` |
| `scripts/fix-repo-settings.sh <repo> [--apply]` | Remediates one repo against the policy files. **Defaults to dry-run** — always review the diff before re-running with `--apply`. Only ever raises settings, never lowers an existing stricter one |
| `scripts/fix-all-repos.sh [--apply]` | Runs `fix-repo-settings.sh` across every repo in `managed-repos.yaml`, one at a time, with a summary at the end. Same dry-run-by-default safety model — nothing here is new logic, just a loop |
| `scripts/validate-policy.rb` | Static validation of the YAML policy files: every file parses, every managed repo has a `repo-tiers.yaml`/`componentowners-policy.yaml` entry, `class`/`subproject` values are from the documented enum, every referenced team slug exists in `generated/teams.yaml`'s last snapshot, and every repo referenced in `milestones-policy.yaml` is managed. No GitHub API calls — safe to run in CI, and also runs there (`.github/workflows/lint.yml`, alongside ShellCheck on every script) |
| `scripts/sync-milestones.rb [repo] [--apply]` | Reconciles GitHub milestones against `milestones-policy.yaml`: creates a missing milestone (matched by exact title), updates its description and/or due date if either has drifted. Due date is a rolling window computed from `due_offset_months` and the date the script runs, not a fixed date — it advances on its own each time this next runs in a new calendar month. Never touches open/closed state or issue assignments. **Defaults to dry-run** — always review the plan before re-running with `--apply` |

## Adding a new repo

`./scripts/create-new-repo.sh` does this end-to-end for a genuinely new
repo — creates it on GitHub from `cnpg-template`, clones it as a sibling,
registers it in `repo-tiers.yaml` and `componentowners-policy.yaml`,
regenerates `generated/managed-repos.yaml`, creates and populates its
`<repo>-owners` team, renders and pushes its real `CODEOWNERS`, brings it
up to the settings baseline (`fix-repo-settings.sh`), runs
`validate-policy.rb`, and opens a PR on `cloudnative-pg/.project` adding
it to `project.yaml`'s `repositories:` list. Dry-run by default, like
every other script here:

```sh
./scripts/create-new-repo.sh \
  --name <repo> \
  --class <A|B|C> \
  --subproject <core|supply-chain|community-ecosystem|extensibility|org-control|unclassified> \
  --description "<one-line GitHub description>" \
  --owners user1,user2,...
# review the plan, then:
./scripts/create-new-repo.sh ... --apply
```

New entries are appended to the end of each policy file's `repositories:`
list, not re-sorted into their class/alphabetical grouping — that's a
human tidy-up afterward, if you want one.

If the repo already exists on GitHub (an existing repo just joining
`cnpg-infra`'s management rather than a genuinely new one), use the
older manual path instead:

1. Clone it as a sibling of `cnpg-infra`:
   `git clone https://github.com/cloudnative-pg/<name>.git`
2. Run `./scripts/update-managed-repos.sh` — it'll now find the new sibling
   clone and add it to `generated/managed-repos.yaml`.
3. Add policy entries for it in `repo-tiers.yaml` and
   `componentowners-policy.yaml` by hand.
4. Run `./scripts/fix-repo-settings.sh <name>` (dry-run first, review the
   diff, then `--apply`) to bring it up to the settings baseline.

## Conventions

Same as every other repo in the org — DCO sign-off, Conventional Commits,
`Assisted-by:` trailer for material AI assistance (see
[governance/AI_POLICY.md](https://github.com/cloudnative-pg/governance/blob/main/AI_POLICY.md)).
