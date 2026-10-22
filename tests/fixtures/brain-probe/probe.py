#!/usr/bin/env python3
"""The exit probe: do pinned decisions survive a real compaction? Run by tests/live/brain-probe.sh on a logged-in machine.

Per run: plant 10 owner decisions in one session with the
brain off and seed the same 10 into the store; read ~120k tokens of near-miss notes; fork twice; arm H with the brain injecting
at SessionStart:compact only (BRAIN_TEST_SOURCES), arm C with BRAIN_OFF=1, so the arms share every byte before the compaction;
compact the fork (method 1: a neutral turn with CLAUDE_CODE_AUTO_COMPACT_WINDOW=100000; method 2: `/compact`); then ask the 10
questions in a second process, brain off and no tools in both arms; grade by script. Every session is hermetic (--plugin-dir
this checkout's brain and, next to it, this checkout's sdlc, which the brain's manifest depends on and which Claude Code does
not load for the brain otherwise under --setting-sources project,local; the sdlc runs silent, `hooks: off` in the scratch
project; --setting-sources project,local, --strict-mcp-config, --settings with this directory's logger hooks, scratch
XDG_STATE_HOME and project, auto memory off). A run whose evidence does not hold is void, never scored. The probe set is
never tuned after seeing results.
rc 0 PASS, 1 FAIL, 2 stopped or void, 3 the control also reached 10/10 ("not shown necessary at this size").
"""
import argparse
import contextlib
import glob
import json
import os
import random
import re
import shutil
import subprocess
import sys
import tempfile
import time
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
BRAIN = os.path.join(ROOT, "plugins", "vibemaestro-brain")
SDLC = os.path.join(ROOT, "plugins", "vibemaestro-sdlc")
PLUGIN_DIRS = [BRAIN, SDLC]             # every session loads both, in both arms: the brain's manifest depends on the sdlc
sys.path.insert(0, os.path.join(BRAIN, "scripts"))
import brain_cost  # noqa: E402

BLOCK_LIMIT = 8000
WINDOW = "100000"                       # the floor of CLAUDE_CODE_AUTO_COMPACT_WINDOW (docs)
FILLER_TURNS, FILLER_KB = 12, 40        # design values: 12 reads of ~10k tokens, about 120k tokens of context at the fork
FRAME = "re-injected at SessionStart:"  # the brain block's first line, whatever the source
FRAME_COMPACT = "re-injected at SessionStart:compact"
NEEDED = ("--print", "--output-format", "--resume", "--fork-session", "--plugin-dir", "--settings", "--setting-sources",
          "--strict-mcp-config", "--tools", "--allowedTools", "--model")
PLANT_ENV = {"BRAIN_OFF": "1"}
H_ENV = {"BRAIN_TEST": "1", "BRAIN_TEST_SOURCES": "compact"}
# a fixed phrase from each of the sdlc's two SessionStart texts (about 11,000 characters together, the same for every
# source); the preflight stops when either is in its own transcript, i.e. when `hooks: off` did not silence the sdlc
SDLC_PHRASES = ("The general way of working (read from the plugin at session start", "The work flow in an app repo")
SDLC_OFF = {"hooks": "off"}             # <scratch project>/.vibemaestro/sdlc.json, the same for every session and both arms
QMARK = "brain-probe questions"
STEP = "(brain-probe compaction step) Reply with exactly: ready"
PREFLIGHT_Q = ("Which commit does this project's preflight decision name? Reply with the 7-character commit only, or "
               "`unknown`.")
EXIT_RUNS = 3
TOKEN = re.compile(r"\b[A-Za-z]+-\d+\b|\b[0-9A-Fa-f]{7}\b")   # any anchor-shaped token: a code word or a 7-hex commit
HEX = "0123456789abcdef"
CALL_TIMEOUT = 1200
DROP_ENV = ("INTENT_SLUG", "SEAT", "BRAIN_OFF", "BRAIN_TEST", "BRAIN_TEST_PAUSE_MS", "BRAIN_TEST_ASK_MODES",
            "BRAIN_TEST_SOURCES", "CLAUDECODE",
            "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_PROJECT_DIR", "CLAUDE_CODE_AUTO_COMPACT_WINDOW",
            "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE", "CLAUDE_PLUGIN_ROOT", "CLAUDE_ENV_FILE", "DISABLE_AUTO_COMPACT",
            "DISABLE_COMPACT")
TEMPLATES = ("In the dry run the {topic} was tried with {near}; the owner did not adopt it.",
             "A draft proposal set the {topic} to {near}, later dropped.",
             "Someone wrote {near} for the {topic} in an old ticket; that value is stale.",
             "The staging notes mention {near} next to the {topic}, copied from last quarter.",
             "On {day} the team discussed whether {near} should become the {topic}; nothing was decided.")
BLAND = ("The CI queue waited {n} minutes; the cache hit ratio was {m}%.",
         "Two reviewers asked for clearer logs in the deploy step; {n} lines were added.",
         "The nightly job took {n} minutes and {m} seconds.",
         "A flaky test was retried {n} times before it passed.",
         "The dependency bump touched {n} files and {m} lockfile entries.")


class Stop(Exception):
    pass


def say(msg):
    sys.stderr.write(msg + "\n")
    sys.stderr.flush()


