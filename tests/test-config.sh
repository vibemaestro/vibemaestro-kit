#!/bin/bash
# =============================================================================
# The config contract (.vibemaestro/sdlc.json): loader, kb.py config check, hook engine, core knobs
# =============================================================================
# Run: bash tests/test-config.sh
#
# Families:
#   [D] defaults equal today's behaviour: the dry-run payload is identical with no file, with {"schema": 1} and with a file
#       that spells out every default
#   [V] every kind of invalid key is rc 65 from `kb.py config check` and names the key; `_` keys are ignored; the worked example
#       (tests/fixtures/hub-shaped) is valid
#   [E] exit codes: kb.py 65, the two cores and the adapters 64, with the key named; nothing is written on the way
#   [A] the rows of the activation table, for the hooks and for kb.py: only `hooks: off` silences; the legacy hook markers do not (2.0.0)
#   [H] a broken config: one warning per session, rc 0, the usual reminder still given
#   [R] rules.dirs, a same-name replacement, rules.disable, `status` other than active
#   [C] kb.py config check: the external-gate review line, duplicate paragraphs, other warnings
#   [T] the timing knobs of the closing-link poll (wait_s, deadline_s), in a family of their own because they take real seconds
#   [K] the knobs of the cores: intent prefix and protected branches, title pattern and length, draft, flow, tester exemption,
#       closing keyword and verification, tokens
#
# Every family runs on a copy of the real plugin; then each planted break (one mutation of the loader, the hook engine, kb.py,
# a core or an adapter) must turn the family it belongs to red, and an unbroken copy must stay green. Real git on throw-away
# repositories, a fake gh, the network shims of netguard.sh, no hub, no network. Prose of messages is never asserted, only exit
# codes, JSON fields, files, refs and the key names a message must carry.
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
SHAPED="$HERE/fixtures/hub-shaped"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"
GHB="$TMP/ghbin"; mk_gh "$GHB"
export GH_LOG="$TMP/gh.log"; : > "$GH_LOG"

PLX=""; PW=""; PT=""; F=""
# an invalid config: a known key with a wrong type (an unknown key is only a warning: rule config-compat)
BAD_CFG='{"pr": {"draft": 1}}'
HOUT=""; HRC=0

# ── helpers ──────────────────────────────────────────────────────────────────────────────────────
mk_repo() { local d; d=$(fresh); git_ init -q -b main "$d"; echo x > "$d/a.txt"; git_ -C "$d" add -A; git_ -C "$d" commit -qm c; printf '%s' "$d"; }
put_cfg() { mkdir -p "$1/.vibemaestro"; printf '%s' "$2" > "$1/.vibemaestro/sdlc.json"; }
put_markers() { mkdir -p "$1/.claude"; cp "$SHAPED/.claude/settings.json" "$1/.claude/settings.json"; }
# kbx <repo> <args...> — kb.py from inside <repo>, stdout and stderr both captured by the caller
kbx() { local d=$1; shift; ( cd "$d" && cenv python3 "$PLX/scripts/kb.py" "$@" ); }
# chk <root> — `kb.py config check --root` from a directory that is not the repo (the root is read from the option)
chk() { ( cd "$TMP" && cenv python3 "$PLX/scripts/kb.py" config check --root "$1" ); }
# hk <repo> <event> <tool> <payload> [index of the hook command] — one hook command of hooks.json, as Claude Code runs it
hk() {
  local c; c=$(hook_cmds "$PLX/hooks/hooks.json" "$2" "$3" | sed -n "${5:-1}p")
  HOUT=$(printf '%s' "$4" | cenv CLAUDE_PLUGIN_ROOT="$PLX" CLAUDE_PROJECT_DIR="$1" bash -c "$c" 2>/dev/null); HRC=$?
}
glog_reset() { : > "$GH_LOG"; rm -f "$GH_LOG.cnt"; }

# ── [D] defaults ─────────────────────────────────────────────────────────────────────────────────
fam_defaults() {
  PLX=$1; local J0 J1 J2 B R
  mk_pr_repo
  J0=$(prd 2>/dev/null)
  put_cfg "$PT" '{"schema": 1}'; J1=$(prd 2>/dev/null)
  python3 -c 'import json,sys; sys.path.insert(0, sys.argv[1]); import sdlc_config as C; print(json.dumps(C.defaults()))' "$PLX/scripts" > "$TMP/defaults.json"
  put_cfg "$PT" "$(cat "$TMP/defaults.json")"; J2=$(prd 2>/dev/null)
  nonempty "$J0" "[D1] the dry run with no config file prints a payload"
  eq "$J1" "$J0" "[D1] {\"schema\": 1} changes nothing: the payload is identical"
  eq "$J2" "$J0" "[D1] a file that spells out every default changes nothing: the payload is identical"
  B=$(pj "$J0" body)
  hasline "$B" "## $TOK_SUMMARY" "[D2] no config: the summary heading is today's literal"
  hasline "$B" "## $TOK_EVIDENCE" "[D2] …the evidence heading"
  eq "$(nline "$B" "## $TOK_FLOW")" 0 "[D2] …and no flow heading (the pr-evidence gate checks the evidence instead)"
  eq "$(pkeys "$J0")" "base body head title" "[D2] …and a draft key is absent (the --draft flag decides)"
  rm -f "$PT/.vibemaestro/sdlc.json"
  J0=$(prd --closes 7 2>/dev/null); eq "$(pj "$J0" body | head -1)" "Closes #7" "[D2] …--closes writes the word Closes"
  eq "$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import sdlc_config as C; print(C.defaults()["kb"]["spec_warn_bytes"])' "$PLX/scripts")" 40000 "[D3] the default spec size warning is 40000 bytes"
  eq "$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import sdlc_config as C; print(C.defaults()["ci"]["runner_default"])' "$PLX/scripts")" "ubuntu-latest" "[D3] the default runner label is still ubuntu-latest (the self-hosted-only form is opt-in)"
  eq "$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import sdlc_config as C; print(C.defaults()["commits"]["round_pattern"])' "$PLX/scripts")" '\bround\s*(\d+)\b' "[D3] the default round pattern is the English 'round N' (group 1 = the number)"
  eq "$(python3 -c 'import json,sys; sys.path.insert(0, sys.argv[1]); import sdlc_config as C; print(C.defaults()["current_state"]["limits"]["lines"], C.defaults()["current_state"]["limits"]["bytes"], C.defaults()["current_state"]["limits"]["line_chars"])' "$PLX/scripts")" "120 12000 200" "[D3] the effective current-state limits are today's (120, 12000, 200)"
  eq "$(cd "$TMP" && cenv python3 "$PLX/scripts/sdlc_config.py" get agents.review_model --root "$(fresh)") $(cd "$TMP" && cenv python3 "$PLX/scripts/sdlc_config.py" get agents.search_model --root "$(fresh)") $(cd "$TMP" && cenv python3 "$PLX/scripts/sdlc_config.py" get agents.worker_model --root "$(fresh)")" "opus haiku sonnet" "[D4] no config: sdlc_config.py get agents.* prints the review, search and worker defaults (opus, haiku, sonnet)"
  R=$(fresh); put_cfg "$R" '{"agents": {"review_model": "fable"}}'
  eq "$(cd "$TMP" && cenv python3 "$PLX/scripts/sdlc_config.py" get agents.review_model --root "$R") $(cd "$TMP" && cenv python3 "$PLX/scripts/sdlc_config.py" get agents.search_model --root "$R")" "fable haiku" "[D4] …a repo value wins for its key and the others keep their defaults"
  R=$(fresh); put_cfg "$R" '{"agents": {"review_model": "fable"}, "pr": {"title": {"pattern": "("}}}'
  ( cd "$TMP" && cenv python3 "$PLX/scripts/sdlc_config.py" get agents.review_model --root "$R" >/dev/null 2>&1 ); eq "$?" 64 "[D4] a broken key anywhere in the file: get agents.review_model exits 64"
  eq "$(cd "$TMP" && cenv python3 "$PLX/scripts/sdlc_config.py" get agents.review_model --default --root "$R" 2>/dev/null)" "opus" "[D4] …and get --default prints the plugin default, not the file's value (the skills' fallback)"
  ( cd "$TMP" && cenv python3 "$PLX/scripts/sdlc_config.py" get agents.nope --default >/dev/null 2>&1 ); eq "$?" 64 "[D4] get --default of a key the schema lacks exits 64"
  eq "$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import sdlc_config as C, current_state as S; print(len(C.HISTORY_IDS) == len(S.HISTORY) + 1, C.defaults()["current_state"]["limits"]["lines"] == S.MAX_LINES and C.defaults()["current_state"]["limits"]["bytes"] == S.MAX_BYTES and C.defaults()["current_state"]["limits"]["line_chars"] == S.MAX_LINE)' "$PLX/scripts")" "True True" "[D3] …and they are the constants of current_state.py; one id per history sign"
}

