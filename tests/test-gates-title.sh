#!/bin/bash
# =============================================================================
# Gate: PR title and branch (plugins/vibemaestro-sdlc/gates/pr_title.py), the families of the hub's two title tests plus the new keys
# =============================================================================
# Run: bash tests/test-gates-title.sh
#
#   [I] the intent-file form (pr.title.intent_form: reject): the stdin form, as the hub's gate had it
#   [K] pr.title.pattern, pr.title.max_len, branch.pattern, and the default (nothing configured: everything passes)
#   [G] --pr through a fake gh: baseline red and green, --paginate required, a draft read as a draft, the branch name, gh failing
#   [B] the base-ref rule: a PR that relaxes its own title rule is judged by the old one; bad refs, bad config, bad usage
# Each family also runs on a copy of the plugin with ONE planted break and must go red. Real git, a fake gh, no network, no sleep.
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
[ -f "$PLUGIN/gates/pr_title.py" ] && ok "the gate exists" || { bad "the gate is missing"; summary; exit 1; }

PT() { printf '%s' "$1/gates/pr_title.py"; }
# tj <plugin> <repo> <json> [gate args...] — the stdin form, run in <repo> (its config is the gate's config)
tj() {
  local p=$1 r=$2 j=$3; shift 3
  RC=0; OUT=$(printf '%s' "$j" | cenv python3 "$(PT "$p")" --cwd "$r" "$@" 2>&1) || RC=$?
}
cfgrepo() { local r; r=$(mk_repo t); put_cfg "$r" "$1"; echo "$r"; }
REJECT='{"pr": {"title": {"intent_form": "reject"}}}'

fam_intent() {
  local p=$1 r; r=$(cfgrepo "$REJECT")
  tj "$p" "$r" '{"title":"docs(kb): intent x","draft":false,"files":["kb/intent/x.md","src/a.yaml"]}'; want 1 "[I] docs(kb) title with a file outside kb/: red" "INTENT-FILE form"
  tj "$p" "$r" '{"title":"intent: Feature X","draft":false,"files":["services/x/y.yaml"]}'; want 1 "[I] the 'intent:' form with a file outside kb/: red"
  tj "$p" "$r" '{"title":"docs(kb): decision ABC","draft":false,"files":["kb/decisions/x.md"]}'; want 0 "[I] docs(kb) but the diff only has kb/: green (not a lie)"
  tj "$p" "$r" '{"title":"fix(api): correct syntax","draft":false,"files":["src/a.yaml"]}'; want 0 "[I] a title already in the type(scope) form: green"
  tj "$p" "$r" '{"title":"docs(intent): enable tracing","draft":false,"files":["src/a.yaml"]}'; want 0 "[I] docs(intent) is not docs(kb): a real type(scope): green"
  tj "$p" "$r" '{"title":"docs(kb): intent x","draft":true,"files":["src/a.yaml"]}'; want 0 "[I] a draft: too early to ask for the real title" "draft"
  tj "$p" "$r" '{"title":"intent: x","draft":false}'; want 1 "[I] intent form, ready, no files in the payload: red (not knowing is not a pass)"
  RC=0; OUT=$(printf 'not-json' | cenv python3 "$(PT "$p")" --cwd "$r" 2>&1) || RC=$?; want 1 "[I] a broken payload is not a pass"
  RC=0; OUT=$(printf '[1]' | cenv python3 "$(PT "$p")" --cwd "$r" 2>&1) || RC=$?; want 1 "[I] a payload that is not an object is not a pass"
  tj "$p" "$r" '{"title":"  INTENT: shouting","draft":false,"files":["src/a"]}'; want 1 "[I] leading space and upper case are still the intent form"
  tj "$p" "$r" '{"title":"docs(kb): intent x","draft":false,"files":["kb/a.md","kb-notes/b.md"]}'; want 1 "[I] kb-notes/ is not kb/: a prefix match on the directory name, not on the letters"
  tj "$p" "$r" '{"title":"docs(kb): intent x","draft":false,"files":[]}'; want 0 "[I] an empty file list: nothing outside kb/, green"
  # the default (intent_form allow): the same payload that is red under reject is green
  r=$(cfgrepo '{}'); tj "$p" "$r" '{"title":"docs(kb): intent x","draft":false,"files":["src/a.yaml"]}'; want 0 "[I] control: with no config the same payload is green (the check is off)" "does not apply"
  r=$(cfgrepo '{"pr": {"title": {"intent_form": "allow"}}}'); tj "$p" "$r" '{"title":"intent: x","draft":false,"files":["src/a.yaml"]}'; want 0 "[I] intent_form allow: green"
}

