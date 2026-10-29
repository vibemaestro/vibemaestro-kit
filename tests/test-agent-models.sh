#!/bin/bash
# =============================================================================
# Every skill or rule that tells the session to spawn a subagent names its model
# =============================================================================
# Run: bash tests/test-agent-models.sh
#
# A block of a skill or rule (one list item or one paragraph; frontmatter and code fences are skipped) that mentions spawning an agent must name an `agents.*` key of the config contract
# or a model alias next to the word `model`, so a new skill cannot silently drop the choice. Every `agents.*` key a skill or rule
# names must exist in the loader defaults, and the defaults must be one alias per job (review opus, search haiku, worker sonnet).
# The checker runs on the real plugin, then on copies with one planted skill each: a spawn with no model must go red.
# =============================================================================
set -uo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
# shellcheck source=fixtures/lib.sh
. "$HERE/fixtures/lib.sh"

PLUGIN="$SRC_ROOT/plugins/vibemaestro-sdlc"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"

# check <plugin dir> — one line per violation on stdout ("<file>:<line>: <reason>"); then "spawn-blocks N" (blocks that spawn)
CHECKER='
import glob, os, re, sys
sys.dont_write_bytecode = True
plugin = sys.argv[1]
sys.path.insert(0, os.path.join(plugin, "scripts"))
import sdlc_config as C
# what "tells the session to spawn an agent" looks like: any standalone word agent (not an agents.* key), a subagent, the
# Task tool, a worker (not worker_model, not worker-branch), spawn, delegate, dispatch, a fresh context. Wide on purpose: a
# sentence that mentions an agent without spawning one is listed in NOT_SPAWN whole (whitespace collapsed), so a new mention, or
# a spawn added to a listed sentence, fails closed until someone decides which it is; a listed sentence no text has any more is
# reported too
SPAWN = re.compile(r"\bagents?\b(?!\.[a-z_*<])|\bsub-?agents?\b|\bTask tool\b|\bworkers?\b(?![-_])|\bspawn|\bdelegat"
                   r"|\bdispatch|fresh[- ]context|context mới", re.I)
NOT_SPAWN = (
    "What a subagent returns is a claim, not evidence: run the acceptance command again yourself before you believe it.",
    "This rule is for a session that owns the work and may edit files; a session or subagent working from a brief stops and asks about anything outside it.",
    # a GitHub workflow_dispatch run, the kit baton that makes one: no agent
    "`kit:workflow-dispatch` dispatches one `workflow_dispatch` run of a workflow of a private repository, on a branch:",
    "<launcher> go kit:workflow-dispatch --repo <owner/name> --workflow <file.yml> --ref <branch> [--input <key>=<value>]...",
)
used = set()
KEY = re.compile(r"\bagents\.([a-z_]+)\b")
ALIAS = re.compile(r"`(?:%s)`" % "|".join(C.MODEL_ALIASES))
ITEM = re.compile(r"^\s{0,6}(?:[-*]|\d+\.)\s")
ALONE = re.compile(r"^\s*(?:#{1,6}\s|\|)")                    # a heading or a table row is a block of its own

def blocks(path):
    lines = open(path, encoding="utf-8").read().split("\n")
    i = 0
    if lines and lines[0].strip() == "---":                     # frontmatter: a summary, not an instruction
        i = 1
        while i < len(lines) and lines[i].strip() != "---":
            i += 1
        i += 1
    cur, start, fence = [], 0, False
    for n in range(i, len(lines)):
        ln = lines[n]
        if ln.lstrip().startswith("```"):
            fence = not fence
            if cur:
                yield start, "\n".join(cur)
            cur = []
            continue
        if fence:
            continue
        if ALONE.match(ln):
            if cur:
                yield start, "\n".join(cur)
            yield n + 1, ln
            cur = []
            continue
        if not ln.strip() or ITEM.match(ln):
            if cur:
                yield start, "\n".join(cur)
            cur, start = ([ln], n + 1) if ln.strip() else ([], n + 1)
            continue
        if not cur:
            start = n + 1
        cur.append(ln)
    if cur:
        yield start, "\n".join(cur)

defaults = C.defaults()["agents"]
files = sorted(set(glob.glob(os.path.join(plugin, "skills", "**", "*.md"), recursive=True)
                   + glob.glob(os.path.join(plugin, "rules", "*.md"))
                   + glob.glob(os.path.join(plugin, "agents", "**", "*.md"), recursive=True)
                   + glob.glob(os.path.join(plugin, "commands", "**", "*.md"), recursive=True)))