# ── [V] validation ───────────────────────────────────────────────────────────────────────────────
# vcase <label> <json> <key the message must name | ok | warn:<text> | quiet:<text>>
vcase() {
  local R out rc; R=$(fresh); put_cfg "$R" "$2"
  out=$(chk "$R" 2>&1); rc=$?
  case "$3" in
    ok) eq "$rc" 0 "[V] $1: valid, rc 0";;
    warn:*) eq "$rc" 0 "[V] $1: valid, rc 0"; has "$out" "${3#warn:}" "[V] $1: a warning names '${3#warn:}'";;
    quiet:*) eq "$rc" 0 "[V] $1: valid, rc 0"; hasnt "$out" "${3#quiet:}" "[V] $1: no '${3#quiet:}' warning";;
    *) eq "$rc" 65 "[V] $1: rc 65"; has "$out" "$3" "[V] …the message names '$3'";;
  esac
}
fam_validate() {
  PLX=$1; local R out rc
  vcase "unknown key: a warning, not a problem (rule config-compat)" '{"bogus": 1}' 'warn:bogus: unknown key (ignored'
  vcase "an unknown top-level section of a newer plugin" '{"future_section": {"a": 1}}' 'warn:future_section: unknown key'
  vcase "a known key with a wrong type still refuses" '{"pr": {"draft": 1}}' pr.draft
  vcase "a wrong type next to an unknown key: still refused" '{"bogus": 1, "pr": {"draft": 1}}' pr.draft
  vcase "schema above the plugin's" '{"schema": 2}' schema
  vcase "schema as a boolean" '{"schema": true}' schema
  vcase "bad regex" '{"pr": {"title": {"pattern": "("}}}' pr.title.pattern
  vcase "bad branch pattern" '{"branch": {"pattern": "[a"}}' branch.pattern
  vcase "bad enum" '{"hooks": "sometimes"}' hooks
  vcase "evidence.trusted_app: an App slug" '{"evidence": {"trusted_app": "acme-ai"}}' ok
  vcase "evidence.trusted_app: github-actions (a PR's own workflow posts as it)" '{"evidence": {"trusted_app": "github-actions"}}' evidence.trusted_app
  vcase "evidence.trusted_app: not a slug" '{"evidence": {"trusted_app": "Bad Slug"}}' evidence.trusted_app
  vcase "evidence.trusted_app: the bot login, not the slug" '{"evidence": {"trusted_app": "acme-ai[bot]"}}' evidence.trusted_app
  vcase "wrong type" '{"pr": {"title": {"max_len": "long"}}}' pr.title.max_len
  vcase "a round pattern that does not compile" '{"commits": {"round_pattern": "("}}' commits.round_pattern
  vcase "a round pattern without a capture group" '{"commits": {"round_pattern": "round"}}' commits.round_pattern
  vcase "a round pattern that is not a string" '{"commits": {"round_pattern": 3}}' commits.round_pattern
  vcase "a round pattern with a group (another language, lower case)" '{"commits": {"round_pattern": "\\bvong\\s*(\\d+)\\b"}}' ok
  # the subject is matched lower-cased, accent-free and with d for the d with stroke, so these can never match. A warning,
  # not rc 65: schema 1 accepted them, and CONTRACT.md counts a narrower set of accepted values as a breaking change
  vcase "a round pattern in upper case" '{"commits": {"round_pattern": "\\bRound\\s*(\\d+)"}}' "warn:WARNING commits.round_pattern can never match"
  vcase "a round pattern with accents" '{"commits": {"round_pattern": "\\bv\u00f2ng\\s*(\\d+)"}}' "warn:can never match"
  vcase "a round pattern with the d with stroke" '{"commits": {"round_pattern": "\\b\u0111ot\\s*(\\d+)"}}' "warn:can never match"
  vcase "a round pattern whose upper-case part is switched back to case-sensitive" '{"commits": {"round_pattern": "(?i)round(?-i:X)(\\d+)"}}' "warn:can never match"
  vcase "a round pattern in upper case under (?i)" '{"commits": {"round_pattern": "(?i)\\bRound\\s*(\\d+)"}}' "quiet:can never match"
  vcase "a round pattern with a scoped (?i:...)" '{"commits": {"round_pattern": "\\b(?i:Round)\\s*(\\d+)"}}' "quiet:can never match"
  vcase "a round pattern whose other branch can match" '{"commits": {"round_pattern": "\\b(?:Round|round)\\s*(\\d+)"}}' "quiet:can never match"
  vcase "a round pattern with a class that can match" '{"commits": {"round_pattern": "\\b[Rr]ound\\s*(\\d+)"}}' "quiet:can never match"
  vcase "the default round pattern" '{}' "quiet:can never match"
  vcase "a round pattern in an atomic group in upper case" '{"commits": {"round_pattern": "(?>Round)\\s*(\\d+)"}}' "warn:can never match"
  vcase "a round pattern behind an upper-case lookahead" '{"commits": {"round_pattern": "(?=R)round\\s*(\\d+)"}}' "warn:can never match"
  vcase "a round pattern behind a negative lookahead" '{"commits": {"round_pattern": "(?!R)round\\s*(\\d+)"}}' "quiet:can never match"
  vcase "a boolean where an integer is due" '{"commits": {"max_per_pr": true}}' commits.max_per_pr
  vcase "unknown nested key" '{"pr": {"titel": {}}}' 'warn:pr.titel: unknown key'
  vcase "unknown key in a list item object" '{"pr": {"flow": [{"text": "a", "dnoe": true}]}}' 'warn:pr.flow[0].dnoe: unknown key'
  vcase "not JSON" '{' '(file)'
  vcase "top level is a list" '[]' '(file)'
  vcase "rules.dirs with .." '{"rules": {"dirs": ["../x"]}}' 'rules.dirs[0]'
  vcase "rules.dirs absolute" '{"rules": {"dirs": ["/etc"]}}' 'rules.dirs[0]'
  vcase "public.private unset (the repo does not publish)" '{"public": {"private": null}}' ok
  vcase "public.private empty (it publishes all but kb/)" '{"public": {"private": []}}' ok
  vcase "public.private with globs" '{"public": {"private": [".vibemaestro/sdlc.json", "ops/**"]}}' ok
  vcase "public.private as a string" '{"public": {"private": ".vibemaestro/sdlc.json"}}' public.private
  vcase "public.private with .." '{"public": {"private": ["../x"]}}' 'public.private[0]'
  vcase "an unknown key under public" '{"public": {"privat": []}}' 'warn:public.privat: unknown key'
  vcase "closing keyword that GitHub does not honour" '{"pr": {"closing": {"keyword": "Relates"}}}' pr.closing.keyword
  vcase "forbid id that does not exist" '{"current_state": {"forbid": ["date_iso", "nope"]}}' 'current_state.forbid[1]'
  vcase "gate that is not a mode" '{"current_state": {"gate": "sometimes"}}' current_state.gate
  vcase "external gate outside the repo" '{"current_state": {"gate": "external:../x.py"}}' current_state.gate
  vcase "tester_exempt without decision" '{"pr": {"tester_exempt": {}}}' pr.tester_exempt.decision
  vcase "empty flow" '{"pr": {"flow": []}}' pr.flow
  vcase "empty token" '{"tokens": {"fixes_line": ""}}' tokens.fixes_line
  vcase "token list with a non-string" '{"tokens": {"no_state_change": [1]}}' 'tokens.no_state_change[0]'
  vcase "sensitive scan with an unknown scope" '{"sensitive": {"scan": ["pr_body", "emails"]}}' 'sensitive.scan[1]'
  vcase "runner variable that is not an identifier" '{"ci": {"runner_var": "1a"}}' ci.runner_var
  vcase "ci.runner_default: a runner label" '{"ci": {"runner_default": "team-runners"}}' 'quiet:is not a runner label'
  vcase "ci.runner_default: the self-hosted-only form is a valid value, with no warning" '{"ci": {"runner_default": "self-hosted only"}}' 'quiet:is not a runner label'
  vcase "ci.runner_default: neither a label nor the form (a near miss) warns, install-gates refuses it" '{"ci": {"runner_default": "self hosted"}}' 'warn:ci.runner_default: is not a runner label'
  vcase "ci.runner_default: the warning names the form" '{"ci": {"runner_default": "self hosted"}}' 'warn:"self-hosted only"'
  vcase "ci.runner_default: empty" '{"ci": {"runner_default": ""}}' ci.runner_default
  vcase "ci.runner_default: null (an older reader refuses it too)" '{"ci": {"runner_default": null}}' ci.runner_default
  vcase "rebase identity with only a name" '{"rebase": {"identity": {"name": "ci"}}}' rebase.identity.email
  vcase "intent prefix with a space" '{"branch": {"intent_prefix": "a b/"}}' branch.intent_prefix
  vcase "intent prefix with an empty segment" '{"branch": {"intent_prefix": "intent//"}}' branch.intent_prefix
  vcase "intent prefix that starts with a slash" '{"branch": {"intent_prefix": "/intent/"}}' branch.intent_prefix
  vcase "a NUL character in a rule directory" '{"rules": {"dirs": ["a\u0000b"]}}' 'rules.dirs[0]'
  vcase "NaN as a wait" '{"pr": {"closing": {"wait_s": NaN}}}' pr.closing.wait_s
  vcase "an infinite deadline" '{"pr": {"closing": {"deadline_s": 1e999}}}' pr.closing.deadline_s
  vcase "a lone surrogate in a token" '{"tokens": {"fixes_line": "\ud800"}}' tokens.fixes_line
  vcase "intent prefix without a trailing slash" '{"branch": {"intent_prefix": "intent"}}' branch.intent_prefix
  vcase "negative wait" '{"pr": {"closing": {"wait_s": -1}}}' pr.closing.wait_s
  vcase "keys that start with an underscore are ignored at every level" '{"_a": 1, "pr": {"_b": 2, "title": {"_c": 3, "max_len": 50}}, "tokens": {"_d": 4}}' 'quiet:unknown key'
  vcase "an empty object" '{}' ok
  vcase "kb.spec_warn_bytes zero" '{"kb": {"spec_warn_bytes": 0}}' kb.spec_warn_bytes
  vcase "kb.spec_warn_bytes as a string" '{"kb": {"spec_warn_bytes": "40k"}}' kb.spec_warn_bytes
  vcase "an unknown key under kb" '{"kb": {"spec_warn_kb": 40}}' 'warn:kb.spec_warn_kb: unknown key'
  vcase "kb.spec_warn_bytes set" '{"kb": {"spec_warn_bytes": 25000}}' ok
  vcase "kb.spec_warn_bytes null (guard off)" '{"kb": {"spec_warn_bytes": null}}' ok
  vcase "the keys of the spec's worked example" "$(cat "$SHAPED/.vibemaestro/sdlc.json")" ok
  vcase "a nested intent prefix" '{"branch": {"intent_prefix": "team/feat/"}}' ok
  vcase "a valid external gate" '{"current_state": {"gate": "external:scripts/check.py"}}' ok
  vcase "closing keyword in lower case" '{"pr": {"closing": {"keyword": "fixes"}}}' ok
  vcase "pr.flow as strings and objects" '{"pr": {"flow": ["a", {"text": "b", "done": true}]}}' ok
  vcase "agents: one alias per job" '{"agents": {"review_model": "opus", "search_model": "haiku", "worker_model": "sonnet"}}' ok
  vcase "agents: the strongest tier for a high-risk repo" '{"agents": {"review_model": "fable"}}' ok
  vcase "agents: an alias the Agent tool does not accept" '{"agents": {"review_model": "gpt"}}' agents.review_model
  vcase "agents: a dated model id instead of an alias" '{"agents": {"search_model": "claude-haiku-4-5"}}' agents.search_model
  vcase "agents: the full id of the review default" '{"agents": {"review_model": "claude-opus-5-5"}}' agents.review_model
  vcase "agents: an alias in another case" '{"agents": {"worker_model": "Sonnet"}}' agents.worker_model
  vcase "agents: a number where an alias is due" '{"agents": {"worker_model": 1}}' agents.worker_model
  vcase "agents: null where an alias is due" '{"agents": {"review_model": null}}' agents.review_model
  vcase "agents: a list instead of the object" '{"agents": ["opus"]}' agents
  vcase "agents: an unknown key" '{"agents": {"plan_model": "opus"}}' 'warn:agents.plan_model: unknown key'
  R=$(fresh); put_cfg "$R" '{"pr": {"draft": 1, "title": {"pattern": "("}}}'
  out=$(chk "$R" 2>&1); has "$out" pr.draft "[V] two problems: the first is listed"; has "$out" pr.title.pattern "[V] …and the second"
  R=$(fresh); mkdir -p "$R/.vibemaestro"; python3 -c 'import sys; sys.stdout.write("[" * 100000)' > "$R/.vibemaestro/sdlc.json"
  out=$(chk "$R" 2>&1); rc=$?; eq "$rc" 65 "[V] a deeply nested file: rc 65, not a traceback"; has "$out" "(file)" "[V] …and the problem is the file"
  R=$(fresh); mkdir -p "$R/.vibemaestro/sdlc.json"; out=$(chk "$R" 2>&1); rc=$?
  eq "$rc" 65 "[V] a directory where the config file should be: rc 65 (present and unreadable, not absent)"
  R=$(fresh); chk "$R" >/dev/null 2>&1; eq "$?" 0 "[V] no config file: rc 0 (defaults)"
  chk "$R/not-there" >/dev/null 2>&1; eq "$?" 64 "[V] --root that is not a directory: rc 64"
}

# ── [E] exit codes of the consumers ──────────────────────────────────────────────────────────────
fam_exit() {
  PLX=$1; local R out rc before
  mk_pr_repo; put_cfg "$PT" "$BAD_CFG"
  out=$(prd 2>&1 >/dev/null); rc=$?
  eq "$rc" 64 "[E] open_pr.py with an invalid config: rc 64 (a core)"; has "$out" pr.draft "[E] …it names the key"
  prg -- >/dev/null 2>&1; eq "$?" 64 "[E] …also on the gh path, before anything is posted"
  out=$(cd "$PT" && cenv PATH="$GHB:$PATH" bash "$PLX/scripts/open-pr.sh" --title t --summary "$F/sum.md" --evidence "$F/ev.txt" --dry-run 2>&1 >/dev/null); rc=$?
  eq "$rc" 64 "[E] open-pr.sh with an invalid config: rc 64"
  rm -f "$PT/.vibemaestro/sdlc.json"; prd >/dev/null 2>&1; eq "$?" 0 "[E] control: the same call with no config: rc 0"
  R=$(mk_origin); put_cfg "$R" "$BAD_CFG"; printf -- '---\ndescription: "x"\n---\n' > "$R/kb/intent/e1.md"
  out=$(core "$R" create-intent --slug e1 2>&1); rc=$?
  eq "$rc" 64 "[E] intent_branch.py with an invalid config: rc 64"; has "$out" pr.draft "[E] …it names the key"
  ref_exists "$R" intent/e1 && bad "[E] …no branch was made" || ok "[E] …no branch was made"
  out=$(cd "$TMP" && cenv bash "$PLX/scripts/intent-branch.sh" --cwd "$R" create-intent --slug e1 --no-issue 2>&1); rc=$?
  eq "$rc" 64 "[E] intent-branch.sh with an invalid config: rc 64"
  rm -f "$R/.vibemaestro/sdlc.json"; core "$R" create-intent --slug e1 >/dev/null 2>&1; eq "$?" 0 "[E] control: with no config the branch is made: rc 0"
  R=$(mk_repo); put_cfg "$R" "$BAD_CFG"; before=$(find "$R" -path "$R/.git" -prune -o -type f -print | sort | tr '\n' ' ')
  out=$(kbx "$R" init 2>&1); rc=$?
  eq "$rc" 65 "[E] kb.py init with an invalid config: rc 65 (kb.py and the gates fail closed)"; has "$out" pr.draft "[E] …it names the key"
  eq "$(find "$R" -path "$R/.git" -prune -o -type f -print | sort | tr '\n' ' ')" "$before" "[E] …and nothing was written"
  kbx "$R" check current-state >/dev/null 2>&1; eq "$?" 65 "[E] kb.py check current-state with an invalid config: rc 65"
  kbx "$R" new intent x >/dev/null 2>&1; eq "$?" 65 "[E] kb.py new with an invalid config: rc 65"
  put_cfg "$R" '{"schema": 1}'; kbx "$R" init >/dev/null 2>&1; eq "$?" 0 "[E] control: a valid config: kb.py init works"
  put_cfg "$R" '{"_note": "x"}'; kbx "$R" check current-state >/dev/null 2>&1; eq "$?" 0 "[E] control: an underscore key does not make the config invalid"
}