fam_keys() {
  local p=$1 r
  r=$(cfgrepo '{"pr": {"title": {"pattern": "^(feat|fix|docs)(\\([a-z0-9._-]+\\))?: .{3,}$"}}}')
  tj "$p" "$r" '{"title":"feat(gates): add the gate","draft":false,"files":[]}'; want 0 "[K] a title that matches pr.title.pattern: green"
  tj "$p" "$r" '{"title":"added the gate","draft":false,"files":[]}'; want 1 "[K] a title that does not match: red" "pr.title.pattern"
  tj "$p" "$r" '{"title":"added the gate","draft":true,"files":[]}'; want 1 "[K] the pattern applies to a draft too"
  tj "$p" "$r" '{"draft":false,"files":[]}'; want 1 "[K] no title at all does not match"
  r=$(cfgrepo '{"pr": {"title": {"pattern": "gate"}}}'); tj "$p" "$r" '{"title":"add the gate now","draft":false,"files":[]}'; want 0 "[K] the pattern is searched, not anchored (re.search, as open_pr.py does)"
  r=$(cfgrepo '{"pr": {"title": {"max_len": 20}}}')
  tj "$p" "$r" '{"title":"12345678901234567890","draft":false,"files":[]}'; want 0 "[K] a title of exactly max_len characters: green"
  tj "$p" "$r" '{"title":"123456789012345678901","draft":false,"files":[]}'; want 1 "[K] max_len + 1: red" "over pr.title.max_len (20)"
  tj "$p" "$r" "{\"title\":\"$(printf '\303\251%.0s' $(seq 1 20))\",\"draft\":false,\"files\":[]}"; want 0 "[K] length is counted in characters, not bytes (20 accented characters)"
  r=$(cfgrepo '{"branch": {"pattern": "^(feat|fix)/[a-z0-9-]+$"}}')
  tj "$p" "$r" '{"title":"x","draft":false,"files":[],"head":"feat/new-gate"}'; want 0 "[K] a branch that matches branch.pattern: green"
  tj "$p" "$r" '{"title":"x","draft":false,"files":[],"head":"my_branch"}'; want 1 "[K] a branch that does not: red" "branch.pattern"
  tj "$p" "$r" '{"title":"x","draft":false,"files":[],"head":"intent/2026-10-14-x"}'; want 0 "[K] an intent/ branch is exempt from branch.pattern (branch.intent_prefix)"
  tj "$p" "$r" '{"title":"x","draft":false,"files":[]}'; want 1 "[K] branch.pattern set and no head in the payload: red (not knowing is not a pass)"
  r=$(cfgrepo '{"branch": {"pattern": "^feat/", "intent_prefix": "work/"}}')
  tj "$p" "$r" '{"title":"x","draft":false,"files":[],"head":"work/x"}'; want 0 "[K] the exempt prefix is the configured one"
  tj "$p" "$r" '{"title":"x","draft":false,"files":[],"head":"intent/x"}'; want 1 "[K] …and intent/ is no longer exempt"
  r=$(cfgrepo '{}'); tj "$p" "$r" '{"title":"anything goes","draft":false,"files":["a"],"head":"any_thing"}'; want 0 "[K] nothing configured: everything passes" "does not apply"
  r=$(cfgrepo '{"pr": {"title": {"pattern": "^feat", "max_len": 10, "intent_form": "reject"}}, "branch": {"pattern": "^feat/"}}')
  tj "$p" "$r" '{"title":"docs(kb): intent that is long","draft":false,"files":["src/a"],"head":"bad"}'; want 1 "[K] all four problems are reported together"
  [ "$(printf '%s' "$OUT" | grep -o 'pr.title.pattern\|max_len\|branch.pattern\|INTENT-FILE' | sort -u | wc -l | tr -d ' ')" = 4 ] && ok "[K] …each named once" || bad "[K] not all four problems are named: $OUT"
}