def n_(x):
    return "—" if x is None else "{:,}".format(int(round(x)))


# --- the probe set ------------------------------------------------------------------------------------------------------------

def load_set():
    """(the 10 items, the floated-draft template) of probe-set.json."""
    d = json.load(open(os.path.join(HERE, "probe-set.json"), encoding="utf-8"))
    return d["items"], d["draft"]


def draw(items, seed, draft):
    """The run's anchors (one per item, all distinct), three near misses each, from `seed`; each item's decision prompt and
    its floated draft, which names the first near miss (fixed before the first live run)."""
    rnd = random.Random(seed)
    used, out = set(), []
    for it in items:
        while True:
            a = ("%s-%d" % (it["word"], rnd.randint(10, 99)) if it["kind"] == "code"
                 else "".join(rnd.choice(HEX) for _ in range(7)))
            if a.lower() not in used:
                break
        used.add(a.lower())
        out.append(dict(it, anchor=a))
    for it in out:
        a, near = it["anchor"], []
        while len(near) < 3:
            if it["kind"] == "code":
                w, d = a.rsplit("-", 1)
                c = "%s-%d" % (w, rnd.randint(10, 99))
            else:
                i = rnd.randrange(7)
                c = a[:i] + rnd.choice(HEX.replace(a[i], "")) + a[i + 1:]
            if c.lower() not in used and c not in near:
                near.append(c)
        it["near"] = near
        it["owner_prompt"] = it["owner"].replace("{A}", a)
        it["draft_prompt"] = draft.replace("{T}", it["topic"]).replace("{N}", near[0])
        it["text_full"] = it["text"].replace("{A}", a)
    return out


def filler_text(items, k, kb, rnd):
    out, size, e = ["# Project notes, part %d" % (k + 1), ""], 0, 0
    while size < kb * 1024:
        e += 1
        it = items[rnd.randrange(len(items))]
        day = "2026-%02d-%02d" % (rnd.randint(1, 9), rnd.randint(1, 28))
        para = rnd.choice(TEMPLATES).format(topic=it["topic"], near=rnd.choice(it["near"]), day=day)
        block = "## Entry %d — %s\n%s %s\n" % (e, day, para, rnd.choice(BLAND).format(n=rnd.randint(2, 97), m=rnd.randint(1, 59)))
        out.append(block)
        size += len(block) + 1
    return "\n".join(out)


def filler_prompt(k):
    return "Read notes/part-%02d.md and reply in one line: how many entries does it have?" % (k + 1)


def question_prompt(items):
    return ("(%s) Answer from what you know about this project's owner decisions. Reply with one line per question, in the "
            "form `N. <answer>`, the exact code word or 7-character hex commit only; write `N. unknown` when you do not "
            "know.\n" % QMARK) + "\n".join("%d. %s" % (i, it["question"]) for i, it in enumerate(items, 1))


def grade(answer, items):
    """(right ids, wrong ids): line n is right when the only anchor-shaped token on it is item n's anchor (any case): a hedge,
    a near miss or another item's anchor makes it wrong. Never graded by a model."""
    lines = {}
    for line in (answer or "").splitlines():
        m = re.match(r"^\s*[-*>]?\s*\**\s*(\d{1,2})\s*[.):]\**\s*(.*)$", line)
        if m and int(m.group(1)) not in lines:
            lines[int(m.group(1))] = m.group(2)
    right, wrong = [], []
    for i, it in enumerate(items, 1):
        line = lines.get(i, "")
        toks = {t.lower() for t in TOKEN.findall(line)}
        good = toks == {it["anchor"].lower()}
        (right if good else wrong).append(it["id"])
    return right, wrong


def loss(summary, items):
    import brain_hook
    if summary is None:
        return None
    return round(1 - sum(1 for it in items if brain_hook.anchor_found(it["anchor"], summary)) / float(len(items)), 2)


# --- files the sessions leave -------------------------------------------------------------------------------------------------

def jsonl(path):
    out = []
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for raw in f:
                try:
                    o = json.loads(raw)
                except ValueError:
                    continue
                if isinstance(o, dict):
                    out.append(o)
    except (OSError, TypeError):
        pass
    return out


def transcript_of(log, sid):
    paths = [l.get("transcript_path") for l in log if l.get("session_id") == sid and l.get("transcript_path")]
    return paths[-1] if paths else None


def brain_blocks(path, frame=FRAME):
    """How many hook_additional_context attachments in a transcript carry the brain's block."""
    n = 0
    for r in jsonl(path):
        a = r.get("attachment") if r.get("type") == "attachment" else None
        if isinstance(a, dict) and a.get("type") == "hook_additional_context":
            if frame in json.dumps(a.get("content"), ensure_ascii=False):
                n += 1
    return n


def prompts(path, marker):
    """How many user prompts in a transcript carry `marker`. The compaction summary is a user record too, and 2.1.290's
    compaction prompt lists the user's messages, so it is not counted."""
    n = 0
    for r in jsonl(path):
        if r.get("isCompactSummary"):
            continue
        if r.get("type") == "user" and marker in json.dumps((r.get("message") or {}).get("content"), ensure_ascii=False):
            n += 1
    return n