# ── [A] activation table ─────────────────────────────────────────────────────────────────────────
# arow <label> <config json | -> <markers 1|0> <hook active 1|0> <kb.py rc>
arow() {
  local R S; R=$(mk_repo); mkdir -p "$R/kb"; S=$(sid)
  [ "$2" != - ] && put_cfg "$R" "$2"; [ "$3" = 1 ] && put_markers "$R"
  hk "$R" PreToolUse Edit "$(p_edit "$S" "$R/kb/current-state.md")"
  eq "$HRC" 0 "[A] $1: the hook exits 0"
  if [ "$4" = 1 ]; then has "$(ctx "$HOUT")" current-state-shape "[A] $1: the reminder hook is active (the current-state rule is named)"
  else empty "$HOUT" "[A] $1: the reminder hook is silent"; fi
  hk "$R" SessionStart "" "$(p_start "$S")" 1
  if [ "$4" = 1 ]; then nonempty "$HOUT" "[A] $1: SessionStart delivers the process core"; else empty "$HOUT" "[A] $1: SessionStart is silent"; fi
  kbx "$R" init >/dev/null 2>&1; eq "$?" "$5" "[A] $1: kb.py init exits $5"
}
fam_activation() {
  PLX=$1
  arow "no config, no markers" - 0 1 0
  arow "no config, markers (not silent since 2.0.0)" - 1 1 0
  arow "config and markers" '{"schema": 1}' 1 1 0
  arow "config, no markers" '{"schema": 1}' 0 1 0
  arow "hooks off" '{"hooks": "off"}' 0 0 0
  arow "hooks off and markers" '{"hooks": "off"}' 1 0 0
  arow "hooks auto spelled out, no markers" '{"hooks": "auto"}' 0 1 0
}

# ── [H] a broken config and the hooks ────────────────────────────────────────────────────────────
fam_hooks_warn() {
  PLX=$1; local R S first
  R=$(mk_repo); put_cfg "$R" "$BAD_CFG"; S=$(sid)
  hk "$R" PreToolUse Bash "$(p_bash "$S" "echo hi")"
  eq "$HRC" 0 "[H] a broken config: the hook still exits 0"
  has "$(ctx "$HOUT")" sdlc.json "[H] …the first call of the session warns (the file is named)"
  has "$(ctx "$HOUT")" pr.draft "[H] …and the key is named"
  nonempty "$(sysm "$HOUT")" "[H] …and the person sees a short message too"
  hk "$R" PreToolUse Bash "$(p_bash "$S" "echo hi again")"
  eq "$HRC" 0 "[H] …the second call exits 0"; empty "$HOUT" "[H] …and does not warn again in the same session"
  hk "$R" PreToolUse Edit "$(p_edit "$S" "$R/src/a.ts")"
  empty "$HOUT" "[H] …nor does the other hook (one warning per session, not per hook)"
  hk "$R" PreToolUse Bash "$(p_bash "$S" "echo hi")"; hk "$R" PreToolUse Bash "$(p_bash "$(sid)" "echo hi")"
  has "$(ctx "$HOUT")" sdlc.json "[H] …a new session warns again"
  # keys a newer plugin knows (rule config-compat): a warning once per session, the rules still delivered
  R=$(mk_repo); put_cfg "$R" '{"bogus": 1}'; S=$(sid)
  hk "$R" PreToolUse Bash "$(p_bash "$S" "git worktree add x y")"
  eq "$HRC" 0 "[H] keys a newer plugin knows: the hook exits 0"
  has "$(ctx "$HOUT")" "bogus: unknown key" "[H] keys a newer plugin knows: the first call warns, naming the key"
  has "$(ctx "$HOUT")" git-process "[H] …and the rules are delivered (the config is valid)"
  nonempty "$(sysm "$HOUT")" "[H] …with a short message for the person"
  hk "$R" PreToolUse Bash "$(p_bash "$S" "echo hi")"; empty "$HOUT" "[H] …once per session"
  # the usual reminder still arrives, with the warning in front, in ONE json
  R=$(mk_repo); put_cfg "$R" "$BAD_CFG"; S=$(sid)
  hk "$R" PreToolUse Bash "$(p_bash "$S" "git worktree add x y")"
  isjson "$HOUT" && ok "[H] warning plus reminder is ONE valid JSON" || bad "[H] warning plus reminder is not one valid JSON: ${HOUT:0:100}"
  has "$(ctx "$HOUT")" git-process "[H] a broken config does not switch the rules off: the git rule is still reminded"
  has "$(ctx "$HOUT")" sdlc.json "[H] …and the warning is in the same output"
  R=$(mk_repo); put_cfg "$R" '{'; S=$(sid)
  hk "$R" PreToolUse Bash "$(p_bash "$S" "echo hi")"; eq "$HRC" 0 "[H] a config that is not JSON: rc 0"; has "$(ctx "$HOUT")" sdlc.json "[H] …and it warns"
  R=$(mk_repo); mkdir -p "$R/.vibemaestro"; python3 -c 'import sys; sys.stdout.write("[" * 100000)' > "$R/.vibemaestro/sdlc.json"; S=$(sid)
  hk "$R" PreToolUse Bash "$(p_bash "$S" "echo hi")"; eq "$HRC" 0 "[H] a deeply nested config: rc 0"; has "$(ctx "$HOUT")" sdlc.json "[H] …it gets the config warning"
  hk "$R" PreToolUse Bash "$(p_bash "$S" "echo hi")"; empty "$HOUT" "[H] …once per session, not an internal-error warning on every call"
  R=$(mk_repo); put_cfg "$R" '{"rules": {"dirs": ["a\u0000b"]}}'; S=$(sid)
  hk "$R" PreToolUse Bash "$(p_bash "$S" "git worktree add x y")"; eq "$HRC" 0 "[H] a NUL in a rule directory: rc 0"
  has "$(ctx "$HOUT")" git-process "[H] …the plugin rules are still delivered (defaults)"; hasnt "$(ctx "$HOUT")" "internal" "[H] …and no internal-error warning"
  # SessionStart: the first of the two hooks of the session warns, the second does not
  R=$(mk_repo); put_cfg "$R" "$BAD_CFG"; S=$(sid)
  hk "$R" SessionStart "" "$(p_start "$S")" 1; first=$HOUT; eq "$HRC" 0 "[H] SessionStart with a broken config: rc 0"
  has "$(ctx "$first")" sdlc.json "[H] …the first SessionStart hook warns"
  has "$(ctx "$first")" "The general way of working" "[H] …and still delivers the process core"
  hk "$R" SessionStart "" "$(p_start "$S")" 2
  hasnt "$(ctx "$HOUT")" "WARNING plugin" "[H] …the second SessionStart hook does not warn again"; nonempty "$(ctx "$HOUT")" "[H] …but delivers the catalogue"
  # the legacy hook markers are plain text since 2.0.0: they neither swallow the warning nor silence a reminder
  R=$(mk_repo); put_markers "$R"; put_cfg "$R" "$BAD_CFG"; S=$(sid)
  hk "$R" PreToolUse Bash "$(p_bash "$S" "git worktree add x y")"; has "$(ctx "$HOUT")" sdlc.json "[H] markers and a broken config: the warning is given"
  has "$(ctx "$HOUT")" git-process "[H] …and the command reminder too"
  R=$(mk_repo); put_markers "$R"; S=$(sid)
  hk "$R" PreToolUse Bash "$(p_bash "$S" "git worktree add x y")"; has "$(ctx "$HOUT")" git-process "[H] markers and no config file: the command reminder is given (not silent since 2.0.0)"
  mkdir -p "$R/kb/intent"; kbx "$R" new intent x >/dev/null 2>&1; eq "$?" 0 "[H] …and kb.py new intent exits 0"
  # a plugin that cannot deliver its rules (no rules/) and a broken config: the PreToolUse hooks give both warnings, and
  # the config warning still arrives when the plugin warning was already given earlier in the session
  local PLOK=$PLX hook PB; PB=$(mktemp -d "$TMP/plug-norules.XXXXXX"); cp -r "$PLX/." "$PB"; rm -rf "$PB/rules"; PLX=$PB
  for hook in Edit Bash; do
    R=$(mk_repo); S=$(sid)
    hk "$R" PreToolUse $hook "$( [ $hook = Edit ] && p_edit "$S" "$R/src/a.ts" || p_bash "$S" "echo hi")"
    has "$(ctx "$HOUT")" "rule cannot be read" "[H] broken plugin, valid config, $hook: the plugin warning"
    put_cfg "$R" "$BAD_CFG"
    hk "$R" PreToolUse $hook "$( [ $hook = Edit ] && p_edit "$S" "$R/src/b.ts" || p_bash "$S" "echo again")"
    eq "$HRC" 0 "[H] broken plugin, config broken later, $hook: rc 0"
    has "$(ctx "$HOUT")" sdlc.json "[H] …the config warning arrives although the plugin warning was given (it was consumed and dropped)"
    nonempty "$(sysm "$HOUT")" "[H] …with a short message for the person"
    R=$(mk_repo); put_cfg "$R" "$BAD_CFG"; S=$(sid)
    hk "$R" PreToolUse $hook "$( [ $hook = Edit ] && p_edit "$S" "$R/src/a.ts" || p_bash "$S" "echo hi")"
    has "$(ctx "$HOUT")" sdlc.json "[H] broken plugin and broken config, $hook: the config warning"
    has "$(ctx "$HOUT")" "rule cannot be read" "[H] …and the plugin warning, in one output"
    isjson "$HOUT" && ok "[H] …as ONE valid JSON" || bad "[H] not one valid JSON: ${HOUT:0:100}"
  done
  PLX=$PLOK
}