# the fake gh: the view JSON and the file list of a PR numbered 246, one file per page
fam_gh() {
  local p=$1 d r
  d=$(mktemp -d "$TMP/gh.XXXXXX"); install_gate_gh "$d/bin" >/dev/null; r=$(cfgrepo '{"pr": {"title": {"intent_form": "reject"}}, "branch": {"pattern": "^feat/"}}')
  prun() {  # prun <view json> <files json list> [extra fixture json]
    python3 - "$d/fx.json" "$1" "$2" "${3:-{\}}" <<'PY'
import json, sys
out, view, files, extra = sys.argv[1:5]
fx = {"pr view": json.loads(view), "pulls/246/files": json.loads(files), "__require_paginate__": True}
fx.update(json.loads(extra)); json.dump(fx, open(out, "w"))
PY
    : > "$d/gh.log"
    RC=0; OUT=$(cenv PATH="$d/bin:$PATH" FAKE_GH_LOG="$d/gh.log" FAKE_GH_FX="$d/fx.json" python3 "$(PT "$p")" --cwd "$r" --pr 246 "${@:4}" 2>&1) || RC=$?
  }
  prun '{"title":"docs(kb): intent x","isDraft":false,"headRefName":"feat/x"}' '["kb/intent/x.md","src/a.yaml"]'; want 1 "[G] positive control: ready, intent form, a file outside kb/: red" "INTENT-FILE form"
  prun '{"title":"fix(api): fix","isDraft":false,"headRefName":"feat/x"}' '["src/a.yaml"]'; want 0 "[G] ready, a proper title: green"
  # the file list is served one file per page: without --paginate only kb/a.md is seen and the PR would pass as "only kb/"
  prun '{"title":"intent: x","isDraft":false,"headRefName":"feat/x"}' '["kb/a.md","src/b.yaml"]'; want 1 "[G] a file outside kb/ on page 2 is seen: --paginate is passed"
  grep -qF -- '--paginate' "$d/gh.log" && ok "[G] …the log shows the call with --paginate" || bad "[G] no --paginate in the gh calls"
  prun '{"title":"docs(kb): intent y","isDraft":true,"headRefName":"feat/x"}' '["kb/y.md","src/c.yaml"]'; want 0 "[G] a draft is read as a draft: green" "draft"
  prun '{"title":"fix: x","isDraft":false,"headRefName":"wrong_branch"}' '["src/c.yaml"]'; want 1 "[G] the head branch comes from gh pr view (headRefName): branch.pattern red" "branch.pattern"
  prun '{"title":"fix: x","isDraft":false,"headRefName":"feat/ok"}' '["src/c.yaml"]' '{"__fail__": true}'; want 2 "[G] gh failing: rc 2, not green"
  prun '{"title":"fix: x","isDraft":false,"headRefName":"feat/ok"}' '["src/c.yaml"]'
  RC=0; OUT=$(cenv PATH="$d/bin:$PATH" FAKE_GH_LOG="$d/gh.log" FAKE_GH_FX="$d/fx.json" python3 "$(PT "$p")" --cwd "$r" --pr 246 --repo acme/service 2>&1) || RC=$?
  want 0 "[G] --repo is accepted" ; grep -qF 'repos/acme/service/pulls/246/files' "$d/gh.log" && grep -qF -- '-R acme/service' "$d/gh.log" && ok "[G] …and passed to both gh calls" || bad "[G] --repo not passed: $(cat "$d/gh.log")"
  RC=0; OUT=$(cenv PATH="$d/bin:$PATH" FAKE_GH_LOG="$d/gh.log" FAKE_GH_FX="$d/fx.json" python3 "$(PT "$p")" --cwd "$r" --pr 2>&1) || RC=$?
  want 64 "[G] --pr with no number is usage, rc 64"
}

