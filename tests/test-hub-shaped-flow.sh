#!/bin/bash
# =============================================================================
# the SDLC flow (intake, spec, plan, ship) at a hub-shaped repo, with only the plugin and the repo's own config
# =============================================================================
# Run: bash tests/test-hub-shaped-flow.sh        (last line `ok: hub-shaped flow` when every check passed)
#
# A scratch copy of tests/fixtures/hub-shaped (synthetic: an instruction directory with `applyTo` rules, both legacy hook markers,
# a map-style ledger, an allowlist) gets what a working repo has (a watched `systems/` file, the tester-exemption decision, git
# history, a bare `origin`) and is adopted through the door, `kb.py init --adopt --answers <the fixture's worked-example config>`.
# The fixture itself is never edited. Then ONE driver, `run_flow <name> <fault>`, runs the scripted parts of the flow in a fresh clone:
#   intake  kb.py new intent + an intent that carries a `## Kết quả brainstorm` section, intent-branch.sh create-intent (branch, issue, label)
#   spec    kb.py new spec, the spec written, kb.py check spec
#   plan    kb.py new plan, worker-branch from the intent tip, one task commit, integrate --to origin (one task = one commit)
#   ship    open-pr.sh --draft through the fake `gh` (closing link), then on the PR the fake `gh` recorded: the current-state diff gate,
#           commit_discipline.py, pr_title.py and pr_sensitive.py, each reading .vibemaestro/sdlc.json of the repo
# and records every step's rc, stopping at the first red one. The clean run is green at every step; five runs with ONE planted fault
# each are red at their own stage with the expected rc. To show the green/red comes from the repo config, the title, commit and diff gates
# are also run under the defaults (`--config-ref` at the commit before adoption, which has no config); the sensitive gate, whose keys in
# the worked example equal the defaults, and the diff gate's minimum reason are contrasted with a scratch edit of the config instead.
# What this does NOT run: the `brainstorm` skill (no script, it needs a model): *chưa kiểm*. Only an intent carrying its result section
# is shown to pass through intake and spec byte-for-byte. Gate transport through `gh api` (`--pr N`) is tests/test-gates-*.sh's job;
# here the gates get the PR as a payload built from what the fake `gh` recorded, and that payload is compared with `open-pr.sh --dry-run`.
# Clean environment (lib.sh clean_env): empty HOME, no VIBEMAESTRO_HUB, no hub tree, network shims first in PATH. Nothing waits on a timer.
# =============================================================================
set -uo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
# shellcheck source=fixtures/lib.sh
. "$HERE/fixtures/lib.sh"
# shellcheck source=fixtures/flow.sh
. "$HERE/fixtures/flow.sh"

now() { python3 -c 'import time; print("%.1f" % time.time())'; }
T0=$(now)
PLUGIN="$SRC_ROOT/plugins/vibemaestro-sdlc"
SHAPED="$HERE/fixtures/hub-shaped"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"
MAIN_STATE0=$(git --no-optional-locks -C "$SRC_ROOT" status --porcelain | sha1sum | cut -d' ' -f1)
SHAPED_H0=$(tree_hash_all "$SHAPED")

# The plugin runs from a COPY (like an installed cache); its hash is compared at the end.
PLG="$TMP/plugin"; cp -r "$PLUGIN" "$PLG"; find "$PLG" -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null
PLG_H0=$(tree_hash_all "$PLG")
KBPY="$PLG/scripts/kb.py"; IB="$PLG/scripts/intent-branch.sh"; OP="$PLG/scripts/open-pr.sh"; GATES="$PLG/gates"
# The gates are run straight from the plugin copy the way tests/test-gates*.sh run them (bytecode off): in a repo they run in CI from
# the vendored `.vibemaestro/gates/` copy, never from the plugin directory, so the "plugin copy unchanged" check below is about the
# cores and adapters, which must leave no `__pycache__` whatever the environment.
gpy() { PYTHONDONTWRITEBYTECODE=1 python3 "$@"; }

# Fake `gh`: flow.sh's mk_gh (issue numbered 42, PR numbered 7, labels file, closing-link reads), behind a recorder that keeps every argv as one JSON
# line, so the PR the gates read is rebuilt from what `open-pr.sh` actually handed to `gh`.
mk_gh "$TMP/ghreal"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<EOF
#!/usr/bin/env python3
import json, os, sys
with open(os.environ["GH_ARGV_LOG"], "a") as f:
    f.write(json.dumps(sys.argv[1:], ensure_ascii=False) + "\n")
os.execv("$TMP/ghreal/gh", ["gh"] + sys.argv[1:])
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export OPEN_PR_LINK_WAIT_S=0 GH_CLOSING_JSON='[42]'   # the closing-link poll reads once and never waits
export GH_ARGV_LOG="$TMP/gh-argv-main.jsonl" GH_LOG="$TMP/gh-main.log"   # calls made outside a flow run (each run sets its own)

