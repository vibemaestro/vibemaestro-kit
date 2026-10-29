#!/usr/bin/env python3
"""Median wall time of the PreToolUse hooks (`pre-edit.py`, `pre-bash.py`) of two plugin trees, side by side.

    python3 tests/hook-latency.py --before <plugin dir> --after <plugin dir> [--runs 40] [--session-start] [--packs]
    python3 tests/hook-latency.py --brain [--after <brain plugin dir>] [--before <brain plugin dir>] [--runs 40]

Not a suite (run-all.sh runs `test-*.sh` only): a measurement for a pull request that touches the hook path. It builds, in a
temporary directory, a bare remote and two clones with a rules directory (`rules.dirs`), five repo rules and five decisions:
one clone up to date and one a commit behind `origin/main` (the commit changes two rules and a decision). Each hook runs as
Claude Code runs it, a fresh `python3` with the payload on stdin, `--runs` times per cell:
  cold   a new session id per run (no dedup mark, no cache: the first hook of a session)
  warm   one session id for all runs (what every later hook of a session pays)
The two trees run interleaved, so a slow moment of the machine hits both. Standard library only; no network.
With --session-start it measures the `loi` SessionStart hook instead, in the up-to-date clone, for two baton states: `manual`
(no baton state, no settings: the common case) and `auto+rules` (mode auto, the launcher installed and the after tree's
`baton.py permissions --print` as the user settings: the full permission check runs), and the `boi-canh` SessionStart hook
(the rule catalogue) in the `manual` state.
With --packs every case has a plugin registry under `$HOME/.claude` (CLAUDE_CONFIG_DIR is never passed on): 10 plugins, 2 of
them rule packs of 7 rules each, none matching the measured edit or command, so every pack rule is read and tried.
With --brain it measures vibemaestro-brain's hooks (`brain_hook.py`) of one tree (default: this checkout's): SessionStart
in a project whose hot memory is at the tree's own count caps (every kind its store has) with full-length lines and quotes
(seeded through the store library, as the probe seeds it), run as the store's writer, `guard-owner` on `git status` (the cost
every Bash call pays), `guard-bash` on `brain op touch N1` without agent_id, and `guard-edit` on a project file; `python3 -c
pass` is printed for scale. SessionStart is every `session-start…` command of the tree's hooks.json started at once, as Claude
Code starts a plugin's commands of one event, timed until the last exits (`update-check` is left out: it is the same in both
trees). Every item of a kind that can close by a link carries one anchor, as `closes` where the tree's store has it (log format
2 or later) and as a plain anchor where it has not, and every pinned decision a plain one; texts are 150 characters in both
trees; a stub `gh` first on PATH answers every lookup `open`, and the anchors' answers are cached before the runs (warm). With
--before, SessionStart of that tree runs too, interleaved with the after tree's, each in its own project seeded the same way,
and the delta is printed with each tree's item count.
"""
import argparse
import json
import os
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
import uuid


def git(*args, cwd=None):
    subprocess.run(("git",) + args, cwd=cwd, check=True, capture_output=True)


def rule(path, body):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(body)


def build(tmp):
    remote, seed = os.path.join(tmp, "remote.git"), os.path.join(tmp, "seed")
    git("init", "-q", "--bare", "-b", "main", remote)
    git("clone", "-q", remote, seed)
    git("checkout", "-q", "-b", "main", cwd=seed)
    rule(os.path.join(seed, ".vibemaestro", "sdlc.json"), '{"schema": 1, "rules": {"dirs": ["policy"]}}')
    rule(os.path.join(seed, "src", "main.ts"), "")
    for i in range(5):
        rule(os.path.join(seed, "policy", "r%d.instructions.md" % i),
             '---\napplyTo: "src/**"\napplyWhen: "\\\\bacme-%d\\\\b"\ndescription: "rule %d"\n---\n\n# Rule %d\n\nv1\n' % (i, i, i))
        rule(os.path.join(seed, "kb", "decisions", "d%d.md" % i), '---\napplyTo: "src/**"\ndescription: "d%d"\n---\n\nv1\n' % i)
    git("add", "-A", cwd=seed)
    git("commit", "-qm", "c1", cwd=seed)
    git("push", "-q", "origin", "main", cwd=seed)
    up, behind = os.path.join(tmp, "up"), os.path.join(tmp, "behind")
    git("clone", "-q", remote, behind)
    for p in ("policy/r0.instructions.md", "policy/r1.instructions.md", "kb/decisions/d0.md"):
        with open(os.path.join(seed, p), "a") as f:
            f.write("v2\n")
    git("commit", "-qam", "c2", cwd=seed)
    git("push", "-q", "origin", "main", cwd=seed)
    git("fetch", "-q", cwd=behind)
    git("clone", "-q", remote, up)
    return {"up to date": up, "behind": behind}


