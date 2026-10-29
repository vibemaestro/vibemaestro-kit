#!/bin/bash
# =============================================================================
# The stage signal: the kit's flow tells the sandbox which SDLC stage an intent is in
# =============================================================================
# Run: bash tests/test-stage-signal.sh
#
# `scripts/stage-signal.sh <stage> [<stem>] [--subagents <n>]` runs `session-notify --intent <stem> --stage <stage> …` with a
# fixed phrase, and only when `session-notify` is on the PATH and its `--help` names `--stage` (a laptop session, or a pod on
# the old image, has nothing to do and sees nothing). intent-branch.sh create-intent emits `spec`, open-pr.sh (not --dry-run)
# emits `ship`; the skills run the helper for `code` and `review`.
# A fake `session-notify` on the PATH records its argv; SN_MODE picks what it is: new (supports --stage), old (the plain form
# only: any argument starting with `-` is refused, exit 64), refuse (supports --stage, then refuses the call with exit 64).
# Real scripts, real cores, throw-away repositories, a fake gh, no network.
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

PLUGIN="$SRC_ROOT/plugins/vibemaestro-sdlc"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"
GHB="$TMP/ghbin"; mk_gh "$GHB"
SNB="$TMP/snbin"; mkdir -p "$SNB"
cat > "$SNB/session-notify" <<'SN'
#!/bin/bash
{ printf 'ARGV:'; for a in "$@"; do printf ' [%s]' "$a"; done; echo; } >> "${SN_LOG:-/dev/null}"
usage='usage: session-notify [--intent <stem> --stage <spec|code|review|ship> [--subagents <n>]] "<text>"'
case "${SN_MODE:-new}" in
  hang)   [ "${1:-}" = --help ] && exec sleep 20; exit 0;;
  old)    case "${1:-}" in -*) echo "session-notify: a milestone must not start with '-'" >&2; exit 64;; esac; exit 0;;
  refuse) [ "${1:-}" = --help ] && { echo "$usage"; exit 0; }; echo "session-notify: refused (text)" >&2; exit 64;;
  *)      [ "${1:-}" = --help ] && { echo "$usage"; exit 0; }; exit 0;;
esac
SN
chmod +x "$SNB/session-notify"

PLX=""; PW=""; PT=""; F=""; LOG=""
# SP <mode> <args...> — the helper alone, PATH with the fake session-notify (mode "none": PATH without any), from $CWD_SP.
CWD_SP=""
SP() {
  local mode=$1; shift; local p; p=$([ "$mode" = none ] && bare_path nogh || echo "$SNB:$(bare_path nogh)")
  ( cd "${CWD_SP:-$TMP}" && cenv PATH="$p" SN_MODE="$mode" SN_LOG="$LOG" bash "$PLX/scripts/stage-signal.sh" "$@" )
}
# calls — the lines of the log that carry the structured form
calls() { grep -F -- '[--stage]' "$LOG" 2>/dev/null || true; }