# ── [R] rules.dirs, replacement, disable ─────────────────────────────────────────────────────────
mk_repo_rules() {  # mk_repo_rules <repo> — a rule directory with an applyTo rule, an applyWhen rule, a draft and a same-name file
  local d="$1/repo-rules"; mkdir -p "$d"
  printf -- '---\napplyTo: "src/**"\ndescription: "REPO-EDIT-RULE"\n---\n\n# Repo edit rule\n\nEdit with care.\n' > "$d/r-edit.instructions.md"
  printf -- '---\napplyWhen: "\\bacme-deploy\\b"\ndescription: "REPO-CMD-RULE"\n---\n\n# Repo command rule\n\nDeploy with care.\n' > "$d/r-cmd.instructions.md"
  printf -- '---\napplyTo: "**"\nstatus: example\ndescription: "REPO-DRAFT-RULE"\n---\n\n# Draft\n\nNever delivered.\n' > "$d/r-draft.instructions.md"
  printf -- '---\napplyWhen: "\\bzzz-never\\b"\ndescription: "REPO-REPLACEMENT"\n---\n\n# Replacement of the git rule\n\nSame name, other trigger.\n' > "$d/git-process.instructions.md"
}
fam_rules() {
  PLX=$1; local R S
  R=$(mk_repo); mk_repo_rules "$R"; put_cfg "$R" '{"rules": {"dirs": ["repo-rules"]}}'; S=$(sid)
  hk "$R" PreToolUse Edit "$(p_edit "$S" "$R/src/a.ts")"
  eq "$HRC" 0 "[R] a repo rule on applyTo: the hook exits 0"
  has "$(ctx "$HOUT")" "$R/repo-rules/r-edit.instructions.md" "[R] …the reminder names the repo's own file"
  hasnt "$(ctx "$HOUT")" r-draft "[R] a rule whose status is not active is not delivered"
  hk "$R" PreToolUse Bash "$(p_bash "$S" "acme-deploy now")"
  has "$(ctx "$HOUT")" "$R/repo-rules/r-cmd.instructions.md" "[R] a repo rule on applyWhen: the command reminder names the repo's file"
  hk "$R" PreToolUse Bash "$(p_bash "$S" "git worktree add x y")"
  empty "$HOUT" "[R] a same-name repo file replaces the plugin rule: the plugin's git rule is not reminded"
  hk "$R" PreToolUse Bash "$(p_bash "$S" "zzz-never")"
  has "$(ctx "$HOUT")" "$R/repo-rules/git-process.instructions.md" "[R] …the replacement answers to its own trigger and names the repo's file"
  hk "$R" SessionStart "" "$(p_start "$S")" 2
  has "$(ctx "$HOUT")" "replaces the plugin rule" "[R] SessionStart says that a repo rule replaces a plugin rule"
  has "$(ctx "$HOUT")" r-edit.instructions.md "[R] …and the catalogue lists the repo's rule"
  hasnt "$(ctx "$HOUT")" r-draft "[R] …and not the draft"
  R=$(mk_repo); mk_repo_rules "$R"; S=$(sid); hk "$R" PreToolUse Edit "$(p_edit "$S" "$R/src/a.ts")"
  empty "$HOUT" "[R] control: with no config the repo's rule directory is not read"
  R=$(mk_repo); put_cfg "$R" '{}'; S=$(sid); hk "$R" PreToolUse Bash "$(p_bash "$S" "git commit -m x")"
  has "$(ctx "$HOUT")" pr-no-leaks "[R] control: a plugin rule that matches git commit is reminded"
  R=$(mk_repo); put_cfg "$R" '{"rules": {"disable": ["pr-no-leaks"]}}'; S=$(sid)
  hk "$R" PreToolUse Bash "$(p_bash "$S" "git commit -m x")"
  hasnt "$(ctx "$HOUT")" pr-no-leaks "[R] rules.disable (a name without the suffix) turns the plugin rule off"
  R=$(mk_repo); put_cfg "$R" '{"rules": {"disable": ["pr-no-leaks.instructions.md"]}}'; S=$(sid)
  hk "$R" PreToolUse Bash "$(p_bash "$S" "git commit -m x")"
  hasnt "$(ctx "$HOUT")" pr-no-leaks "[R] …and with the suffix"
  hk "$R" SessionStart "" "$(p_start "$S")" 2
  hasnt "$(ctx "$HOUT")" "- pr-no-leaks" "[R] …the catalogue does not list it"
  has "$(ctx "$HOUT")" "pr-no-leaks" "[R] …but says it was turned off"
  has "$(ctx "$HOUT")" "git-process" "[R] …the other plugin rules stay"
  R=$(mk_repo); put_cfg "$R" '{"rules": {"disable": ["workflow-core"]}}'; S=$(sid)
  hk "$R" SessionStart "" "$(p_start "$S")" 1; has "$(ctx "$HOUT")" "The general way of working" "[R] the process core cannot be disabled"
  # the five rule files renamed to English still answer to their old names
  R=$(mk_repo); put_cfg "$R" '{"rules": {"disable": ["pr-khong-lo-thong-tin"]}}'; S=$(sid)
  hk "$R" PreToolUse Bash "$(p_bash "$S" "git commit -m x")"
  hasnt "$(ctx "$HOUT")" pr-no-leaks "[R] rules.disable with the OLD name of a renamed rule turns the rule off"
  hk "$R" SessionStart "" "$(p_start "$S")" 2
  has "$(ctx "$HOUT")" "pr-khong-lo-thong-tin.instructions.md, which was renamed to pr-no-leaks.instructions.md" "[R] …and SessionStart says the old name was renamed"
  has "$(ctx "$HOUT")" "git-process" "[R] …the other plugin rules stay"
  out=$(chk "$R" 2>&1); eq "$?" 0 "[R] …kb.py config check: rc 0 (a warning, not an error)"
  has "$out" "rules.disable: pr-khong-lo-thong-tin.instructions.md was renamed to pr-no-leaks.instructions.md" "[R] …and it prints the rename warning"
  hasnt "$out" "matches no plugin rule" "[R] …and does not call the old name unknown"
  R=$(mk_repo); put_cfg "$R" '{"rules": {"disable": ["pr-khong-lo-thong-tin.instructions.md", "pr-khong-lo-thong-tin"]}}'; S=$(sid)
  hk "$R" PreToolUse Bash "$(p_bash "$S" "git commit -m x")"
  hasnt "$(ctx "$HOUT")" pr-no-leaks "[R] the old name with the suffix, and both spellings together: the rule is off"
  eq "$(chk "$R" 2>&1 | grep -c 'was renamed')" 1 "[R] …one warning for one old name, however many spellings"
  R=$(mk_repo); put_cfg "$R" '{"rules": {"disable": ["pr-no-leaks"]}}'; S=$(sid)
  hasnt "$(chk "$R" 2>&1)" "was renamed" "[R] control: the NEW name prints no rename warning"
  hk "$R" SessionStart "" "$(p_start "$S")" 2; hasnt "$(ctx "$HOUT")" "was renamed" "[R] …nor does SessionStart"
  R=$(mk_repo); put_cfg "$R" '{"rules": {"disable": ["quy-trinh-git", "truoc-khi-chuyen-ready", "khuon-current-state"]}}'; S=$(sid)
  hk "$R" PreToolUse Bash "$(p_bash "$S" "git worktree add x y")"; hasnt "$(ctx "$HOUT")" git-process "[R] the old name of the git rule turns it off"
  hk "$R" PreToolUse Bash "$(p_bash "$S" "gh pr ready 3")"; hasnt "$(ctx "$HOUT")" before-ready "[R] …and of the ready rule"
  hk "$R" PreToolUse Edit "$(p_edit "$S" "$R/kb/current-state.md")"; hasnt "$(ctx "$HOUT")" current-state-shape "[R] …and of the current-state rule"
  eq "$(chk "$R" 2>&1 | grep -c 'was renamed')" 3 "[R] …three old names, three warnings"
  R=$(mk_repo); put_cfg "$R" '{"rules": {"disable": ["cach-lam-viec-chung"]}}'; S=$(sid)
  hk "$R" SessionStart "" "$(p_start "$S")" 1; has "$(ctx "$HOUT")" "The general way of working" "[R] the OLD name of the process core cannot disable it either"
  out=$(chk "$R" 2>&1); has "$out" "was renamed to workflow-core.instructions.md" "[R] …and the old core name prints the rename warning"
  has "$out" "is the process core" "[R] …and the process-core warning"
  # a repo rule file with an old name keeps the place of the renamed plugin rule
  R=$(mk_repo); mk_repo_rules "$R"; mv "$R/repo-rules/git-process.instructions.md" "$R/repo-rules/quy-trinh-git.instructions.md"
  put_cfg "$R" '{"rules": {"dirs": ["repo-rules"]}}'; S=$(sid)
  hk "$R" PreToolUse Bash "$(p_bash "$S" "git worktree add x y")"
  empty "$HOUT" "[R] a repo file with the OLD name replaces the renamed plugin rule: the plugin's git rule is not reminded"
  hk "$R" PreToolUse Bash "$(p_bash "$S" "zzz-never")"
  has "$(ctx "$HOUT")" "$R/repo-rules/quy-trinh-git.instructions.md" "[R] …the replacement answers to its own trigger and names the repo's file"
  hk "$R" SessionStart "" "$(p_start "$S")" 2
  has "$(ctx "$HOUT")" "has the old name of the plugin rule git-process.instructions.md" "[R] …SessionStart tells the file to be renamed"
  hasnt "$(ctx "$HOUT")" "- git-process.instructions.md" "[R] …and the catalogue lists the repo's file, not the plugin's"
  out=$(chk "$R" 2>&1); eq "$(printf '%s\n' "$out" | grep -c 'has the old name of the plugin rule')" 1 "[R] …kb.py config check prints one old-name warning"
  hasnt "$out" "duplicate paragraph" "[R] …and no duplicate paragraph (the plugin file is not delivered)"
  has "$(ctx "$HOUT")" "repo-rules/quy-trinh-git.instructions.md replaces the plugin rule" "[R] …and the replacement message names the file that exists"
  hasnt "$(ctx "$HOUT")" "repo-rules/git-process.instructions.md" "[R] …not a file of the new name that is not there"
  # both spellings of one rule in one directory: the file with the current name is delivered, the old one is not
  R=$(mk_repo); mk_repo_rules "$R"; S=$(sid)
  printf -- '---\napplyWhen: "\\bzzz-old\\b"\ndescription: "OLD-SPELLING"\n---\n\n# Old\n\nOld spelling.\n' > "$R/repo-rules/pr-khong-lo-thong-tin.instructions.md"
  printf -- '---\napplyWhen: "\\bzzz-new\\b"\ndescription: "NEW-SPELLING"\n---\n\n# New\n\nNew spelling.\n' > "$R/repo-rules/pr-no-leaks.instructions.md"
  put_cfg "$R" '{"rules": {"dirs": ["repo-rules"]}}'
  hk "$R" PreToolUse Bash "$(p_bash "$S" "zzz-new")"; has "$(ctx "$HOUT")" "$R/repo-rules/pr-no-leaks.instructions.md" "[R] an old-name file and a new-name file of one rule in one directory: the new-name file is delivered"
  hk "$R" PreToolUse Bash "$(p_bash "$S" "zzz-old")"; empty "$HOUT" "[R] …and the old-name file is not"
  out=$(chk "$R" 2>&1); hasnt "$out" "has the old name" "[R] …and it is not told to be renamed (it is not delivered)"
  # the same old name in two directories: only the delivered one is told to be renamed
  R=$(mk_repo); mkdir -p "$R/r1" "$R/r2"
  for d in r1 r2; do printf -- '---\napplyTo: "x/**"\ndescription: "d"\n---\n\nText %s.\n' "$d" > "$R/$d/quy-trinh-git.instructions.md"; done
  put_cfg "$R" '{"rules": {"dirs": ["r1", "r2"]}}'; out=$(chk "$R" 2>&1)
  eq "$(printf '%s\n' "$out" | grep -c 'has the old name')" 1 "[R] the same old name in two directories: one old-name warning (the delivered file)"
  R=$(mk_repo); mk_repo_rules "$R"; mv "$R/repo-rules/git-process.instructions.md" "$R/repo-rules/cach-lam-viec-chung.instructions.md"
  put_cfg "$R" '{"rules": {"dirs": ["repo-rules"]}}'; S=$(sid)
  hk "$R" PreToolUse Bash "$(p_bash "$S" "zzz-never")"; empty "$HOUT" "[R] a repo file with the OLD name of the core is not delivered (the core always comes from the plugin)"
  has "$(chk "$R" 2>&1)" "repo-rules/cach-lam-viec-chung.instructions.md has the name of the process core" "[R] …and is reported as such"
  # the hub-shaped fixture with a copy of a plugin rule under its old name: replaced, not delivered twice
  R=$(fresh); cp -r "$SHAPED/." "$R/"; cp "$PLX/rules/pr-no-leaks.instructions.md" "$R/.github/instructions/pr-khong-lo-thong-tin.instructions.md"
  out=$(chk "$R" 2>&1); hasnt "$out" "duplicate paragraph" "[R] hub-shaped fixture + a copy of a plugin rule under its old name: no duplicate rule"
  has "$out" "has the old name of the plugin rule pr-no-leaks.instructions.md" "[R] …it is the old-name replacement"
  R=$(fresh); cp -r "$SHAPED/." "$R/"; cp "$PLX/rules/pr-no-leaks.instructions.md" "$R/.github/instructions/pr-no-leaks.instructions.md"
  out=$(chk "$R" 2>&1); hasnt "$out" "duplicate paragraph" "[R] control: the same copy under the NEW name replaces it too"
  hasnt "$out" "old name" "[R] …with no old-name warning"
}