def fake_registry(cfg):
    """A Claude Code plugin registry under `cfg`: 10 installed plugins, the first 2 depending on vibemaestro-sdlc with 7 rules each,
    all enabled in `cfg`'s user settings (what an install writes)."""
    plugins = {}
    for i in range(10):
        name = "p%d" % i
        inst = os.path.join(cfg, "plugins", "cache", "acme", name, "1.0.0")
        deps = [{"name": "vibemaestro-sdlc", "version": ">=2.5.0"}] if i < 2 else []
        rule(os.path.join(inst, ".claude-plugin", "plugin.json"), json.dumps({"name": name, "version": "1.0.0", "dependencies": deps}))
        for j in range(7 if i < 2 else 0):
            rule(os.path.join(inst, "rules", "%s-r%d.instructions.md" % (name, j)),
                 '---\napplyTo: "infra/**"\napplyWhen: "\\bkubectl-%d\\b"\ndescription: "pack rule %d"\n---\n\n# Rule\n\nv1\n' % (j, j))
        plugins[name + "@acme"] = [{"scope": "user", "installPath": inst, "version": "1.0.0"}]
    plugins["vibemaestro-sdlc@acme"] = [{"scope": "user", "version": "2.5.0", "auto": True,
                                         "installPath": os.path.join(cfg, "plugins", "cache", "acme", "vibemaestro-sdlc", "2.5.0")}]
    rule(os.path.join(cfg, "plugins", "installed_plugins.json"), json.dumps({"version": 2, "plugins": plugins}))
    rule(os.path.join(cfg, "settings.json"), json.dumps({"enabledPlugins": {k: True for k in plugins}}))


def payload(hook, repo, sid):
    if hook.startswith("session-start"):
        return {"session_id": sid, "hook_event_name": "SessionStart", "source": "startup"}
    if hook == "pre-edit":
        return {"session_id": sid, "hook_event_name": "PreToolUse", "tool_name": "Edit",
                "tool_input": {"file_path": os.path.join(repo, "src", "main.ts")}}
    return {"session_id": sid, "hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": {"command": "acme-3 --now"}}


def run_once(plugin, hook, repo, sid, env):
    e = dict(env, CLAUDE_PLUGIN_ROOT=plugin, CLAUDE_PROJECT_DIR=repo)
    data = json.dumps(payload(hook, repo, sid))
    t = time.perf_counter()
    hook, _, arg = hook.partition(":")
    argv = (sys.executable, os.path.join(plugin, "scripts", hook + ".py")) + (((arg or "loi"),) if hook == "session-start" else ())
    subprocess.run(argv, input=data, text=True, env=e, cwd=repo if hook == "session-start" else None, capture_output=True,
                   timeout=30)
    return (time.perf_counter() - t) * 1000


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--before")
    ap.add_argument("--after")
    ap.add_argument("--brain", action="store_true")
    ap.add_argument("--runs", type=int, default=40)
    ap.add_argument("--session-start", action="store_true")
    ap.add_argument("--packs", action="store_true")
    a = ap.parse_args()
    if a.brain:
        return brain(a)
    if not (a.before and a.after):
        ap.error("--before and --after are required (or --brain)")
    trees = {"before": os.path.abspath(a.before), "after": os.path.abspath(a.after)}
    tmp = tempfile.mkdtemp(prefix="hook-latency-")
    try:
        gcfg = os.path.join(tmp, "gitconfig")
        with open(gcfg, "w") as f:
            f.write("[user]\n\tname = t\n\temail = t@t\n[init]\n\tdefaultBranch = main\n")
        env = dict(os.environ, GIT_CONFIG_GLOBAL=gcfg, GIT_CONFIG_NOSYSTEM="1", HOME=tmp, TMPDIR=os.path.join(tmp, "t"),
                   PYTHONDONTWRITEBYTECODE="1")
        env.pop("CLAUDE_CONFIG_DIR", None)             # the registry read is the one under HOME, never the machine's
        os.makedirs(env["TMPDIR"])
        if a.packs:
            fake_registry(os.path.join(tmp, ".claude"))
        os.environ.update(GIT_CONFIG_GLOBAL=gcfg, GIT_CONFIG_NOSYSTEM="1")
        repos = build(tmp)
        print("median ms of %d runs (p90 in brackets); before = %s, after = %s%s" % (a.runs, trees["before"], trees["after"],
                                                                                   "; with a registry of 2 rule packs" if a.packs else ""))
        if a.session_start:
            return session_start(a, trees, repos["up to date"], env, tmp)
        print("%-9s %-11s %-5s %16s %16s %8s" % ("hook", "repo", "mode", "before", "after", "delta"))
        for hook in ("pre-edit", "pre-bash"):
            for rname, repo in repos.items():
                for mode in ("cold", "warm"):
                    ts = {k: [] for k in trees}
                    sids = {k: "lat-" + uuid.uuid4().hex for k in trees}
                    for _ in range(a.runs):
                        for k, pl in trees.items():
                            sid = sids[k] if mode == "warm" else "lat-" + uuid.uuid4().hex
                            ts[k].append(run_once(pl, hook, repo, sid, env))
                    med = {k: statistics.median(v) for k, v in ts.items()}
                    p90 = {k: sorted(v)[int(len(v) * 0.9) - 1] for k, v in ts.items()}
                    print("%-9s %-11s %-5s %8.1f [%5.1f] %8.1f [%5.1f] %+8.1f" % (
                        hook, rname, mode, med["before"], p90["before"], med["after"], p90["after"], med["after"] - med["before"]))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return 0