def context_around(path):
    """(context of the last call before the compaction, of the first call after it), by the boundary or summary record."""
    before = after = None
    seen = False
    for r in jsonl(path):
        if (r.get("type") == "system" and r.get("subtype") == "compact_boundary") or r.get("isCompactSummary"):
            seen = True
            continue
        u = (r.get("message") or {}).get("usage") if r.get("type") == "assistant" else None
        if isinstance(u, dict):
            c = brain_cost.context(brain_cost.values(u))
            if not seen:
                before = c
            elif after is None:
                after = c
    return before, after


# --- sessions -----------------------------------------------------------------------------------------------------------------

class Claude(object):
    def __init__(self, ctx):
        self.ctx = ctx
        self.calls = []

    def env(self, run, extra):
        e = dict((k, v) for k, v in os.environ.items() if k not in DROP_ENV)
        e.update({"XDG_STATE_HOME": run.state, "BRAIN_PROBE_LOG": run.log, "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1"})
        e.update(extra)
        return e

    def run(self, prompt, run, extra_env, extra_args, label, model=None):
        a = self.ctx.a
        args = [self.ctx.bin, "-p", prompt, "--output-format", "json"]
        for d in PLUGIN_DIRS:
            args += ["--plugin-dir", d]
        args += ["--settings", run.settings, "--strict-mcp-config"]
        if not a.keep_user_settings:
            args += ["--setting-sources", "project,local"]
        m = model or a.model
        if m:
            args += ["--model", m]
        args += extra_args
        say("  %s" % label)
        t0 = time.time()
        try:
            p = subprocess.run(args, cwd=run.project, env=self.env(run, extra_env), stdin=subprocess.DEVNULL,
                               capture_output=True, text=True, timeout=CALL_TIMEOUT)
        except subprocess.TimeoutExpired:
            raise Stop("%s: no answer in %d s" % (label, CALL_TIMEOUT))
        except OSError as e:
            raise Stop("%s: cannot run %s (%s)" % (label, self.ctx.bin, e.__class__.__name__))
        res = None
        for line in reversed(p.stdout.strip().splitlines()):
            try:
                o = json.loads(line)
            except ValueError:
                continue
            if isinstance(o, dict):
                res = o
                break
        if res is None:
            raise Stop("%s: no JSON result (rc %d): %s" % (label, p.returncode, (p.stderr or p.stdout).strip()[-300:]))
        self.calls.append({"run": run.n, "label": label, "seconds": time.time() - t0, "usage": res.get("usage") or {},
                           "cost": res.get("total_cost_usd") or 0, "models": sorted((res.get("modelUsage") or {}).keys())})
        if res.get("is_error"):
            raise Stop("%s: the session failed: %s" % (label, str(res.get("result"))[:300]))
        if not res.get("session_id"):
            raise Stop("%s: the result has no session_id" % label)
        return res


class Run(object):
    def __init__(self, ctx, n, name):
        self.n = n
        self.dir = os.path.join(ctx.work, name)
        self.project = os.path.join(self.dir, "project")
        self.state = os.path.join(self.dir, "state")
        self.log = os.path.join(self.dir, "log.jsonl")
        self.settings = os.path.join(self.dir, "settings.json")
        shutil.rmtree(self.dir, ignore_errors=True)          # a --work reused: this run starts clean
        os.makedirs(os.path.join(self.project, "notes"))
        os.makedirs(self.state)
        if shutil.which("git"):
            subprocess.run(["git", "init", "-q", self.project], capture_output=True)
        os.makedirs(os.path.join(self.project, ".vibemaestro"))
        with open(os.path.join(self.project, ".vibemaestro", "sdlc.json"), "w", encoding="utf-8") as f:
            json.dump(SDLC_OFF, f)
        cmd = "%s %s" % (sys.executable, os.path.join(HERE, "log_hook.py"))
        hook = [{"hooks": [{"type": "command", "command": cmd, "timeout": 30}]}]
        with open(self.settings, "w", encoding="utf-8") as f:
            json.dump({"hooks": {"SessionStart": hook, "PreCompact": hook, "PostCompact": hook}}, f)

    def logs(self):
        return jsonl(self.log)

    def episodes(self):
        with brain_env(self.state):
            import brain_store
            d = brain_store.state_dir(self.project)
        return jsonl(os.path.join(d, "episodes.jsonl"))


@contextlib.contextmanager
def brain_env(state, session="probe-seed"):
    keys = ("XDG_STATE_HOME", "CLAUDE_CODE_SESSION_ID", "INTENT_SLUG", "SEAT")
    saved = dict((k, os.environ.get(k)) for k in keys)
    os.environ.update({"XDG_STATE_HOME": state, "CLAUDE_CODE_SESSION_ID": session})
    os.environ.pop("INTENT_SLUG", None)
    os.environ.pop("SEAT", None)
    try:
        yield
    finally:
        for k, v in saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v


def seed_store(run, items):
    """The same decisions, pinned in the scratch store through the store library (test code: a -p session cannot pass the
    owner dialog). Each op is marked confirm.mode probe-seed."""
    cwd = os.getcwd()
    os.chdir(run.project)
    try:
        with brain_env(run.state):
            import brain_store as s
            for it in items:
                def build(d, st, it=it):
                    iid = s.next_id(st, "D")
                    item = {"id": iid, "kind": "decision", "pinned": True, "text": it["text_full"],
                            "source": {"type": "owner", "quote": it["owner_prompt"][:300], "where": "brain-probe plant"},
                            "expires": None, "links": [], "anchors": [it["anchor"]], "supersedes": None}
                    return ({"op": "owner-add", "item": item, "confirm": {"asked": True, "mode": "probe-seed"}},
                            [it["text_full"]], "pinned %s" % iid, None)
                s.write(build)
    except Exception as e:  # noqa: BLE001 — a Refused or an OSError: the run cannot start
        raise Stop("seeding the store failed: %s" % getattr(e, "msg", e))
    finally:
        os.chdir(cwd)


