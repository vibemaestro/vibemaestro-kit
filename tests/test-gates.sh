#!/bin/bash
# =============================================================================
# The SDLC gates, end to end
# =============================================================================
# Run: bash tests/test-gates.sh
#
# The four gates (commit discipline, sensitive-info with its allowlist, PR title and branch, dead branches) are run in the form a repo
# gets them: INSTALLED by scripts/install_gates.py into a scratch repo, then run from `.vibemaestro/gates/` there. Each gate is red on its
# planted fault and green on its clean case; an invalid config is rc 65 naming the key in every gate; the base-ref rule holds for
# every key a PR could relax (commits.*, the allowlist, pr.title.*, branch.pattern, dead_branches.*); a base with no config file means the
# defaults and a base ref that does not read is rc 2; the installer writes, keeps and refuses as specified.
# The per-gate families of the hub's tests (the same planted faults in depth, and a planted break of each script) live in
# tests/test-gates-{commit,sensitive,title,dead,workflows}.sh; here every gate has one mutation probe per fault class of the spec.
#
#   [E] each installed gate: planted fault red, clean green      [V] invalid config rc 65, key named, in every gate
#   [R] the base-ref rule, per gate                              [I] the installer
# Real git in throw-away repositories, a fake gh, no network, no sleep.
# =============================================================================
set -uo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
# shellcheck source=fixtures/lib.sh
. "$HERE/fixtures/lib.sh"
# shellcheck source=fixtures/flow.sh
. "$HERE/fixtures/flow.sh"
# shellcheck source=fixtures/ports.sh
. "$HERE/fixtures/ports.sh"
# shellcheck source=fixtures/gates.sh
. "$HERE/fixtures/gates.sh"

PLUGIN="$SRC_ROOT/plugins/vibemaestro-sdlc"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"
export PYTHONDONTWRITEBYTECODE=1
for f in gate_common.py commit_discipline.py pr_sensitive.py pr_title.py dead_branches.sh; do [ -f "$PLUGIN/gates/$f" ] && ok "gates/$f exists" || bad "gates/$f is missing"; done
[ -f "$PLUGIN/scripts/install_gates.py" ] && ok "scripts/install_gates.py exists" || { bad "scripts/install_gates.py is missing"; summary; exit 1; }