fam_helper() {  # the helper alone: what it emits, and when it stays silent
  PLX=$1; local out rc; LOG=$(fresh)/sn.log; : > "$LOG"; CWD_SP=""
  out=$(SP new spec my-intent 2>&1); rc=$?
  eq "$rc" 0 "[S1] a supported session-notify: rc 0"; empty "$out" "[S1] …and no output"
  eq "$(calls)" "ARGV: [--intent] [my-intent] [--stage] [spec] [my-intent: spec stage started]" "[S1] spec: the stem, the stage and the fixed phrase, nothing else"
  : > "$LOG"; SP new code my-intent >/dev/null 2>&1
  eq "$(calls)" "ARGV: [--intent] [my-intent] [--stage] [code] [my-intent: coding started]" "[S1] code: its own fixed phrase"
  : > "$LOG"; SP new review my-intent --subagents 3 >/dev/null 2>&1
  eq "$(calls)" "ARGV: [--intent] [my-intent] [--stage] [review] [--subagents] [3] [my-intent: review round started]" "[S1] review --subagents 3: the count reaches session-notify"
  : > "$LOG"; SP new ship my-intent >/dev/null 2>&1
  eq "$(calls)" "ARGV: [--intent] [my-intent] [--stage] [ship] [my-intent: ship started]" "[S1] ship: its own fixed phrase"
  : > "$LOG"; out=$(SP none spec my-intent 2>&1); rc=$?
  eq "$rc" 0 "[S2] no session-notify on the PATH: rc 0"; empty "$out" "[S2] …and no output at all"; empty "$(cat "$LOG")" "[S2] …and nothing was called"
  : > "$LOG"; out=$(SP old spec my-intent 2>&1); rc=$?
  eq "$rc" 0 "[S3] an old session-notify (no --stage): rc 0"; empty "$out" "[S3] …and no output"; empty "$(calls)" "[S3] …and no structured call"
  empty "$(grep -vF -- '[--help]' "$LOG" || true)" "[S3] …and nothing but the --help probe was called (no plain milestone either)"
  : > "$LOG"; out=$(SP refuse spec my-intent 2>&1); rc=$?
  eq "$rc" 0 "[S4] a refusal (exit 64): the helper still exits 0"; eq "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" 1 "[S4] …and logs exactly one line to stderr"
  has "$out" "stage-signal" "[S4] …naming itself"; eq "$(calls | wc -l | tr -d ' ')" 1 "[S4] …after one try (no retry)"
  : > "$LOG"; local n=0 s; for s in "a b" "x/y" 'a;b' "https://x.io" "$(printf 'a%.0s' $(seq 1 81))" "" "-x" 'a$b' "dot.dot"; do
    SP new spec "$s" >/dev/null 2>&1; n=$((n+1)); done
  empty "$(calls)" "[S5] a stem with a space, a slash, a URL, a dot, a leading dash, empty or 81 characters: no call ($n tried)"
  : > "$LOG"; SP new spec "$(printf 'a%.0s' $(seq 1 80))" >/dev/null 2>&1
  eq "$(calls | wc -l | tr -d ' ')" 1 "[S5] control: a stem of exactly 80 characters is sent"
  : > "$LOG"; SP new nope my-intent >/dev/null 2>&1; SP new review my-intent --subagents 100 >/dev/null 2>&1; SP new review my-intent --subagents x >/dev/null 2>&1
  SP new review my-intent --subagents >/dev/null 2>&1; SP new review my-intent --bogus >/dev/null 2>&1
  empty "$(calls)" "[S5] an unknown stage, --subagents 100, x, none, or an unknown option: no call"
  : > "$LOG"; SP new review my-intent --subagents 99 >/dev/null 2>&1; SP new review my-intent --subagents 0 >/dev/null 2>&1
  eq "$(calls | wc -l | tr -d ' ')" 2 "[S5] control: --subagents 99 and 0 are sent"
  # a --help that never ends must not hold the caller (the probe has the same timeout as the call)
  mk_tools "$TMP/tools-timeout" timeout sleep; local t0=$SECONDS
  ( cd "$TMP" && cenv PATH="$SNB:$TMP/tools-timeout:$(bare_path nogh)" SN_MODE=hang SN_LOG="$LOG" bash "$PLX/scripts/stage-signal.sh" spec my-intent ) >/dev/null 2>&1
  [ $((SECONDS - t0)) -lt 15 ] && ok "[S5] a session-notify whose --help hangs: the helper returns within the probe's timeout" || bad "[S5] a session-notify whose --help hangs held the helper for $((SECONDS - t0)) s"
  : > "$LOG"; SP new spec >/dev/null 2>&1; empty "$(calls)" "[S6] no stem and not in a repository: no call"
  # the stem from the checked-out branch
  PW=$(mk_origin); git_ -C "$PW" worktree add -q -b intent/2026-03-04-from-branch "$PW/../ib" main; CWD_SP="$PW/../ib"
  : > "$LOG"; SP new code >/dev/null 2>&1
  eq "$(calls)" "ARGV: [--intent] [2026-03-04-from-branch] [--stage] [code] [2026-03-04-from-branch: coding started]" "[S6] no stem: it is read from the branch intent/<stem>"
  git_ -C "$PW" worktree add -q -b feat/other "$PW/../ot" main; CWD_SP="$PW/../ot"
  : > "$LOG"; SP new code >/dev/null 2>&1; empty "$(calls)" "[S6] on a branch that is not intent/*: no call"
  CWD_SP=""
}