# --- the protocol -------------------------------------------------------------------------------------------------------------

def version_ok(version, rng):
    """True when `version` (x.y.z) satisfies `rng`: comparators >=, >, <=, <, = (or a bare version) joined by spaces. Any other
    form raises Stop: this probe does not guess what a range it cannot read means."""
    def parts(v):
        m = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", v)
        if not m:
            raise Stop("preflight: cannot read the version %r" % v)
        return tuple(int(x) for x in m.groups())
    have = parts(version)
    for c in rng.split():
        m = re.fullmatch(r"(>=|<=|>|<|=)?(\d+\.\d+\.\d+)", c)
        if not m:
            raise Stop("preflight: cannot read the range %r (this probe reads >=, >, <=, <, = with x.y.z, space-joined)" % rng)
        want = parts(m.group(2))
        op = m.group(1) or "="
        if not {">=": have >= want, ">": have > want, "<=": have <= want, "<": have < want, "=": have == want}[op]:
            return False
    return True


def manifest(plugin_dir):
    try:
        with open(os.path.join(plugin_dir, ".claude-plugin", "plugin.json"), encoding="utf-8") as f:
            m = json.load(f)
    except (OSError, ValueError):
        raise Stop("preflight: cannot read %s" % os.path.join(plugin_dir, ".claude-plugin", "plugin.json"))
    if not isinstance(m, dict):
        raise Stop("preflight: %s is not a JSON object" % os.path.join(plugin_dir, ".claude-plugin", "plugin.json"))
    return m


def check_dependencies(plugin_dirs=None):
    """Before anything is spent: every dependency the manifests of the plugins given by --plugin-dir declare is itself given by
    one of them, at a version in the range. Claude Code does not load a plugin whose dependency is not enabled, and under
    --setting-sources project,local the installed one is not (measured 2.1.303: `dependency-unsatisfied`, no hook runs)."""
    dirs = PLUGIN_DIRS if plugin_dirs is None else plugin_dirs
    given = {}
    for d in dirs:
        m = manifest(d)
        given[m.get("name")] = m.get("version")
    for d in dirs:
        m = manifest(d)
        for dep in m.get("dependencies") or []:
            name, rng = (dep.get("name"), dep.get("version")) if isinstance(dep, dict) else (dep, None)
            if name not in given:
                raise Stop("preflight: %s depends on %s (its plugin.json), which no --plugin-dir of this probe gives: Claude Code "
                           "would not load %s under --setting-sources project,local" % (m.get("name"), name, m.get("name")))
            if rng and name in given and not version_ok(str(given[name]), rng):
                raise Stop("preflight: %s depends on %s %s, but this checkout's %s is %s" % (
                    m.get("name"), name, rng, name, given[name]))


def preflight(ctx):
    say("preflight")
    check_dependencies()
    try:
        h = subprocess.run([ctx.bin, "--help"], capture_output=True, text=True, timeout=60).stdout
    except (OSError, subprocess.SubprocessError) as e:
        raise Stop("preflight: cannot run %s (%s)" % (ctx.bin, e.__class__.__name__))
    missing = [f for f in NEEDED if f not in h]
    if missing:
        raise Stop("preflight: `claude --help` does not list %s, which this probe needs" % ", ".join(missing))
    run = Run(ctx, 0, "preflight")
    ctx.runs.append(run)
    a = "".join(random.Random().choice(HEX) for _ in range(7))
    seed_store(run, [{"text_full": "Preflight decision: commit %s" % a, "owner_prompt": "preflight", "anchor": a}])
    res = ctx.claude.run("Reply with exactly: ok", run, {}, ["--tools", ""], "preflight: one turn",
                         model=ctx.a.preflight_model)
    sid = res["session_id"]
    if not any(l.get("event") == "SessionStart" and l.get("session_id") == sid for l in run.logs()):
        raise Stop("preflight: the probe's own logger hook did not fire (hooks given by --settings are not run?)")
    tr = transcript_of(run.logs(), sid)
    if not tr:
        raise Stop("preflight: the logger hook gave no transcript path for the preflight session, so the sdlc's silence cannot be checked")
    seen = open(tr, encoding="utf-8", errors="replace").read()
    loud = [p for p in SDLC_PHRASES if p in seen]
    if loud:
        raise Stop("preflight: the sdlc plugin's SessionStart text is in the preflight transcript (%r): `hooks: off` in the scratch "
                   "project's .vibemaestro/sdlc.json did not silence it, so every session would carry about 11k extra characters "
                   "and the context at the fork would move" % loud[0])
    starts = [e for e in run.episodes() if e.get("kind") == "session-start" and e.get("session") == sid]
    if len(starts) != 1:
        raise Stop("preflight: %d brains loaded (want exactly 1, this checkout's by --plugin-dir): %s" % (
            len(starts), "an installed vibemaestro-brain is still enabled for these sessions" if starts else
            "--plugin-dir was not honoured"))
    # H's path end to end, in a new session that never saw the decision: the block held back until SessionStart:compact,
    # a headless /compact, then a question after --resume with the brain off. Only that block can answer it.
    res2 = ctx.claude.run("Reply with exactly: ok", run, dict(H_ENV), ["--tools", ""], "preflight: a turn, block held back",
                          model=ctx.a.preflight_model)
    res3 = ctx.claude.run("/compact", run, dict(H_ENV), ["--resume", res2["session_id"]], "preflight: /compact",
                          model=ctx.a.preflight_model)
    m2 = any(l.get("event") == "PostCompact" and l.get("session_id") == res3["session_id"] and (l.get("summary_chars") or 0)
             for l in run.logs())
    replay = "not checked (a headless /compact does not compact)"
    ctx.replay_checked = False
    if m2:
        res4 = ctx.claude.run(PREFLIGHT_Q, run, {"BRAIN_OFF": "1"}, ["--resume", res3["session_id"], "--tools", ""],
                              "preflight: ask after --resume", model=ctx.a.preflight_model)
        got = str(res4.get("result"))
        ok = {t.lower() for t in TOKEN.findall(got)} == {a}
        if not ok:
            raise Stop("preflight: the block SessionStart:compact left is not used after --resume (asked for the preflight "
                       "decision, answered %r): both methods ask in a second process, so the probe cannot measure here"
                       % got[:80])
        replay = "the block SessionStart:compact left is used after --resume"
        ctx.replay_checked = True
    ctx.preflight = ("logged in · the logger fires · one brain loaded (injected %s) · /compact headless %s · %s"
                     % (n_(starts[0].get("injected")), "compacts" if m2 else "does not compact", replay))
    say("preflight: " + ctx.preflight)