SLUG=2026-10-15-flow; IBR="intent/$SLUG"
TITLE="feat(systems): example service limits"
RUNS="$TMP/runs"; mkdir -p "$RUNS"
at() { local d=$1; shift; (cd "$d" && "$@"); }
ci() { local d=$1 m=$2; shift 2; git_ -C "$d" add -- "$@" && git_ -C "$d" commit -qm "$m"; }

# ── the hub-shaped repo, adopted through the door ────────────────────────────────────────────────────────────
echo "== adopt: a hub-shaped scratch repo through kb.py init --adopt --answers <worked example> =="
B="$TMP/base"; cp -R "$SHAPED/." "$B/"
ANSWERS="$TMP/answers.json"; mv "$B/.vibemaestro/sdlc.json" "$ANSWERS"; rmdir "$B/.vibemaestro"
mkdir -p "$B/systems/example" "$B/kb/decisions"
printf 'replicas: 2\nmemory: 256Mi\n' > "$B/systems/example/limits.yaml"
printf -- '---\ndescription: "No end-to-end run for the example platform"\n---\n\n# No end-to-end run\n\nThe example platform has no e2e suite.\n' > "$B/kb/decisions/example-no-e2e.md"
git_ init -q -b main "$B"; git_ -C "$B" add -A; git_ -C "$B" commit -qm "chore: hub-shaped base"
PRE=$(git_ -C "$B" rev-parse HEAD)       # the commit before adoption: no config, so `--config-ref $PRE` reads the defaults
for f in .claude/settings.json .pr-sensitive-allow kb/current-state.md; do [ -f "$B/$f" ] && ok "instrument: the scratch copy has $f" || bad "instrument: $f missing from the copy"; done
ls "$B"/.github/instructions/*.instructions.md >/dev/null 2>&1 && ok "instrument: the scratch copy has an instruction directory" || bad "instrument: no instruction files"
grep -q 'instructions-for-path.py' "$B/.claude/settings.json" && grep -q 'instructions-for-command.py' "$B/.claude/settings.json" \
  && ok "instrument: both legacy hook markers are in .claude/settings.json" || bad "instrument: a hook marker is missing"
O=$(at "$B" python3 "$KBPY" new intent before-adopt 2>&1); eq "$?" 2 "before adoption: kb.py new intent gets past the markers to the kb/ check (rc 2, no refusal since 2.0.0)"
has "$O" "kb/intent/" "…and names the missing kb/intent/, not the markers"
H_BEFORE=$(cd "$B" && find . -path ./.git -prune -o -type f -print | LC_ALL=C sort | while IFS= read -r p; do printf '%s %s\n' "$p" "$(sha1sum < "$p" | cut -d' ' -f1)"; done)
O=$(at "$B" python3 "$KBPY" init --adopt --answers "$ANSWERS" 2>&1); eq "$?" 0 "kb.py init --adopt --answers <worked example>: rc 0"
python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])) == json.load(open(sys.argv[2])) else 1)' "$B/.vibemaestro/sdlc.json" "$ANSWERS" \
  && ok "the written config equals the worked example" || bad "the written config differs from the answers"
CHANGED=$(printf '%s\n' "$H_BEFORE" | while IFS=' ' read -r p h; do [ "$(sha1sum < "$B/$p" | cut -d' ' -f1)" = "$h" ] || echo "$p"; done)
empty "$CHANGED" "adoption changes no pre-existing file"
O=$(at "$B" python3 "$KBPY" config check 2>&1); eq "$?" 0 "kb.py config check on the adopted repo: rc 0"
O=$(at "$B" python3 "$KBPY" check current-state 2>&1); eq "$?" 0 "kb.py check current-state: the map ledger passes the repo's current_state profile"
# …and that profile is the repo's: a Status outside the config's enum, and the config's forbidden pattern, are each red
sed 's/| example-worker | in review |/| example-worker | paused |/' "$B/kb/current-state.md" > "$TMP/ledger-enum.md"
printf '\nMeasured 13/10 on the batch.\n' | cat "$B/kb/current-state.md" - > "$TMP/ledger-forbid.md"
O=$(at "$B" python3 "$KBPY" check current-state "$TMP/ledger-enum.md" 2>&1); eq "$?" 65 "…a Status outside the config's enum for section 2: rc 65"; has "$O" 'column Status holds `paused`' "…on the enum"
O=$(at "$B" python3 "$KBPY" check current-state "$TMP/ledger-forbid.md" 2>&1); eq "$?" 65 "…the config's forbid pattern measured_dm: rc 65"; has "$O" '[measured_dm]' "…on that pattern"
git_ -C "$B" add -A; git_ -C "$B" commit -qm "chore: adopt the plugin"
git_ init -q --bare -b main "$TMP/origin.git"; git_ -C "$B" push -q "$TMP/origin.git" main
eq "$(tree_hash_all "$SHAPED")" "$SHAPED_H0" "the shared fixture tests/fixtures/hub-shaped is unchanged (only the scratch copy is extended)"

# ── the flow driver ──────────────────────────────────────────────────────────────────────────────────────────
BRAINSTORM='## Kết quả brainstorm

- Direction chosen: one limits file under `systems/example/`, and the ledger row of the batch says it runs.
- Rejected: a directory per service (no second service yet).'
write_intent() {
  printf -- '---\ndescription: "Example service limits under systems/"\n---\n\n# Example service limits\n\n*Recorded in the requester'"'"'s words.*\n\nRaise the example service limits and keep the ledger current.\n\n%s\n' "$BRAINSTORM" > "$1"
}
write_spec() {  # write_spec <file> <fault>: the four sections; the `spec` fault drops one
  {
    printf -- '---\ndescription: "Example service limits under systems/"\n---\n\n# Example service limits\n\nIntent: kb/intent/%s.md\n\n' "$SLUG"
    printf '## Bối cảnh\n\nThe example service runs with the default limits.\n\n## Mục tiêu\n\nThe limits live in `systems/example/limits.yaml` and the ledger says the batch runs.\n\n'
    [ "$2" = spec ] || printf '## Ngoài phạm vi\n\nOther services.\n\n'
    printf '## Tiêu chí chấp nhận\n\n1. `cat systems/example/limits.yaml` shows the new limits.\n2. PR có mục `## Bằng chứng chạy` ghi output thật của lệnh trên.\n'
  } > "$1"
}
# step <label> <command...> — one step of the current STAGE: appends "<stage> <label> <rc>" to steps; a non-zero rc is also
# written as "RED <stage> <label> <rc>" and the driver stops there. The step's output goes to its own <stage>-<label>.log (so a
# message is read from the step that printed it) and to the run's log.
step() {
  local label=$1 rc=0; shift
  "$@" > "$RUN/$STAGE-$label.log" 2>&1 || rc=$?
  cat "$RUN/$STAGE-$label.log" >> "$RUN/log"
  echo "$STAGE $label $rc" >> "$RUN/steps"
  [ "$rc" -eq 0 ] && return 0
  echo "RED $STAGE $label $rc" >> "$RUN/steps"; return 1
}
# mk_payloads — the PR as the fake gh recorded it (argv of `pr create` + its stdin) into pr.json, and the three gate inputs
mk_payloads() {
  python3 - "$GH_ARGV_LOG" "$GH_STDIN" "$RUN" "$1" "$IBR" <<'PY'
import json, subprocess, sys
argv_log, body_file, run, wt, head = sys.argv[1:6]
calls = [json.loads(l) for l in open(argv_log, encoding="utf-8") if l.strip()]
a = [c for c in calls if c[:2] == ["pr", "create"]][-1]
opt = lambda k: a[a.index(k) + 1]
body = open(body_file, encoding="utf-8").read()
pr = {"title": opt("--title"), "head": opt("--head"), "base": opt("--base"), "body": body}
if "--draft" in a:
    pr["draft"] = True
json.dump(pr, open(run + "/pr.json", "w"), ensure_ascii=False)
git = lambda *x: subprocess.run(["git", "-C", wt] + list(x), capture_output=True, text=True, check=True).stdout
files = [f for f in git("diff", "--name-only", "--no-renames", "origin/%s...%s" % (pr["base"], pr["head"])).split("\n") if f]
json.dump({"title": pr["title"], "draft": pr.get("draft", False), "files": files, "head": pr["head"]},
          open(run + "/title.json", "w"), ensure_ascii=False)
commits = [c.split("\x00", 1) for c in git("log", "--format=%H%x00%B%x1e", "origin/%s..%s" % (pr["base"], pr["head"])).split("\x1e") if c.strip()]
json.dump({"number": 7, "body": body, "comments": [], "commits": [{"sha": s.strip(), "message": m} for s, m in commits]},
          open(run + "/sensitive.json", "w"), ensure_ascii=False)
PY
}
gate_title() { gpy "$GATES/pr_title.py" --cwd "$1" < "$RUN/title.json"; }

# A planted e-mail address, built at run time: a whole one in this file would be a value the repo's own scanners report.
SECRET="ops.lead$(printf '\100')acme-mail.test"

run_flow() {  # run_flow <name> <fault: none|intent|spec|commit|ledger|sensitive>
  local name=$1 fault=$2 R WT TW t
  RUN="$RUNS/$name"; mkdir -p "$RUN"; : > "$RUN/steps"; : > "$RUN/log"
  export GH_LOG="$RUN/gh.log" GH_STDIN="$RUN/pr-body.md" GH_ARGV_LOG="$RUN/gh-argv.jsonl" GH_LABELS_FILE="$RUN/labels.txt"
  : > "$GH_LOG"; : > "$GH_ARGV_LOG"; printf 'bug\nenhancement\n' > "$GH_LABELS_FILE"
  for t in $NET_TOOLS; do command -v "$t"; done > "$RUN/net-path"     # what this run resolves the network tools to
  cp -R "$TMP/origin.git" "$RUN/origin.git"; R="$RUN/repo"; git_ clone -q "$RUN/origin.git" "$R"
  WT="$R/.claude/worktrees/intake"; TW="$R/.claude/worktrees/t1"

  STAGE=intake
  step worktree git_ -C "$R" worktree add -q --detach "$WT" origin/main || return 0
  step new-intent at "$WT" python3 "$KBPY" new intent flow --date 2026-10-15 || return 0
  if [ "$fault" = intent ]; then rm -f "$WT/kb/intent/$SLUG.md"; else write_intent "$WT/kb/intent/$SLUG.md"; fi
  cp "$WT/kb/intent/$SLUG.md" "$RUN/intent-written.md" 2>/dev/null
  step create-intent at "$WT" bash "$IB" create-intent --slug "$SLUG" || return 0
  step commit ci "$WT" "docs(kb): intent flow" "kb/intent/$SLUG.md" || return 0
  git_ -C "$WT" show "HEAD:kb/intent/$SLUG.md" > "$RUN/intent-after-intake.md"

  STAGE=spec
  step new-spec at "$WT" python3 "$KBPY" new spec flow --date 2026-10-15 || return 0
  write_spec "$WT/kb/specs/$SLUG.md" "$fault"
  step check-spec at "$WT" python3 "$KBPY" check spec "$SLUG" || return 0
  step commit ci "$WT" "docs(kb): spec flow" "kb/specs/$SLUG.md" || return 0
  git_ -C "$WT" show "HEAD:kb/intent/$SLUG.md" > "$RUN/intent-after-spec.md"

  STAGE=plan
  step new-plan at "$WT" python3 "$KBPY" new plan flow --date 2026-10-15 || return 0
  printf -- '---\ndescription: "one task"\n---\n\n# Plan\n\n1. task/flow-1: the limits file and the ledger row. Check: `cat systems/example/limits.yaml`.\n' > "$WT/kb/plans/$SLUG.md"
  step commit ci "$WT" "docs(kb): plan flow" "kb/plans/$SLUG.md" || return 0
  step push git_ -C "$WT" push -q -u origin "$IBR" || return 0
  git_ -C "$R" rev-parse "origin/$IBR" > "$RUN/tip-at-cut"
  step worker-branch at "$R" bash "$IB" worker-branch --intent "$SLUG" --name task/flow-1 --no-checkout || return 0
  step task-worktree git_ -C "$R" worktree add -q "$TW" task/flow-1 || return 0
  printf 'replicas: 3\nmemory: 512Mi\n' > "$TW/systems/example/limits.yaml"
  if [ "$fault" = ledger ]; then
    step task-commit ci "$TW" "feat(systems): example service limits" systems/example/limits.yaml || return 0
  else
    sed 's/| example-batch | off | Nightly batch, switched off/| example-batch | running | Nightly batch with the example limits/' "$TW/kb/current-state.md" > "$TW/kb/current-state.md.new"
    mv "$TW/kb/current-state.md.new" "$TW/kb/current-state.md"
    step task-commit ci "$TW" "feat(systems): example service limits" systems/example/limits.yaml kb/current-state.md || return 0
  fi
  if [ "$fault" = commit ]; then
    printf 'cpu: 1\n' >> "$TW/systems/example/limits.yaml"
    step second-commit ci "$TW" "feat(systems): example cpu" systems/example/limits.yaml || return 0
  fi
  step integrate at "$TW" bash "$IB" integrate --intent "$SLUG" --to origin || return 0

  STAGE=ship
  step catch-up git_ -C "$WT" pull -q --ff-only origin "$IBR" || return 0
  printf 'The example service gets its limits in `systems/example/limits.yaml`; the ledger row of the batch is current.\n' > "$RUN/sum.md"
  [ "$fault" = sensitive ] && printf '\nQuestions go to %s.\n' "$SECRET" >> "$RUN/sum.md"
  printf '$ cat systems/example/limits.yaml\nreplicas: 3\nmemory: 512Mi\n' > "$RUN/ev.txt"
  step open-pr at "$WT" bash "$OP" --title "$TITLE" --summary "$RUN/sum.md" --evidence "$RUN/ev.txt" --draft || return 0
  step payload mk_payloads "$WT" || return 0
  step current-state at "$WT" python3 "$KBPY" check current-state --diff "origin/main...$IBR" --body-file "$GH_STDIN" || return 0
  step commit-discipline gpy "$GATES/commit_discipline.py" origin/main "$IBR" --body-file "$GH_STDIN" --cwd "$WT" || return 0
  step title gate_title "$WT" || return 0
  step sensitive gpy "$GATES/pr_sensitive.py" --payload "$RUN/sensitive.json" --cwd "$WT" || return 0
  echo done >> "$RUN/steps"
}

# The six runs are independent (each its own clone, bare origin and gh logs), so they run side by side.
# the five faulty runs are planted breaks: capped (fixtures/capped.sh: memory and time caps; the exit code lands in <run>.caprc); the clean run is not
for r in clean:none intent:intent spec:spec commit:commit ledger:ledger sensitive:sensitive; do
  if [ "${r#*:}" = none ]; then ( run_flow "${r%%:*}" "${r#*:}" ) &
  else ( capped run_flow "${r%%:*}" "${r#*:}"; echo $? > "$RUNS/${r%%:*}.caprc" ) &
  fi
done
wait

# ── what each run shows ──────────────────────────────────────────────────────────────────────────────────────
STAGES="intake spec plan ship"
red_at() {  # red_at <run> <stage> <step> <rc> — red exactly there, every earlier stage green, nothing ran after it
  local s="$RUNS/$1/steps" st reds
  cap_red "$(cat "$RUNS/$1.caprc" 2>/dev/null)" "fault '$1'" && return
  reds=$(grep '^RED ' "$s")
  eq "$reds" "RED $2 $3 $4" "fault '$1': red at $2 ($3) with rc $4"
  for st in $STAGES; do
    [ "$st" = "$2" ] && break
    grep -q "^$st [a-z-]* 0$" "$s" && ! grep -q "^$st [a-z-]* [1-9]" "$s" && ok "fault '$1': stage $st green before it" || bad "fault '$1': stage $st not green: $(grep "^$st " "$s" | tr '\n' ';')"
  done
  [ "$(tail -1 "$s")" = "RED $2 $3 $4" ] && ok "fault '$1': nothing ran after the red step" || bad "fault '$1': steps after the red one: $(tail -2 "$s" | tr '\n' ';')"
}

echo "== clean run: every stage green =="
C="$RUNS/clean"; CR="$C/repo"; CWT="$CR/.claude/worktrees/intake"
empty "$(grep '^RED ' "$C/steps")" "clean run: no red step$( [ -s "$C/log" ] && printf ' (log tail: %s)' "$(tail -3 "$C/log" | tr '\n' ' ')")"
eq "$(tail -1 "$C/steps")" done "clean run: the driver reached the end"
for st in $STAGES; do grep -q "^$st " "$C/steps" && ok "clean run: stage $st ran" || bad "clean run: stage $st did not run"; done
for s in create-intent check-spec worker-branch integrate open-pr current-state commit-discipline title sensitive; do
  grep -qE "^[a-z]+ $s 0$" "$C/steps" && ok "clean run: $s rc 0" || bad "clean run: $s not green"
done

echo "== intake: branch, issue and label through the intent core =="
eq "$(git_ -C "$CR" rev-parse --abbrev-ref HEAD)" main "the main tree stays on main"
eq "$(git_ -C "$CWT" rev-parse --abbrev-ref HEAD)" "$IBR" "the intake worktree is on $IBR"
eq "$(grep -c '^issue: 42$' "$C/intent-after-intake.md")" 1 "the tracking issue number is written into the intent"
grep -qF '["label", "create", "intent"' "$C/gh-argv.jsonl" && ok "the missing label 'intent' is created" || bad "no gh label create intent"
grep -qxF intent "$C/labels.txt" && ok "…and is present afterwards" || bad "label 'intent' absent after intake"
grep -F '["issue", "create"' "$C/gh-argv.jsonl" | grep -qF '"--label", "intent"' && ok "the issue is created with the label" || bad "gh issue create without --label intent"

echo "== brainstorm: the result section passes intake and spec unchanged (the skill itself: chưa kiểm, it needs a model) =="
sec() { python3 -c 'import sys; t=open(sys.argv[1],encoding="utf-8").read(); i=t.find("## Kết quả brainstorm"); print(t[i:] if i>=0 else "")' "$1"; }
nonempty "$(sec "$C/intent-written.md")" "instrument: the written intent carries the section"
eq "$(sec "$C/intent-after-intake.md")" "$(sec "$C/intent-written.md")" "the section after intake is byte-identical"
eq "$(sec "$C/intent-after-spec.md")" "$(sec "$C/intent-written.md")" "the section after spec is byte-identical"
eq "$(grep -v '^issue: 42$' "$C/intent-after-spec.md" | sha1sum)" "$(sha1sum < "$C/intent-written.md")" "the whole intent differs from what was written only by the issue line"
git_ -C "$C/origin.git" show "$IBR:kb/intent/$SLUG.md" > "$TMP/intent-at-origin.md"
eq "$(sec "$TMP/intent-at-origin.md")" "$(sec "$C/intent-written.md")" "…and so does the intent at the end of the flow, on origin"

echo "== plan: worker branch cut from the intent tip, one task commit, integrated back =="
nonempty "$(git_ -C "$C/origin.git" branch --list "$IBR")" "the bare origin has $IBR (the driver pushes it before the cut)"
eq "$(git_ -C "$CR" rev-parse task/flow-1^)" "$(cat "$C/tip-at-cut")" "the task commit's parent is the intent tip at the cut"
eq "$(git_ -C "$C/origin.git" rev-parse "$IBR")" "$(git_ -C "$CR" rev-parse task/flow-1)" "origin's $IBR is the task commit (fast-forward, no merge commit)"
eq "$(git_ -C "$C/origin.git" rev-list --count "main..$IBR")" 4 "the intent branch carries intent, spec, plan and task: 4 commits"

echo "== ship: open-pr.sh draft through the fake gh, and the PR the gates read =="
PRC=$(grep -F '["pr", "create"' "$C/gh-argv.jsonl")
has "$PRC" '"--draft"' "gh pr create is called with --draft"
has "$PRC" "\"--head\", \"$IBR\"" "…head is the intent branch"
has "$PRC" '"--base", "main"' "…base is main"
BODY=$(cat "$C/pr-body.md")
has "$BODY" 'Closes #42' "the body closes the tracking issue (number read from the intent; the keyword Closes is also the default)"
has "$(cat "$C/log")" 'closing link confirmed: PR #7 closes #42' "the closing link is checked and confirmed"
grep -qF '["pr", "view", "7", "--json", "closingIssuesReferences"' "$C/gh-argv.jsonl" && ok "…by reading the PR's closingIssuesReferences through gh" || bad "no gh pr view closingIssuesReferences call"
O=$(cd "$CWT" && GH_CLOSING_JSON='[41]' GH_STDIN="$TMP/ctl-body.md" bash "$OP" --title "$TITLE" --summary "$C/sum.md" --evidence "$C/ev.txt" --draft 2>&1); rc=$?
eq "$rc" 0 "control: GitHub links another issue (#41): open-pr.sh still rc 0 (the PR exists)"
has "$O" 'WARNING: could not confirm that PR #7 closes #42' "…and warns that the link is not confirmed"
# the worked example still sets pr.flow and pr.tester_exempt (deprecated): the body has no flow checklist and no tester note
hasnt "$BODY" "- [ ] Worker" "the body carries no flow checklist, although the config sets pr.flow (deprecated)"
hasnt "$BODY" 'example-no-e2e.md' "…and no tester note, although pr.tester_exempt and its decision file are there"
DEPR=$(at "$CWT" bash "$OP" --title "$TITLE" --summary "$C/sum.md" --evidence "$C/ev.txt" --draft --dry-run 2>&1 >/dev/null)
has "$DEPR" "pr.flow: deprecated since" "…and open-pr.sh warns that pr.flow is deprecated"
has "$DEPR" "pr.tester_exempt: deprecated since" "…and that pr.tester_exempt is"
DRY=$(at "$CWT" bash "$OP" --title "$TITLE" --summary "$C/sum.md" --evidence "$C/ev.txt" --draft --dry-run 2>/dev/null | tail -1)
printf '%s' "$DRY" > "$TMP/dry.json"
python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])) == json.load(open(sys.argv[2])) else 1)' "$C/pr.json" "$TMP/dry.json" \
  && ok "the PR rebuilt from the fake gh recording equals open-pr.sh --dry-run's payload (title, head, base, draft, body)" \
  || bad "hand-off drift: recorded $(head -c 200 "$C/pr.json") vs dry-run $(head -c 200 "$TMP/dry.json")"
python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))["body"] == open(sys.argv[2],encoding="utf-8").read() else 1)' "$C/sensitive.json" "$C/pr-body.md" \
  && ok "instrument: the sensitive payload's body is the body gh received" || bad "the sensitive payload body differs from gh's stdin"
eq "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["commits"]))' "$C/sensitive.json")" 4 "instrument: …and it carries the 4 commit messages of the PR"

echo "== ship: each gate reads the repo config (defaults through --config-ref at the commit before adoption) =="
tj() { printf '{"title": "%s", "draft": %s, "files": ["systems/example/limits.yaml", "kb/current-state.md"], "head": "%s"}' "$1" "$2" "$IBR"; }
O=$(tj "Update example limits" true | gpy "$GATES/pr_title.py" --cwd "$CWT" 2>&1); eq "$?" 1 "title gate: a title outside pr.title.pattern is red under the config"
O=$(tj "Update example limits" true | gpy "$GATES/pr_title.py" --cwd "$CWT" --config-ref "$PRE" 2>&1); eq "$?" 0 "…and green under the defaults (no pattern)"
O=$(tj "docs(kb): intent flow" false | gpy "$GATES/pr_title.py" --cwd "$CWT" 2>&1); eq "$?" 1 "title gate: an intent-form title on a ready PR with code is red (intent_form reject)"
O=$(tj "docs(kb): intent flow" false | gpy "$GATES/pr_title.py" --cwd "$CWT" --config-ref "$PRE" 2>&1); eq "$?" 0 "…and green under the defaults (intent_form allow)"
O=$(at "$CWT" bash "$OP" --title "Update example limits" --summary "$C/sum.md" --evidence "$C/ev.txt" --draft --dry-run 2>&1); eq "$?" 64 "open-pr.sh refuses a title outside the config pattern (rc 64)"
# commit discipline: a 16-commit range against max_per_pr 15, exempted only by the config's token
git_ -C "$CR" worktree add -q -b task/many "$CR/.claude/worktrees/many" origin/main
for i in $(seq 1 16); do echo "$i" > "$CR/.claude/worktrees/many/n$i.txt"; ci "$CR/.claude/worktrees/many" "chore: note $i" "n$i.txt"; done
printf 'Sixteen notes.\n' > "$TMP/b-none.md"
printf 'Sixteen notes.\nNGOAI LE COMMIT: each note is one revertible step\n' > "$TMP/b-cfg.md"
printf 'Sixteen notes.\nCOMMIT EXCEPTION: each note is one revertible step\n' > "$TMP/b-dflt.md"
cd_() { gpy "$GATES/commit_discipline.py" origin/main task/many --cwd "$CWT" "$@" >/dev/null 2>&1; echo $?; }
eq "$(cd_ --body-file "$TMP/b-none.md")" 1 "commit gate: 16 commits, no exemption line: red"
eq "$(cd_ --body-file "$TMP/b-cfg.md")" 0 "commit gate: the config's token (NGOAI LE COMMIT:) exempts it"
eq "$(cd_ --body-file "$TMP/b-dflt.md")" 1 "commit gate: the default token does not, under the config"
eq "$(cd_ --body-file "$TMP/b-dflt.md" --config-ref "$PRE")" 0 "…while under the defaults it does (the token is read from the config)"

echo "== fault runs: one planted fault per stage, red at that stage only =="
red_at intent intake create-intent 3
red_at spec spec check-spec 65
red_at commit plan integrate 8
red_at ledger ship open-pr 4
red_at sensitive ship sensitive 1
has "$(cat "$RUNS/intent/intake-create-intent.log")" "chưa có kb/intent/$SLUG.md" "intent fault: create-intent's refusal names the missing file"
has "$(cat "$RUNS/spec/spec-check-spec.log")" 'Ngoài phạm vi' "spec fault: check spec names the missing section"
has "$(cat "$RUNS/commit/plan-integrate.log")" 'task/flow-1 có 2 commit' "commit fault: integrate counts 2 commits on the task branch"
eq "$(git_ -C "$RUNS/commit/origin.git" rev-parse "$IBR")" "$(cat "$RUNS/commit/tip-at-cut")" "commit fault: the intent branch on origin did not move"
eq "$(grep -c '"pr", "create"' "$RUNS/ledger/gh-argv.jsonl")" 0 "ledger fault: no PR was opened"

echo "== ledger fault: the diff gate on the same tree, the exemption, and the defaults =="
L="$RUNS/ledger"; LWT="$L/repo/.claude/worktrees/intake"
dg() { (cd "$LWT" && python3 "$KBPY" check current-state --diff "origin/main...$IBR" "$@" >/dev/null 2>&1); echo $?; }
printf 'Limits only.\n' > "$TMP/l-none.md"
printf 'Limits only.\nNO STATE CHANGE: too short\n' > "$TMP/l-short.md"
printf 'Limits only.\nNO STATE CHANGE: the limits file is not a ledger fact\n' > "$TMP/l-ok.md"
eq "$(dg --body-file "$TMP/l-none.md")" 65 "diff gate: systems/ changed, no ledger change, no exemption: rc 65"
eq "$(dg --body-file "$TMP/l-short.md")" 65 "diff gate: an exemption with a reason under the config's 15 characters: rc 65"
eq "$(dg --body-file "$TMP/l-ok.md")" 0 "diff gate: the exemption line with a real reason: rc 0"
eq "$(dg --body-file "$TMP/l-none.md" --config-ref "$PRE")" 0 "diff gate under the defaults (nothing watched): rc 0, so the red comes from the config"
printf 'Limits only.\n\nNO STATE CHANGE: the limits file is not a ledger fact\n' > "$TMP/l-sum.md"
O=$(at "$LWT" bash "$OP" --title "$TITLE" --summary "$TMP/l-sum.md" --evidence "$L/ev.txt" --draft --dry-run 2>&1); eq "$?" 0 "open-pr.sh with the exemption line in the summary: rc 0"
# the minimum comes from current_state.exempt.min_reason_chars: a scratch edit to 5 lets the short reason through
python3 - "$LWT/.vibemaestro/sdlc.json" <<'EOF'
import json, sys
c = json.load(open(sys.argv[1], encoding="utf-8")); c["current_state"]["exempt"]["min_reason_chars"] = 5
json.dump(c, open(sys.argv[1], "w", encoding="utf-8"), ensure_ascii=False)
EOF
eq "$(dg --body-file "$TMP/l-short.md")" 0 "diff gate: the same short reason passes once the config's minimum is 5 (the 15 is read from the config)"
git_ -C "$LWT" checkout -q -- .vibemaestro/sdlc.json

echo "== sensitive fault: masked, and cleared by the allowlist the config names =="
S="$RUNS/sensitive"; SWT="$S/repo/.claude/worktrees/intake"
hasnt "$(cat "$S/log")" "$SECRET" "the gate's output never repeats the planted value"
has "$(cat "$S/pr-body.md")" "$SECRET" "instrument: the planted value is in the body gh received"
printf '%s  # a team mailbox, approved\n' "$(python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest())' "$SECRET")" >> "$SWT/$(gpy "$GATES/gate_common.py" get sensitive.allowlist --root "$SWT")"
O=$(gpy "$GATES/pr_sensitive.py" --payload "$S/sensitive.json" --cwd "$SWT" 2>&1); eq "$?" 0 "with its hash in the allowlist file the config names: rc 0"
hasnt "$O" "WARNING allowlist" "…and the fixture's allowlist raises no allowlist WARNING (every line is a bare digest the gate reads)"
# instrument: the same gate does warn about a line in the other format, so the assertion above can go red
printf 'sha256:%s  # prefixed\n' "$(printf '%s' example-allowed-one | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')" > "$S/allow-prefixed.txt"
O2=$(gpy "$GATES/pr_sensitive.py" --payload "$S/sensitive.json" --cwd "$SWT" --allow "$S/allow-prefixed.txt" 2>&1)
has "$O2" "WARNING allowlist: 1 line(s)" "instrument: a 'sha256:<hex>' line makes the gate warn (and is ignored)"
# The worked example's sensitive keys equal the defaults, so the contrast needs a config of its own: the scratch tree's config names
# another allowlist file. The hash now sits only in a file the config no longer names (red), then in the one it names (green).
python3 - "$SWT/.vibemaestro/sdlc.json" <<'EOF'
import json, sys
c = json.load(open(sys.argv[1], encoding="utf-8")); c["sensitive"]["allowlist"] = "kb/sensitive-allow.txt"
json.dump(c, open(sys.argv[1], "w", encoding="utf-8"), ensure_ascii=False)
EOF
O=$(gpy "$GATES/pr_sensitive.py" --payload "$S/sensitive.json" --cwd "$SWT" 2>&1); eq "$?" 1 "a config that names another allowlist file: the hash in .pr-sensitive-allow no longer clears it (rc 1)"
tail -1 "$SWT/.pr-sensitive-allow" > "$SWT/kb/sensitive-allow.txt"
O=$(gpy "$GATES/pr_sensitive.py" --payload "$S/sensitive.json" --cwd "$SWT" 2>&1); eq "$?" 0 "…and the same line in the file it names clears it (rc 0)"
# commit messages are a source of their own: the clean run's PR with the value planted in one commit message only
python3 - "$C/sensitive.json" "$TMP/commit-leak.json" "$SECRET" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8")); d["commits"][-1]["message"] += "\nAsk " + sys.argv[3] + "\n"
json.dump(d, open(sys.argv[2], "w", encoding="utf-8"), ensure_ascii=False)
EOF
O=$(gpy "$GATES/pr_sensitive.py" --payload "$C/sensitive.json" --cwd "$CWT" 2>&1); eq "$?" 0 "instrument: the clean run's PR passes the sensitive gate"
O=$(gpy "$GATES/pr_sensitive.py" --payload "$TMP/commit-leak.json" --cwd "$CWT" 2>&1); eq "$?" 1 "the same PR with the value in a commit message only: red (commit messages are scanned)"

echo "== nothing reaches outside: no hub, no network, only the scratch repos =="
[ -z "${VIBEMAESTRO_HUB:-}" ] && [ -z "${CLAUDE_PLUGIN_OPTION_HUB_PATH:-}" ] && ok "instrument: VIBEMAESTRO_HUB and the hub option are unset (clean_env)" || bad "a hub variable is set"
OUTSIDE=$(cat "$RUNS"/*/gh.log "$GH_LOG" | grep '^CWD=' | grep -v "^CWD=$RUNS/" || true)
empty "$OUTSIDE" "every fake-gh call, in the runs and after them, ran inside a scratch repo"
nonempty "$(cat "$RUNS"/*/gh.log | grep '^CWD=')" "instrument: the gh logs of the runs are not empty"
nonempty "$(grep '^CWD=' "$GH_LOG")" "instrument: …nor is the log of the calls after them"
for r in clean intent spec commit ledger sensitive; do
  eq "$(git_ -C "$RUNS/$r/repo" remote -v | awk '{print $1" "$2}' | sort -u)" "origin $RUNS/$r/origin.git" "run '$r': the only remote configured is its own bare origin"