def session_start(a, trees, repo, env, tmp):
    after = os.path.join(trees["after"], "scripts", "baton.py")
    print("%-22s %-11s %16s %16s %8s" % ("hook", "baton", "before", "after", "delta"))
    for hook, case in (("session-start", "manual"), ("session-start", "auto+rules"), ("session-start:boi-canh", "manual")):
        home, state = os.path.join(tmp, "home-%s-%s" % (hook, case)), os.path.join(tmp, "state-%s-%s" % (hook, case))
        os.makedirs(os.path.join(home, ".claude"))
        if a.packs:
            fake_registry(os.path.join(home, ".claude"))
        e = dict(env, HOME=home, XDG_STATE_HOME=state)
        e.pop("CLAUDE_CONFIG_DIR", None)                # the settings below are the ones read
        if case == "auto+rules":
            for args in (("mode", "auto"), ("permissions", "--install-launcher")):
                subprocess.run((sys.executable, after) + args, env=e, capture_output=True, check=True)
            snip = subprocess.run((sys.executable, after, "permissions", "--print"), env=e, capture_output=True, text=True,
                                  check=True).stdout
            if a.packs:                                # the permission snippet and the enabled plugins in one settings file
                with open(os.path.join(home, ".claude", "settings.json")) as f:
                    snip = json.dumps(dict(json.loads(snip), enabledPlugins=json.load(f)["enabledPlugins"]))
            with open(os.path.join(home, ".claude", "settings.json"), "w") as f:
                f.write(snip)
        ts = {k: [] for k in trees}
        for _ in range(a.runs):
            for k, pl in trees.items():
                ts[k].append(run_once(pl, hook, repo, "lat-" + uuid.uuid4().hex, e))
        med = {k: statistics.median(v) for k, v in ts.items()}
        p90 = {k: sorted(v)[int(len(v) * 0.9) - 1] for k, v in ts.items()}
        print("%-22s %-11s %8.1f [%5.1f] %8.1f [%5.1f] %+8.1f" % (
            hook, case, med["before"], p90["before"], med["after"], p90["after"], med["after"] - med["before"]))
    return 0