spawns = 0
for f in files:
    rel = os.path.relpath(f, plugin)
    for start, text in blocks(f):
        for k in KEY.findall(text):
            if k not in defaults:
                print("%s:%d: names agents.%s, which is not a key of the config contract" % (rel, start, k))
        said = " ".join(text.split())
        for phrase in NOT_SPAWN:
            if phrase in said:
                used.add(phrase)
                said = said.replace(phrase, "")
        if not SPAWN.search(said):
            continue
        spawns += 1
        if not (any(k in defaults for k in KEY.findall(text)) or (re.search(r"\bmodel\b", text) and ALIAS.search(text))):
            print("%s:%d: spawns an agent without naming its model (an agents.* key or a model alias)" % (rel, start))
for phrase in NOT_SPAWN:
    if phrase not in used:
        print("NOT_SPAWN: no block has the listed sentence any more (drop it from the allowlist): %s" % phrase)
print("spawn-blocks %d files %d" % (spawns, len(files)))
'
check() { python3 -I -B -c "$CHECKER" "$1"; }
viol() { printf '%s\n' "$1" | grep -v '^spawn-blocks ' || true; }
# the checker on a planted copy runs capped (fixtures/capped.sh: memory and time caps). red_has: it names <needle> (a cap hit is red too);
# green_on: a control that must stay clean (a cap hit is a failure there: an empty output would pass for clean).
red_has() {  # red_has <copy> <needle> <label>
  local o rc; o=$(capped check "$1"); rc=$?
  cap_red "$rc" "$3" && return
  has "$(viol "$o")" "$2" "$3"
}
green_on() {  # green_on <copy> <label>
  local o rc; o=$(capped check "$1"); rc=$?
  case "$rc" in 247|248) bad "$2 (a cap stopped the checker, rc $rc)"; return;; esac
  empty "$(viol "$o")" "$2"
}
plugin_copy() { local d="$TMP/$1"; mkdir -p "$d"; cp -R "$PLUGIN/skills" "$PLUGIN/rules" "$PLUGIN/scripts" "$d/"; printf '%s' "$d"; }
add_extra_skill() {  # add_extra_skill <copy> <body> — one more skill in the copy
  mkdir -p "$1/skills/planted"
  printf -- '---\nname: planted\ndescription: "Use when: a test plants it"\n---\n\n# planted\n\n%s\n' "$2" > "$1/skills/planted/SKILL.md"
}

echo "== the real plugin =="
OUT=$(check "$PLUGIN"); rc=$?
eq "$rc" 0 "the checker runs on the plugin (rc 0)"
empty "$(viol "$OUT")" "every skill and rule block that spawns an agent names its model, and every agents.* key named exists"
N=$(printf '%s\n' "$OUT" | sed -n 's/^spawn-blocks \([0-9]*\) files \([0-9]*\)$/\1/p')
F=$(printf '%s\n' "$OUT" | sed -n 's/^spawn-blocks \([0-9]*\) files \([0-9]*\)$/\2/p')
[ "${N:-0}" -ge 5 ] && ok "instrument: the checker sees the spawn sites (ship, plan, brainstorm, two rules: $N blocks)" || bad "instrument: only ${N:-0} spawn blocks seen; the trigger misses the known sites"
[ "${F:-0}" -ge 10 ] && ok "instrument: the checker reads the skills and the rules ($F files)" || bad "instrument: only ${F:-0} files read"
for p in skills/ship/SKILL.md:agents.review_model rules/before-ready.instructions.md:agents.review_model \
         skills/plan/SKILL.md:agents.worker_model skills/brainstorm/SKILL.md:agents.search_model \
         rules/workflow-core.instructions.md:agents.worker_model rules/workflow-core.instructions.md:agents.search_model \
         rules/workflow-core.instructions.md:agents.review_model; do
  has "$(cat "$PLUGIN/${p%%:*}")" "${p#*:}" "${p%%:*} names ${p#*:}"
done
for f in skills/ship/SKILL.md skills/plan/SKILL.md skills/brainstorm/SKILL.md rules/before-ready.instructions.md \
         rules/workflow-core.instructions.md; do
  T=$(cat "$PLUGIN/$f")
  has "$T" 'python3 "${CLAUDE_PLUGIN_ROOT}/scripts/sdlc_config.py" get agents.' "$f gives the full read command"
  has "$T" 'the same command with `--default`' "$f says what to do when the read fails (the plugin default)"
done
empty "$(grep -oE '`(opus|sonnet|haiku)`' "$PLUGIN/rules/before-ready.instructions.md" "$PLUGIN/skills/ship/SKILL.md" || true)" "the review model is the configured one: no fixed alias in the review texts other than fable for a high-risk change"
has "$(cat "$PLUGIN/rules/before-ready.instructions.md")" 'may run its review on `fable`' "the ready rule says a high-risk change may review on fable"

echo "== defaults: one alias per job =="
eq "$(cd "$TMP" && python3 "$PLUGIN/scripts/sdlc_config.py" get agents --root "$TMP")" '{"review_model": "opus", "search_model": "haiku", "worker_model": "sonnet"}' "no config: review opus, search haiku, worker sonnet"
eq "$(python3 -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import sdlc_config as C; print(" ".join(C.MODEL_ALIASES))' "$PLUGIN/scripts")" "fable opus sonnet haiku" "the aliases are the four the Agent tool accepts, strongest first; no dated id"