# ── [C] kb.py config check ───────────────────────────────────────────────────────────────────────
fam_check() {
  PLX=$1; local R out rc
  out=$(chk "$SHAPED" 2>&1); rc=$?
  eq "$rc" 0 "[C] the worked example (hub-shaped fixture): rc 0"
  hasnt "$out" "markers present" "[C] …no markers line (the markers mean nothing since 2.0.0)"
  has "$out" valid "[C] …and says the file is valid"
  hasnt "$out" "duplicate paragraph" "[C] …no duplicate paragraph between the fixture's rules and the plugin's"
  R=$(fresh); cp -r "$SHAPED/." "$R/"; python3 - "$R/.vibemaestro/sdlc.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["hooks"] = "off"; json.dump(d, open(p, "w"))
PY
  out=$(chk "$R" 2>&1); eq "$?" 0 "[C] hooks off: rc 0"
  put_cfg "$R" "$BAD_CFG"
  out=$(chk "$R" 2>&1); eq "$?" 65 "[C] an invalid config with markers: rc 65"
  R=$(fresh); put_markers "$R"; out=$(chk "$R" 2>&1); eq "$?" 0 "[C] markers and no config file: rc 0"
  R=$(fresh); put_cfg "$R" '{"current_state": {"gate": "external:scripts/check-ledger.py"}}'
  out=$(chk "$R" 2>&1); eq "$?" 0 "[C] an external gate: rc 0"
  has "$out" "external:scripts/check-ledger.py" "[C] …it is listed for review"; has "$out" REVIEW "[C] …under the review tag"
  R=$(fresh); put_cfg "$R" '{}'; out=$(chk "$R" 2>&1); hasnt "$out" REVIEW "[C] no external gate: no review line"
  # duplicate paragraphs between a repo rule directory and the plugin rules
  R=$(fresh); mkdir -p "$R/rr"; cp "$PLX/rules/git-process.instructions.md" "$R/rr/my-copy.instructions.md"
  put_cfg "$R" '{"rules": {"dirs": ["rr"]}}'
  out=$(chk "$R" 2>&1); rc=$?
  eq "$rc" 0 "[C] a repo rule that copies a plugin rule: rc 0 (a warning, not an error)"
  has "$out" "duplicate paragraph" "[C] …the duplicate paragraph is listed"; has "$out" my-copy.instructions.md "[C] …with the repo file named"
  put_cfg "$R" '{"rules": {"dirs": ["rr"], "disable": ["git-process"]}}'
  out=$(chk "$R" 2>&1); hasnt "$out" "duplicate paragraph" "[C] …no warning when the plugin rule is disabled (it is not delivered twice)"
  R=$(fresh); mkdir -p "$R/rr"; printf -- '---\napplyTo: "x/**"\ndescription: "d"\n---\n\nA short and entirely different text.\n' > "$R/rr/other.instructions.md"
  put_cfg "$R" '{"rules": {"dirs": ["rr"]}}'; out=$(chk "$R" 2>&1); hasnt "$out" "duplicate paragraph" "[C] control: a different rule: no duplicate warning"
  R=$(fresh); mkdir -p "$R/rr"; cp "$PLX/rules/git-process.instructions.md" "$R/rr/git-process.instructions.md"
  put_cfg "$R" '{"rules": {"dirs": ["rr"]}}'; out=$(chk "$R" 2>&1)
  has "$out" "replaces the plugin rule" "[C] a same-name rule is reported as a replacement"; hasnt "$out" "duplicate paragraph" "[C] …and its paragraphs are not counted as duplicates (the plugin file is not delivered)"
  # the two collisions that were settled without a word; delivery stays as it was
  R=$(fresh); mkdir -p "$R/r1" "$R/r2"
  printf -- '---\napplyTo: "x/**"\ndescription: "d"\n---\n\nA repo text named like the core.\n' > "$R/r1/workflow-core.instructions.md"
  printf -- '---\napplyTo: "y/**"\ndescription: "FIRST-MINE"\n---\n\nOne.\n' > "$R/r1/mine.instructions.md"
  printf -- '---\napplyTo: "z/**"\ndescription: "SECOND-MINE"\n---\n\nTwo.\n' > "$R/r2/mine.instructions.md"
  printf -- '---\napplyTo: "w/**"\ndescription: "d"\n---\n\nThree.\n' > "$R/r2/only-here.instructions.md"
  put_cfg "$R" '{"rules": {"dirs": ["r1", "r2", "r1", "./r1/"]}}'; out=$(chk "$R" 2>&1); rc=$?
  eq "$rc" 0 "[C] rule-name collisions: rc 0 (warnings, not errors)"
  has "$out" "r1/workflow-core.instructions.md has the name of the process core" "[C] …a repo rule named like the process core is reported"
  has "$out" "r2/mine.instructions.md has the name of r1/mine.instructions.md" "[C] …a name repeated across rules.dirs is reported, naming the one delivered"
  hasnt "$out" "only-here" "[C] …a name used once is not reported"
  eq "$(printf '%s\n' "$out" | grep -c 'has the name of')" 2 "[C] …a directory listed twice, spelled two ways, adds no warning of its own"
  hk "$R" PreToolUse Edit "$(p_edit "$(sid)" "$R/y/a.ts")"; has "$(ctx "$HOUT")" "$R/r1/mine.instructions.md" "[C] …delivery unchanged: the first directory's file is reminded"
  hk "$R" PreToolUse Edit "$(p_edit "$(sid)" "$R/z/a.ts")"; hasnt "$(ctx "$HOUT")" "r2/mine" "[C] …and the second one is not"
  R=$(fresh); put_cfg "$R" '{"rules": {"dirs": ["no-such-dir"], "disable": ["no-such-rule", "workflow-core"]}}'
  out=$(chk "$R" 2>&1); eq "$?" 0 "[C] a missing rule directory and unknown disable names: rc 0"
  has "$out" "no-such-dir" "[C] …the missing directory is listed"; has "$out" "no-such-rule" "[C] …the unknown disable name is listed"
  has "$out" "process core" "[C] …disabling the core is explained"
}

# ── [K] the knobs of the cores ───────────────────────────────────────────────────────────────────
fam_knobs() {
  PLX=$1; local J B W S out rc IW
  # intent prefix: the core and the adapters
  W=$(mk_origin); put_cfg "$W" '{"branch": {"intent_prefix": "feat/"}}'; git_ -C "$W" add -A; git_ -C "$W" commit -q -m cfg; git_ -C "$W" push -q origin main
  printf -- '---\ndescription: "x"\n---\n' > "$W/kb/intent/k1.md"
  core "$W" create-intent --slug k1 >/dev/null 2>&1; eq "$?" 0 "[K] branch.intent_prefix feat/: create-intent exits 0"
  ref_exists "$W" feat/k1 && ok "[K] …the branch is feat/k1" || bad "[K] …the branch is feat/k1 (missing)"
  ref_exists "$W" intent/k1 && bad "[K] …and there is no intent/k1" || ok "[K] …and there is no intent/k1"
  git_ -C "$W" add -A; git_ -C "$W" commit -q -m "record k1"; git_ -C "$W" push -q -u origin feat/k1; git_ -C "$W" checkout -q main
  S=$(task_wt_p "$W" task/one k1 feat 2)
  out=$(cd "$TMP" && cenv bash "$PLX/scripts/intent-branch.sh" --cwd "$S" integrate --intent k1 --branch task/one --to origin 2>&1); rc=$?
  eq "$rc" 8 "[K] intent-branch.sh counts commits against the configured prefix: a task with 2 commits is rc 8"
  core "$W" worker-branch --intent intent/k1 --name task/two --no-checkout >/dev/null 2>&1; eq "$?" 5 "[K] a name under the default prefix is not an intent here: rc 5 (no such base)"
  # protected branches, in the core and in the PR core
  eq "$(cd "$W" && python3 - "$PLX/scripts" <<'PY'
import sys; sys.path.insert(0, sys.argv[1]); import intent_branch as ib
W = "."
ib.apply_config(W); a = ib.is_protected("main", W)
import os; os.makedirs(".vibemaestro", exist_ok=True)
open(".vibemaestro/sdlc.json", "w").write('{"branch": {"protected": ["trunk"]}}')
ib.apply_config(W); print(a, ib.is_protected("main", W), ib.is_protected("trunk", W), ib.is_protected("refs/heads/trunk", W))
PY
)" "True False True True" "[K] branch.protected is read by intent_branch (main by default, then only what the file lists)"
  mk_pr_repo; put_cfg "$PT" '{"branch": {"protected": ["main", "trunk"]}}'
  prx "$PT" --dry-run --title t --summary-file "$F/sum.md" --evidence-file "$F/ev.txt" --head trunk >/dev/null 2>&1; eq "$?" 64 "[K] branch.protected: --head trunk is refused (rc 64)"
  prx "$PT" --dry-run --title t --summary-file "$F/sum.md" --evidence-file "$F/ev.txt" --head main >/dev/null 2>&1; eq "$?" 64 "[K] …and main still is"
  put_cfg "$PT" '{"branch": {"protected": ["trunk"]}}'
  prx "$PT" --dry-run --title t --summary-file "$F/sum.md" --evidence-file "$F/ev.txt" --head main >/dev/null 2>&1; eq "$?" 0 "[K] …a list without main allows --head main (the file decides)"
  # title pattern and length
  put_cfg "$PT" '{"pr": {"title": {"pattern": "^(feat|fix): .+$", "max_len": 20}}}'
  prd >/dev/null 2>&1; eq "$?" 0 "[K] pr.title: a title that fits the pattern and the length: rc 0"
  out=$(prx "$PT" --dry-run --title "chore: x" --summary-file "$F/sum.md" --evidence-file "$F/ev.txt" --head feat/x 2>&1); rc=$?
  eq "$rc" 64 "[K] pr.title.pattern: a title that does not match: rc 64"
  prx "$PT" --dry-run --title "feat: a title that is much too long" --summary-file "$F/sum.md" --evidence-file "$F/ev.txt" --head feat/x >/dev/null 2>&1
  eq "$?" 64 "[K] pr.title.max_len: a title over the length: rc 64"
  put_cfg "$PT" '{"pr": {"title": {"intent_form": "reject"}}}'; prd >/dev/null 2>&1; eq "$?" 0 "[K] pr.title.intent_form is validated only (gate-side): rc 0"
  # draft
  put_cfg "$PT" '{"pr": {"draft": true}}'; J=$(prd 2>/dev/null); eq "$(pj "$J" draft)" true "[K] pr.draft true: the payload is a draft without the flag"
  put_cfg "$PT" '{"pr": {"draft": false}}'; J=$(prd 2>/dev/null); eq "$(pkeys "$J")" "base body head title" "[K] pr.draft false: no draft key"
  # flow and tester exemption: deprecated, still valid, and they change no body
  put_cfg "$PT" '{"pr": {"flow": ["Write it", {"text": "Review it", "done": true}, "Ship it"]}}'; B=$(pj "$(prd 2>/dev/null)" body)
  hasnt "$B" "Write it" "[K] pr.flow (deprecated): its lines are not written into the body"
  vcase "pr.flow (deprecated): valid, with a warning that names it" '{"pr": {"flow": ["Write it"]}}' 'warn:pr.flow: deprecated since'
  vcase "pr.tester_exempt (deprecated): valid, with a warning" '{"pr": {"tester_exempt": {"decision": "kb/decisions/x.md"}}}' 'warn:pr.tester_exempt: deprecated since'
  vcase "pr.flow with a wrong type: still refused" '{"pr": {"flow": 3}}' pr.flow
  # closing keyword, verification, tries
  put_cfg "$PT" '{"pr": {"closing": {"keyword": "fixes"}}}'; B=$(pj "$(prd --closes 7 2>/dev/null)" body)
  eq "$(printf '%s\n' "$B" | head -1)" "Fixes #7" "[K] pr.closing.keyword: the body starts with the configured word"
  glog_reset; put_cfg "$PT" '{"pr": {"closing": {"verify": false}}}'
  prg GH_CLOSING_JSON='[7]' -- --closes 7 >/dev/null 2>&1; eq "$?" 0 "[K] pr.closing.verify false: the PR is opened"
  eq "$(grep -c 'pr\] \[view' "$GH_LOG")" 0 "[K] …and gh pr view is never asked"
  glog_reset; put_cfg "$PT" '{"pr": {"closing": {"verify": true}}}'
  prg GH_CLOSING_JSON='[7]' -- --closes 7 >/dev/null 2>&1; eq "$(grep -c 'pr\] \[view' "$GH_LOG")" 1 "[K] control: with verify true the link is read (and found at once)"
  glog_reset; put_cfg "$PT" '{"pr": {"closing": {"tries": 3}}}'
  prg GH_CLOSING_AFTER=99 -- --closes 7 >/dev/null 2>&1; eq "$(grep -c 'pr\] \[view' "$GH_LOG")" 3 "[K] pr.closing.tries: a link that never appears is read exactly 3 times"
  # tokens
  mk_pr_repo; printf '## Summary\nA real summary line.\n' > "$F/sum-h.md"; printf 'one\n' > "$F/crit.txt"
  put_cfg "$PT" '{"tokens": {"summary_heading": "Summary", "criteria_heading": "Criteria", "evidence_heading": "Evidence", "flow_heading": "Flow", "fixes_line": "Fixes for", "not_run": "NOT RUN:"}}'
  B=$(pj "$(prd --summary-file "$F/sum-h.md" --crit-file "$F/crit.txt" --fixes 9 --closes 5 2>/dev/null)" body)
  hasline "$B" "## Summary" "[K] tokens: the summary heading"; hasline "$B" "## Criteria" "[K] …the criteria heading"; hasline "$B" "## Evidence" "[K] …the evidence heading"
  eq "$(nline "$B" "## Flow")" 0 "[K] …and no flow heading in English either"; hasline "$B" "Fixes for #9" "[K] …the fixes line"
  eq "$(printf '%s\n' "$B" | grep -c '^## Summary')" 1 "[K] …a summary file that starts with the configured heading does not get it twice"
  hasnt "$B" "## $TOK_SUMMARY" "[K] …and the default heading is gone"
  printf 'NOT RUN: no database\n' > "$F/ev-nr.txt"; B=$(pj "$(prd --evidence-file "$F/ev-nr.txt" 2>/dev/null)" body)
  has "$B" "⚠" "[K] tokens.not_run: the configured token makes the evidence an exemption"
  printf '%s no database\n' "$TOK_NOT_RUN" > "$F/ev-nr2.txt"; B=$(pj "$(prd --evidence-file "$F/ev-nr2.txt" 2>/dev/null)" body)
  hasnt "$B" "⚠" "[K] …and the old token no longer does"
  # adapter: the intent prefix when reading `issue: N`
  mk_pr_repo; OPENV=(); put_cfg "$PW" '{"branch": {"intent_prefix": "feat/"}}'; git_ -C "$PW" add -A; git_ -C "$PW" commit -q -m cfg
  git_ -C "$PW" worktree add -q -b feat/ad "$PW/../ad" main; IW=$(cd "$PW/../ad" && pwd -P)
  mkdir -p "$IW/kb/intent"; printf -- '---\nissue: 33\ndescription: "x"\n---\n' > "$IW/kb/intent/ad.md"
  J=$(cd "$IW" && cenv PATH="$GHB:$PATH" bash "$PLX/scripts/open-pr.sh" --title "feat: x" --summary "$F/sum.md" --evidence "$F/ev.txt" --dry-run 2>/dev/null)
  eq "$(pj "$J" body | head -1)" "Closes #33" "[K] open-pr.sh reads issue: N from kb/intent/ad.md on branch feat/ad (branch.intent_prefix feat/)"
  rm -f "$IW/.vibemaestro/sdlc.json"; git_ -C "$IW" rm -q --cached .vibemaestro/sdlc.json 2>/dev/null; rm -rf "$IW/.vibemaestro"
  J=$(cd "$IW" && cenv PATH="$GHB:$PATH" bash "$PLX/scripts/open-pr.sh" --title "feat: x" --summary "$F/sum.md" --evidence "$F/ev.txt" --dry-run 2>/dev/null)
  eq "$(pj "$J" body | grep -c 'Closes #')" 0 "[K] …and with the default prefix feat/ is not an intent branch: no Closes line"
}
# task_wt_p <main tree> <branch> <slug> <prefix> <commits> — like task_wt for a configured prefix
task_wt_p() {
  local wt="$1/../wt-${2//\//-}" n
  git_ -C "$1" worktree add -q -b "$2" "$wt" "origin/$4/$3"
  wt=$(cd "$wt" && pwd -P)
  for n in $(seq 1 "${5:-1}"); do commit_in "$wt" "${2//\//-}-$n.txt" "$2 $n" "work $2 $n"; done
  printf '%s' "$wt"
}