def arm_run(ctx, run, arm, method, fork_from, project):
    """One arm by one method: fork and compact, then ask in a second process; the arm's record, or None when the method did
    not compact."""
    arm_env = {"BRAIN_OFF": "1"} if arm == "C" else dict(H_ENV)
    questions = question_prompt(run.items)
    if method == 1:
        res = ctx.claude.run(STEP, run, dict(arm_env, CLAUDE_CODE_AUTO_COMPACT_WINDOW=WINDOW),
                             ["--resume", fork_from, "--fork-session", "--tools", ""],
                             "run %d %s: fork and auto-compact (method 1)" % (run.n, arm))
    else:
        res = ctx.claude.run("/compact", run, arm_env, ["--resume", fork_from, "--fork-session"],
                             "run %d %s: fork and /compact (method 2)" % (run.n, arm))
    fork = res["session_id"]
    run.last_fork = fork
    log = run.logs()
    tr = transcript_of(log, fork)
    pcs = [l for l in log if l.get("event") == "PostCompact" and l.get("session_id") == fork and (l.get("summary_chars") or 0)]
    compacted = bool(pcs)
    if not compacted:
        return None
    sessions, transcripts = [fork], [tr]
    res = ctx.claude.run(questions, project, {"BRAIN_OFF": "1"}, ["--resume", fork, "--tools", ""],
                         "run %d %s: ask, brain off, no tools" % (run.n, arm))
    sessions.append(res["session_id"])
    tr2 = transcript_of(run.logs(), res["session_id"])
    if tr2 not in transcripts:
        transcripts.append(tr2)
    summary = None
    with contextlib.suppress(OSError, TypeError):
        summary = open(pcs[-1].get("summary_file"), encoding="utf-8").read()
    return {"arm": arm, "method": method, "sessions": sessions, "transcripts": transcripts,
            "answer": res.get("result"), "summary": summary, "trigger": pcs[-1].get("trigger")}


def validate(ctx, run, arms):
    """The run's evidence; each problem voids the run."""
    problems = []
    eps = run.episodes()
    for arm in ("H", "C"):
        if not arms[arm]["transcripts"] or not all(arms[arm]["transcripts"]):
            return ["arm %s: the logger recorded no transcript path for one of its sessions" % arm]
    shared_tr = transcript_of(run.logs(), run.shared)
    if brain_blocks(shared_tr):
        problems.append("the shared history holds the brain's block (the plant or filler ran with the brain on)")
    if any(l.get("event") == "PostCompact" and l.get("session_id") in run.shared_ids for l in run.logs()):
        problems.append("the shared history was compacted before the fork (the run would measure two compactions)")
    c = arms["C"]
    if any(e.get("session") in c["sessions"] for e in eps):
        problems.append("arm C ran with the brain on (the brain logged its session)")
    if any(brain_blocks(p) for p in c["transcripts"]):
        problems.append("arm C's transcript holds the brain's block")
    h = arms["H"]
    if not any(brain_blocks(p, FRAME_COMPACT) for p in h["transcripts"]):
        problems.append("arm H's transcript lacks the brain's block from SessionStart:compact")
    # The compaction starts at the brain's pre-compact line: Claude Code 2.1.290 usually runs SessionStart:compact before
    # PostCompact (round 2 read it in the binary), so the compact line can come after the block it re-injects.
    seen = logged = False
    for e in eps:
        if e.get("session") not in h["sessions"]:
            continue
        if e.get("kind") in ("pre-compact", "compact"):
            seen = True
            logged = logged or e.get("kind") == "compact"
        elif e.get("kind") == "session-start" and not (seen and e.get("source") == "compact"):
            problems.append("arm H got the brain's block outside SessionStart:compact (SessionStart:%s%s)" % (
                e.get("source"), "" if seen else ", before the compaction"))
    if not logged:
        problems.append("arm H: the brain logged no compaction")
    for arm in ("H", "C"):
        steps = 1 if arms[arm]["method"] == 1 else 0
        if any(prompts(p, QMARK) > 1 or prompts(p, STEP) > steps for p in arms[arm]["transcripts"][-1:]):
            problems.append("arm %s's transcript holds the questions or the compaction step more than its method sends (a "
                            "fork that was already used)" % arm)
    for m in memory_files(ctx, run):
        problems.append("auto memory wrote %s" % m)
    return problems