echo "== planted skills: the checker must go red =="
d=$(plugin_copy spawn-no-model); add_extra_skill "$d" "1. Spawn a review agent on the PR head and read what it finds."
red_has "$d" "skills/planted/SKILL.md:" "a skill that spawns a review agent with no model goes red"
d=$(plugin_copy subagent-vi); add_extra_skill "$d" "- Đọc nhiều file thì giao agent đọc giúp rồi tóm tắt."
red_has "$d" "skills/planted/SKILL.md:" "a Vietnamese 'giao agent' with no model goes red"
d=$(plugin_copy unknown-key); add_extra_skill "$d" "1. Spawn a planning subagent on \`agents.plan_model\`."
red_has "$d" "agents.plan_model" "a skill that names a key the config contract lacks goes red"
d=$(plugin_copy other-item); add_extra_skill "$d" "1. Spawn a review agent on \`agents.review_model\`.
2. Then spawn a search agent over the repo."
red_has "$d" "skills/planted/SKILL.md:" "a second list item that spawns without a model goes red although the first names one"
n=0
for line in "Launch an agent to review the diff at the head SHA." "Use the Task tool to have another agent check the PR." \
            "Hand the sweep of the codebase to an Explore agent." "Ask a reviewer agent to read the final diff." \
            "Run a general-purpose agent over the repo." "Run two agents in parallel, one per task." \
            "Nhờ một agent khác review diff cuối." "Giao cho agent đọc toàn bộ thư mục." "Gọi agent để rà code." \
            "Delegate the inventory to a helper and keep the summary."; do
  n=$((n+1)); d=$(plugin_copy phrasing-$n); add_extra_skill "$d" "1. $line"
  red_has "$d" "skills/planted/SKILL.md:" "a planted spawn phrased '$line' with no model goes red"
done
for line in "Giao task cho worker đọc toàn bộ thư mục." "Hand each task to a worker and wait." \
            "Pass the diff to the agent who needs it, and let it review."; do
  n=$((n+1)); d=$(plugin_copy phrasing-$n); add_extra_skill "$d" "1. $line"
  red_has "$d" "skills/planted/SKILL.md:" "a planted spawn phrased '$line' with no model goes red"
done
d=$(plugin_copy allowlisted-plus-spawn)
python3 - "$d/rules/workflow-core.instructions.md" <<'PY'
import sys
p = sys.argv[1]; s = open(p, encoding="utf-8").read()
s = s.replace("before you believe it.", "before you believe it, then hand it to an agent to review.", 1)
open(p, "w", encoding="utf-8").write(s)
PY
OUTA=$(capped check "$d"); arc=$?; OUTA=$(viol "$OUTA")
if cap_red "$arc" "a spawn appended to an allowlisted sentence"; then :; else
has "$OUTA" "rules/workflow-core.instructions.md:" "a spawn appended to an allowlisted sentence goes red"
has "$OUTA" "NOT_SPAWN: no block has the listed sentence any more" "…and the allowlist entry it broke is reported as stale"
fi
d=$(plugin_copy table-row); add_extra_skill "$d" "| Step | Who |
|---|---|
| review | an agent on \`agents.review_model\` |
| search | an agent over the repo |"
red_has "$d" "skills/planted/SKILL.md:" "a table row that spawns cannot borrow the key of another row"
d=$(plugin_copy heading); add_extra_skill "$d" "## Review with an agent
Read \`agents.review_model\` first."
red_has "$d" "skills/planted/SKILL.md:" "a heading that spawns cannot borrow the key of the paragraph under it"
d=$(plugin_copy reference-file); mkdir -p "$d/skills/ship"; printf 'Spawn a review agent over the diff.\n' > "$d/skills/ship/reference.md"
red_has "$d" "skills/ship/reference.md:" "a spawn in a reference file of a skill is checked too"
d=$(plugin_copy alias-after); add_extra_skill "$d" "1. Spawn a review agent on the \`haiku\` model."
green_on "$d" "control: an alias before the word model counts"
d=$(plugin_copy with-key); add_extra_skill "$d" "1. Spawn a review agent on the configured review model (\`agents.review_model\`)."
green_on "$d" "control: a planted skill that names agents.review_model stays green"
d=$(plugin_copy with-alias); add_extra_skill "$d" "1. Spawn a search subagent with model \`haiku\`."
green_on "$d" "control: a planted skill that names a model alias stays green"
d=$(plugin_copy in-fence); add_extra_skill "$d" '```bash
echo "spawn a review agent"
```'
green_on "$d" "control: a spawn word inside a code fence is not an instruction"

summary