# ── [T] the timing knobs of the closing-link poll (kept apart: they take real seconds, so only their own probes run them) ──
fam_timing() {
  PLX=$1; local rc
  mk_pr_repo
  glog_reset; put_cfg "$PT" '{"pr": {"closing": {"tries": 3, "wait_s": 0.2}}}'
  SECONDS=0; prg GH_CLOSING_AFTER=99 OPEN_PR_LINK_WAIT_S= -- --closes 7 >/dev/null 2>&1
  eq "$(grep -c 'pr\] \[view' "$GH_LOG")" 3 "[K] pr.closing.wait_s: three reads"; [ "$SECONDS" -le 2 ] && ok "[K] …with a short wait between them (it is read from the file, the default is 2 s)" || bad "[K] pr.closing.wait_s is ignored: ${SECONDS}s for two gaps of 0.2 s"
  glog_reset; put_cfg "$PT" '{"pr": {"closing": {"tries": 10, "wait_s": 0.4, "deadline_s": 1}}}'
  prg GH_CLOSING_AFTER=99 OPEN_PR_LINK_WAIT_S= -- --closes 7 >/dev/null 2>&1; rc=$?
  eq "$rc" 0 "[K] pr.closing.deadline_s: the PR exists, so a link that never shows still exits 0"
  [ "$(grep -c 'pr\] \[view' "$GH_LOG")" -le 4 ] && ok "[K] …the poll stops at the deadline of the file (at most 4 reads of 10)" || bad "[K] pr.closing.deadline_s is ignored: $(grep -c 'pr\] \[view' "$GH_LOG") reads"
}

# ── [M] the guarded merge's keys: merge.* and ci.backend ──────────────────────────────────────────────────────
fam_merge() {
  PLX=$1; local out rc
  vcase "merge: deny globs unset (the default: the guard refuses to run, the file is valid)" '{}' ok
  vcase "merge: an empty deny list is a valid answer" '{"merge": {"deny_globs": []}}' ok
  vcase "merge: every key of the guarded merge" '{"merge": {"deny_globs": [".github/workflows/**", ".vibemaestro/**", "**/*secret*", "deploy/*.yaml"],
    "admin_bypass": true, "required_checks": ["bash tests/run-all.sh"], "log": "merge-log-acme.jsonl",
    "image_bump": {"enabled": true, "tag_files": ["deploy/app.yaml", "src/image_ref.py"], "tree": "image/",
      "revision": {"file": ".github/workflows/image.yml", "pattern": "IMAGE_REVISION: \"(r[0-9]+)\""},
      "registry": {"backend": "ghcr", "host": "ghcr.io", "image": "acme/app-image"}}},
    "ci": {"backend": "external:tools/ci_adapter.py"}}' ok
  vcase "merge: an external registry adapter" '{"merge": {"deny_globs": [], "image_bump": {"registry": {"backend": "external:tools/reg.py", "host": "registry.example.test:5000", "image": "team/app"}}}}' ok
  vcase "merge: a deny glob that is absolute" '{"merge": {"deny_globs": ["/srv/data/**"]}}' 'merge.deny_globs[0]'
  vcase "merge: a deny glob with .." '{"merge": {"deny_globs": ["docs/../clusters/**"]}}' 'merge.deny_globs[0]'
  vcase "merge: a deny glob with a . segment" '{"merge": {"deny_globs": ["./clusters/**"]}}' 'merge.deny_globs[0]'
  vcase "merge: a deny glob with a class" '{"merge": {"deny_globs": ["ok/**", "[cC]lusters/**"]}}' 'merge.deny_globs[1]'
  vcase "merge: a deny glob with braces" '{"merge": {"deny_globs": ["{a,b}/**"]}}' 'merge.deny_globs[0]'
  vcase "merge: a deny glob with ** inside a segment" '{"merge": {"deny_globs": ["a**b"]}}' 'merge.deny_globs[0]'
  vcase "merge: an empty deny glob" '{"merge": {"deny_globs": [""]}}' 'merge.deny_globs[0]'
  vcase "merge: a deny glob with an empty segment" '{"merge": {"deny_globs": ["a//b"]}}' 'merge.deny_globs[0]'
  vcase "merge: a deny glob with a backslash" '{"merge": {"deny_globs": ["a\\b"]}}' 'merge.deny_globs[0]'
  vcase "merge: deny globs as a string" '{"merge": {"deny_globs": "clusters/**"}}' 'merge.deny_globs'
  vcase "merge: an unknown key under merge" '{"merge": {"deny": []}}' 'warn:merge.deny: unknown key'
  vcase "merge: admin bypass as a word" '{"merge": {"admin_bypass": "yes"}}' 'merge.admin_bypass'
  vcase "merge: an empty required check name" '{"merge": {"required_checks": [""]}}' 'merge.required_checks[0]'
  vcase "merge: required checks as a string" '{"merge": {"required_checks": "test"}}' 'merge.required_checks'
  vcase "merge: the lane on without a registry" '{"merge": {"image_bump": {"enabled": true, "tag_files": ["deploy/app.yaml"]}}}' 'merge.image_bump.registry'
  vcase "merge: the lane on without a tag file" '{"merge": {"image_bump": {"enabled": true, "tag_files": [], "registry": {"backend": "ghcr", "host": "ghcr.io", "image": "acme/app"}}}}' 'merge.image_bump.tag_files'
  vcase "merge: an unknown registry backend" '{"merge": {"image_bump": {"registry": {"backend": "quay", "host": "quay.io", "image": "acme/app"}}}}' 'merge.image_bump.registry.backend'
  vcase "merge: an external registry adapter outside the repo" '{"merge": {"image_bump": {"registry": {"backend": "external:/opt/reg.py", "host": "r.test", "image": "a/b"}}}}' 'merge.image_bump.registry.backend'
  vcase "merge: a registry without a host" '{"merge": {"image_bump": {"registry": {"backend": "ghcr", "image": "acme/app"}}}}' 'merge.image_bump.registry.host'
  vcase "merge: a ghcr registry on another host" '{"merge": {"image_bump": {"registry": {"backend": "ghcr", "host": "quay.io", "image": "acme/app"}}}}' 'merge.image_bump.registry.host'
  vcase "merge: an image name in upper case" '{"merge": {"image_bump": {"registry": {"backend": "ghcr", "host": "ghcr.io", "image": "Acme/App"}}}}' 'merge.image_bump.registry.image'
  vcase "merge: a tag file outside the repo" '{"merge": {"image_bump": {"tag_files": ["/srv/app.yaml"]}}}' 'merge.image_bump.tag_files[0]'
  vcase "merge: an image tree with .." '{"merge": {"image_bump": {"tree": "../image/"}}}' 'merge.image_bump.tree'
  vcase "merge: a revision pattern without a group" '{"merge": {"image_bump": {"revision": {"file": "rev.txt", "pattern": "r[0-9]+"}}}}' 'merge.image_bump.revision.pattern'
  vcase "merge: a revision without its file" '{"merge": {"image_bump": {"revision": {"pattern": "(r[0-9]+)"}}}}' 'merge.image_bump.revision.file'
  vcase "merge: a log path with .." '{"merge": {"log": "../merge.jsonl"}}' 'merge.log'
  vcase "merge: an absolute log path" '{"merge": {"log": "/var/log/merge.jsonl"}}' 'merge.log'
  vcase "merge: a log path that is a directory" '{"merge": {"log": "logs/"}}' 'merge.log'
  vcase "merge: a log path into a subdirectory (the baton state is one)" '{"merge": {"log": "baton/mode"}}' 'merge.log'
  vcase "merge: a log named baton" '{"merge": {"log": "baton"}}' 'merge.log'
  vcase "ci: an unknown CI backend" '{"ci": {"backend": "jenkins"}}' 'ci.backend'
  vcase "ci: an external CI adapter outside the repo" '{"ci": {"backend": "external:../ci.py"}}' 'ci.backend'
  vcase "ci: an external CI adapter path with a ./ segment (it would not equal the path git prints)" '{"ci": {"backend": "external:./tools/ci.py"}}' 'ci.backend'
  vcase "merge: a registry adapter path with a trailing /" '{"merge": {"image_bump": {"registry": {"backend": "external:tools/reg.py/", "host": "r.test", "image": "a/b"}}}}' 'merge.image_bump.registry.backend'
  vcase "merge: a log named BATON (the baton directory on a case-insensitive disk)" '{"merge": {"log": "BATON"}}' 'merge.log'
  vcase "merge: a log name with a newline" '{"merge": {"log": "x\n"}}' 'merge.log'
  vcase "merge: a planner (the --behind auto contract)" '{"merge": {"planner": {"script": "tests/plan.py", "inputs": ["tests/suites.map", "tests/map-exclusions.txt"]}}}' ok
  vcase "merge: no planner (null)" '{"merge": {"planner": null}}' ok
  vcase "merge: a planner script outside the repo" '{"merge": {"planner": {"script": "../plan.py", "inputs": []}}}' 'merge.planner.script'
  vcase "merge: a planner input that is absolute" '{"merge": {"planner": {"script": "tests/plan.py", "inputs": ["/srv/map.txt"]}}}' 'merge.planner.inputs[0]'
  vcase "merge: planner inputs as a string" '{"merge": {"planner": {"script": "tests/plan.py", "inputs": "tests/suites.map"}}}' 'merge.planner.inputs'
  vcase "merge: a planner without its inputs list" '{"merge": {"planner": {"script": "tests/plan.py"}}}' 'merge.planner.inputs'
  out=$(cd "$TMP" && cenv python3 "$PLX/scripts/sdlc_config.py" get merge.deny_globs --default 2>&1); rc=$?
  eq "$rc:$out" "0:null" "[M] the plugin default of merge.deny_globs is null (unset: the guard fails closed)"
  out=$(cd "$TMP" && cenv python3 "$PLX/scripts/sdlc_config.py" get ci.backend --default 2>&1)
  eq "$out" "github-actions" "[M] the plugin default of ci.backend is github-actions"
  out=$(cd "$TMP" && cenv python3 "$PLX/scripts/sdlc_config.py" get merge.admin_bypass --default 2>&1)
  eq "$out" "false" "[M] the plugin default of merge.admin_bypass is false"
  out=$(cd "$TMP" && cenv python3 "$PLX/scripts/sdlc_config.py" get merge.planner --default 2>&1)
  eq "$out" "null" "[M] the plugin default of merge.planner is null (no planner: --behind auto takes its docs-only fallback)"
  # the deny floor follows the config's rules.dirs: merge_deny_floor(dirs) is the default plus <dir>/** for each folder under .vibemaestro/
  fl() { (cd "$TMP" && cenv python3 -I -B -c 'import json, sys
sys.path.insert(0, sys.argv[1] + "/scripts")
import sdlc_config as C
try:
    got, base = list(C.merge_deny_floor(json.loads(sys.argv[2]))), list(C.MERGE_DENY_DEFAULT)
except AttributeError:
    print("no merge_deny_floor"); sys.exit()
print(json.dumps(got[len(base):]) if got[:len(base)] == base else "not the default first")' "$PLX" "$1" 2>&1); }
  eq "$(fl '[]')" "[]" "[M] floor: no rules.dirs gives the default and nothing more"
  eq "$(fl '[".vibemaestro/rules"]')" "[]" "[M] floor: the scaffold's rules folder is in the default already (the init-kb list stays equal)"
  eq "$(fl '[".vibemaestro/policies"]')" '[".vibemaestro/policies/**"]' "[M] floor: a rules folder under .vibemaestro/ with another name is added"
  eq "$(fl '[".vibemaestro/policies/", ".vibemaestro/policies"]')" '[".vibemaestro/policies/**"]' "[M] floor: a trailing slash and a repeat add it once"
  eq "$(fl '[".vibemaestro"]')" '[".vibemaestro/**"]' "[M] floor: .vibemaestro itself as the rules folder denies the whole directory (the owner's choice)"
  eq "$(fl '["docs/rules", "kb/rules"]')" "[]" "[M] floor: a folder outside .vibemaestro/ adds nothing"
  eq "$(fl '[".vibemaestro/a*b", ".vibemaestro/x?y"]')" '[".vibemaestro/a*b/**", ".vibemaestro/x?y/**"]' "[M] floor: * and ? in a folder name stay (it denies that folder and perhaps a neighbour: fail closed)"
  eq "$(fl '[".vibemaestro/p[1]", ".vibemaestro/q{a}", ".vibemaestro/r]"]')" '[".vibemaestro/p?1?/**", ".vibemaestro/q?a?/**", ".vibemaestro/r?/**"]' "[M] floor: a class or brace character in a folder name becomes ? (the glob language cannot spell it, and a folder must not go undenied)"
  eq "$(fl '[".vibemaestro/a**b"]')" '[".vibemaestro/a*b/**"]' "[M] floor: a run of * in a name is one *"
  eq "$(fl '5')|$(fl '"x"')|$(fl '[5, null, ""]')" "[]|[]|[]" "[M] floor: rules.dirs that is not a list of paths adds nothing and does not crash"
}

