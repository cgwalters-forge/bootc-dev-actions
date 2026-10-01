#!/usr/bin/env bash
# The /signoff and /rebase-signoff pull request commands, run by
# .github/workflows/pr-signoff.yml; see README.md ("pr-signoff").
#
# Security notes, since this force-pushes PR branches (including forks)
# with a token that can write to the repository:
# - Nothing from the PR is executed or checked out: commits are rewritten in
#   a bare repository with git plumbing (hash-object, merge-tree), hooks
#   disabled, system/global config ignored and no attributes from the PR.
# - The comment body, branch names and user names arrive only through the
#   environment, and replies never echo PR-controlled text.
# - Only a head that GitHub recorded being pushed before the comment is
#   signed off (and the one named, if a SHA is given); the push uses
#   --force-with-lease against it.
#
# Environment: GH_TOKEN, HAVE_APP (true/false), REPO, PR_NUMBER,
# COMMENT_ID, COMMENT_BODY, COMMENT_CREATED_AT, COMMENTER, COMMENTER_TYPE,
# SERVER_URL, GITHUB_RUN_ID, GITHUB_OUTPUT.
# shellcheck disable=SC2153 # COMMENTER and friends come from the environment
set -euo pipefail
shopt -s inherit_errexit
export LC_ALL=C

declare -rA ROLE_RANK=([none]=0 [read]=1 [triage]=2 [write]=3 [maintain]=4 [admin]=5)
# A shorter prefix could be matched by a commit the PR author ground out.
readonly MIN_SHA_LEN=12
readonly SHA_RE="^[0-9a-f]{${MIN_SHA_LEN},40}$"
# Like gh-aw's slash commands: the command is the first word of the comment.
readonly COMMAND_RE='^/(signoff|rebase-signoff)([[:space:]].*)?$'
readonly SIGNOFF_KEY=Signed-off-by
# Branch rule types that mean a branch must not be force-pushed.
readonly NO_REWRITE_RULES='["non_fast_forward", "update"]'

# parse_command BODY: sets COMMAND and ARGS from the first line of a comment,
# or returns 1 if it isn't one of the commands.
parse_command() {
    local first=${1%%$'\n'*}
    first=${first%$'\r'}
    [[ $first =~ $COMMAND_RE ]] || return 1
    COMMAND=${BASH_REMATCH[1]}
    read -r -a ARGS <<< "${BASH_REMATCH[2]:-}"
}

# effective_role PERMISSION_JSON: the commenter's role from the collaborator
# permission API. Like gh-aw's check_membership, role_name is preferred (the
# legacy "permission" folds triage into read and maintain into write), and a
# custom role falls back to its base permission, never admin.
effective_role() {
    local role
    role=$(jq -r '.role_name // "" | if . == "maintainer" then "maintain" else . end' <<< "$1")
    if [[ -n $role && -n ${ROLE_RANK[$role]:-} ]]; then
        echo "$role"
        return
    fi
    case $(jq -r '.permission // "none"' <<< "$1") in
        write) echo write ;;
        read) echo read ;;
        *) echo none ;;
    esac
}

# required_role COMMAND FORK: signing off needs triage, like other PR
# housekeeping. Rebasing changes the PR's content, like "Update branch", so
# it needs write. On a fork PR, pushing with the App token makes the PR's CI
# run without the "approve and run" gate for outside contributors, which
# needs write too.
required_role() {
    if [[ $1 == rebase-signoff || $2 == true ]]; then
        echo write
    else
        echo triage
    fi
}

# role_allows ROLE REQUIRED: whether ROLE is REQUIRED or higher.
role_allows() {
    (( ROLE_RANK[$1] >= ROLE_RANK[$2] ))
}