SEED = r"""
import json, sys
sys.path.insert(0, sys.argv[1])
import brain_store as s
d = s.state_dir(sys.argv[2])
links = ["kb/" + "l" * 77] * 8
closes = getattr(s, "FORMAT", 1) >= 2                  # the store knows `closes`: a base before it gets plain anchors
linked = tuple(getattr(s, "CLOSES_LETTERS", ("N", "X")))
n = items = 0
with s.locked(d):
    raw = s.append(d, [], {"op": "claim", "t": s.now_iso(), "by": {"session": "lat", "agent": None}, "takeover": False})
    for letter, cap in s.CAPS.items():
        kind = [k for k, v in s.KINDS.items() if v == letter][0]
        for i in range(1, cap + 1):
            items += 1
            src = ({"type": "owner", "quote": "q" * 300, "where": "w" * 60} if letter in "DW" else {"type": "coordinator"})
            item = {"id": "%s%d" % (letter, i), "kind": kind, "pinned": letter == "D", "text": "t" * 150, "source": src,
                    "links": links, "anchors": [], "expires": "2099-01-02T22:00:00Z" if letter == "W" else None,
                    "supersedes": None}
            if letter in linked + ("D",):
                n += 1
                item["anchors"] = ["acme/app#%d" % n]
                if closes and letter in linked:
                    item["closes"] = item["anchors"]
            raw = s.append(d, raw, {"op": "owner-add" if letter in "DW" else "add", "t": s.now_iso(), "item": item,
                                    "by": {"session": "lat", "agent": None}})
    ops = [json.loads(b) for b in raw]
    s.write_caches(d, s.fold(ops), s.head_of(raw))
print(n, items)
"""
GH_STUB = """#!/bin/sh
# stub gh for the brain's lookups: every issue or PR is open, in the --jq shape the caller asks for
case "$*" in
  *state_reason*) printf 'open\\t\\t\\t\\tpr\\n' ;;
  *) printf 'open\\t\\t\\n' ;;
esac
"""


def brain_seed(plugin, project, env):
    """Hot memory at its count caps, every text 150 characters with 8 links, an anchor on every Now, Next and pinned item,
    appended through the tree's own store library (a subprocess, so two trees' libraries never meet). Returns the anchors."""
    r = subprocess.run((sys.executable, "-c", SEED, os.path.join(plugin, "scripts"), project), env=env, capture_output=True,
                       text=True, check=True)
    return [int(x) for x in r.stdout.split()]


def start_events(plugin):
    """The SessionStart commands of a brain tree that inject (`session-start…`), from its hooks.json."""
    h = json.load(open(os.path.join(plugin, "hooks", "hooks.json"), encoding="utf-8"))
    cmds = [c.get("command", "") for g in h["hooks"]["SessionStart"] for c in g["hooks"]]
    return [c.rsplit(" ", 1)[1] for c in cmds if c.rsplit(" ", 1)[-1].startswith("session-start")]