FAMILIES="fam_defaults fam_validate fam_merge fam_exit fam_activation fam_hooks_warn fam_rules fam_check fam_knobs fam_timing"
PL0="$TMP/plugin-real"; mk_plugin_copy "$PL0"
[ -f "$PL0/scripts/sdlc_config.py" ] && ok "instrument: the plugin copy has the loader" || bad "instrument: the loader is missing from the copy"
[ -f "$SHAPED/.vibemaestro/sdlc.json" ] && ok "instrument: the hub-shaped fixture has its config" || bad "instrument: the fixture is incomplete"
for f in $FAMILIES; do echo "-- $f"; "$f" "$PL0"; done

echo "== planted breaks: each family must go red on a plugin with one break =="
BRK() {  # BRK <label> <family> <needle> <file under scripts/> <old> <new>
  local d="$TMP/break-$1"; mk_plugin_copy "$d"
  mutate "$d/scripts/$4" "$5" "$6" && expect_red "$1" "$2" "$d" "$3"
}
BRK round-pattern-group-unchecked fam_validate '[V] a round pattern without a capture group: rc 65' sdlc_config.py '        if rx.groups < 1:' '        if False:'
BRK round-pattern-never-warned fam_validate "[V] a round pattern in upper case: a warning names" kb.py '    if C.round_never_matches(cfg["commits"]["round_pattern"]):' '    if False:'
BRK round-pattern-scoped-flag-ignored fam_validate '[V] a round pattern with a scoped (?i:...)' sdlc_config.py '            inner = (fold or bool(av[1] & re.IGNORECASE)) and not av[2] & re.IGNORECASE' '            inner = fold'
BRK round-pattern-scoped-unflag-ignored fam_validate '[V] a round pattern whose upper-case part is switched back' sdlc_config.py ' and not av[2] & re.IGNORECASE' ''
BRK round-pattern-atomic-unwalked fam_validate '[V] a round pattern in an atomic group in upper case: a warning' sdlc_config.py '        if name == "ATOMIC_GROUP":' '        if False:'
BRK round-pattern-lookahead-unwalked fam_validate '[V] a round pattern behind an upper-case lookahead: a warning' sdlc_config.py '        if name == "ASSERT":' '        if False:'
BRK round-pattern-branch-all fam_validate '[V] a round pattern whose other branch can match' sdlc_config.py '            return any(_round_can_match(alt, fold) for alt in av[1])' '            return all(_round_can_match(alt, fold) for alt in av[1])'
BRK round-pattern-fold-ignored fam_validate '[V] a round pattern in upper case under (?i)' sdlc_config.py "bool(rx.flags & re.IGNORECASE)" "False"
BRK bad-regex-accepted fam_validate '[V] bad regex: rc 65' sdlc_config.py '            re.compile(v)' '            pass'
BRK planner-script-unchecked fam_merge '[V] merge: a planner script outside the repo: rc 65' sdlc_config.py '"planner": ("objnull", {"script": ("gitfile",),' '"planner": ("objnull", {"script": _STR,'
BRK deprecation-unnoted fam_knobs '[V] pr.flow (deprecated): valid, with a warning that names it: a warning names' sdlc_config.py '        if not d.get("removed") and _lookup(data, key)[0]:' '        if False:'
BRK unknown-key-refused fam_validate '[V] unknown key: a warning, not a problem (rule config-compat): valid, rc 0' sdlc_config.py '            out.append((_safe(dotted), Note(_deprecation_note(dotted, gone) if gone and gone.get("removed") else UNKNOWN_NOTE)))' '            out.append((dotted, "unknown key"))'
BRK unknown-key-silent fam_validate "[V] unknown key: a warning, not a problem (rule config-compat): a warning names" kb.py '        lines = ["WARNING %s: %s" % (k, why) for k, why in C.load_notes(root)] + lines' '        pass'
BRK runner-default-form-noted fam_validate '[V] ci.runner_default: the self-hosted-only form is a valid value, with no warning' sdlc_config.py '    if _text(rd) and rd != RUNNER_SELF_HOSTED_ONLY and not RUNNER_LABEL.fullmatch(rd):' '    if _text(rd) and not RUNNER_LABEL.fullmatch(rd):'
BRK runner-default-near-miss-silent fam_validate '[V] ci.runner_default: neither a label nor the form (a near miss) warns, install-gates refuses it: a warning names' sdlc_config.py '    if _text(rd) and rd != RUNNER_SELF_HOSTED_ONLY and not RUNNER_LABEL.fullmatch(rd):' '    if False:'
BRK wrong-type-ignored fam_validate '[V] a known key with a wrong type still refuses: rc 65' sdlc_config.py '    probs = [p for p in out if not isinstance(p[1], Note)]' '    probs = []'
BRK kb-warn-zero-accepted fam_validate '[V] kb.spec_warn_bytes zero: rc 65' sdlc_config.py '    "kb": ("obj", {"spec_warn_bytes": ("intnull", 1)}),' '    "kb": ("obj", {"spec_warn_bytes": ("intnull", 0)}),'
BRK newer-schema-accepted fam_validate "[V] schema above the plugin's: rc 65" sdlc_config.py 'if _is_int(schema) and schema > SCHEMA:' 'if False:'
BRK underscore-not-ignored fam_validate '[V] keys that start with an underscore' sdlc_config.py '        if k.startswith("_"):
            continue
        if k not in fields:' '        if k not in fields:'
BRK boolean-is-integer fam_validate '[V] a boolean where an integer' sdlc_config.py 'return isinstance(v, int) and not isinstance(v, bool)' 'return isinstance(v, int)'
BRK recursion-uncaught fam_validate '[V] a deeply nested file: rc 65' sdlc_config.py '    except (OSError, ValueError, RecursionError) as e:' '    except (OSError, ValueError) as e:'
BRK control-char-accepted fam_validate '[V] a NUL character in a rule directory' sdlc_config.py "any(ord(c) < 32 or ord(c) == 127 for c in v)" "False"
BRK non-finite-accepted fam_validate '[V] NaN as a wait' sdlc_config.py 'not math.isfinite(v) or ' ''
BRK surrogate-accepted fam_validate '[V] a lone surrogate in a token' sdlc_config.py '        v.encode("utf-8")
    except UnicodeEncodeError:' '        pass
    except UnicodeEncodeError:'
BRK directory-is-absent fam_validate '[V] a directory where the config file should be' sdlc_config.py '    if not os.path.lexists(path):
        return None, [], False' '    if not os.path.isfile(path):
        return None, [], False'