# rewrite MODE ONTO COMMIT...: recreates the commits (oldest first) on ONTO
# with TRAILER added unless the same trailer is already there, and with
# COMMITTER as the committer; prints the new head. In "signoff" mode ONTO is
# their original base and every tree is kept; in "rebase-signoff" mode each
# tree comes from merge-tree, commits that become empty are dropped (like
# git rebase, ones that were empty to begin with are kept), and a conflict
# returns 2. Everything but the trailer and the
# committer is copied byte for byte from the original commit object,
# including the author line and the message; signatures are dropped.
rewrite() {
    local mode=$1 parent=$2 c orig_parent tree raw msg rc
    shift 2
    raw=$(mktemp)
    msg=$(mktemp)
    for c in "$@"; do
        git cat-file commit "$c" > "$raw"
        orig_parent=$(git rev-parse "$c^")
        if [[ $mode == signoff ]]; then
            tree=$(git rev-parse "$c^{tree}")
        else
            rc=0
            tree=$(git merge-tree --write-tree --no-messages --merge-base="$orig_parent" "$parent" "$c") || rc=$?
            if (( rc != 0 )); then
                rm -f "$raw" "$msg"
                return 2
            fi
            if [[ $tree == "$(git rev-parse "$parent^{tree}")" &&
                $(git rev-parse "$c^{tree}") != "$(git rev-parse "$orig_parent^{tree}")" ]]; then
                continue
            fi
        fi
        sed '1,/^$/d' "$raw" |
            git interpret-trailers --no-divider --if-exists addIfDifferent \
                --trailer "$TRAILER" > "$msg"
        if [[ $parent == "$orig_parent" ]] && sed '1,/^$/d' "$raw" | cmp -s - "$msg"; then
            parent=$c
            continue
        fi
        parent=$({
            printf 'tree %s\nparent %s\n' "$tree" "$parent"
            sed -n '/^$/q; /^author /p' "$raw"
            printf 'committer %s\n' "$COMMITTER"
            sed -n '/^$/q; /^encoding /p' "$raw"
            echo
            cat "$msg"
        } | git hash-object -t commit -w --stdin)
    done
    rm -f "$raw" "$msg"
    echo "$parent"
}

api() { gh api -H 'X-GitHub-Api-Version: 2022-11-28' "$@"; }
react() {
    api -X POST "repos/$REPO/issues/comments/$COMMENT_ID/reactions" \
        -f content="$1" > /dev/null || echo "::warning::Failed to add a $1 reaction"
}
# Posts the one result comment and ends the job successfully.
finish() {
    react "$1"
    api -X POST "repos/$REPO/issues/$PR_NUMBER/comments" -f body="$2" > /dev/null
    echo "replied=true" >> "$GITHUB_OUTPUT"
    exit 0
}
refuse() {
    echo "::notice::Refused: $1"
    finish confused ":x: @$COMMENTER \`/$COMMAND\`: $1"
}
short() { printf '%.7s' "$1"; }