fam_base() {
  local p=$1 r
  r=$(mk_repo base); commit_cfg "$r" '{"pr": {"title": {"max_len": 20}}}' "base: config"; G -C "$r" branch base
  G -C "$r" checkout -qb pr; commit_cfg "$r" '{"pr": {"title": {"max_len": 200}}}' "head: relaxes max_len"
  local long='{"title":"a title that is much longer than twenty","draft":false,"files":[]}'
  tj "$p" "$r" "$long" --config-ref base; want 1 "[B] a PR that raises its own pr.title.max_len is judged by the base: red" "max_len (20)"
  tj "$p" "$r" "$long"; want 0 "[B] control: without the ref the head's config applies: green"
  commit_cfg "$r" '{"branch": {"pattern": "^feat/"}}' "head: another rule"
  tj "$p" "$r" '{"title":"x","draft":false,"files":[],"head":"nope"}' --config-ref base; want 0 "[B] a branch.pattern that exists only in the head is not applied under the base ref"
  tj "$p" "$r" '{"title":"x","draft":false,"files":[],"head":"nope"}'; want 1 "[B] …and is applied without it"
  tj "$p" "$r" "$long" --config-ref no-such-ref; want 2 "[B] a ref that does not read: rc 2, not green"
  r=$(mk_repo nocfg); G -C "$r" branch base; put_cfg "$r" '{"pr": {"title": {"max_len": 5}}}'
  tj "$p" "$r" "$long" --config-ref base; want 0 "[B] a base with no config file means the defaults: green"
  tj "$p" "$r" "$long"; want 1 "[B] …control: the working tree's config applies without the ref"
  put_cfg "$r" '{"pr": {"title": {"max_len": 0}}}'; tj "$p" "$r" "$long"; want 65 "[B] an invalid config is rc 65 and names the key" pr.title.max_len
  put_cfg "$r" '{"pr": {"title": {"pattern": "("}}}'; tj "$p" "$r" "$long"; want 65 "[B] a pattern that does not compile is rc 65" pr.title.pattern
  put_cfg "$r" '{"branch": {"pattern": "[a"}}'; tj "$p" "$r" "$long"; want 65 "[B] a bad branch.pattern is rc 65" branch.pattern
  put_cfg "$r" '{"pr": {"title": {"intent_form": "maybe"}}}'; tj "$p" "$r" "$long"; want 65 "[B] an unknown intent_form is rc 65" pr.title.intent_form
  local rb; rb=$(mk_repo badbase); commit_cfg "$rb" '{"pr": {"title": {"max_len": "x"}}}' "base: invalid"; G -C "$rb" branch base
  tj "$p" "$rb" "$long" --config-ref base; want 65 "[B] an invalid config AT THE BASE REF is rc 65 and names the key" pr.title.max_len
  tj "$p" "$r" "$long" --bogus; want 64 "[B] an unknown flag is rc 64"
  python3 - "$p/gates/pr_title.py" <<'PY' && ok "[B] the gate parses as Python 3.8 and imports only the standard library" || bad "[B] the gate is not Python 3.8 or imports something else"
import ast, sys
tree = ast.parse(open(sys.argv[1], encoding="utf-8").read(), feature_version=(3, 8))
allowed = {"json", "re", "subprocess", "sys", "gate_common"}
imports = set()
for n in ast.walk(tree):
    if isinstance(n, ast.Import):
        imports |= {a.name.split(".")[0] for a in n.names}
    elif isinstance(n, ast.ImportFrom):
        imports.add((n.module or "").split(".")[0])
sys.exit(1 if imports - allowed else 0)
PY
}

FAMILIES="fam_intent fam_keys fam_gh fam_base"
for f in $FAMILIES; do "$f" "$PLUGIN"; done

echo "== planted breaks: each turns its family red =="
T=pr_title.py
BRKG draft-ignored fam_intent '[I] a draft: too early' $T '        if draft:
            applied.append("intent_form (draft: not applied)")' '        if False:
            applied.append("intent_form (draft: not applied)")'