def brain(a):
    plugin = os.path.abspath(a.after or os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                                                     "plugins", "vibemaestro-brain"))
    trees = {"after": plugin}
    if a.before:
        trees = {"before": os.path.abspath(a.before), "after": plugin}
    tmp = tempfile.mkdtemp(prefix="hook-latency-b-")   # no hook word in the paths the input carries
    try:
        gcfg = os.path.join(tmp, "gitconfig")
        with open(gcfg, "w") as f:
            f.write("[user]\n\tname = t\n\temail = t@t\n[init]\n\tdefaultBranch = main\n")
        stub = os.path.join(tmp, "bin")
        os.makedirs(stub)
        with open(os.path.join(stub, "gh"), "w") as f:
            f.write(GH_STUB)
        os.chmod(os.path.join(stub, "gh"), 0o755)
        env = dict(os.environ, GIT_CONFIG_GLOBAL=gcfg, GIT_CONFIG_NOSYSTEM="1", HOME=tmp, XDG_STATE_HOME=os.path.join(tmp, "state"),
                   PYTHONDONTWRITEBYTECODE="1", PATH=stub + os.pathsep + os.environ.get("PATH", ""))
        for k in ("CLAUDE_CONFIG_DIR", "BRAIN_OFF", "INTENT_SLUG", "SEAT", "BRAIN_TEST", "BRAIN_TEST_PAUSE_MS", "BRAIN_DEFAULT_REPO",
                  "CLAUDE_PROJECT_DIR", "CLAUDE_CODE_SESSION_ID"):
            env.pop(k, None)
        os.environ.update(GIT_CONFIG_GLOBAL=gcfg, GIT_CONFIG_NOSYSTEM="1", HOME=tmp, XDG_STATE_HOME=env["XDG_STATE_HOME"])
        projs, anchors, items, events = {}, {}, {}, {}
        for name, tree in trees.items():
            projs[name] = os.path.join(tmp, "proj-" + name)
            os.makedirs(os.path.join(projs[name], "src"))
            git("init", "-q", "-b", "main", projs[name])
            anchors[name], items[name] = brain_seed(tree, projs[name], env)
            events[name] = start_events(tree)
        start = {"source": "compact", "hook_event_name": "SessionStart"}

        def run(tree, event, extra, sid):
            data = json.dumps(dict({"hook_event_name": "PreToolUse"}, session_id=sid, cwd=projs[tree], **extra))
            t = time.perf_counter()
            r = subprocess.run((sys.executable, os.path.join(trees[tree], "scripts", "brain_hook.py"), event), input=data,
                               text=True, env=env, cwd=projs[tree], capture_output=True, timeout=30)
            return (time.perf_counter() - t) * 1000, r.stdout

        def run_start(tree):
            """Every SessionStart command of the tree at once; (wall ms until the last exits, [the strings injected])."""
            data = json.dumps(dict(start, session_id="lat", cwd=projs[tree]))
            t = time.perf_counter()
            ps = [subprocess.Popen((sys.executable, os.path.join(trees[tree], "scripts", "brain_hook.py"), e), stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, env=env, cwd=projs[tree])
                  for e in events[tree]]
            for p in ps:                                # every command gets its input at once, as Claude Code gives it
                p.stdin.write(data)
                p.stdin.close()
            outs = [p.stdout.read() for p in ps]        # a string is ≤ 10,000 characters: no pipe fills
            for p in ps:
                p.wait(timeout=30)
            ms = (time.perf_counter() - t) * 1000
            return ms, [json.loads(o)["hookSpecificOutput"]["additionalContext"] if o.strip() else "" for o in outs]

        for name in trees:                              # warm: every anchor answered and cached (12 lookups per start)
            for _ in range(2 + anchors[name] // 12):
                run_start(name)
        here = os.path.relpath(plugin, os.getcwd())
        print("vibemaestro-brain hooks, %s; median ms of %d runs (p90 in brackets)" % (
            here if not here.startswith("..") else os.path.basename(plugin), a.runs))   # no local path in a PR body
        base = []
        for _ in range(a.runs):
            t = time.perf_counter()
            subprocess.run((sys.executable, "-c", "pass"), env=env, capture_output=True)
            base.append((time.perf_counter() - t) * 1000)
        print("%-14s %8.1f [%5.1f]" % ("python3 -c pass", statistics.median(base), sorted(base)[int(len(base) * 0.9) - 1]))
        ts, outs = {k: [] for k in trees}, {}
        for _ in range(a.runs):                         # the writer's SessionStart, the trees interleaved
            for name in trees:
                ms, outs[name] = run_start(name)
                ts[name].append(ms)
        for name in trees:
            if "hot memory" not in outs[name][0] or "checked" in outs[name][0]:
                print("SessionStart (%s) injected no hot memory, or not from a warm cache: the measurement is void" % name)
                return 1
        med = {k: statistics.median(v) for k, v in ts.items()}
        for name in trees:
            print("%-14s %8.1f [%5.1f]  (%s; %d command%s; %s characters injected; writer, warm cache, %d items, %d anchors)" % (
                "SessionStart", med[name], sorted(ts[name])[int(len(ts[name]) * 0.9) - 1], name, len(events[name]),
                "" if len(events[name]) == 1 else "s", " + ".join("{:,}".format(len(o)) for o in outs[name]), items[name],
                anchors[name]))
        if a.before:
            print("%-14s %+8.1f  (after - before)" % ("delta", med["after"] - med["before"]))
        cases = [
            ("guard-owner", "guard-owner", {"tool_name": "Bash", "tool_input": {"command": "git status"}, "permission_mode": "default"}),
            ("guard-bash", "guard-bash", {"tool_name": "Bash", "tool_input": {"command": "brain op touch N1"}}),
            ("guard-edit", "guard-edit", {"tool_name": "Edit", "tool_input": {"file_path": os.path.join(projs["after"], "src", "main.py")}}),
        ]
        for label, event, extra in cases:
            ts1 = [run("after", event, extra, "lat-" + uuid.uuid4().hex)[0] for _ in range(a.runs)]
            print("%-14s %8.1f [%5.1f]" % (label, statistics.median(ts1), sorted(ts1)[int(len(ts1) * 0.9) - 1]))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