main() {
    parse_command "$COMMENT_BODY" || { echo "Not a signoff command; nothing to do."; exit 0; }
    # Others (bots, apps) are ignored silently, as are commenters who can't
    # even read the repository, so the command can't be used for noise.
    if [[ $COMMENTER_TYPE != User ]]; then
        echo "::notice::Ignoring a command from $COMMENTER ($COMMENTER_TYPE)"
        exit 0
    fi
    local perm_json role
    perm_json=$(api "repos/$REPO/collaborators/$COMMENTER/permission") || perm_json='{}'
    role=$(effective_role "$perm_json")
    echo "Commenter $COMMENTER has role: $role"
    if ! role_allows "$role" read; then
        echo "::notice::Ignoring a command from $COMMENTER, who has no access"
        exit 0
    fi
    react eyes

    local pr_json head_sha head_ref head_repo base_ref fork=false required
    pr_json=$(api "repos/$REPO/pulls/$PR_NUMBER")
    pr() { jq -r "$1" <<< "$pr_json"; }
    head_sha=$(pr .head.sha)
    head_ref=$(pr .head.ref)
    head_repo=$(pr '.head.repo.full_name // ""')
    base_ref=$(pr .base.ref)
    [[ -n $head_repo && $head_repo != "$REPO" ]] && fork=true
    required=$(required_role "$COMMAND" "$fork")
    if ! role_allows "$role" "$required"; then
        refuse "this command requires the $required role or higher on this repository$([[ $fork == true && $COMMAND == signoff ]] && echo " for PRs from forks, since the push runs their CI")."
    fi
    [[ $(pr .state) == open ]] || refuse "the pull request is not open."
    [[ -n $head_repo ]] || refuse "the PR's source repository no longer exists."
    local ref
    for ref in "$head_ref" "$base_ref"; do
        git check-ref-format "refs/heads/$ref" || refuse "unsupported branch name."
    done

    # Which head: one pushed before the comment was posted, per GitHub's
    # activity log (commit dates can't be used; the PR author sets them),
    # and the named one if a SHA is given. What the maintainer looked at
    # before commenting can't be known; naming the SHA pins that.
    local usage want push_json pushed_sha pushed_at pushed_ts comment_ts
    usage="Usage: \`/$COMMAND [<sha>]\`, where the optional \`<sha>\` ($MIN_SHA_LEN to 40 hex digits) must match the PR's head."
    (( ${#ARGS[@]} <= 1 )) || refuse "$usage"
    if (( ${#ARGS[@]} == 1 )); then
        want=${ARGS[0],,}
        [[ $want =~ $SHA_RE ]] || refuse "$usage"
        [[ $head_sha == "$want"* ]] ||
            refuse "the PR head is now $head_sha, not $want. Review the new commits, then retry."
    fi
    push_json=$(api -X GET "repos/$head_repo/activity" -f ref="refs/heads/$head_ref" \
        -f direction=desc -f per_page=1 --jq '.[0] // {} | {after, timestamp}') || push_json='{}'
    pushed_sha=$(jq -r '.after // ""' <<< "$push_json")
    pushed_at=$(jq -r '.timestamp // ""' <<< "$push_json")
    echo "Last push to the head branch: $pushed_sha at $pushed_at; comment at $COMMENT_CREATED_AT"
    [[ $pushed_sha == "$head_sha" && -n $pushed_at ]] ||
        refuse "couldn't confirm when the PR head $(short "$head_sha") was pushed; please retry in a minute."
    pushed_ts=$(date -d "$pushed_at" +%s)
    comment_ts=$(date -d "$COMMENT_CREATED_AT" +%s)
    (( pushed_ts < comment_ts )) ||
        refuse "the PR was pushed after your comment (head is now $(short "$head_sha")). Review the new commits, then retry."

    # Where we'd push: never a shared branch that rules keep from rewrites.
    if [[ $fork == false ]]; then
        local protected blocked
        protected=$(api -X GET "repos/$REPO/branches" -f protected=true --paginate --jq '.[].name')
        blocked=$(api "repos/$REPO/rules/branches/$head_ref" --jq "[.[] | select(.type | IN(${NO_REWRITE_RULES}[]))] | length")
        if [[ $head_ref == "$(pr .base.repo.default_branch)" ]] || grep -qxF -- "$head_ref" <<< "$protected" || (( blocked > 0 )); then
            refuse "the PR's head is a protected branch of this repository, which this command won't rewrite."
        fi
    else
        [[ $(pr .maintainer_can_modify) == true ]] ||
            refuse "this PR is from a fork that doesn't allow edits by maintainers. The author can enable \"Allow edits by maintainers\" on the PR, or sign off the commits themselves with \`git rebase --signoff\`."
        [[ $HAVE_APP == true ]] ||
            refuse "pushing to fork PRs needs a GitHub App token, and this repository's workflow doesn't provide one."
    fi

    # The commenter signs off and is the committer, which is what dco-2
    # matches a sign-off against when it isn't the author's.
    local user_json name email
    user_json=$(api "users/$COMMENTER")
    name=$(jq -r '.name // ""' <<< "$user_json")
    email=$(jq -r '.email // ""' <<< "$user_json")
    [[ -n $name && $name != *[$'<>\n']* ]] || name=$COMMENTER
    [[ -n $email && $email != *[$'<> \n']* ]] || email="$(jq -r .id <<< "$user_json")+$COMMENTER@users.noreply.github.com"
    TRAILER="$SIGNOFF_KEY: $name <$email>"
    COMMITTER="$name <$email> $(date +%s) +0000"
    echo "Signing off as: $name <$email>"

    # A bare repository with no hooks, no system/global config, no
    # attributes from any tree, and only https.
    export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
    GIT_DIR=$(mktemp -d)
    export GIT_DIR
    git init -q --bare "$GIT_DIR"
    git config core.hooksPath /dev/null
    git config protocol.allow never
    git config protocol.https.allow always
    printf '* merge=text -filter\n' > "$GIT_DIR/info/attributes"
    # shellcheck disable=SC2016 # expanded by git's shell, from the environment
    git config credential.helper '!f() { test "$1" = get && echo username=x-access-token && echo "password=$GH_TOKEN"; }; f'
    git remote add origin "$SERVER_URL/$REPO.git"
    # refs/pull/N/head mirrors the head in the base repository, fork PRs
    # included.
    git fetch -q --no-tags --no-recurse-submodules origin \
        "+refs/heads/$base_ref:refs/remotes/base" "+refs/pull/$PR_NUMBER/head:refs/remotes/pr"
    [[ $(git rev-parse refs/remotes/pr) == "$head_sha" ]] ||
        refuse "GitHub hasn't updated this PR's refs yet; please retry in a minute."

    local base_tip merge_base onto new_head rc=0
    local -a commits
    base_tip=$(git rev-parse refs/remotes/base)
    merge_base=$(git merge-base "$base_tip" "$head_sha") ||
        refuse "the PR has no history in common with the target branch."
    [[ -z $(git rev-list --merges "$merge_base..$head_sha") ]] ||
        refuse "the PR contains merge commits; please rebase it without merges first."
    mapfile -t commits < <(git rev-list --reverse "$merge_base..$head_sha")
    (( ${#commits[@]} > 0 )) || refuse "the PR has no commits of its own."
    onto=$merge_base
    [[ $COMMAND == signoff ]] || onto=$base_tip
    new_head=$(rewrite "$COMMAND" "$onto" "${commits[@]}") || rc=$?
    (( rc != 2 )) ||
        refuse "the commits don't apply cleanly onto the target branch (at $(short "$base_tip")); the PR needs a manual rebase."
    (( rc == 0 ))
    if [[ $new_head == "$head_sha" ]]; then
        finish rocket ":white_check_mark: All ${#commits[@]} commit(s) already carry the \`$SIGNOFF_KEY\` of @$COMMENTER; nothing to do."
    fi

    # Self-check: /signoff kept every tree and author line.
    if [[ $COMMAND == signoff ]]; then
        local fmt='%T %an <%ae> %ad'
        diff -u <(git log --reverse --format="$fmt" "$merge_base..$head_sha") \
            <(git log --reverse --format="$fmt" "$merge_base..$new_head")
    fi

    if ! git push -q --force-with-lease="refs/heads/$head_ref:$head_sha" \
        "$SERVER_URL/$head_repo.git" "$new_head:refs/heads/$head_ref"; then
        react confused
        api -X POST "repos/$REPO/issues/$PR_NUMBER/comments" -f body=":x: @$COMMENTER \`/$COMMAND\`: pushing the rewritten branch failed. Either the branch changed meanwhile, or the token may not push to it (for example, commits touching \`.github/workflows\` need the App's workflows permission). See the [workflow run]($SERVER_URL/$REPO/actions/runs/$GITHUB_RUN_ID)." > /dev/null
        echo "replied=true" >> "$GITHUB_OUTPUT"
        exit 1
    fi

    local count summary note=""
    count=$(git rev-list --count "$onto..$new_head")
    summary="$(short "$head_sha") → $(short "$new_head")"
    [[ $HAVE_APP == true ]] ||
        note=" This repository has no App token configured, so workflows won't run on the new head until the next push."
    if [[ $COMMAND == signoff ]]; then
        finish rocket ":white_check_mark: Added the \`$SIGNOFF_KEY\` of @$COMMENTER to the PR's $count commit(s), content unchanged: $summary.$note"
    fi
    local dropped=$(( ${#commits[@]} - count ))
    (( dropped == 0 )) || note=" $dropped commit(s) became empty and were dropped.$note"
    finish rocket ":white_check_mark: Rebased $count commit(s) onto the target branch (at $(short "$base_tip")) and added the \`$SIGNOFF_KEY\` of @$COMMENTER: $summary.$note"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main
fi