BRKG missing-files-pass fam_intent '[I] intent form, ready, no files' $T '        elif files is None:
            applied.append("intent_form")
            problems.append(' '        elif files is None:
            applied.append("intent_form")
            (lambda *a: None)('
BRKG kb-prefix-by-letters fam_intent '[I] kb-notes/ is not kb/' $T 'not f.startswith("kb/")' 'not f.startswith("kb")'
BRKG docs-intent-flagged fam_intent '[I] docs(intent) is not docs(kb)' $T 'PROFILE_RX = re.compile(r"^\s*(intent:|docs\(kb\):)", re.I)' 'PROFILE_RX = re.compile(r"^\s*(intent:|docs\(\w+\):)", re.I)'
BRKG case-sensitive fam_intent '[I] leading space and upper case' $T 'PROFILE_RX = re.compile(r"^\s*(intent:|docs\(kb\):)", re.I)' 'PROFILE_RX = re.compile(r"^\s*(intent:|docs\(kb\):)")'
BRKG intent-form-default-on fam_intent '[I] control: with no config' $T '    if t["intent_form"] == "reject":' '    if True:'
BRKG broken-payload-passes fam_intent '[I] a broken payload is not a pass' $T '        print("FAIL cannot read the payload: %s" % e)
        return gc.RED' '        print("FAIL cannot read the payload: %s" % e)
        return gc.OK'
BRKG pattern-anchored fam_keys '[K] the pattern is searched' $T 're.search(t["pattern"], title)' 're.match(t["pattern"], title)'
BRKG max-len-off-by-one fam_keys '[K] a title of exactly max_len' $T 'len(title) > t["max_len"]' 'len(title) >= t["max_len"]'
BRKG max-len-in-bytes fam_keys '[K] length is counted in characters' $T 'len(title) > t["max_len"]' 'len(title.encode("utf-8")) > t["max_len"]'
BRKG branch-prefix-ignored fam_keys '[K] an intent/ branch is exempt' $T 'elif not head.startswith(prefix) and not re.search' 'elif not re.search'
BRKG branch-prefix-literal fam_keys '[K] the exempt prefix is the configured one' $T 'elif not head.startswith(prefix) and not re.search' 'elif not head.startswith("intent/") and not re.search'
BRKG missing-head-pass fam_keys '[K] branch.pattern set and no head' $T '            problems.append("the payload has no `head`: without the branch name branch.pattern cannot be checked")' '            pass'
BRKG first-problem-only fam_keys '[K] not all four problems are named' $T '        return gc.RED, "; ".join(problems)' '        return gc.RED, problems[0]'
BRKG draft-read-false fam_gh '[G] a draft is read as a draft' $T 'bool(meta.get("isDraft"))' 'False'
BRKG paginate-dropped fam_gh '[G] a file outside kb/ on page 2' $T '"--paginate", "--jq", ".[].filename"]' '"--jq", ".[].filename"]'
BRKG head-ignored fam_gh '[G] ready, a proper title' $T 'meta.get("headRefName"), cfg)' 'None, cfg)'
BRKG gh-failure-green fam_gh '[G] gh failing' $T '        raise gc.Infra("gh %s failed: %s" % (" ".join(args[:2]), p.stderr.decode("utf-8", "replace").strip()[:160]))' '        return "{}"'
BRKG repo-dropped fam_gh '[G] --repo not passed' $T '(["-R", repo] if repo else [])' '[]'
BRKG config-from-head fam_base '[B] a PR that raises its own pr.title.max_len' $T '    cfg = gc.load_config(cwd, ref)' '    cfg = gc.load_config(cwd, None)'
BRKG bad-ref-green fam_base '[B] a ref that does not read' gate_common.py '        raise Infra("ref `%s` does not read" % ref)
    if git(["cat-file"' '        return None
    if git(["cat-file"'
BRKG config-error-swallowed fam_base '[B] an invalid config is rc 65' gate_common.py '        if probs:
            raise ConfigError(sdlc_config.render_problems(probs))
        return cfg' '        return cfg'
BRKG ref-config-error-swallowed fam_base '[B] an invalid config AT THE BASE' gate_common.py '    if probs:
        raise ConfigError(sdlc_config.render_problems(probs) + where)' '    if False:
        raise ConfigError(sdlc_config.render_problems(probs) + where)'

PLC="$TMP/break-none"; mk_plugin_copy "$PLC"
QN=0; okdef=$(declare -f ok); baddef=$(declare -f bad); sp=$PASS; sf=$FAIL
ok() { :; }; bad() { QN=$((QN+1)); }
for f in $FAMILIES; do "$f" "$PLC" >/dev/null 2>&1; done
eval "$okdef"; eval "$baddef"; PASS=$sp; FAIL=$sf
eq "$QN" 0 "control: an unbroken copy passes every family"

echo; summary