IPX() { printf '%s.%s.%s.%s' "$@"; }
shaof() { printf '%s' "$1" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'; }
# inst <plugin> <repo> — install the gates of that plugin copy into the repo and commit them on main
inst() {
  cenv python3 "$1/scripts/install_gates.py" --root "$2" >/dev/null 2>&1
  G -C "$2" add -A; G -C "$2" commit -qm "chore: install the gates"
}
# vendored script paths inside an installed repo
V() { printf '%s/.vibemaestro/gates/%s' "$1" "$2"; }

fam_each() {
  local p=$1 r i ip mail
  ip=$(IPX 103 97 12 44); mail=$(printf 'jane.doe%sgmail.com' @)
  # commit discipline: 16 commits red, 15 green; one file x5 red
  r=$(mk_repo e1); inst "$p" "$r"; G -C "$r" checkout -qb feat; for i in $(seq 1 15); do cm "$r" "f$i.txt" "feat: task $i"; done
  run_gate python3 "$(V "$r" commit_discipline.py)" --cwd "$r" main feat; want 0 "[E] commit-discipline (installed copy): 15 commits are green"
  cm "$r" f16.txt "feat: task 16"; run_gate python3 "$(V "$r" commit_discipline.py)" --cwd "$r" main feat; want 1 "[E] commit-discipline: 16 commits are red (the 15-commit default)" "limit 15"
  r=$(mk_repo e2); inst "$p" "$r"; G -C "$r" checkout -qb feat; for i in 1 2 3 4 5; do cm "$r" hot.txt "feat: pass $i"; done
  run_gate python3 "$(V "$r" commit_discipline.py)" --cwd "$r" main feat; want 1 "[E] commit-discipline: one file in 5 commits is red (the 4-touch default)" "hot.txt x5"
  # sensitive: a planted secret, IP, e-mail and phone in a PR body are red, a clean one is green
  local k v
  for k in "github-token:$(printf 'gh%s_%s' p aB3xK9pQ2mZ7vL4nW8rT6yU1aB3xK9pQ2mZ7)" "ip:node $ip" "email:log in with $mail" "phone:call 0$(printf 912345678)"; do
    v=${k#*:}; printf '%s' "$v" > "$TMP/body.txt"
    RC=0; OUT=$(cenv python3 "$(V "$r" pr_sensitive.py)" --cwd "$r" --text < "$TMP/body.txt" 2>&1) || RC=$?
    want 1 "[E] pr-sensitive: a planted ${k%%:*} is red"
  done
  RC=0; OUT=$(printf 'Summary: the gates now run.\n' | cenv python3 "$(V "$r" pr_sensitive.py)" --cwd "$r" --text 2>&1) || RC=$?; want 0 "[E] pr-sensitive: a clean body is green"
  # title: a ready PR in intent form that carries code is red under reject; the same payload under the default is green
  put_cfg "$r" '{"pr": {"title": {"intent_form": "reject"}}}'
  RC=0; OUT=$(printf '{"title":"docs(kb): intent x","draft":false,"files":["kb/a.md","src/b.py"]}' | cenv python3 "$(V "$r" pr_title.py)" --cwd "$r" 2>&1) || RC=$?; want 1 "[E] pr-title: a ready PR in intent form with code is red" "INTENT-FILE"
  RC=0; OUT=$(printf '{"title":"feat(x): add b","draft":false,"files":["kb/a.md","src/b.py"]}' | cenv python3 "$(V "$r" pr_title.py)" --cwd "$r" 2>&1) || RC=$?; want 0 "[E] pr-title: a proper title is green"
  rm -f "$r/.vibemaestro/sdlc.json"
  RC=0; OUT=$(printf '{"title":"docs(kb): intent x","draft":false,"files":["src/b.py"]}' | cenv python3 "$(V "$r" pr_title.py)" --cwd "$r" 2>&1) || RC=$?; want 0 "[E] pr-title: the default config passes everything (inert until configured)"
  # dead branches: one merged branch is red at threshold 0 and green with the threshold at 1
  local W; W=$(mk_origin dead); inst "$p" "$W"; G -C "$W" push -q origin main; G -C "$W" checkout -q -b old; cm "$W" o.txt "feat: o"; G -C "$W" checkout -q main; G -C "$W" merge -q --ff-only old; G -C "$W" push -q origin main old
  run_gate bash "$(V "$W" dead_branches.sh)" --repo "$W"; want 1 "[E] dead-branches: one branch already in main is red (threshold 0)" "origin/old"
  run_gate bash "$(V "$W" dead_branches.sh)" --repo "$W" --threshold 1; want 0 "[E] dead-branches: the same with the threshold at 1 is green"
  G -C "$W" push -q origin --delete old; G -C "$W" fetch -q --prune origin
  run_gate bash "$(V "$W" dead_branches.sh)" --repo "$W"; want 0 "[E] dead-branches: after the branch is deleted: green"
}

fam_invalid() {
  local p=$1 r
  r=$(mk_repo inv); inst "$p" "$r"; G -C "$r" checkout -qb feat; cm "$r" a.txt "feat: a"
  put_cfg "$r" '{"commits": {"max_per_pr": "many"}}'
  run_gate python3 "$(V "$r" commit_discipline.py)" --cwd "$r" main feat; want 65 "[V] commit-discipline: an invalid config is rc 65 and names the key" commits.max_per_pr
  put_cfg "$r" '{"sensitive": {"scan": ["pr_title"]}}'
  RC=0; OUT=$(printf 'x\n' | cenv python3 "$(V "$r" pr_sensitive.py)" --cwd "$r" --text 2>&1) || RC=$?; want 65 "[V] pr-sensitive: an invalid config is rc 65 and names the key" 'sensitive.scan[0]'
  put_cfg "$r" '{"pr": {"title": {"pattern": "("}}}'
  RC=0; OUT=$(printf '{}' | cenv python3 "$(V "$r" pr_title.py)" --cwd "$r" 2>&1) || RC=$?; want 65 "[V] pr-title: an invalid config is rc 65 and names the key" pr.title.pattern
  put_cfg "$r" '{"dead_branches": {"max_merged_on_remote": "none"}}'
  local W; W=$(mk_origin invd); inst "$p" "$W"; G -C "$W" push -q origin main; put_cfg "$W" '{"dead_branches": {"max_merged_on_remote": "none"}}'
  run_gate bash "$(V "$W" dead_branches.sh)" --repo "$W"; want 65 "[V] dead-branches: an invalid config is rc 65 and names the key" dead_branches.max_merged_on_remote
  put_cfg "$r" '{"bogus": 1, "pr": {"draft": 1}}'
  run_gate python3 "$(V "$r" commit_discipline.py)" --cwd "$r" main feat; want 65 "[V] a wrong-typed key is rc 65 in a gate too, beside an unknown one" pr.draft
  put_cfg "$r" '{"schema": 2}'
  run_gate python3 "$(V "$r" commit_discipline.py)" --cwd "$r" main feat; want 65 "[V] a config newer than the plugin is rc 65" schema
  put_cfg "$r" '{'
  run_gate python3 "$(V "$r" commit_discipline.py)" --cwd "$r" main feat; want 65 "[V] a config that is not JSON is rc 65"
}

# the base-ref rule for every key a PR could relax: the PR changes the key in its own commit; judged by the base it stays red
fam_base() {
  local p=$1 r i A ip
  # commits.*
  r=$(mk_repo b1); commit_cfg "$r" '{"commits": {"max_per_pr": 2}}' "base: config"; inst "$p" "$r"; G -C "$r" branch base
  G -C "$r" checkout -qb pr; for i in 1 2 3; do cm "$r" "f$i.txt" "feat: task $i"; done; commit_cfg "$r" '{"commits": {"max_per_pr": 99}}' "feat: relax"
  run_gate python3 "$(V "$r" commit_discipline.py)" --cwd "$r" base pr --config-ref base; want 1 "[R] commits.max_per_pr relaxed in the PR: judged by the base, red"
  run_gate python3 "$(V "$r" commit_discipline.py)" --cwd "$r" base pr; want 0 "[R] …control: without the ref the relaxed value applies, green"
  # the allowlist: the PR adds the hash of the value it leaks
  ip=$(IPX 45 77 12 34); r=$(mk_repo b2); inst "$p" "$r"; G -C "$r" branch base
  G -C "$r" checkout -qb pr; shaof "$ip" >> "$r/.pr-sensitive-allow"; G -C "$r" commit -qam "feat: exempt what I leak"
  RC=0; OUT=$(printf 'node %s\n' "$ip" | cenv python3 "$(V "$r" pr_sensitive.py)" --cwd "$r" --text --config-ref base 2>&1) || RC=$?; want 1 "[R] a PR that adds the hash of its own leak to the allowlist: judged by the base, red"
  RC=0; OUT=$(printf 'node %s\n' "$ip" | cenv python3 "$(V "$r" pr_sensitive.py)" --cwd "$r" --text 2>&1) || RC=$?; want 0 "[R] …control: the working tree's allowlist applies without the ref, green"
  # pr.title.* and branch.pattern
  r=$(mk_repo b3); commit_cfg "$r" '{"pr": {"title": {"max_len": 20}}, "branch": {"pattern": "^feat/"}}' "base: config"; inst "$p" "$r"; G -C "$r" branch base
  G -C "$r" checkout -qb pr; commit_cfg "$r" '{}' "feat: relax the naming"
  RC=0; OUT=$(printf '{"title":"a title that is well over twenty","draft":false,"files":[],"head":"x"}' | cenv python3 "$(V "$r" pr_title.py)" --cwd "$r" --config-ref base 2>&1) || RC=$?
  want 1 "[R] pr.title.max_len and branch.pattern relaxed in the PR: judged by the base, red" "max_len"
  RC=0; OUT=$(printf '{"title":"a title that is well over twenty","draft":false,"files":[],"head":"x"}' | cenv python3 "$(V "$r" pr_title.py)" --cwd "$r" 2>&1) || RC=$?; want 0 "[R] …control: without the ref, green"
  # dead_branches.*
  local W; W=$(mk_origin b4); commit_cfg "$W" '{"dead_branches": {"max_merged_on_remote": 0}}' "base: config"; inst "$p" "$W"; G -C "$W" push -q origin main; G -C "$W" branch base
  G -C "$W" checkout -qb old; cm "$W" o.txt "feat: o"; G -C "$W" checkout -q main; G -C "$W" merge -q --ff-only old; G -C "$W" push -q origin main old
  G -C "$W" checkout -qb pr; commit_cfg "$W" '{"dead_branches": {"max_merged_on_remote": 50}}' "feat: relax"
  run_gate bash "$(V "$W" dead_branches.sh)" --repo "$W" --config-ref base; want 1 "[R] dead_branches.max_merged_on_remote relaxed in the PR: judged by the base, red"
  run_gate bash "$(V "$W" dead_branches.sh)" --repo "$W"; want 0 "[R] …control: without the ref, green"
  # a base with no config file means the defaults; a ref that does not read is rc 2, for every gate
  r=$(mk_repo b5); G -C "$r" branch base; inst "$p" "$r"; G -C "$r" checkout -qb pr; for i in $(seq 1 16); do cm "$r" "f$i.txt" "feat: task $i"; done
  put_cfg "$r" '{"commits": {"max_per_pr": 99}}'
  run_gate python3 "$(V "$r" commit_discipline.py)" --cwd "$r" base pr --config-ref base; want 1 "[R] a base with no config file means the defaults (15): 16 commits red even if the head's file says 99"
  run_gate python3 "$(V "$r" commit_discipline.py)" --cwd "$r" base pr --config-ref no-such-ref; want 2 "[R] commit-discipline: a ref that does not read is rc 2"
  RC=0; OUT=$(printf 'x\n' | cenv python3 "$(V "$r" pr_sensitive.py)" --cwd "$r" --text --config-ref no-such-ref 2>&1) || RC=$?; want 2 "[R] pr-sensitive: a ref that does not read is rc 2"
  RC=0; OUT=$(printf '{}' | cenv python3 "$(V "$r" pr_title.py)" --cwd "$r" --config-ref no-such-ref 2>&1) || RC=$?; want 2 "[R] pr-title: a ref that does not read is rc 2"
  run_gate bash "$(V "$W" dead_branches.sh)" --repo "$W" --config-ref no-such-ref; want 2 "[R] dead-branches: a ref that does not read is rc 2"
}

fam_install() {
  local p=$1 r t1 t2 O f
  r=$(mk_repo ins); G -C "$r" rm -q seed.txt 2>/dev/null; G -C "$r" commit -qm empty --allow-empty
  RC=0; OUT=$(cenv python3 "$p/scripts/install_gates.py" --root "$r" 2>&1) || RC=$?
  want 0 "[I] an empty git repo: rc 0, files written" "install-gates: wrote 16"
  for f in commit-discipline pr-sensitive pr-title pr-body dead-branches; do [ -f "$r/.github/workflows/$f.yml" ] && ok "[I] workflow $f.yml written" || bad "[I] workflow $f.yml missing"; done
  for f in gate_common.py commit_discipline.py pr_sensitive.py pr_title.py pr_body.py dead_branches.sh sdlc_config.py messages.py; do [ -f "$r/.vibemaestro/gates/$f" ] && ok "[I] .vibemaestro/gates/$f written" || bad "[I] .vibemaestro/gates/$f missing"; done
  [ -x "$r/.vibemaestro/gates/dead_branches.sh" ] && [ -x "$r/.vibemaestro/gates/commit_discipline.py" ] && ok "[I] the vendored scripts are executable" || bad "[I] a vendored script is not executable"
  [ -f "$r/.pr-sensitive-allow" ] && ! grep -qE '^[0-9a-f]{64}' "$r/.pr-sensitive-allow" && grep -q '^#' "$r/.pr-sensitive-allow" && ok "[I] the allowlist is written with its header and no entry" || bad "[I] the allowlist is not header-only"
  has "$OUT" "commits.max_per_pr" "[I] the output names the config keys the gates read"
  t1=$(tree_hash "$r"); RC=0; OUT=$(cenv python3 "$p/scripts/install_gates.py" --root "$r" 2>&1) || RC=$?
  t2=$(tree_hash "$r"); want 0 "[I] a second run: rc 0" "install-gates: kept 16"
  eq "$t2" "$t1" "[I] …and the tree hash is identical (a no-op)"
  [ "$(printf '%s\n' "$OUT" | grep -c '^kept ')" = 16 ] && ok "[I] …every file is reported kept" || bad "[I] the second run did not keep all 16: $OUT"
  # the refresh the skill names: delete .vibemaestro/gates/, re-run: every vendored file (loader and message table included) is
  # written again, the workflows and the allowlist are kept, and the tree is as installed
  rm -r "$r/.vibemaestro/gates"
  RC=0; OUT=$(cenv python3 "$p/scripts/install_gates.py" --root "$r" 2>&1) || RC=$?
  want 0 "[I] the refresh (.vibemaestro/gates/ deleted, re-run): rc 0" "wrote            .vibemaestro/gates/messages.py"
  has "$OUT" "wrote            .vibemaestro/gates/sdlc_config.py" "[I] …the loader is written again"
  has "$OUT" "wrote            .vibemaestro/gates/pr_evidence.py" "[I] …and the gate that prints from the table"
  [ "$(printf '%s\n' "$OUT" | grep -c '^wrote ')" = 9 ] && [ "$(tree_hash "$r")" = "$t1" ] && ok "[I] …the nine vendored files only, and the tree is as installed" || bad "[I] the refresh wrote other files: $OUT"
  # a pre-existing different workflow is kept byte for byte
  r=$(mk_repo ins2); mkdir -p "$r/.github/workflows"; printf 'name: mine\non: push\n' > "$r/.github/workflows/pr-title.yml"; t1=$(shasum "$r/.github/workflows/pr-title.yml" | cut -d' ' -f1)
  RC=0; OUT=$(cenv python3 "$p/scripts/install_gates.py" --root "$r" 2>&1) || RC=$?
  want 0 "[I] a workflow that already exists and differs: rc 0" "kept (differs)   .github/workflows/pr-title.yml"
  eq "$(shasum "$r/.github/workflows/pr-title.yml" | cut -d' ' -f1)" "$t1" "[I] …kept byte for byte"
  # an existing allowlist with entries is not touched
  r=$(mk_repo ins3); printf '%s  # kept\n' "$(shaof x)" > "$r/.pr-sensitive-allow"; t1=$(shasum "$r/.pr-sensitive-allow" | cut -d' ' -f1)
  cenv python3 "$p/scripts/install_gates.py" --root "$r" >/dev/null 2>&1; eq "$(shasum "$r/.pr-sensitive-allow" | cut -d' ' -f1)" "$t1" "[I] an allowlist with entries is never rewritten"
  # --only
  r=$(mk_repo ins4); RC=0; OUT=$(cenv python3 "$p/scripts/install_gates.py" --root "$r" --only commit-discipline,pr-title 2>&1) || RC=$?
  want 0 "[I] --only commit-discipline,pr-title: rc 0"
  [ -f "$r/.github/workflows/commit-discipline.yml" ] && [ ! -e "$r/.github/workflows/pr-sensitive.yml" ] && [ ! -e "$r/.vibemaestro/gates/pr_sensitive.py" ] && [ ! -e "$r/.pr-sensitive-allow" ] && ok "[I] …only the chosen gates, their scripts, and no allowlist" || bad "[I] --only wrote other files"
  # --dry-run
  r=$(mk_repo ins5); t1=$(tree_hash "$r"); RC=0; OUT=$(cenv python3 "$p/scripts/install_gates.py" --root "$r" --dry-run 2>&1) || RC=$?
  want 0 "[I] --dry-run: rc 0, the plan is printed" "would write"; eq "$(tree_hash "$r")" "$t1" "[I] …and nothing is written"
  # refusals write nothing
  r=$(mk_repo ins6); t1=$(tree_hash "$r")
  RC=0; OUT=$(cenv python3 "$p/scripts/install_gates.py" --root "$r" --runner-default "bad'label" 2>&1) || RC=$?; want 64 "[I] a runner label with a quote: rc 64"
  eq "$(tree_hash "$r")" "$t1" "[I] …nothing written"
  RC=0; OUT=$(cenv python3 "$p/scripts/install_gates.py" --root "$r" --runner-default "a b" 2>&1) || RC=$?; want 64 "[I] a runner label with a space: rc 64"
  RC=0; OUT=$(cenv python3 "$p/scripts/install_gates.py" --root "$r" --runner-var "1x" 2>&1) || RC=$?; want 64 "[I] a runner variable that is not an identifier: rc 64"
  RC=0; OUT=$(cenv python3 "$p/scripts/install_gates.py" --root "$r" --only nope 2>&1) || RC=$?; want 64 "[I] an unknown gate: rc 64" nope
  RC=0; OUT=$(cenv python3 "$p/scripts/install_gates.py" --root "$TMP" 2>&1) || RC=$?; want 64 "[I] a directory that is not a git repo: rc 64"
  RC=0; OUT=$(cenv python3 "$p/scripts/install_gates.py" --root "$r" --bogus 2>&1) || RC=$?; want 64 "[I] an unknown flag: rc 64"
  put_cfg "$r" '{"ci": {"runner_var": 7}}'; RC=0; OUT=$(cenv python3 "$p/scripts/install_gates.py" --root "$r" 2>&1) || RC=$?; want 65 "[I] an invalid config: rc 65 naming the key" ci.runner_var
  eq "$(ls "$r/.github" 2>/dev/null | wc -l | tr -d ' ')" 0 "[I] …and nothing written"
  # a symlinked directory that points outside the repo, and a parent that is a file: refused before anything is written
  local OUTSIDE; OUTSIDE=$(mktemp -d "$TMP/outside.XXXXXX"); r=$(mk_repo ins8); ln -s "$OUTSIDE" "$r/.github"
  RC=0; OUT=$(cenv python3 "$p/scripts/install_gates.py" --root "$r" --only pr-title 2>&1) || RC=$?
  want 64 "[I] .github is a symlink to a directory outside the repo: rc 64" "outside the repo"
  [ -z "$(ls -A "$OUTSIDE")" ] && [ ! -e "$r/.vibemaestro" ] && ok "[I] …nothing was written, inside or outside" || bad "[I] files were written despite the refusal"
  r=$(mk_repo ins9); printf 'x\n' > "$r/.vibemaestro"
  RC=0; OUT=$(cenv python3 "$p/scripts/install_gates.py" --root "$r" --only pr-title 2>&1) || RC=$?
  want 64 "[I] .vibemaestro is a regular file: rc 64, no traceback" "not a directory"; [ ! -e "$r/.github" ] && ok "[I] …and nothing was written" || bad "[I] .github was written before the refusal"
  # a partial vendored copy (no loader next to the gate) is "could not conclude", not a traceback that reads as red
  local PART; PART=$(mktemp -d "$TMP/partial.XXXXXX"); cp "$p/gates/commit_discipline.py" "$p/gates/pr_title.py" "$p/gates/pr_sensitive.py" "$PART/"
  for g in commit_discipline pr_title pr_sensitive; do
    RC=0; OUT=$(printf '{}' | cenv python3 "$PART/$g.py" --text 2>&1) || RC=$?
    [ "$RC" = 2 ] && ok "[I] $g.py without gate_common.py: rc 2" || bad "[I] $g.py without gate_common.py: rc $RC: ${OUT:0:120}"
  done
  # the installed copy works on its own: a repo with the installed gates and no plugin on PATH
  r=$(mk_repo ins7); cenv python3 "$p/scripts/install_gates.py" --root "$r" >/dev/null 2>&1; G -C "$r" add -A; G -C "$r" commit -qm gates; G -C "$r" checkout -qb feat; cm "$r" a.txt "feat: a"
  RC=0; OUT=$(cd "$r" && env -i PATH="$PATH" HOME="$HOME" python3 .vibemaestro/gates/commit_discipline.py main feat 2>&1) || RC=$?; want 0 "[I] the installed commit gate runs from the repo alone (loader vendored next to it)"
  # the installed pr-evidence gate prints from the vendored message table, in the repo's language
  put_cfg "$r" '{"language": "en", "evidence": {"ui_paths": ["web/**"]}}'
  printf '{"head": "%s", "files": [{"filename": "web/a.js"}], "capped": false, "base": "main", "comments": []}' "$(printf 'a%.0s' $(seq 40))" > "$r/../facts-ins7.json"
  RC=0; OUT=$(cd "$r" && env -i PATH="$PATH" HOME="$HOME" python3 .vibemaestro/gates/pr_evidence.py --facts "$r/../facts-ins7.json" 2>&1) || RC=$?
  want 1 "[I] the installed pr-evidence gate runs from the repo alone (message table vendored next to it), en: red" 'E2E not run: <reason>'
  hasnt "$OUT" "không" "[I] …and prints no Vietnamese in an en repo"
  # the skill
  local S="$p/skills/install-gates/SKILL.md"
  [ -f "$S" ] && eq "$(sed -n 2p "$S")" "name: install-gates" "[I] the skill exists and its name matches" || bad "[I] the skill is missing"
  has "$(cat "$S")" 'scripts/install_gates.py' "[I] the skill calls the installer script"
  has "$(cat "$S")" 'never overwrites' "[I] …and says it never overwrites"
}

FAMILIES="fam_each fam_invalid fam_base fam_install"
for f in $FAMILIES; do "$f" "$PLUGIN"; done

echo "== planted breaks: one probe per fault class, each must turn its family red =="
BRKG count-off-by-one fam_each '[E] commit-discipline: 16 commits are red' commit_discipline.py '    if m["commits"] > max_commits:' '    if m["commits"] > max_commits + 1:'
BRKG exemption-always-honoured fam_each '[E] commit-discipline: one file in 5 commits is red' commit_discipline.py '    blocking = [f for f in found if not (f[2] and why)]' '    blocking = []'
BRKG allowlist-from-working-tree fam_base '[R] a PR that adds the hash of its own leak' pr_sensitive.py '        elif a.config_ref:
            text = gc.read_at(a.cwd, a.config_ref, rel)' '        elif a.config_ref:
            text = gc.read_at(a.cwd, None, rel)'
BRKG pattern-removed fam_each '[E] pr-sensitive: a planted email is red' pr_sensitive.py '    ("email", r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b", 0, lambda s: bool(_EMAIL_OK.match(s))),' ''
BRKG draft-check-inverted fam_each '[E] pr-title: a ready PR in intent form with code is red' pr_title.py '        if draft:
            applied.append("intent_form (draft: not applied)")' '        if not draft:
            applied.append("intent_form (draft: not applied)")'
BRKG dead-order-swapped fam_each '[E] dead-branches: one branch already in main is red' dead_branches.sh '  if is_in "$b" "$merged_main"; then
    dead="$dead$b"$'"'"'\n'"'"'           # group 1: deletable
    continue
  fi' '  if false; then
    continue
  fi'
BRKG config-error-swallowed fam_invalid '[V] commit-discipline: an invalid config is rc 65' gate_common.py '        if probs:
            raise ConfigError(sdlc_config.render_problems(probs))
        return cfg' '        return cfg'
BRKG config-from-head fam_base '[R] commits.max_per_pr relaxed in the PR' commit_discipline.py '    cfg = gc.load_config(a.cwd, a.config_ref)' '    cfg = gc.load_config(a.cwd, None)'
BRKG title-config-from-head fam_base '[R] pr.title.max_len and branch.pattern relaxed' pr_title.py '    cfg = gc.load_config(cwd, ref)' '    cfg = gc.load_config(cwd, None)'
BRKG dead-config-from-head fam_base '[R] dead_branches.max_merged_on_remote relaxed' dead_branches.sh '${CONFIG_REF:+--config-ref "$CONFIG_REF"}' ''
BRKG bad-ref-green fam_base '[R] commit-discipline: a ref that does not read' gate_common.py '        raise Infra("ref `%s` does not read" % ref)
    if git(["cat-file"' '        return None
    if git(["cat-file"'
d="$TMP/break-installer-overwrites"; mk_plugin_copy "$d"
mutate "$d/scripts/install_gates.py" '    if os.path.lexists(path):' '    if False:' && mutate "$d/scripts/install_gates.py" 'os.O_WRONLY | os.O_CREAT | os.O_EXCL' 'os.O_WRONLY | os.O_CREAT | os.O_TRUNC' \
  && expect_red installer-overwrites fam_install "$d" '[I] a workflow that already exists and differs'
BRKS installer-follows-symlinks fam_install '[I] .github is a symlink to a directory outside the repo' install_gates.py '        if os.path.commonpath([real_root, os.path.realpath(anc)]) != real_root:' '        if False:'
BRKG import-guard-gone fam_install '[I] commit_discipline.py without gate_common.py' commit_discipline.py '    sys.exit(2)
' '    raise
'
BRKS installer-label-unchecked fam_install '[I] a runner label with a quote' install_gates.py '    if not re.fullmatch(r"[A-Za-z0-9._-]+", default):' '    if False:'
BRKS installer-existing-reported-wrote fam_install '[I] a second run' install_gates.py '        return "kept" if same else "kept (differs)"' '        return "wrote"'
PLC="$TMP/break-none"; mk_plugin_copy "$PLC"
QN=0; okdef=$(declare -f ok); baddef=$(declare -f bad); sp=$PASS; sf=$FAIL
ok() { :; }; bad() { QN=$((QN+1)); }
for f in $FAMILIES; do "$f" "$PLC" >/dev/null 2>&1; done
eval "$okdef"; eval "$baddef"; PASS=$sp; FAIL=$sf
eq "$QN" 0 "control: an unbroken copy passes every family"

echo; summary
