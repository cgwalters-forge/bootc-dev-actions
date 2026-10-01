# Reusable GitHub Actions for the bootc-dev organization.

At the current time, these actions are not intended for use outside
of the organization.

## pr-signoff

A reusable workflow implementing two pull request comment commands for
repositories that require the [DCO](https://developercertificate.org/)
check. The logic is [pr-signoff/pr-signoff.sh](pr-signoff/pr-signoff.sh),
with offline tests in `pr-signoff/test.sh`.

- `/signoff` adds the commenter's `Signed-off-by` to every commit of the
  PR that lacks it. The commits keep their base, trees, author
  lines and messages byte for byte; only the trailer and the committer
  change (they are recreated with git plumbing, not rebased).
- `/rebase-signoff` does the same, but moves the commits onto the current
  tip of the target branch, dropping any that become empty.

Either command only signs off a head that GitHub's activity log for the
head branch shows was pushed before the comment was posted, so a push
racing the command is never signed off (commit dates can't be used for
this, since the PR author controls them). An optional `<sha>` (12 to 40
hex digits; shorter prefixes can be forged) must also match the head: pass
it when there's any doubt the head is what you reviewed, since without it
a push between your review and your comment would be signed off too. The
push uses `--force-with-lease` against that head, so a concurrent push is
never overwritten. In repositories that dismiss stale reviews, the push can
dismiss approvals like any push, so sign off before approving.

Who can use it: `/signoff` needs the triage role or higher, but write on
PRs from forks, since the App's push runs their CI without the "approve and
run" step GitHub otherwise requires for outside contributors.
`/rebase-signoff` changes the PR's content, like the "Update branch"
button, so it needs write. Comments by bots and by people without access
to the repository are ignored silently.

The trailer uses the commenter's GitHub name and public email, falling
back to their `ID+login@users.noreply.github.com` address; the commenter
also becomes the committer, which is what the `dco-2` App matches a
sign-off against when it isn't the author's. dco-2 re-checks the PR on the
push, and a push with the App token also runs the PR's CI again. Pushing
removes a PR from the merge queue, as any push does.

The command reacts with :eyes: when it starts, then :rocket: or :confused:,
and posts one comment with the result. Commands on the same PR run one at
a time, and GitHub keeps only the newest one waiting: a command sent while
another is already waiting replaces it, and the replaced one gets no
reply. PRs with merge commits are refused, as are fork PRs that don't allow
edits by maintainers and PRs whose head is a branch of this repository
that is the default, protected, or covered by a rule against force pushes.
Rewritten commits lose any GPG/SSH signature their author made.

### Installing it

Each repository needs this stub as `.github/workflows/signoff.yml`. In
bootc-dev, [infra](https://github.com/bootc-dev/infra) syncs it to every
repository from `common/.github/workflows/signoff.yml`, so there's nothing
to do per repository; other organizations can copy it:

```yaml
name: PR signoff command

on:
  issue_comment:
    types: [created]

permissions: {}

jobs:
  signoff:
    # GitHub evaluates this before assigning a runner: any other comment
    # creates a skipped run, which uses no runner time.
    if: >-
      github.event.issue.pull_request &&
      github.event.comment.user.type == 'User' &&
      (startsWith(github.event.comment.body, '/signoff') ||
       startsWith(github.event.comment.body, '/rebase-signoff'))
    # Only used where the App below isn't configured, for same-repository
    # PRs; the job runs no code from the PR.
    permissions:
      contents: write
      pull-requests: write
    # Pinned: this hands the App's private key to the called workflow.
    uses: bootc-dev/actions/.github/workflows/pr-signoff.yml@<commit> # main
    with:
      app-client-id: ${{ vars.GH_AW_APP_CLIENT_ID }}
      workflows-permission: true
    secrets:
      app-private-key: ${{ secrets.GH_AW_APP_PRIVATE_KEY }}
```

Pin a commit of this repository's main branch, since the stub hands the
App's private key to the called workflow, which runs its script from that
same commit. Update the pin in infra's `common/` copy and sync-common
carries it to every repository.

The workflow is public, so repositories in any organization can call it.
It needs a GitHub App installed on the repository with contents and pull
requests write access (and workflows write, for `workflows-permission:
true`, to push PRs that change `.github/workflows`), whose client ID is
the `GH_AW_APP_CLIENT_ID` variable and private key the
`GH_AW_APP_PRIVATE_KEY` secret. In bootc-dev that is the bootc-bot App,
which has these permissions; another organization needs an App of its own
(or that one installed) and the same variable and secret. The App token is
what makes the rewritten branch run CI again, and what can push to forks.
Without it the workflow falls back to the job's `GITHUB_TOKEN`: dco-2
still re-checks, but other workflows don't run on the new head, and fork
PRs are refused.

The job-level `if:` matters: GitHub can't filter `issue_comment` events on
their body in `on:`, so every comment on an issue or PR creates a run of
the stub. With the `if:` false, that run's job is skipped without ever
requesting a runner: it costs no runner time, and only shows up as a
skipped run in the Actions tab.