# the two scripts run their own work first and signal as a side effect: the results are those of a session with no sandbox
IBS=""   # the slug used by fam_ib
ib() {  # ib <mode> <cwd> <args...> — intent-branch.sh with the fake session-notify (mode none: PATH without one)
  local mode=$1 d=$2; shift 2; local p; p=$([ "$mode" = none ] && echo "$GHB:$(bare_path nogh)" || echo "$SNB:$GHB:$(bare_path nogh)")
  ( cd "$d" && cenv PATH="$p" SN_MODE="$mode" SN_LOG="$LOG" bash "$PLX/scripts/intent-branch.sh" "$@" )
}
fam_ib() {
  PLX=$1; local W S out rc o2 o3 W2 W3; S=2026-03-05-sig; LOG=$(fresh)/sn.log; : > "$LOG"; OUTSIDE=$(fresh)
  W=$(mk_origin); printf -- '---\ndescription: "example"\n---\n\ntext\n' > "$W/kb/intent/$S.md"
  out=$(ib new "$OUTSIDE" --cwd "$W" create-intent --slug "$S" 2>&1); rc=$?
  eq "$rc" 0 "[S7] create-intent with a supported session-notify: rc 0"
  eq "$(calls)" "ARGV: [--intent] [$S] [--stage] [spec] [$S: spec stage started]" "[S7] …it emitted the spec stage, with the slug as the stem"
  local W5; W5=$(mk_origin); printf -- '---\ndescription: "example"\n---\n\ntext\n' > "$W5/kb/intent/$S.md"; : > "$LOG"
  ib new "$OUTSIDE" --cwd "$W5" create-intent --slug "intent/$S" >/dev/null 2>&1; rc=$?
  eq "$rc" 0 "[S7] create-intent --slug intent/<slug> (the prefix form the core accepts): rc 0"
  eq "$(calls)" "ARGV: [--intent] [$S] [--stage] [spec] [$S: spec stage started]" "[S7] …the stem is the slug without the prefix"
  W2=$(mk_origin); printf -- '---\ndescription: "example"\n---\n\ntext\n' > "$W2/kb/intent/$S.md"; : > "$LOG"
  o2=$(ib none "$OUTSIDE" --cwd "$W2" create-intent --slug "$S" 2>&1); rc=$?
  eq "$rc" 0 "[S8] create-intent with no session-notify: rc 0"; empty "$(cat "$LOG")" "[S8] …nothing called"
  eq "$o2" "$out" "[S8] …and its output is exactly the one of a session with the signal (nothing added, nothing removed)"
  W3=$(mk_origin); printf -- '---\ndescription: "example"\n---\n\ntext\n' > "$W3/kb/intent/$S.md"; : > "$LOG"
  o3=$(ib old "$OUTSIDE" --cwd "$W3" create-intent --slug "$S" 2>&1); rc=$?
  eq "$rc" 0 "[S9] create-intent with an old session-notify: rc 0"; empty "$(calls)" "[S9] …no structured call"; eq "$o3" "$out" "[S9] …and the same output"
  local W4; W4=$(mk_origin); printf -- '---\ndescription: "example"\n---\n\ntext\n' > "$W4/kb/intent/$S.md"; : > "$LOG"
  ib refuse "$OUTSIDE" --cwd "$W4" create-intent --slug "$S" >/dev/null 2>"$LOG.err"; rc=$?
  eq "$rc" 0 "[S10] create-intent with a session-notify that refuses: rc 0 (the branch was made)"
  has "$(cat "$LOG.err")" "stage-signal" "[S10] …one line on stderr says so"
  ref_exists "$W4" "intent/$S" && ok "[S10] …and the branch intent/$S exists" || bad "[S10] the branch is missing"
  : > "$LOG"; ib new "$OUTSIDE" --cwd "$W" create-intent --slug "$S" >/dev/null 2>&1; rc=$?
  ne "$rc" 0 "[S11] control: creating the same branch again fails"; empty "$(calls)" "[S11] …and a failed create-intent emits nothing"
  : > "$LOG"; ib new "$OUTSIDE" --cwd "$W" integrate --intent "$S" --to local >/dev/null 2>&1
  empty "$(calls)" "[S11] another subcommand (integrate) emits nothing"
}

