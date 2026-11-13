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
# The per-gate families of the hub's tests (the same planted faults in depth) live in
# tests/test-gates-{commit,sensitive,title,dead,workflows}.sh; here every gate has one probe per fault class of the spec.
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

# lines holding a letter of U+00C0..U+1EF9 (the Vietnamese letters, with the Latin Extended ones between): in each file named, or on
# stdin when none is. The counter is never trusted alone: [L] runs it on a string it must count (see the control there).
vc() { python3 -c '
import re, sys
r = re.compile("[" + chr(0xc0) + "-" + chr(0x1ef9) + "]")
srcs = [open(f, encoding="utf-8", errors="replace") for f in sys.argv[1:]] or [sys.stdin]
print(sum(1 for s in srcs for ln in s if r.search(ln)))' "$@"; }
# vc_tree <repo> — the same, over every file the installer writes that a person could keep in an English-only repo
vc_tree() { vc "$1"/.vibemaestro/gates/* "$1"/.github/workflows/*; }

# facts <file> — the facts of a PR that touches a UI file and carries no E2E evidence
facts() { printf '{"head": "%s", "files": [{"filename": "web/a.js"}], "capped": false, "base": "main", "comments": []}' "$(printf 'a%.0s' $(seq 40))" > "$1"; }

# language: the copies a repo keeps follow its `language`. en: no Vietnamese letter in any installed file, and the gates still run from
# them; vi: the loader and the table are what the plugin has; an older copy is kept, said so, and a clean one comes from deleting it.
fam_english() {
  local p=$1 r r2 c i d t1 t2 f
  printf 'x \xe1\xba\xa1 y\n' > "$TMP/ctl-letter.txt"
  eq "$(vc "$TMP/ctl-letter.txt")" 1 "[L] control: the counter counts a line with one Vietnamese letter"
  ne "$(vc "$p/scripts/messages.py")" 0 "[L] control: the counter finds the Vietnamese table in the plugin's own messages.py"
  # en: nothing Vietnamese in what is installed
  r=$(mk_repo en1); put_cfg "$r" '{"language": "en"}'; inst "$p" "$r"
  eq "$(vc_tree "$r")" 0 "[L] language en: no installed file holds a Vietnamese letter"
  for f in messages.py sdlc_config.py commit_discipline.py pr_sensitive.py; do eq "$(vc "$r/.vibemaestro/gates/$f")" 0 "[L] en: .vibemaestro/gates/$f has none"; done
  [ -s "$r/.vibemaestro/gates/messages.py" ] && [ -s "$r/.vibemaestro/gates/sdlc_config.py" ] && ok "[L] en: the loader and the table are written" || bad "[L] en: the loader or the table is missing"
  # the copies work: the commit gate (config + a failing message), the sensitive gate (table + a failing message)
  G -C "$r" checkout -qb feat; for i in $(seq 1 15); do cm "$r" "f$i.txt" "feat: task $i"; done
  run_gate python3 "$(V "$r" commit_discipline.py)" --cwd "$r" main feat; want 0 "[L] en: the installed commit gate is green on 15 commits"
  cm "$r" f16.txt "feat: task 16"; run_gate python3 "$(V "$r" commit_discipline.py)" --cwd "$r" main feat; want 1 "[L] en: …and red on 16" "limit 15"
  RC=0; OUT=$(printf 'login with %s\n' "$(printf 'jane.doe%sgmail.com' @)" | cenv python3 "$(V "$r" pr_sensitive.py)" --cwd "$r" --text 2>&1) || RC=$?
  want 1 "[L] en: the installed sensitive gate is red on a planted e-mail"
  # the one gate that prints from the message table: pr_evidence (a UI file in the PR, no E2E evidence)
  facts "$TMP/facts-en.json"
  put_cfg "$r" '{"language": "en", "evidence": {"ui_paths": ["web/**"]}}'
  RC=0; OUT=$(cd "$r" && cenv python3 .vibemaestro/gates/pr_evidence.py --facts "$TMP/facts-en.json" 2>&1) || RC=$?
  want 1 "[L] en: the installed pr-evidence gate prints from the copied table, red" 'E2E not run: <reason>'
  eq "$(printf '%s' "$OUT" | vc)" 0 "[L] en: …and its message holds no Vietnamese letter"
  # the gate keeps accepting the Vietnamese spelling of an E2E skip line (its regex is written with escapes now), in the en copy too
  python3 - "$TMP/facts-skip.json" "$(printf 'E2E kh\xc3\xb4ng ch\xe1\xba\xa1y: the reason is long enough here')" <<'PY'
import json, sys
head = "a" * 40
body = "SHA: %s - review round 1 (m)\n\n%s\n" % (head, sys.argv[2])
json.dump({"head": head, "files": [{"filename": "web/a.js"}], "capped": False, "base": "main",
           "comments": [{"url": "u", "author": "o", "association": "OWNER", "id": 1, "created_at": "2026-01-01T00:00:00Z", "body": body}]},
          open(sys.argv[1], "w"))
PY
  RC=0; OUT=$(cd "$r" && cenv python3 .vibemaestro/gates/pr_evidence.py --facts "$TMP/facts-skip.json" 2>&1) || RC=$?
  want 0 "[L] en: the installed pr-evidence gate accepts an E2E skip line written in Vietnamese" "e2e ok"
  # the same repo in vi (the default): the message is Vietnamese (control for the two checks above) and the copies are the plugin's own
  r2=$(mk_repo vi1); put_cfg "$r2" '{"evidence": {"ui_paths": ["web/**"]}}'; inst "$p" "$r2"
  RC=0; OUT=$(cd "$r2" && cenv python3 .vibemaestro/gates/pr_evidence.py --facts "$TMP/facts-en.json" 2>&1) || RC=$?
  want 1 "[L] vi (no language key), same facts: pr-evidence is red" 'E2E'
  ne "$(printf '%s' "$OUT" | vc)" 0 "[L] control: the same gate in a vi repo prints Vietnamese letters"
  for f in messages.py sdlc_config.py; do cmp -s "$p/scripts/$f" "$r2/.vibemaestro/gates/$f" && ok "[L] vi: $f is the plugin's, byte for byte" || bad "[L] vi: $f differs from the plugin's"; done
  for f in commit_discipline.py pr_sensitive.py; do cmp -s "$p/gates/$f" "$r2/.vibemaestro/gates/$f" && ok "[L] vi: $f is the plugin's, byte for byte" || bad "[L] vi: $f differs from the plugin's"; done
  r2=$(mk_repo vi2); put_cfg "$r2" '{"language": "vi"}'; inst "$p" "$r2"
  cmp -s "$p/scripts/messages.py" "$r2/.vibemaestro/gates/messages.py" && ok "[L] vi named in the config: messages.py is the plugin's" || bad "[L] vi named: messages.py differs"
  # an older copy (a vi table) in an en repo: kept as it is, said so, and deleting it gives a clean one
  r=$(mk_repo en2); put_cfg "$r" '{"language": "en"}'; mkdir -p "$r/.vibemaestro/gates"; cp "$p/scripts/messages.py" "$r/.vibemaestro/gates/messages.py"
  t1=$(shasum "$r/.vibemaestro/gates/messages.py" | cut -d' ' -f1)
  RC=0; OUT=$(cenv python3 "$p/scripts/install_gates.py" --root "$r" 2>&1) || RC=$?
  want 0 "[L] an older vi messages.py in an en repo: rc 0, kept" "kept (differs)   .vibemaestro/gates/messages.py"
  has "$OUT" "WARNING .vibemaestro/gates/messages.py is kept and still holds Vietnamese text" "[L] …with a WARNING naming the file"
  eq "$(shasum "$r/.vibemaestro/gates/messages.py" | cut -d' ' -f1)" "$t1" "[L] …and the file is untouched"
  rm "$r/.vibemaestro/gates/messages.py"
  RC=0; OUT=$(cenv python3 "$p/scripts/install_gates.py" --root "$r" 2>&1) || RC=$?
  want 0 "[L] …deleted and installed again: written" "wrote            .vibemaestro/gates/messages.py"
  eq "$(vc_tree "$r")" 0 "[L] …and no installed file holds a Vietnamese letter"
  hasnt "$OUT" "WARNING .vibemaestro/gates/messages.py" "[L] …and no warning is left"
  # a vi repo is not warned about its own copy
  r2=$(mk_repo vi3); inst "$p" "$r2"; RC=0; OUT=$(cenv python3 "$p/scripts/install_gates.py" --root "$r2" 2>&1) || RC=$?
  hasnt "$OUT" "still holds Vietnamese text" "[L] a vi repo installed twice: no such warning"
  printf '# a local note\n' >> "$r2/.vibemaestro/gates/messages.py"
  RC=0; OUT=$(cenv python3 "$p/scripts/install_gates.py" --root "$r2" 2>&1) || RC=$?
  has "$OUT" "kept (differs)   .vibemaestro/gates/messages.py" "[L] a vi repo with an older, differing copy: kept"
  hasnt "$OUT" "still holds Vietnamese text" "[L] …and no such warning (the vi copy is meant to hold the table)"
  # what the repo owns is never named in that warning, and an unreadable kept path does not stop the install
  r=$(mk_repo en4); put_cfg "$r" '{"language": "en"}'; printf '0123abcd  # gi\xc3\xa1 tr\xe1\xbb\x8b\n' > "$r/.pr-sensitive-allow"; t1=$(shasum "$r/.pr-sensitive-allow" | cut -d' ' -f1)
  RC=0; OUT=$(cenv python3 "$p/scripts/install_gates.py" --root "$r" 2>&1) || RC=$?
  want 0 "[L] en: an allowlist of the repo with Vietnamese text: rc 0, kept" "kept (differs)   .pr-sensitive-allow"
  hasnt "$OUT" "still holds Vietnamese text" "[L] en: …and no warning telling the repo to delete its allowlist"
  eq "$(shasum "$r/.pr-sensitive-allow" | cut -d' ' -f1)" "$t1" "[L] en: …the allowlist is untouched"
  r=$(mk_repo en5); put_cfg "$r" '{"language": "en"}'; mkdir -p "$r/.vibemaestro/gates"; ln -s "$TMP/no-such-target" "$r/.vibemaestro/gates/messages.py"
  RC=0; OUT=$(cenv python3 "$p/scripts/install_gates.py" --root "$r" 2>&1) || RC=$?
  want 0 "[L] en: a messages.py that is a dangling symlink: rc 0, kept, no traceback" "kept (differs)   .vibemaestro/gates/messages.py"
  hasnt "$OUT" "Traceback" "[L] en: …and the rest of the install ran"
  # a Vietnamese letter that is the repo's own token (it lands in a workflow, not in a copy of the plugin) is not the plugin's fault
  r=$(mk_repo en6); put_cfg "$r" "$(printf '{"language": "en", "tokens": {"commit_exception": "NGO\xe1\xba\xa0I L\xe1\xbb\x86:"}}')"
  RC=0; OUT=$(cenv python3 "$p/scripts/install_gates.py" --root "$r" 2>&1) || RC=$?
  want 0 "[L] en: the repo's own exemption token holds Vietnamese letters: the install still runs" "install-gates: wrote 16"
  eq "$(vc "$r/.vibemaestro/gates/messages.py" "$r/.vibemaestro/gates/sdlc_config.py")" 0 "[L] en: …and the plugin's copies are still English only"
  # the English text of the copies, not only the effective config under en (where the preset hides a wrong default): the vendored
  # loader read as a vi repo gives what the plugin's own loader gives for en
  r=$(mk_repo en7); put_cfg "$r" '{"language": "en"}'; inst "$p" "$r"; r2=$(mk_repo en8); put_cfg "$r2" '{"schema": 1}'
  cfg_of() { python3 -I -B -c '
import json, sys
sys.path.insert(0, sys.argv[1])
import sdlc_config
cfg = sdlc_config.load(sys.argv[2])[0]
cfg.pop("language", None)
print(json.dumps(cfg, sort_keys=True))' "$1" "$2"; }
  eq "$(cfg_of "$r/.vibemaestro/gates" "$r2")" "$(cfg_of "$p/scripts" "$r")" "[L] en: the vendored loader's defaults are the plugin's en text (read as vi, equal to the plugin's en)"
  # the rewrite counts columns in bytes: a non-ASCII text before the literal on the same line must not shift it
  python3 -I -B - "$p/scripts" <<'PY' && ok "[L] the rewrite puts the English text in place after non-ASCII text on the same line" || bad "[L] the rewrite shifted a literal after non-ASCII text"
import sys
sys.path.insert(0, sys.argv[1])
import install_gates as ig
src = ('TABLE = {"k\u2192": {"vi": "ạ ạ", "en": "one"}, "k2": {"en": "two", "vi": "ạ"}}\n').encode("utf-8")
out = ig.english_messages(src)
ns = {}
exec(compile(out.decode("utf-8"), "t", "exec"), ns)
assert ns["TABLE"]["k\u2192"] == {"vi": "one", "en": "one"} and ns["TABLE"]["k2"] == {"en": "two", "vi": "two"}, ns["TABLE"]
assert ig.viet_lines(out) == []
PY
  # a Vietnamese letter the rewrite cannot reach: the install stops before it writes anything
  d=$(mktemp -d "$TMP/lcopy.XXXXXX"); cp -r "$p/." "$d"; printf '# \xc4\x91 left in a comment\n' >> "$d/gates/commit_discipline.py"
  r=$(mk_repo en3); put_cfg "$r" '{"language": "en"}'; t1=$(tree_hash "$r")
  RC=0; OUT=$(cenv python3 "$d/scripts/install_gates.py" --root "$r" 2>&1) || RC=$?
  want 65 "[L] a Vietnamese letter left in a vendored file, language en: rc 65, the file and line named" "gates/commit_discipline.py"
  eq "$(tree_hash "$r")" "$t1" "[L] …and nothing was written"
  r=$(mk_repo vi4); t1=$(tree_hash "$r"); RC=0; OUT=$(cenv python3 "$d/scripts/install_gates.py" --root "$r" 2>&1) || RC=$?
  want 0 "[L] the same plugin copy in a vi repo: installs" "install-gates: wrote 16"
  rm -rf "$d"
  # every vendored file is held to it, the loader and the table after their rewrite too: a letter outside what the rewrite reaches
  local vf
  for vf in gates/gate_common.py scripts/sdlc_config.py scripts/messages.py; do
    d=$(mktemp -d "$TMP/lcopy.XXXXXX"); cp -r "$p/." "$d"; printf '\n# \xc4\x91 left in a comment\n' >> "$d/$vf"
    r=$(mk_repo en11); put_cfg "$r" '{"language": "en"}'; t1=$(tree_hash "$r")
    RC=0; OUT=$(cenv python3 "$d/scripts/install_gates.py" --root "$r" 2>&1) || RC=$?
    want 65 "[L] a Vietnamese letter left in $vf, language en: rc 65, the file named" "$(basename "$vf")"
    eq "$(tree_hash "$r")" "$t1" "[L] …and nothing was written"; rm -rf "$d"
  done
  # the plugin's own workflow template and allowlist header are held to the same rule (a rendered workflow is not: see en6)
  d=$(mktemp -d "$TMP/lcopy.XXXXXX"); cp -r "$p/." "$d"; printf '# t\xe1\xbb\x91i\n' >> "$d/gates/workflows/pr-title.yml"
  r=$(mk_repo en9); put_cfg "$r" '{"language": "en"}'; t1=$(tree_hash "$r")
  RC=0; OUT=$(cenv python3 "$d/scripts/install_gates.py" --root "$r" 2>&1) || RC=$?
  want 65 "[L] a Vietnamese letter in a workflow template, language en: rc 65, the template named" "pr-title.yml (the template)"
  eq "$(tree_hash "$r")" "$t1" "[L] …and nothing was written"; rm -rf "$d"
  # an allowlist the repo put under .vibemaestro/gates/ is still the repo's file: no warning for it
  r=$(mk_repo en10); put_cfg "$r" '{"language": "en", "sensitive": {"allowlist": ".vibemaestro/gates/allow.txt"}}'; mkdir -p "$r/.vibemaestro/gates"
  printf '0123abcd  # gi\xc3\xa1 tr\xe1\xbb\x8b\n' > "$r/.vibemaestro/gates/allow.txt"
  RC=0; OUT=$(cenv python3 "$p/scripts/install_gates.py" --root "$r" 2>&1) || RC=$?
  want 0 "[L] en: the repo's allowlist placed under .vibemaestro/gates/: kept" "kept (differs)   .vibemaestro/gates/allow.txt"
  hasnt "$OUT" "still holds Vietnamese text" "[L] en: …and no warning telling the repo to delete it"
}

# ig <args…> — the installer of the plugin under test, with the registry of $CC (unset: the test HOME's, which has none)
ig() { cenv env ${CC:+CLAUDE_CONFIG_DIR="$CC"} python3 "$PLUGIN/scripts/install_gates.py" "$@"; }
# sr <repo> <head> — the vendored signing-rules gate as the installed workflow runs it: from a checkout of the base (main), the repo
# alone (no plugin anywhere), the head only as data
sr() { G -C "$1" checkout -q main && (cd "$1" && env -i PATH="$PATH" HOME="$HOME" python3 .vibemaestro/gates/signing_rules.py main "$2" --list .vibemaestro/signing-rules.json); }

fam_signing() {
  local r OUT RC
  r=$(mk_repo sr1); RC=0; OUT=$(ig --root "$r" --only signing-rules 2>&1) || RC=$?
  want 0 "[S] --only signing-rules: rc 0" "install-gates: wrote 7"
  eq "$(printf '%s\n' "$OUT" | grep -E '^wrote ' | awk '{print $2}' | tr '\n' ' ')" \
    ".github/workflows/signing-rules.yml .vibemaestro/gates/gate_common.py .vibemaestro/gates/signing_rules.py .vibemaestro/gates/baton.py .vibemaestro/gates/sdlc_config.py .vibemaestro/gates/messages.py .vibemaestro/signing-rules.json " \
    "[S] …the workflow, the gate with everything it loads, and the list"
  eq "$(tr -d ' \n' < "$r/.vibemaestro/signing-rules.json")" \
    '{"baton_dirs":["batons","templates/baton-kinds",".vibemaestro/gates"],"lists":{},"files":[".github/workflows/signing-rules.yml",".vibemaestro/gates/signing_rules.py",".vibemaestro/gates/gate_common.py",".vibemaestro/gates/sdlc_config.py",".vibemaestro/gates/baton.py"]}' \
    "[S] …the starter list names the gate, every file it loads and its job"
  has "$(cat "$r/.github/workflows/signing-rules.yml")" 'python3 .vibemaestro/gates/signing_rules.py "origin/$BASE_REF" "$HEAD_SHA" --list .vibemaestro/signing-rules.json --touches "$RUNNER_TEMP/trust-touches.txt"' \
    "[S] …the workflow runs the vendored gate with the repo's list and writes the findings"
  mkdir -p "$r/batons"; printf '#!/bin/bash\n# Stops: none\necho hi\n' > "$r/batons/x.sh"
  G -C "$r" add -A; G -C "$r" commit -qm "chore: signing-rules and a baton"
  G -C "$r" checkout -qb stops; printf '#!/bin/bash\n# Stops: delete\necho hi\n' > "$r/batons/x.sh"; G -C "$r" commit -qam "feat: stops"
  RC=0; OUT=$(capped sr "$r" stops 2>&1) || RC=$?
  want 1 "[S] a PR that changes a baton's Stops: red from the vendored copy alone" "RED batons/x.sh: Stops 'none' → 'delete'"
  G -C "$r" checkout -q main; G -C "$r" checkout -qb readme; cm "$r" README.md "docs: readme"
  RC=0; OUT=$(sr "$r" readme 2>&1) || RC=$?
  want 0 "[S] a PR that changes only a README: green" "signing-rules: green (0 names, 0 baton files changed)"
  G -C "$r" checkout -q main; G -C "$r" checkout -qb gate; printf '# a line\n' >> "$r/.vibemaestro/gates/baton.py"; G -C "$r" commit -qam "chore: baton copy"
  RC=0; OUT=$(capped sr "$r" gate 2>&1) || RC=$?
  want 1 "[S] a PR that changes the vendored baton.py: red, judged by the base's list" "RED .vibemaestro/gates/baton.py: the gate or its list changed"
  G -C "$r" checkout -q main; G -C "$r" checkout -qb newcopy; printf 'import sys\nsys.exit(0)\n' > "$r/.vibemaestro/gates/keyword.py"; G -C "$r" add -A; G -C "$r" commit -qm "chore: a module"
  RC=0; OUT=$(capped sr "$r" newcopy 2>&1) || RC=$?
  want 1 "[S] a PR that adds a file beside the vendored gate (it would shadow a module the gate imports): red" "RED .vibemaestro/gates/keyword.py: a new file under a baton directory"
  G -C "$r" checkout -q main; G -C "$r" checkout -qb list; printf '{"baton_dirs": [], "lists": {}, "files": []}\n' > "$r/.vibemaestro/signing-rules.json"; G -C "$r" commit -qam "chore: list"
  RC=0; OUT=$(capped sr "$r" list 2>&1) || RC=$?
  want 1 "[S] a PR that empties the list: red, judged by the list at the base" "RED .vibemaestro/signing-rules.json: the gate or its list changed"
  G -C "$r" checkout -q main
  r=$(mk_repo sr2); ig --root "$r" >/dev/null 2>&1
  [ ! -e "$r/.github/workflows/signing-rules.yml" ] && [ ! -e "$r/.vibemaestro/gates/baton.py" ] && ok "[S] a run with no --only does not install signing-rules (opt-in)" || bad "[S] a default run installed signing-rules"
}

fam_update() {
  local r OUT RC OUTSIDE
  r=$(mk_repo up1); ig --root "$r" >/dev/null 2>&1
  printf '# an older copy\n' > "$r/.vibemaestro/gates/gate_common.py"; printf 'name: mine\non: push\n' > "$r/.github/workflows/pr-title.yml"
  printf '%s  # kept\n' "$(shaof x)" > "$r/.pr-sensitive-allow"
  RC=0; OUT=$(ig --root "$r" 2>&1) || RC=$?
  want 0 "[U] without --update a stale copy is only reported, as before" "kept (differs)   .vibemaestro/gates/gate_common.py"
  eq "$(cat "$r/.vibemaestro/gates/gate_common.py")" "# an older copy" "[U] …and stays as it was"
  RC=0; OUT=$(ig --root "$r" --update --dry-run 2>&1) || RC=$?
  want 0 "[U] --update --dry-run: the replacement is planned" "would replace    .vibemaestro/gates/gate_common.py"
  eq "$(cat "$r/.vibemaestro/gates/gate_common.py")" "# an older copy" "[U] …and nothing is written"
  RC=0; OUT=$(ig --root "$r" --update 2>&1) || RC=$?
  want 0 "[U] --update replaces the stale plugin copy, printing it" "replaced         .vibemaestro/gates/gate_common.py"
  cmp -s "$r/.vibemaestro/gates/gate_common.py" "$PLUGIN/gates/gate_common.py" && ok "[U] …which is now the plugin's own" || bad "[U] the copy was not replaced"
  has "$OUT" "kept (differs)   .github/workflows/pr-title.yml" "[U] …a changed workflow is still kept (differs)"
  eq "$(cat "$r/.github/workflows/pr-title.yml")" "name: mine
on: push" "[U] …byte for byte"
  has "$OUT" "kept (differs)   .pr-sensitive-allow" "[U] …and the allowlist with entries is kept"
  has "$OUT" "install-gates: kept 13, kept (differs) 2, replaced 1" "[U] …the counts"
  OUTSIDE=$(mktemp -d "$TMP/outside.XXXXXX"); printf 'outside\n' > "$OUTSIDE/f"
  rm "$r/.vibemaestro/gates/pr_title.py"; ln -s "$OUTSIDE/f" "$r/.vibemaestro/gates/pr_title.py"
  RC=0; OUT=$(ig --root "$r" --update 2>&1) || RC=$?
  want 0 "[U] a vendored copy that is a link to a file outside the repo: replaced" "replaced         .vibemaestro/gates/pr_title.py"
  [ ! -L "$r/.vibemaestro/gates/pr_title.py" ] && cmp -s "$r/.vibemaestro/gates/pr_title.py" "$PLUGIN/gates/pr_title.py" && ok "[U] …by a regular file, the plugin's" || bad "[U] the link was not replaced"
  eq "$(cat "$OUTSIDE/f")" "outside" "[U] …and the file outside is unchanged"
  r=$(mk_repo up2); mkdir -p "$r/src/lib" "$r/.vibemaestro"; printf '# the repo'"'"'s own module\n' > "$r/src/lib/messages.py"; ln -s ../src/lib "$r/.vibemaestro/gates"
  RC=0; OUT=$(capped ig --root "$r" --only pr-title --update 2>&1) || RC=$?
  want 64 "[U] --update where .vibemaestro/gates is a link to another directory of the repo: rc 64" ".vibemaestro/gates/gate_common.py: a parent directory is a link"
  eq "$(cat "$r/src/lib/messages.py")" "# the repo's own module" "[U] …the repo's file behind the link is unchanged"
  [ ! -e "$r/src/lib/gate_common.py" ] && [ ! -e "$r/.github" ] && ok "[U] …and nothing was written" || bad "[U] files were written through the link"
}

# cc <dir> <name>=<plugin source dir>… — a Claude config dir whose registry lists each plugin at version 1.0.0 in the vibemaestro cache;
# a source with no manifest gets one that depends on vibemaestro-sdlc (the fixture ships none: suites that read every manifest skip it)
cc() {
  local d=$1 kv p; shift; mkdir -p "$d/plugins"
  for kv in "$@"; do
    p="$d/plugins/cache/vibemaestro/${kv%%=*}/1.0.0"; mkdir -p "${p%/*}"; cp -R "${kv#*=}" "$p"
    [ -f "$p/.claude-plugin/plugin.json" ] || { mkdir -p "$p/.claude-plugin"; printf '{"name": "%s", "dependencies": ["vibemaestro-sdlc"]}\n' "${kv%%=*}" > "$p/.claude-plugin/plugin.json"; }
  done
  python3 -c '
import json, sys
d = sys.argv[1]
reg = {"version": 2, "plugins": {}}
for kv in sys.argv[2:]:
    n = kv.split("=", 1)[0]
    reg["plugins"][n + "@vibemaestro"] = [{"scope": "user", "installPath": "%s/plugins/cache/vibemaestro/%s/1.0.0" % (d, n),
                                           "version": "1.0.0", "lastUpdated": "2026-11-05T00:00:00.000Z"}]
json.dump(reg, open(d + "/plugins/installed_plugins.json", "w"))' "$d" "$@"
}
DEPFX="$HERE/fixtures/gates-dependent"

fam_dependent() {
  local r OUT RC CC t1 P2
  CC=$(mktemp -d "$TMP/cc.XXXXXX"); cc "$CC" demo-gates="$DEPFX"
  r=$(mk_repo dep1); RC=0; OUT=$(ig --root "$r" --only demo 2>&1) || RC=$?
  want 0 "[D] --only demo installs the dependent plugin's gate" "dependent plugin demo-gates 1.0.0: demo"
  has "$OUT" "wrote            .github/workflows/demo.yml" "[D] …its workflow"
  has "$OUT" "wrote            .vibemaestro/gates/demo_gate.py" "[D] …its gate copy"
  has "$OUT" "  demo: demo.key" "[D] …and the keys it declares"
  grep -qxF "    runs-on: \${{ vars.CI_GATE_RUNNER || vars.CI_RUNNER || 'ubuntu-latest' }}" "$r/.github/workflows/demo.yml" && ok "[D] …the runner markers rendered" || bad "[D] demo.yml runs-on not rendered"
  [ -x "$r/.vibemaestro/gates/demo_gate.py" ] && cmp -s "$r/.vibemaestro/gates/demo_gate.py" "$DEPFX/gates/demo_gate.py" && ok "[D] …the copy byte for byte, executable" || bad "[D] demo_gate.py is not the plugin's, executable"
  printf '# old\n' > "$r/.vibemaestro/gates/demo_gate.py"
  RC=0; OUT=$(ig --root "$r" --only demo --update 2>&1) || RC=$?
  want 0 "[D] --update replaces a stale copy of the dependent's gate" "replaced         .vibemaestro/gates/demo_gate.py"
  has "$OUT" "kept             .github/workflows/demo.yml" "[D] …and keeps its workflow"
  RC=0; OUT=$(ig --root "$r" --only nope 2>&1) || RC=$?
  want 64 "[D] an unknown gate names the dependent's among the known" "commit-discipline, pr-sensitive, pr-title, pr-body, pr-evidence, dead-branches, signing-rules, demo)"
  # refusals: each bad declaration is rc 65, before anything is written, whatever --only names
  local P d2
  decl() {  # decl <label> <needle> <install.json text> [more registry entries] — a copy of the fixture with that declaration
    P=$(mktemp -d "$TMP/decl.XXXXXX"); cp -R "$DEPFX/." "$P/"; printf '%s\n' "$3" > "$P/gates/install.json"   # an input, not a break
    CC=$(mktemp -d "$TMP/cc.XXXXXX"); cc "$CC" demo-gates="$P" "${@:4}"
    r=$(mk_repo decl); t1=$(tree_hash "$r")
    RC=0; OUT=$(capped ig --root "$r" --only pr-title 2>&1) || RC=$?
    want 65 "[D] $1: rc 65" "$2"; eq "$(tree_hash "$r")" "$t1" "[D] …nothing written"
  }
  F='{"from": "gates/demo_gate.py", "to": ".vibemaestro/gates/demo_gate.py"}'
  g1() { printf '{"format": 1, "gates": {"%s": {"keys": "k", "files": [%s]}}}' "$1" "$2"; }
  decl "from with .." "from '../README.md' is not a plain file inside the plugin" "$(g1 demo '{"from": "../README.md", "to": ".vibemaestro/gates/x.py"}')"
  decl "from absolute" "from '/etc/hostname' is not a plain file inside the plugin" "$(g1 demo '{"from": "/etc/hostname", "to": ".vibemaestro/gates/x.py"}')"
  decl "from missing" "from 'gates/none.py' is not a plain file inside the plugin" "$(g1 demo '{"from": "gates/none.py", "to": ".vibemaestro/gates/x.py"}')"
  P2=$(mktemp -d "$TMP/link.XXXXXX"); cp -R "$DEPFX/." "$P2/"; printf 'print(1)\n' > "$TMP/outside.py"; ln -s "$TMP/outside.py" "$P2/gates/link.py"; g1 demo '{"from": "gates/link.py", "to": ".vibemaestro/gates/x.py"}' > "$P2/gates/install.json"
  CC=$(mktemp -d "$TMP/cc.XXXXXX"); cc "$CC" demo-gates="$P2"; r=$(mk_repo decl); t1=$(tree_hash "$r")
  RC=0; OUT=$(capped ig --root "$r" --only pr-title 2>&1) || RC=$?
  want 65 "[D] from a link to a file outside the plugin: rc 65" "from 'gates/link.py' is not a plain file inside the plugin"; eq "$(tree_hash "$r")" "$t1" "[D] …nothing written"
  decl "to .github/actions/" "to '.github/actions/x.yml' is neither" "$(g1 demo '{"from": "gates/workflows/demo.yml", "to": ".github/actions/x.yml"}')"
  decl "to .vibemaestro/sdlc.json" "to '.vibemaestro/sdlc.json' is neither" "$(g1 demo '{"from": "gates/demo_gate.py", "to": ".vibemaestro/sdlc.json"}')"
  decl "to a subdirectory of .vibemaestro/gates/" "to '.vibemaestro/gates/sub/x.py' is neither" "$(g1 demo '{"from": "gates/demo_gate.py", "to": ".vibemaestro/gates/sub/x.py"}')"
  decl "to a workflow that is not .yml" "to '.github/workflows/x.sh' is neither" "$(g1 demo '{"from": "gates/demo_gate.py", "to": ".github/workflows/x.sh"}')"
  decl "a kit gate's name" "gate name pr-title is already a gate of this plugin" "$(g1 pr-title "$F")"
  decl "a kit copy's path, another case" "to .vibemaestro/gates/GATE_COMMON.py is already a path of this plugin" "$(g1 demo '{"from": "gates/demo_gate.py", "to": ".vibemaestro/gates/GATE_COMMON.py"}')"
  decl "a kit workflow's path" "to .github/workflows/signing-rules.yml is already a path of this plugin" "$(g1 demo '{"from": "gates/workflows/demo.yml", "to": ".github/workflows/signing-rules.yml"}')"
  d2=$(mktemp -d "$TMP/dep2.XXXXXX"); cp -R "$DEPFX/." "$d2/"; mkdir -p "$d2/.claude-plugin"; printf '{"name": "other-gates", "dependencies": [{"name": "vibemaestro-sdlc"}]}\n' > "$d2/.claude-plugin/plugin.json"
  decl "two plugins, one gate name" "gate name demo is already declared by plugin demo-gates" "$(g1 demo "$F")" other-gates="$d2"
  g1 other '{"from": "gates/demo_gate.py", "to": ".vibemaestro/gates/demo_gate.py"}' > "$d2/gates/install.json"
  decl "two plugins, one target" "to .vibemaestro/gates/demo_gate.py is already declared by plugin demo-gates (gate demo)" "$(g1 demo "$F")" other-gates="$d2"
  decl "not JSON" "not readable as JSON (JSONDecodeError)" '{"format": 1,'
  decl "an unknown key" 'an object with exactly the keys "format" and "gates"' '{"format": 1, "gates": {}, "run": "x"}'
  decl "format 2" "format must be 1" '{"format": 2, "gates": {}}'
  decl "a gate name with a slash" "gate name '../x' is not [a-z0-9][a-z0-9-]*" "$(g1 ../x "$F")"
  decl "a stdlib module name, which every vendored gate would import" "to '.vibemaestro/gates/json.py' would shadow the module json" "$(g1 demo '{"from": "gates/demo_gate.py", "to": ".vibemaestro/gates/json.py"}')"
  decl "a kit module name under another suffix" "to '.vibemaestro/gates/baton.pyc' would shadow the module baton" "$(g1 demo '{"from": "gates/demo_gate.py", "to": ".vibemaestro/gates/baton.pyc"}')"
  decl "sitecustomize" "to '.vibemaestro/gates/sitecustomize.py' would shadow the module sitecustomize" "$(g1 demo '{"from": "gates/demo_gate.py", "to": ".vibemaestro/gates/sitecustomize.py"}')"
  decl "a name that ends in a dot" "to '.vibemaestro/gates/x.py.' is neither" "$(g1 demo '{"from": "gates/demo_gate.py", "to": ".vibemaestro/gates/x.py."}')"
  decl "nested past the parser's depth" "not readable as JSON (RecursionError)" "$(python3 -c 'print("[" * 100000)')"
  # the repo's allowlist named with a `.` segment is still the repo's
  P=$(mktemp -d "$TMP/decl.XXXXXX"); cp -R "$DEPFX/." "$P/"; g1 demo '{"from": "gates/demo_gate.py", "to": ".vibemaestro/gates/allow.txt"}' > "$P/gates/install.json"
  CC=$(mktemp -d "$TMP/cc.XXXXXX"); cc "$CC" demo-gates="$P"; r=$(mk_repo decl); put_cfg "$r" '{"sensitive": {"allowlist": "./.vibemaestro/gates/allow.txt"}}'; t1=$(tree_hash "$r")
  RC=0; OUT=$(capped ig --root "$r" --only demo 2>&1) || RC=$?
  want 65 "[D] to the repo's allowlist, configured as ./.vibemaestro/gates/allow.txt: rc 65" "to .vibemaestro/gates/allow.txt is already a path of this plugin"; eq "$(tree_hash "$r")" "$t1" "[D] …nothing written"
  # a dependent's copy through a .vibemaestro/gates that is a link (to .git/hooks): refused, nothing written there
  CC=$(mktemp -d "$TMP/cc.XXXXXX"); cc "$CC" demo-gates="$DEPFX"; r=$(mk_repo decl); mkdir -p "$r/.vibemaestro"; ln -s ../.git/hooks "$r/.vibemaestro/gates"
  RC=0; OUT=$(capped ig --root "$r" --only demo 2>&1) || RC=$?
  want 64 "[D] .vibemaestro/gates is a link into .git/hooks: rc 64" "a parent directory is a link"
  [ ! -e "$r/.git/hooks/demo_gate.py" ] && [ ! -e "$r/.git/hooks/gate_common.py" ] && ok "[D] …nothing written into .git/hooks" || bad "[D] a file was written into .git/hooks"
  # the en check holds a dependent's copy too
  P=$(mktemp -d "$TMP/decl.XXXXXX"); cp -R "$DEPFX/." "$P/"; printf '# t\xe1\xbb\x91i\n' >> "$P/gates/demo_gate.py"   # the dependent's file, an input, not a break
  CC=$(mktemp -d "$TMP/cc.XXXXXX"); cc "$CC" demo-gates="$P"; r=$(mk_repo decl); put_cfg "$r" '{"language": "en"}'; t1=$(tree_hash "$r")
  RC=0; OUT=$(capped ig --root "$r" --only demo 2>&1) || RC=$?
  want 65 "[D] language en, a Vietnamese letter in the dependent's copy: rc 65" ".vibemaestro/gates/demo_gate.py: language is en"; eq "$(tree_hash "$r")" "$t1" "[D] …nothing written"
}

# today's output of a default run (main at 8287e13), with no dependent plugin and with one installed: a dependent's gate is opt-in
NOW_DEFAULT='wrote            .github/workflows/commit-discipline.yml
wrote            .github/workflows/pr-sensitive.yml
wrote            .github/workflows/pr-title.yml
wrote            .github/workflows/pr-body.yml
wrote            .github/workflows/pr-evidence.yml
wrote            .github/workflows/dead-branches.yml
wrote            .vibemaestro/gates/gate_common.py
wrote            .vibemaestro/gates/commit_discipline.py
wrote            .vibemaestro/gates/pr_sensitive.py
wrote            .vibemaestro/gates/pr_title.py
wrote            .vibemaestro/gates/pr_body.py
wrote            .vibemaestro/gates/pr_evidence.py
wrote            .vibemaestro/gates/dead_branches.sh
wrote            .vibemaestro/gates/sdlc_config.py
wrote            .vibemaestro/gates/messages.py
wrote            .pr-sensitive-allow
install-gates: wrote 16
runs-on in the workflows: ${{ vars.CI_GATE_RUNNER || vars.CI_RUNNER || '"'"'ubuntu-latest'"'"' }}  (set it in ci.runner_var / ci.runner_default of .vibemaestro/sdlc.json to keep it there)
@@RUNNER_CHECK@@
config keys the gates read:
  commit-discipline: commits.max_per_pr, commits.max_touches, commits.round_pattern, tokens.commit_exception
  pr-sensitive: sensitive.scan, sensitive.allowlist
  pr-title: pr.title.pattern, pr.title.max_len, pr.title.intent_form, branch.pattern, branch.intent_prefix
  pr-body: pr.body.max_chars, pr.body.summary_max_lines, pr.body.evidence_max_lines, tokens.summary_heading, tokens.evidence_heading
  pr-evidence: evidence.ui_paths, tokens.round_comment_prefix, commits.round_pattern
  dead-branches: dead_branches.max_merged_on_remote, branch.protected, branch.intent_prefix
a gate judges a PR by the scripts and the config of its BASE branch: merge this change first, then it applies to later PRs'

fam_nodep() {
  local r OUT RC CC
  r=$(mk_repo nd1); RC=0; OUT=$(ig --root "$r" 2>&1) || RC=$?
  want 0 "[N] no dependent plugin: a default run, rc 0"
  # the runner-variable line depends on the gh this machine has; every other line is today's, byte for byte
  local CHECK; CHECK=$(printf '%s\n' "$OUT" | grep -E '^(install-gates: runner variable check skipped|runner variable |WARNING runner variable )')
  eq "$(printf '%s\n' "$CHECK" | grep -c .)" 1 "[N] instrument: exactly one runner-variable line"
  eq "$OUT" "${NOW_DEFAULT/@@RUNNER_CHECK@@/"$CHECK"}" "[N] …the output is today's, byte for byte"
  CC=$(mktemp -d "$TMP/cc.XXXXXX"); cc "$CC" demo-gates="$DEPFX"
  r=$(mk_repo nd2); RC=0; OUT=$(ig --root "$r" 2>&1) || RC=$?
  eq "$OUT" "${NOW_DEFAULT/@@RUNNER_CHECK@@/"$CHECK"}" "[N] a dependent plugin with a gate installed: a default run's output is still today's"
  [ ! -e "$r/.github/workflows/demo.yml" ] && [ ! -e "$r/.vibemaestro/gates/demo_gate.py" ] && ok "[N] …and its gate is not installed" || bad "[N] a default run installed the dependent's gate"
}

FAMILIES="fam_each fam_invalid fam_base fam_install fam_english fam_signing fam_update fam_dependent fam_nodep"
for f in $FAMILIES; do "$f" "$PLUGIN"; done

echo; summary