def memory_files(ctx, run):
    dirs = set(os.path.dirname(l["transcript_path"]) for l in run.logs() if l.get("transcript_path"))
    out = []
    for d in sorted(dirs):
        out += [p for p in glob.glob(os.path.join(d, "memory", "**"), recursive=True) if os.path.isfile(p)]
    return out


def run_once(ctx, n):
    run = Run(ctx, n, "run%d" % n)
    ctx.runs.append(run)
    t0 = time.time()
    run.items = draw(ctx.items, ctx.seed + n, ctx.draft)
    rnd = random.Random(ctx.seed * 1000 + n)
    for k in range(ctx.a.filler_turns):
        with open(os.path.join(run.project, "notes", "part-%02d.md" % (k + 1)), "w", encoding="utf-8") as f:
            f.write(filler_text(run.items, k, ctx.a.filler_kb, rnd))
    say("run %d" % n)
    sid = None
    run.shared_ids = set()
    for i, it in enumerate(run.items, 1):
        turns = [it["owner_prompt"], it["draft_prompt"]] if i % 2 else [it["draft_prompt"], it["owner_prompt"]]
        for prompt in turns:
            res = ctx.claude.run(prompt, run, PLANT_ENV, (["--resume", sid] if sid else []) + ["--tools", ""],
                                 "run %d: plant %d/%d, %s" % (n, i, len(run.items),
                                                              "decision" if prompt == it["owner_prompt"] else "draft"))
            sid = res["session_id"]
            run.shared_ids.add(sid)
    seed_store(run, run.items)
    for k in range(ctx.a.filler_turns):
        res = ctx.claude.run(filler_prompt(k), run, PLANT_ENV, ["--resume", sid, "--tools", "Read", "--allowedTools", "Read"],
                             "run %d: filler %d/%d" % (n, k + 1, ctx.a.filler_turns))
        sid = res["session_id"]
        run.shared_ids.add(sid)
    shared = run.shared = sid
    project = run                       # Claude.run takes the run: its project, state, log and settings
    arms = {}
    for arm in ("H", "C"):
        out, failed = None, None
        if ctx.method in (None, 1):
            out = arm_run(ctx, run, arm, 1, shared, project)
            if out is not None:
                ctx.method = 1
            elif ctx.method == 1:
                return {"void": ["arm %s did not compact by method 1, which run 1 used" % arm]}
            else:
                failed = run.last_fork      # its step ran without a compaction: never forked again
        if out is None:
            say("  method 1 did not compact; method 2 on a fresh fork of the shared history (not %s)" % (failed or "-"))
            out = arm_run(ctx, run, arm, 2, shared, project)
            if out is None and ctx.method == 2:
                return {"void": ["arm %s did not compact by method 2, which run 1 used" % arm]}
            if out is None:
                raise Stop("no method compacted: neither the auto window (method 1) nor a headless /compact (method 2) left "
                           "a PostCompact with a summary; the interactive method 3 (tmux) is a follow-up row")
            ctx.method = 2
        arms[arm] = out
    problems = validate(ctx, run, arms)
    if problems:
        return {"void": problems}
    out = {}
    eps = run.episodes()
    for arm in ("H", "C"):
        a = arms[arm]
        right, wrong = grade(a["answer"], run.items)
        inj = [e for e in eps if e.get("kind") == "session-start" and e.get("source") == "compact"
               and e.get("session") in a["sessions"]]
        before, after = context_around(a["transcripts"][0])
        out[arm] = {"score": len(right), "wrong": wrong, "injected": inj[-1].get("injected") if inj else None,
                    "cut": inj[-1].get("cut") if inj else None,
                    "loss": loss(a["summary"], run.items), "before": before, "after": after, "trigger": a["trigger"]}
    sums = brain_cost.Sums(keep=None)
    for p in [transcript_of(run.logs(), run.shared)] + arms["H"]["transcripts"] + arms["C"]["transcripts"]:
        with contextlib.suppress(OSError, TypeError):
            brain_cost.parse(p, sums)
    calls = [c for c in ctx.claude.calls if c["run"] == n]
    own = sum(sum(int(c["usage"].get(k) or 0) for k in ("input_tokens", "cache_read_input_tokens",
                                                          "cache_creation_input_tokens", "output_tokens")) for c in calls)
    out["cost"] = {"report": sums.report(), "own_tokens": own, "own_usd": sum(float(c["cost"] or 0) for c in calls),
                   "seconds": time.time() - t0}
    out["models"] = sorted(set(m for c in calls for m in c["models"]))
    return out