op() {  # op <mode> <cwd> <args...> — open-pr.sh from <cwd>, fake gh and the fake session-notify first
  local mode=$1 d=$2; shift 2; local p; p=$([ "$mode" = none ] && echo "$GHB:$(bare_path nogh)" || echo "$SNB:$GHB:$(bare_path nogh)")
  ( cd "$d" && cenv PATH="$p" SN_MODE="$mode" SN_LOG="$LOG" GH_STDIN="$F/stdin.md" bash "$PLX/scripts/open-pr.sh" "$@" )
}
mk_intent_wt() {  # mk_intent_wt <main tree> <slug> — a linked worktree on branch intent/<slug> holding the record
  local w; git_ -C "$1" worktree add -q -b "intent/$2" "$1/../iw-$2" main; w=$(cd "$1/../iw-$2" && pwd -P)
  mkdir -p "$w/kb/intent"; printf -- '---\nissue: 17\ndescription: "example"\n---\n\ntext\n' > "$w/kb/intent/$2.md"; printf '%s' "$w"
}
fam_op() {
  PLX=$1; local IW S out rc o2; S=2026-03-06-ship; LOG=$(fresh)/sn.log; : > "$LOG"; mk_pr_repo; IW=$(mk_intent_wt "$PW" "$S")
  local A=(--title "feat: x" --summary "$F/sum.md" --evidence "$F/ev.txt")
  out=$(op new "$IW" "${A[@]}" 2>/dev/null); rc=$?
  eq "$rc" 0 "[S12] open-pr.sh on intent/<slug> with a supported session-notify: rc 0"; eq "$out" 7 "[S12] …the PR number is still the only stdout"
  eq "$(calls)" "ARGV: [--intent] [$S] [--stage] [ship] [$S: ship started]" "[S12] …it emitted the ship stage, with the slug as the stem"
  : > "$LOG"; out=$(op new "$IW" "${A[@]}" --dry-run 2>/dev/null); rc=$?
  eq "$rc" 0 "[S13] --dry-run: rc 0"; empty "$(cat "$LOG")" "[S13] …nothing is signalled (no ship step was started)"
  : > "$LOG"; op new "$PT" "${A[@]}" >/dev/null 2>&1
  empty "$(calls)" "[S13] on a branch that is not intent/*: no signal"
  : > "$LOG"; o2=$(op none "$IW" "${A[@]}" 2>&1); rc=$?
  eq "$rc" 0 "[S14] no session-notify: rc 0"; empty "$(cat "$LOG")" "[S14] …nothing called"
  : > "$LOG"; out=$(op none "$IW" "${A[@]}" 2>&1); eq "$out" "$o2" "[S14] …the output is stable"
  local o3; : > "$LOG"; o3=$(op old "$IW" "${A[@]}" 2>&1); rc=$?
  eq "$rc" 0 "[S15] an old session-notify: rc 0"; empty "$(calls)" "[S15] …no structured call"; eq "$o3" "$o2" "[S15] …the same output as with none"
  : > "$LOG"; out=$(op refuse "$IW" "${A[@]}" 2>"$LOG.err"); rc=$?
  eq "$rc" 0 "[S16] a refusal: rc 0"; eq "$out" 7 "[S16] …the PR is opened (its number printed)"; has "$(cat "$LOG.err")" "stage-signal" "[S16] …one line on stderr says so"
}

FAMILIES="fam_helper fam_ib fam_op"

echo "== the real scripts =="
PL0="$TMP/plugin-real"; mk_plugin_copy "$PL0"
[ -f "$PL0/scripts/stage-signal.sh" ] && ok "instrument: the plugin copy has the helper" || bad "instrument: the helper is missing from the copy"
for f in $FAMILIES; do echo "-- $f"; "$f" "$PL0"; done

echo "== planted breaks: each family must go red on a copy with one break =="
BRK() {  # BRK <label> <family> <needle> <script> <old> <new>
  local d="$TMP/break-$1"; mk_plugin_copy "$d"
  mutate "$d/scripts/$4" "$5" "$6" && expect_red "$1" "$2" "$d" "$3"
}
BRK probe-skipped fam_helper '[S3] …and no structured call' stage-signal.sh 'grep -qF -- --stage' 'true'
BRK refusal-fails fam_helper '[S4] a refusal (exit 64)' stage-signal.sh 'exit 0 # refused: the signal never fails the caller' 'exit 1'
BRK stem-unchecked fam_helper '[S5] a stem with a space' stage-signal.sh '*[!A-Za-z0-9_-]*) return 0 ;;' '*) ;;'
BRK stage-wrong fam_helper '[S1] code: its own fixed phrase' stage-signal.sh 'code) T="$STEM: coding started"' 'code) T="$STEM: code started"'
BRK ib-not-emitting fam_ib '[S7] …it emitted the spec stage' intent-branch.sh 'signal spec' ':'
BRK probe-unbounded fam_helper '[S5] a session-notify whose --help hangs' stage-signal.sh '"${TO[@]+"${TO[@]}"}" session-notify --help' 'session-notify --help'
BRK ib-emits-on-failure fam_ib '[S11] …and a failed create-intent emits nothing' intent-branch.sh '[ "$RC" -eq 0 ] && [ -n "$SLUG" ] && signal' '[ -n "$SLUG" ] && signal'
BRK op-dry-emits fam_op '[S13] …nothing is signalled' open-pr.sh 'if [ "$DRY" -eq 1 ]; then' 'bash "$HERE/stage-signal.sh" ship; if [ "$DRY" -eq 1 ]; then'
PLC="$TMP/break-none"; mk_plugin_copy "$PLC"
QN=0; okdef=$(declare -f ok); baddef=$(declare -f bad); sp=$PASS; sf=$FAIL
ok() { :; }; bad() { QN=$((QN+1)); }
for f in $FAMILIES; do "$f" "$PLC" >/dev/null 2>&1; done
eval "$okdef"; eval "$baddef"; PASS=$sp; FAIL=$sf
eq "$QN" 0 "control: an unbroken copy passes every family (no failed check)"

echo; summary