done
empty "$(find "$HOME" -mindepth 1 2>/dev/null)" "HOME is still empty"
# The shims catch curl, wget, nc and ssh looked up through PATH; a call by absolute path is not seen (netguard.sh's limit).
NP=$(cat "$RUNS"/*/net-path)
eq "$(printf '%s\n' "$NP" | grep -c .)" 24 "each of the six runs resolved the four network tools"
empty "$(printf '%s\n' "$NP" | grep -v "^$NET_SHIM_DIR/")" "…all to the logging shims (so the network check below covers the flows)"
( net_guard_install "$TMP/ctl"; curl -s http://example.invalid/ >/dev/null 2>&1 ); [ -s "$TMP/ctl/net.log" ] \
  && ok "instrument: a shim logs its call" || bad "instrument: the network shim does not log"
eq "$(tree_hash_all "$PLG")" "$PLG_H0" "the plugin copy is unchanged (no __pycache__, no write)"
eq "$(git --no-optional-locks -C "$SRC_ROOT" status --porcelain | sha1sum | cut -d' ' -f1)" "$MAIN_STATE0" "the source tree's git status (tracked and untracked files, not ignored ones) is unchanged"

summary; rc=$?
echo "wall-clock: $(python3 -c 'import sys; print("%.1f" % (float(sys.argv[2]) - float(sys.argv[1])))' "$T0" "$(now)") s"
if [ "$rc" -eq 0 ]; then echo "ok: hub-shaped flow"; else echo "FAIL: hub-shaped flow"; exit 1; fi