BRK prefix-unchecked fam_validate '[V] intent prefix with a space' sdlc_config.py 'all(_REF_SEG.match(seg) and ".." not in seg and not seg.endswith(".lock")' 'all(True'
BRK merge-glob-dotdot-accepted fam_merge '[V] merge: a deny glob with ..: rc 65' sdlc_config.py '    if any(seg in ("", ".", "..") for seg in segs):' '    if False:'
BRK merge-glob-class-accepted fam_merge '[V] merge: a deny glob with a class: rc 65' sdlc_config.py 'any(c in g for c in GLOB_BAD_CHARS)' 'False'
BRK merge-glob-starstar-accepted fam_merge '[V] merge: a deny glob with ** inside a segment: rc 65' sdlc_config.py '    return all("**" not in seg or seg == "**" for seg in segs)' '    return True'
BRK merge-lane-without-registry fam_merge '[V] merge: the lane on without a registry: rc 65' sdlc_config.py '    if v.get("enabled") is True and v.get("registry") is None:' '    if False:'
BRK merge-floor-class-skipped fam_merge '[M] floor: a class or brace character in a folder name becomes ?' sdlc_config.py 'g = re.sub(r"\*+", "*", re.sub(r"[\[\]{}]", "?", norm)) + "/**"' 'g = norm + "/**"'
BRK merge-floor-ignores-dirs fam_merge '[M] floor: a rules folder under .vibemaestro/ with another name is added' sdlc_config.py '    return list(MERGE_DENY_DEFAULT) + extra' '    return list(MERGE_DENY_DEFAULT)'
BRK merge-deny-default-open fam_merge '[M] the plugin default of merge.deny_globs is null' sdlc_config.py '"merge": {"deny_globs": None,' '"merge": {"deny_globs": [],'
BRK merge-log-any-path fam_merge '[V] merge: a log path into a subdirectory (the baton state is one): rc 65' sdlc_config.py 'if v is not None and (not isinstance(v, str) or not _LOG_NAME.fullmatch(v) or v.lower() == "baton"):' 'if v is not None and not _rel_ok(v):'
BRK adapter-path-unnormalised fam_merge '[V] ci: an external CI adapter path with a ./ segment' sdlc_config.py '(v.startswith("external:") and _git_path_ok(v[len("external:"):]) and not v.endswith("/"))' '(v.startswith("external:") and _rel_ok(v[len("external:"):]))'
BRK merge-ghcr-any-host fam_merge '[V] merge: a ghcr registry on another host: rc 65' sdlc_config.py '    if reg.get("backend") == "ghcr" and reg.get("host") != "ghcr.io":' '    if False:'
BRK default-changed fam_defaults '[D2] …and a draft key is absent' sdlc_config.py '        "draft": False,' '        "draft": True,'
BRK agents-default-changed fam_defaults '[D4] no config: sdlc_config.py get agents.*' sdlc_config.py '"review_model": "opus", "search_model"' '"review_model": "fable", "search_model"'
BRK agents-repo-value-ignored fam_defaults '[D4] …a repo value wins' sdlc_config.py '    return _normalise(_merge(_with_preset(data), data))' '    return _normalise(_merge(_with_preset(data), {k: v for k, v in data.items() if k != "agents"}))'
BRK get-default-reads-file fam_defaults '[D4] …and get --default prints the plugin default' sdlc_config.py '    cfg, probs, _present = (defaults(), [], False) if plain else load(repo_root(root), quiet=True)' '    cfg, probs, _present = load(repo_root(root), quiet=True)'
BRK agents-alias-unchecked fam_validate '[V] agents: an alias the Agent tool does not accept: rc 65' sdlc_config.py 'MODEL_ALIASES = ("fable", "opus", "sonnet", "haiku")' 'MODEL_ALIASES = ("fable", "opus", "sonnet", "haiku", "gpt")'
BRK default-limit-changed fam_defaults '[D3] the effective current-state limits' sdlc_config.py '"limits": {"lines": 120,' '"limits": {"lines": 121,'
BRK broken-plugin-drops-warning fam_hooks_warn '[H] …the config warning arrives although the plugin warning was given' vsdlc.py '    ctx, sysmsg = with_warn(warn, *((warn_text(' '    ctx, sysmsg = (lambda c, s: (c, s))(*((warn_text('
BRK warning-every-time fam_hooks_warn '[H] …and does not warn again in the same session' vsdlc.py 'if once("config-invalid:" + troot, sid) else None' 'if True else None'
BRK notes-never-shown fam_hooks_warn '[H] keys a newer plugin knows: the first call warns' vsdlc.py 'if notes and once("config-notes:" + troot, sid) else None' 'if False else None'
BRK hook-dies-on-bad-config fam_hooks_warn '[H] a broken config: the hook still exits 0' vsdlc.py '    cfg, probs, _present = C.load(troot, quiet=True)
    if probs:
' '    cfg, probs, _present = C.load(troot, quiet=True)
    if probs:
        os._exit(2)
'
BRK hooks-off-ignored fam_activation '[A] hooks off: the reminder hook is silent' vsdlc.py 'return cfg, cfg["hooks"] == "off", warn' 'return cfg, False, warn'
BRK markers-silence-restored fam_activation '[A] no config, markers (not silent since 2.0.0): the reminder hook is active' vsdlc.py 'return cfg, cfg["hooks"] == "off", warn' 'return cfg, cfg["hooks"] == "off" or all(m in (read_text(os.path.join(troot, ".claude", "settings.json")) or "") for m in ("instructions-for-path.py", "instructions-for-command.py")), warn'
BRK markers-refusal-restored fam_activation '[A] no config, markers (not silent since 2.0.0): kb.py init exits 0' kb.py '        return 65
    if rest[0] == "base":' '        return 65
    if all(m in (vsdlc.read_text(os.path.join(root, ".claude", "settings.json")) or "") for m in ("instructions-for-path.py", "instructions-for-command.py")):
        return die("refused", 3)
    if rest[0] == "base":'
BRK kb-ignores-bad-config fam_exit '[E] …and nothing was written' kb.py '        return 65
    if rest[0] == "base":' '        pass
    if rest[0] == "base":'
BRK core-ignores-bad-config fam_exit '[E] open_pr.py with an invalid config: rc 64' open_pr.py '        return 64
    tcfg = cfg["pr"]["title"]' '        pass
    tcfg = cfg["pr"]["title"]'
BRK intent-core-ignores-bad-config fam_exit '[E] intent_branch.py with an invalid config: rc 64' intent_branch.py '        return RC_USAGE
    PREFIX = cfg["branch"]["intent_prefix"]' '        pass
    PREFIX = cfg["branch"]["intent_prefix"]'
BRK rules-dirs-ignored fam_rules '[R] …the reminder names the repo'"'"'s own file' rules.py '    for d in repo_dirs(rules_cfg):' '    for d in []:'
BRK replacement-not-applied fam_rules '[R] a same-name repo file replaces the plugin rule' rules.py '        elif n in repo:' '        elif False:'
BRK disable-ignored fam_rules '[R] rules.disable (a name without the suffix)' rules.py '        if n in disabled:' '        if False:'
BRK disable-needs-suffix fam_rules '[R] rules.disable (a name without the suffix)' rules.py '    return name if name.endswith(RULE_SUFFIX) else name + RULE_SUFFIX' '    return name'
BRK draft-rule-delivered fam_rules '[R] a rule whose status is not active' rules.py '    return (front(t, "status") or "active") in ("active", "live")' '    return True'
BRK external-gate-unlisted fam_check '[C] …it is listed for review' kb.py 'if cfg["current_state"]["gate"].startswith("external:"):' 'if False:'
BRK duplicates-unlisted fam_check '[C] …the duplicate paragraph is listed' kb.py '            if para in plugin_paras:' '            if False:'
BRK duplicates-with-disabled-rule fam_check '…no warning when the plugin rule is disabled' kb.py '    rules, paths, notes = R.load_all(plugin, root, rcfg, keep=(vsdlc.CORE_NAME,), packs=packs)' '    rules, paths, notes = R.load_all(plugin, root, {"dirs": rcfg["dirs"], "disable": []}, keep=(vsdlc.CORE_NAME,), packs=packs)'
BRK old-disable-name-unmapped fam_rules '[R] rules.disable with the OLD name of a renamed rule turns the rule off' rules.py '        disabled.add(canonical(old))' '        disabled.add(old)'
BRK old-disable-name-silent fam_rules '[R] …one warning for one old name' rules.py '            notes.append(("renamed", old, RENAMED_RULES[old]))' '            pass'
BRK old-repo-file-unmapped fam_rules '[R] a repo file with the OLD name replaces the renamed plugin rule' rules.py '            n = canonical(fname)' '            n = fname'
BRK old-name-sorts-first fam_rules '[R] an old-name file and a new-name file of one rule in one directory: the new-name file is delivered' rules.py 'key=lambda x: x[0] != canonical(x[0])' 'key=lambda x: x[0]'
BRK old-repo-file-silent fam_rules '[R] …kb.py config check prints one old-name warning' rules.py '                if n != fname:                  # only a delivered file is told to be renamed' '                if False:'
BRK old-repo-file-duplicate fam_rules '[R] hub-shaped fixture + a copy of a plugin rule under its old name: no duplicate rule' rules.py '            n = canonical(fname)' '            n = fname'
BRK unknown-disable-silent fam_check '[C] …the unknown disable name is listed' kb.py '            out.append("WARNING rules.disable: %s matches no plugin rule" % n)' '            pass'
BRK intent-prefix-ignored fam_knobs '[K] …the branch is feat/k1' intent_branch.py '    PREFIX = cfg["branch"]["intent_prefix"]' '    PREFIX = "intent/"'
BRK protected-ignored-core fam_knobs '[K] branch.protected is read by intent_branch' intent_branch.py '    PROTECTED = tuple(cfg["branch"]["protected"])' '    PROTECTED = ("main", "master")'
BRK protected-ignored-pr fam_knobs '[K] branch.protected: --head trunk is refused' open_pr.py '    if head in cfg["branch"]["protected"]:' '    if head in ("main", "master"):'
BRK title-pattern-ignored fam_knobs '[K] pr.title.pattern: a title that does not match' open_pr.py 'if tcfg["pattern"] and not re.search(tcfg["pattern"], a.title):' 'if False:'
BRK title-length-ignored fam_knobs '[K] pr.title.max_len: a title over the length' open_pr.py 'if tcfg["max_len"] and len(a.title) > tcfg["max_len"]:' 'if False:'
BRK draft-config-ignored fam_knobs '[K] pr.draft true: the payload is a draft' open_pr.py '    if a.draft or cfg["pr"]["draft"]:' '    if a.draft:'
BRK closing-keyword-ignored fam_knobs '[K] pr.closing.keyword: the body starts' open_pr.py '(cfg["pr"]["closing"]["keyword"], n)' '("Closes", n)'
BRK closing-verify-ignored fam_knobs '[K] …and gh pr view is never asked' open_pr.py 'if m and closes and (closing or {}).get("verify", True):' 'if m and closes:'
BRK closing-tries-ignored fam_knobs '[K] pr.closing.tries: a link that never appears' open_pr.py '    tries = int(closing.get("tries", LINK_TRIES))' '    tries = LINK_TRIES'
BRK closing-wait-ignored fam_timing '[K] pr.closing.wait_s is ignored' open_pr.py 'float(closing.get("wait_s", LINK_WAIT_S))' 'LINK_WAIT_S'
BRK closing-deadline-ignored fam_timing '[K] pr.closing.deadline_s is ignored' open_pr.py 'float(closing.get("deadline_s", LINK_DEADLINE_S))' 'LINK_DEADLINE_S'
BRK token-summary-ignored fam_knobs '[K] tokens: the summary heading' open_pr.py 'tk["summary_heading"], summ, crit_block' '"Tóm tắt", summ, crit_block'
BRK token-fixes-ignored fam_knobs '[K] …the fixes line' open_pr.py '(tk["fixes_line"], n)' '("Vá cho", n)'
BRK token-not-run-ignored fam_knobs '[K] tokens.not_run: the configured token' open_pr.py 'exempt = ev.lstrip().startswith(tk["not_run"])' 'exempt = ev.lstrip().startswith("KHÔNG CHẠY:")'
BRK adapter-prefix-literal fam_knobs '[K] open-pr.sh reads issue: N' open-pr.sh '        "$PFX"?*)' '        intent/*)'
BRK adapter-count-prefix-literal fam_knobs '[K] intent-branch.sh counts commits against the configured prefix' intent-branch.sh 'case "$I" in "$PFX"*) ;; *) I="$PFX$I" ;; esac' 'case "$I" in intent/*) ;; *) I="intent/$I" ;; esac'
PLC="$TMP/break-none"; mk_plugin_copy "$PLC"
QN=0; okdef=$(declare -f ok); baddef=$(declare -f bad); sp=$PASS; sf=$FAIL
ok() { :; }; bad() { QN=$((QN+1)); }
for f in $FAMILIES; do "$f" "$PLC" >/dev/null 2>&1; done
eval "$okdef"; eval "$baddef"; PASS=$sp; FAIL=$sf
eq "$QN" 0 "control: an unbroken copy passes every family (no failed check)"

echo; summary