def verdict(results):
    over = [r["H"]["injected"] for r in results if r["H"]["injected"] is None or r["H"]["injected"] > BLOCK_LIMIT
            or r["H"]["cut"]]               # the hook's hard cut is the backstop that keeps a block at 8,000: it must not fire
    if any(r["H"]["score"] != 10 for r in results) or over:
        return "FAIL", 1
    elif any(r["C"]["score"] == 10 for r in results):
        return "the control also reached 10/10: not shown necessary at this size (the owner decides)", 3
    return "PASS", 0


def arm_line(n, arm, r):
    return ("run %d %s: %d/10%s · injected %s · cut %s · loss %s · context %s → %s · compacted %s" % (
        n, arm, r["score"], " (wrong %s)" % " ".join(r["wrong"]) if r["wrong"] else "", n_(r["injected"]), n_(r["cut"]),
        "—" if r["loss"] is None else r["loss"], n_(r["before"]), n_(r["after"]), r["trigger"]))


def cost_line(n, c):
    rep = c["report"]
    t = rep["tokens"]
    sp = rep["split"]
    return ("run %d cost: %s tokens in the transcripts (%s units at A's weights; read %.0f%% · write %.0f%% · output %.0f%%) · "
            "Claude Code's own usage %s tokens, $%.2f · %dm %02ds" % (
                n, n_(sum(t.values())), n_(rep["units"]["total"]), sp["read"] * 100, sp["write"] * 100, sp["output"] * 100,
                n_(c["own_tokens"]), c["own_usd"], int(c["seconds"] // 60), int(c["seconds"] % 60)))


def plan_text():
    return """brain-probe --plan: the exit probe. Starts nothing.

Run, from this repository's checkout, on a machine where `claude` is logged in:
    bash tests/live/brain-probe.sh --runs 3 --model opus
Needs: Claude Code (`claude`, logged in, its --help listing %s), python3 (3.8+), git. Not tmux.
--model: the sessions do not read user settings, so without it they run on the account's default model; pass the coordinator's.
Other options: --preflight-model M (haiku), --method try|1|2, --seed S, --keep, --work DIR, --keep-user-settings, --claude BIN.
--filler-turns and --filler-kb exist for the suite; a run that changes them or --runs (3) is labelled "not an exit run".

Sessions: `claude -p --output-format json --plugin-dir <this checkout's brain> --plugin-dir <this checkout's sdlc>
--settings <the probe's logger hooks> --strict-mcp-config --setting-sources project,local`, in a scratch project with a scratch
XDG_STATE_HOME, the same plugin directories in every session and both arms (preflight, plant, filler, both forks, compaction,
questions). The sdlc is there because the brain's plugin.json depends on it: under --setting-sources project,local the installed
one is not enabled, so without it Claude Code refuses to load the brain (dependency-unsatisfied, no hook runs; measured 2.1.303).
The scratch project holds `.vibemaestro/sdlc.json` {"hooks": "off"}, so the sdlc is loaded and silent.
CLAUDE_CODE_DISABLE_AUTO_MEMORY=1; INTENT_SLUG, SEAT, BRAIN_OFF, CLAUDECODE, DISABLE_COMPACT and DISABLE_AUTO_COMPACT are dropped.
Preflight (once, Haiku, about a minute): before anything is spent, the brain's plugin.json dependencies are each given by a
--plugin-dir of this checkout at a version in the range; `claude --help` lists the flags; one turn: logged in, the logger fires,
the sdlc's SessionStart text is NOT in the transcript, exactly one brain loaded; then H's path on a decision the session never saw: the block held back until SessionStart:compact, a headless /compact,
a question after --resume with the brain off, which only that block can answer.
Per run: plant 10 owner decisions (anchors drawn from the printed seed) and, fixed before the first live run, one owner turn per
item floating a near miss as "not decided" (decision first for odd items, draft first for even), all with BRAIN_OFF=1; seed the
10 decisions into the store; %d reads of
~%d KB near-miss notes (about 120k tokens at the fork); fork twice: H with BRAIN_TEST=1 BRAIN_TEST_SOURCES=compact (its block
arrives only at SessionStart:compact), C with BRAIN_OFF=1, so both share every byte before the compaction; compact the fork by
method 1 (a neutral turn with CLAUDE_CODE_AUTO_COMPACT_WINDOW=%s) or, if no PostCompact, method 2 (`/compact` on a fresh
fork); then ask the 10 questions in a second process, brain off and no tools in both arms; grade by script (the only
anchor-shaped token on line n must be item n's anchor).
Void (rc 2, not scored): C saw the brain; the shared history holds the block or was compacted; H lacks the SessionStart:compact
block or got one anywhere else; a fork already used; a session with no transcript path; auto memory written.
sdlc silenced, not left active (measured on sdlc 2.28.0 in a scratch project): its SessionStart hooks print 11,276
characters (about 3k tokens) at every session start, `--resume` ones included, and the transcript keeps each; over the 32 sessions
that share the history that is about 95k extra tokens at the fork and about 1.8M extra tokens per run (about 4.3M in all), and
the history at the fork would pass 200k. No hook writes a file; `hooks: off` makes all of them print nothing, so none of this is
in the estimate below.
Cost of one run (estimate, not yet measured): about 2.5M tokens processed (about 2.25M cache read, 180k cache write, 17k output,
up to 300k uncached input), about 0.6-0.85M base-input units at A's weights; 9-13 minutes. --runs 3: 30-45 minutes.
Exit: H 10/10 in every run, every block <= 8,000 characters with no hard cut, C < 10/10 in every run -> PASS (rc 0); H misses
or a block is cut -> FAIL (rc 1); C reaches 10/10 -> rc 3, reported as is; stopped or void -> rc 2.
""" % (" ".join(NEEDED), FILLER_TURNS, FILLER_KB, WINDOW)


class Ctx(object):
    pass


def main(argv):
    p = argparse.ArgumentParser(prog="brain-probe", description="the B1 exit probe (live; not in CI)")
    p.add_argument("--plan", action="store_true")
    p.add_argument("--runs", type=int, default=3)
    p.add_argument("--model")
    p.add_argument("--preflight-model", default="haiku")
    p.add_argument("--method", choices=("try", "1", "2"), default="try")
    p.add_argument("--seed", type=int)
    p.add_argument("--claude")
    p.add_argument("--work")
    p.add_argument("--keep", action="store_true")
    p.add_argument("--keep-user-settings", action="store_true")
    p.add_argument("--filler-turns", type=int, default=FILLER_TURNS)
    p.add_argument("--filler-kb", type=int, default=FILLER_KB)
    a = p.parse_args(argv)
    if a.plan:
        sys.stdout.write(plan_text())
        return 0
    ctx = Ctx()
    ctx.a = a
    ctx.bin = a.claude or shutil.which("claude")
    if not ctx.bin:
        say("brain-probe: stopped: `claude` is not on PATH")
        return 2
    if os.environ.get("BRAIN_OFF", "") not in ("", "0"):
        say("brain-probe: stopped: BRAIN_OFF is set in this shell")
        return 2
    ctx.items, ctx.draft = load_set()
    ctx.seed = a.seed if a.seed is not None else int.from_bytes(os.urandom(3), "big")
    ctx.method = None if a.method == "try" else int(a.method)
    ctx.claude = Claude(ctx)
    ctx.runs = []
    ctx.work = os.path.abspath(a.work) if a.work else tempfile.mkdtemp(prefix="brain-probe-")
    os.makedirs(ctx.work, exist_ok=True)
    default = a.filler_turns == FILLER_TURNS and a.filler_kb == FILLER_KB and a.runs == EXIT_RUNS
    results, rc, lines = [], 0, []
    try:
        preflight(ctx)
        for n in range(1, a.runs + 1):
            r = run_once(ctx, n)
            if "void" in r:
                lines.append("run %d VOID: %s" % (n, "; ".join(r["void"])))
                rc = 2
                break
            results.append(r)
            lines += [arm_line(n, "H", r["H"]), arm_line(n, "C", r["C"]), cost_line(n, r["cost"])]
            for l in lines[-3:]:
                say(l)
    except Stop as e:
        lines.append("brain-probe: stopped: %s" % e)
        rc = 2
    except Exception as e:  # noqa: BLE001 — a crash is not a FAIL
        lines.append("brain-probe: stopped: internal error: %s: %s" % (e.__class__.__name__, str(e)[:300]))
        say(traceback.format_exc())
        rc = 2
    models = sorted(set(m for r in results for m in r["models"])) or [a.model or "default"]
    head = "brain-probe: model %s · method %s · runs %d of %d · seed %d · protocol %s" % (
        ", ".join(models), {1: "1 (auto)", 2: "2 (manual)", None: "none"}[ctx.method], len(results), a.runs, ctx.seed,
        "default" if default else "NOT default (%d runs, filler %d x %d KB): not an exit run" % (
            a.runs, a.filler_turns, a.filler_kb))
    out = [head]
    if getattr(ctx, "preflight", None):
        out.append("preflight: " + ctx.preflight)
    out += lines
    if rc == 0 and results:
        word, rc = verdict(results)
        if rc == 1 and not getattr(ctx, "replay_checked", False):
            word += " (the preflight could not check that the compact block is read after --resume: H may have missed it there)"
        out.append("exit: H %s of 10 (10/10 in %d of %d runs) · C %s of 10 · injected max %s of %s · cut max %s → %s" % (
            ", ".join(str(r["H"]["score"]) for r in results), sum(1 for r in results if r["H"]["score"] == 10), len(results),
            ", ".join(str(r["C"]["score"]) for r in results), n_(max(r["H"]["injected"] or 0 for r in results)),
            n_(BLOCK_LIMIT), n_(max(r["H"]["cut"] or 0 for r in results)), word))
    else:
        out.append("exit: not measured (rc 2)")
    tdirs = sorted(set(os.path.dirname(l["transcript_path"]) for r in getattr(ctx, "runs", []) for l in r.logs()
                       if l.get("transcript_path")))
    if tdirs:
        say("Claude Code keeps these sessions' transcripts under: %s" % ", ".join(tdirs))
    if a.keep:
        out.append("kept: %s" % ctx.work)
    else:
        shutil.rmtree(ctx.work, ignore_errors=True)
    sys.stdout.write("\n".join(out) + "\n")
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
