# Reusable GitHub Actions for the bootc-dev organization.

At the current time, these actions are not intended for use outside
of the organization.

## static-checks

> This text is LLM generated.

`static-checks` runs cheap, offline repository hygiene checks over a
checked-out tree and prints one pass/fail/skip line per check, with a
fix hint, plus a job summary table. It needs only `contents: read`.

Checks:

- `license`: a top-level `LICENSE`, `LICENSE-*` or `COPYING` file exists
  and is recognized as an SPDX license by
  [askalono](https://github.com/jpeddicord/askalono) (pinned and
  checksummed in the action). If `Cargo.toml` or `package.json` declares a
  `license`, it must name the same licenses as the files; for example
  `LICENSE-APACHE` plus `LICENSE-MIT` matches `Apache-2.0 OR MIT`.

Inputs: `checks` (comma-separated, default `all`), `skip`
(comma-separated) and `path` (default `.`).

The reusable workflow `.github/workflows/static-checks.yml` checks out the
calling repository and runs the action; it accepts the same `checks` and
`skip` inputs. Outside this repository it always uses the action from
`bootc-dev/actions` main:

```yaml
jobs:
  static-checks:
    uses: bootc-dev/actions/.github/workflows/static-checks.yml@main
```

### Exceptions

A check is skipped only with a reason committed in the checked
repository's `.github/static-checks.toml`, so exceptions show up in
review. A check listed there is skipped even when the workflow is run by a
ruleset without inputs; a check passed in `skip` without a reason there
fails.

```toml
[skip]
license = "documentation only; content is covered by the parent project"
```

Only `[skip]` tables of `name = "reason"` lines are read.

### Requiring it org-wide

Org rulesets can't target "non-fork" repositories directly. Instead,
create a custom repository property such as `static-checks` with the value
`required`, set it on source repositories, and add a ruleset that targets
repositories with `static-checks = required` and requires the
`.github/workflows/static-checks.yml` workflow from `bootc-dev/actions`.
As a backstop, the workflow's job is skipped in forks.
