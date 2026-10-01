#!/usr/bin/env bash
# Offline tests of pr-signoff.sh: command parsing, role mapping, and the
# commit rewrite in a scratch repository. No network.
#   pr-signoff/test.sh
set -euo pipefail
shopt -s inherit_errexit

# shellcheck source=pr-signoff/pr-signoff.sh
source "$(dirname "$0")/pr-signoff.sh"

failures=0
fail() { echo "FAIL: $*" 1>&2; failures=$((failures + 1)); }
expect() { [[ $2 == "$3" ]] || fail "$1: expected '$3', got '$2'"; }

# COMMENT (\n-escaped) => "COMMAND ARGS" or "-" for not a command.
while IFS='|' read -r body expected; do
    [[ -n $body ]] || continue
    body=$(printf '%b' "$body")
    got=-
    if parse_command "$body"; then got="$COMMAND ${ARGS[*]}"; fi
    expect "parse '$body'" "${got% }" "$expected"
done <<'EOF'
/signoff|signoff
/signoff 0123456789ab|signoff 0123456789ab
/rebase-signoff  abc def |rebase-signoff abc def
/signoff\r\nthanks|signoff
/signoff\tabc|signoff abc
/signoffs|-
please /signoff|-
 /signoff|-
/SIGNOFF|-
hello\n/signoff|-
EOF

# role_name|permission => effective role
while IFS='|' read -r role_name permission expected; do
    [[ -n $expected ]] || continue
    json=$(jq -nc --arg r "$role_name" --arg p "$permission" \
        '{permission: $p} + (if $r == "null" then {} else {role_name: $r} end)')
    expect "role $role_name/$permission" "$(effective_role "$json")" "$expected"
done <<'EOF'
admin|admin|admin
maintain|write|maintain
maintainer|write|maintain
triage|read|triage
read|read|read
|write|write
null|read|read
Security Champions|write|write
Custom admin-ish|admin|none
null|none|none
EOF
expect "role from {}" "$(effective_role '{}')" none

# ROLE REQUIRED => allowed?
while read -r role required expected; do
    [[ -n $role ]] || continue
    got=no
    if role_allows "$role" "$required"; then got=yes; fi
    expect "$role allows $required" "$got" "$expected"
done <<'EOF'
none read no
read read yes
read triage no
triage triage yes
triage write no
write write yes
maintain write yes
admin write yes
EOF

# SHA argument => valid?
while read -r sha expected; do
    [[ -n $sha ]] || continue
    got=no
    if [[ $sha =~ $SHA_RE ]]; then got=yes; fi
    expect "sha $sha" "$got" "$expected"
done <<'EOF'
0123456789a no
0123456789ab yes
0123456789abcdef0123456789abcdef01234567 yes
0123456789abcdef0123456789abcdef012345678 no
0123456789aB no
EOF

# COMMAND FORK => required role
while read -r command fork expected; do
    [[ -n $command ]] || continue
    expect "required $command fork=$fork" "$(required_role "$command" "$fork")" "$expected"
done <<'EOF'
signoff false triage
signoff true write
rebase-signoff false write
rebase-signoff true write
EOF

# --- rewrite, in a scratch repository -----------------------------------------
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
git init -q -b main "$work"
cd "$work"
export GIT_AUTHOR_NAME="A. Author." GIT_AUTHOR_EMAIL=author@example.com GIT_AUTHOR_DATE="1700000000 +0200"
export GIT_COMMITTER_NAME=Committer GIT_COMMITTER_EMAIL=committer@example.com GIT_COMMITTER_DATE="1700000000 +0200"
TRAILER="Signed-off-by: Maintainer <m@example.com>"
COMMITTER="Maintainer <m@example.com> 1800000000 +0000"
commit() { # commit FILE CONTENT [git commit args]: prints the new commit
    printf '%s\n' "$2" > "$1"
    git add "$1"
    git commit -q --cleanup=verbatim "${@:3}"
    git rev-parse HEAD
}
base=$(commit f base -m base)
git switch -q -c pr
# A message git's usual cleanup would change, one in Latin-1, and one that
# already has the sign-off.
c1=$(commit a 1 -m $'Keep  trailing space \n\n\n# not a comment\n---\nbody  ')
c2=$(printf 'Caf\xe9\n' | git -c i18n.commitEncoding=ISO-8859-1 commit -q --allow-empty -F - && git rev-parse HEAD)
c3=$(commit b 3 -m "Signed" -m "$TRAILER")

new=$(rewrite signoff "$base" "$c1" "$c2" "$c3")
mapfile -t olds < <(git rev-list --reverse "$base..$c3")
mapfile -t news < <(git rev-list --reverse "$base..$new")
expect "signoff commit count" "${#news[@]}" 3
for i in 0 1 2; do
    o=${olds[$i]} n=${news[$i]}
    expect "tree $i" "$(git rev-parse "$n^{tree}")" "$(git rev-parse "$o^{tree}")"
    expect "author $i" "$(git cat-file commit "$n" | grep '^author ')" "$(git cat-file commit "$o" | grep '^author ')"
    expect "committer $i" "$(git cat-file commit "$n" | sed -n 's/^committer //p')" "$COMMITTER"
    # The message starts with the original's exact bytes, and ends with
    # the trailer.
    size=$(git cat-file commit "$o" | sed '1,/^$/d' | wc -c)
    expect "message $i" "$(git cat-file commit "$n" | sed '1,/^$/d' | head -c "$size" | od -c)" \
        "$(git cat-file commit "$o" | sed '1,/^$/d' | od -c)"
    expect "trailer $i" "$(git cat-file commit "$n" | tail -n1)" "$TRAILER"
done
expect "encoding kept" "$(git cat-file commit "${news[1]}" | sed -n 's/^encoding //p')" ISO-8859-1
expect "one trailer on the signed commit" "$(git cat-file commit "${news[2]}" | grep -c "^$TRAILER$")" 1
expect "rerun is a no-op" "$(rewrite signoff "$base" "${news[@]}")" "$new"

# rebase-signoff: onto a moved base, a commit that becomes empty is dropped
# (one that was empty to begin with is kept), and a conflict returns 2.
git switch -q main
moved=$(commit a 1 -m "same change as c1 on main")
new=$(rewrite rebase-signoff "$moved" "$c1" "$c2" "$c3")
expect "rebased onto the moved base" "$(git merge-base "$moved" "$new")" "$moved"
expect "emptied c1 dropped, empty c2 kept" "$(git rev-list --count "$moved..$new")" 2
expect "rebased content" "$(git show "$new:b")" 3
conflict=$(commit b other -m "conflicting change on main")
rc=0
rewrite rebase-signoff "$conflict" "$c1" "$c2" "$c3" > /dev/null || rc=$?
expect "conflict" "$rc" 2

(( failures == 0 )) || { echo "$failures failure(s)" 1>&2; exit 1; }
echo "ok: pr-signoff tests passed"
