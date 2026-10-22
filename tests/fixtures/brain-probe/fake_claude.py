#!/usr/bin/env python3
"""A fake `claude` for tests/test-brain-matrix.sh: the probe's logic is tested against this, never a live session (a sandbox's
nested claude is not logged in). It plays the part of Claude Code that tests/live/brain-probe.sh relies on:

- `-p PROMPT`, `--output-format json`, `--resume ID`, `--fork-session`, `--plugin-dir D`, `--settings FILE|JSON`,
  `--setting-sources`, `--tools`, `--allowedTools`, `--model`, `--help`;
- transcripts in the recorded shape (two `assistant` records per `message.id` with `usage` and its TTL split,
  `hook_additional_context` attachments, a `compact_boundary` record and an `isCompactSummary` user record), under
  $FAKE_HOME/projects/<cwd with every non-alphanumeric as ->/<session>.jsonl;
- the rule for `--plugin-dir` plugins (measured by the coordinator on 2.1.303, `dependency-unsatisfied`): a plugin whose plugin.json
  declares a dependency that is not itself loaded is not loaded, so its hooks do not run; the installed plugins are not
  consulted (the probe runs with --setting-sources project,local);
- the plugin's and the settings' command hooks (SessionStart, PreCompact, PostCompact, SessionEnd) with Claude Code's input fields;
  a SessionStart hook's additionalContext becomes a `hook_additional_context` attachment (list content, hookName SessionStart)
  and its raw stdout a `hook_success` one, as measured on a 2.1.290 transcript; the brain sees the environment the fake was
  given (BRAIN_OFF, XDG_STATE_HOME);
- compaction on `/compact`, or before a prompt when the visible context is past CLAUDE_CODE_AUTO_COMPACT_WINDOW less 13,000;
  the summary keeps the anchors of the first FAKE_SUMMARY_KEEP (6) owner decisions and, for the rest, a near miss read in the
  notes (a summary that drifts); it never copies an attachment;
- an answer to numbered questions from what is visible after the last compaction: the brain's block first, then the summary.

Switches: FAKE_NOT_LOGGED_IN, FAKE_NO_AUTO, FAKE_NO_SLASH, FAKE_NO_COMPACT_INJECT, FAKE_TWO_BRAINS, FAKE_WRITE_MEMORY,
FAKE_HEDGE, FAKE_HELP_DROP=<flag>, FAKE_BASE_TOKENS (10,000: the system prompt), FAKE_SUMMARY_KEEP, FAKE_IGNORE_BLOCK (the
model never reads an attachment), FAKE_SUMMARY_COPIES_BLOCK (the summary keeps what an earlier block said),
FAKE_SUMMARY_LISTS_PROMPTS (the summary lists the user's prompts, the one being answered included, as 2.1.290's compaction
prompt asks), FAKE_SESSIONSTART_FIRST (SessionStart:compact before PostCompact), FAKE_COMPACT_IN_FILLER, FAKE_FORK_SOURCE (the SessionStart source a fork reports; real: fork), FAKE_ODD_RESULT (a
non-string result to the questions). A switch ending in _AFTER_PREFLIGHT acts only outside the probe's preflight directory.
"""
import glob
import json
import os
import re
import subprocess
import sys
import time
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
FLAGS = ("--print", "--output-format", "--resume", "--fork-session", "--plugin-dir", "--settings", "--setting-sources",
         "--strict-mcp-config", "--tools", "--allowedTools", "--model")
VALUED = ("--output-format", "--resume", "--plugin-dir", "--settings", "--setting-sources", "--tools", "--allowedTools",
          "--model")
BUFFER = 13000


def loaded_plugin_dirs(dirs):
    """The `--plugin-dir`s Claude Code would load: one whose manifest declares a dependency by name that no loaded one gives is
    dropped, and dropping it can drop what depended on it, so the check repeats until nothing changes. A version is not compared
    (the probe's own preflight does that); a directory with no readable manifest is loaded as is."""
    info = {}
    for d in dirs:
        try:
            m = json.load(open(os.path.join(d, ".claude-plugin", "plugin.json"), encoding="utf-8"))
        except (OSError, ValueError):
            m = {}
        deps = [x.get("name") if isinstance(x, dict) else x for x in (m.get("dependencies") or [])]
        info[d] = (m.get("name"), deps)
    loaded = list(dirs)
    while True:
        names = set(info[d][0] for d in loaded)
        keep = [d for d in loaded if all(n in names for n in info[d][1])]
        if keep == loaded:
            return loaded
        loaded = keep


def switch(name):
    """FAKE_<name>, or FAKE_<name>_AFTER_PREFLIGHT outside the probe's preflight directory."""
    return bool(os.environ.get("FAKE_" + name)) or (bool(os.environ.get("FAKE_%s_AFTER_PREFLIGHT" % name))
                                                     and "%spreflight%s" % (os.sep, os.sep) not in os.getcwd() + os.sep)


def env_int(name, default):
    try:
        return int(os.environ.get(name, default))
    except ValueError:
        return default


def iso(t=None):
    t = time.time() if t is None else t
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(t)) + ".%03dZ" % int((t % 1) * 1000)


def items():
    return json.load(open(os.path.join(HERE, "probe-set.json"), encoding="utf-8"))["items"]


def token_re(it):
    return re.compile(r"\b%s-\d{2}\b" % it["word"] if it["kind"] == "code" else r"\b[0-9a-f]{7}\b", re.I)


class Session(object):
    def __init__(self, a):
        self.a = a
        self.cwd = os.getcwd()
        self.model = a["model"] or "fake-model"
        home = os.environ.get("FAKE_HOME") or os.path.join(os.path.expanduser("~"), ".fake-claude")
        self.dir = os.path.join(home, "projects", re.sub(r"[^A-Za-z0-9]", "-", self.cwd))
        os.makedirs(self.dir, exist_ok=True)
        self.records, source = [], "startup"
        if a["resume"]:
            found = glob.glob(os.path.join(home, "projects", "*", a["resume"] + ".jsonl"))
            if not found:
                raise SystemExit(self.fail("No conversation found with session ID: %s" % a["resume"]))
            with open(found[0], encoding="utf-8") as f:
                self.records = [json.loads(l) for l in f if l.strip()]
            source = (os.environ.get("FAKE_FORK_SOURCE") or "fork") if a["fork"] else "resume"
            self.sid = str(uuid.uuid4()) if a["fork"] else a["resume"]
        else:
            self.sid = str(uuid.uuid4())
        self.path = os.path.join(self.dir, self.sid + ".jsonl")
        with open(self.path, "w", encoding="utf-8") as f:
            for r in self.records:
                r = dict(r, sessionId=self.sid) if "sessionId" in r else r
                f.write(json.dumps(r) + "\n")
        self.usage = {"input_tokens": 0, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0, "output_tokens": 0}
        self.start_source = source

    def fail(self, msg):
        sys.stdout.write(json.dumps({"type": "result", "subtype": "success", "is_error": True, "result": msg,
                                     "session_id": None}) + "\n")
        return 1

    def add(self, rec):
        rec = dict(rec, sessionId=self.sid, timestamp=rec.get("timestamp") or iso())
        self.records.append(rec)
        with open(self.path, "a", encoding="utf-8") as f:
            f.write(json.dumps(rec) + "\n")

    def visible(self):
        last = 0
        for i, r in enumerate(self.records):
            if r.get("type") == "system" and r.get("subtype") == "compact_boundary":
                last = i + 1
        return self.records[last:]

    def tokens(self):
        return env_int("FAKE_BASE_TOKENS", 10000) + len(json.dumps(self.visible())) // 4

    # --- hooks ----------------------------------------------------------------------------------------------------------------
    def hook_commands(self, event):
        out = []
        for pd in loaded_plugin_dirs(self.a["plugin_dirs"]):
            try:
                hooks = json.load(open(os.path.join(pd, "hooks", "hooks.json"), encoding="utf-8"))["hooks"]
            except (OSError, ValueError, KeyError):
                continue
            for _ in range(2 if os.environ.get("FAKE_TWO_BRAINS") else 1):
                for entry in hooks.get(event, []):
                    for h in entry.get("hooks", []):
                        if h.get("type") == "command":
                            out.append((h["command"].replace("${CLAUDE_PLUGIN_ROOT}", pd), pd))
        st = self.a["settings"]
        if st:
            try:
                obj = json.loads(st) if st.lstrip().startswith("{") else json.load(open(st, encoding="utf-8"))
            except (OSError, ValueError):
                obj = {}
            for entry in (obj.get("hooks") or {}).get(event, []):
                for h in entry.get("hooks", []):
                    if h.get("type") == "command":
                        out.append((h["command"], None))
        return out

    def run_hooks(self, event, **fields):
        inp = dict(fields, session_id=self.sid, transcript_path=self.path, cwd=self.cwd, hook_event_name=event)
        contexts = []
        for cmd, root in self.hook_commands(event):
            env = dict(os.environ, CLAUDE_PROJECT_DIR=self.cwd)
            if root:
                env["CLAUDE_PLUGIN_ROOT"] = root
            p = subprocess.run(["sh", "-c", cmd], input=json.dumps(inp), capture_output=True, text=True, env=env, timeout=60)
            out = p.stdout.strip()
            if not out:
                continue
            if event == "SessionStart":         # measured: the raw stdout is kept too, as a hook_success attachment
                self.add({"type": "attachment", "attachment": {"type": "hook_success", "hookEvent": event, "hookName":
                                                               "SessionStart:" + fields.get("source", ""), "content": out}})
            try:
                ctx = (json.loads(out).get("hookSpecificOutput") or {}).get("additionalContext")
            except (ValueError, AttributeError):
                ctx = out
            if ctx:
                contexts.append(ctx)
        if event == "SessionStart":
            for c in contexts:
                self.add({"type": "attachment", "attachment": {"type": "hook_additional_context", "hookEvent": event,
                                                               "hookName": event, "content": [c]}})

    # --- the model ------------------------------------------------------------------------------------------------------------
    def call(self, text, block="text"):
        ctx = self.tokens()
        prev = 0
        for r in reversed(self.visible()):
            if r.get("type") == "assistant":
                u = r["message"]["usage"]
                prev = u["input_tokens"] + u["cache_read_input_tokens"] + u["cache_creation_input_tokens"]
                break
        read = min(prev, ctx)
        u = {"input_tokens": 3, "cache_read_input_tokens": read, "cache_creation_input_tokens": max(0, ctx - read - 3),
             "cache_creation": {"ephemeral_1h_input_tokens": max(0, ctx - read - 3), "ephemeral_5m_input_tokens": 0},
             "output_tokens": len(text) // 4 + 1}
        mid = "msg_" + uuid.uuid4().hex[:24]
        for b in ("thinking", block):
            self.add({"type": "assistant", "isSidechain": False, "requestId": "req_" + mid[4:],
                      "message": {"id": mid, "model": self.model, "role": "assistant",
                                  "content": [{"type": b, "text": text if b != "thinking" else ""}], "usage": u}})
        for k in self.usage:
            self.usage[k] += u[k]

    def summary(self, pending=None):
        vis = self.visible()
        users = [r["message"]["content"] for r in vis if r.get("type") == "user" and isinstance(r.get("message"), dict)
                 and isinstance(r["message"].get("content"), str)]
        notes = [r["toolUseResult"] for r in vis if r.get("type") == "user" and isinstance(r.get("toolUseResult"), str)]
        blocks = [json.dumps(r["attachment"].get("content"), ensure_ascii=False).replace("\\n", "\n") for r in vis
                  if r.get("type") == "attachment" and r["attachment"].get("type") == "hook_additional_context"]
        keep = env_int("FAKE_SUMMARY_KEEP", 6)
        lines = ["Summary of the conversation so far.", "Owner decisions:"]
        for n, it in enumerate(items()):
            said = [u for u in users if "Owner decision" in u and it["topic"] in u]
            anchor = token_re(it).search(said[0]).group(0) if said and token_re(it).search(said[0]) else None
            copied = None
            if os.environ.get("FAKE_SUMMARY_COPIES_BLOCK"):
                for line in "\n".join(blocks).splitlines():
                    if it["topic"].lower() in line.lower() and token_re(it).search(line):
                        copied = token_re(it).search(line).group(0)
                        break
            if (anchor and n < keep) or copied:
                lines.append("- %s: %s" % (it["topic"], copied or anchor))
                continue
            near = None
            for t in notes:
                for line in t.splitlines():
                    if it["topic"] in line:
                        m = [x for x in token_re(it).findall(line) if x != anchor]
                        if m:
                            near = m[0]
                            break
                if near:
                    break
            lines.append("- %s: %s" % (it["topic"], near or "(not kept)"))
        lines.append("The assistant read %d notes files." % len(notes))
        if os.environ.get("FAKE_SUMMARY_LISTS_PROMPTS"):
            lines.append("User messages: " + " | ".join(u for u in users + [pending or ""] if u and "Owner decision" not in u))
        return "\n".join(lines)

    def compact(self, trigger, pending=None):
        self.run_hooks("PreCompact", trigger=trigger, custom_instructions="")
        text = self.summary(pending)
        pre = self.tokens()
        self.add({"type": "system", "subtype": "compact_boundary", "content": "Conversation compacted",
                  "compactMetadata": {"trigger": trigger, "preTokens": pre}})
        self.add({"type": "user", "isCompactSummary": True, "message": {"role": "user", "content": text}})
        first = os.environ.get("FAKE_SESSIONSTART_FIRST")      # 2.1.290's usual order (round 2 read it in the binary)
        if first and not switch("NO_COMPACT_INJECT"):
            self.run_hooks("SessionStart", source="compact")
        self.run_hooks("PostCompact", trigger=trigger, compact_summary=text)
        if not first and not switch("NO_COMPACT_INJECT"):
            self.run_hooks("SessionStart", source="compact")

    def answer(self, prompt):
        qs = re.findall(r"(?m)^(\d+)\. (.+)$", prompt)
        vis = self.visible()
        blocks, rest = [], []
        for r in vis:
            if r.get("type") == "attachment" and r["attachment"].get("type") == "hook_additional_context":
                if not switch("IGNORE_BLOCK"):
                    blocks.append(json.dumps(r["attachment"].get("content"), ensure_ascii=False).replace("\\n", "\n"))
            elif r.get("type") == "user" and r.get("isCompactSummary"):
                rest.append(r["message"]["content"])
        if "preflight decision" in prompt:
            for line in "\n".join(blocks + rest).splitlines():
                m = re.search(r"\b[0-9a-f]{7}\b", line) if "Preflight decision" in line else None
                if m:
                    return m.group(0)
            return "unknown"
        if not qs:
            if "Owner decision" in prompt:
                return "noted"
            return "ok"
        if os.environ.get("FAKE_ODD_RESULT"):
            return {"odd": True}
        its = items()
        out = {}
        for n, q in qs:
            it = next((x for x in its if x["topic"] in q), None)
            got = None
            for text in blocks + rest:
                for line in text.splitlines():
                    if it and it["topic"].lower() in line.lower():
                        m = token_re(it).search(line)
                        if m:
                            got = m.group(0)
                            break
                if got:
                    break
            out[int(n)] = got
        lines = []
        for n, q in qs:
            n = int(n)
            a = out[n] or "unknown"
            if os.environ.get("FAKE_HEDGE") and out[n]:
                if n == 1:
                    w, d = a.rsplit("-", 1)
                    a = "%s-%02d or %s" % (w, (int(d) + 1) % 90 + 10, a)
                elif n == 2:
                    a = "**`%s`**." % a
                elif n == 3:
                    a = a.lower()
                elif n == 4:
                    a = "%s (or %s)" % (a, out.get(5) or "HERON-00")
            lines.append("%d. %s" % (n, a))
        return "\n".join(lines)

    def turn(self, prompt):
        if prompt.strip() == "/compact" and not os.environ.get("FAKE_NO_SLASH"):
            self.compact("manual")
            return "Compacted."
        window = os.environ.get("CLAUDE_CODE_AUTO_COMPACT_WINDOW")
        m = re.match(r"Read (\S+)", prompt)
        if (window and not os.environ.get("FAKE_NO_AUTO") and self.tokens() > int(window) - BUFFER) or (
                m and os.environ.get("FAKE_COMPACT_IN_FILLER")):
            self.compact("auto", pending=prompt)        # inside the query: the pending prompt is summarised too
        self.add({"type": "user", "message": {"role": "user", "content": prompt}})
        if m and "Read" in (self.a["tools"] or "") and os.path.isfile(os.path.join(self.cwd, m.group(1))):
            self.call("", block="tool_use")
            body = open(os.path.join(self.cwd, m.group(1)), encoding="utf-8").read()
            self.add({"type": "user", "toolUseResult": body, "message": {"role": "user", "content": [
                {"type": "tool_result", "content": body}]}})
            text = "It has %d entries." % body.count("## Entry")
        else:
            text = self.answer(prompt)
        self.call(text if isinstance(text, str) else json.dumps(text))
        return text


def parse(argv):
    a = {"prompt": None, "resume": None, "fork": False, "plugin_dirs": [], "settings": None, "tools": None, "model": None,
         "help": False}
    i = 0
    while i < len(argv):
        x = argv[i]
        if x in ("-p", "--print"):
            if i + 1 < len(argv) and not argv[i + 1].startswith("--"):
                a["prompt"] = argv[i + 1]
                i += 1
        elif x in ("--help", "-h"):
            a["help"] = True
        elif x == "--fork-session":
            a["fork"] = True
        elif x == "--strict-mcp-config":
            pass
        elif x in VALUED and i + 1 < len(argv):
            v = argv[i + 1]
            i += 1
            if x == "--resume":
                a["resume"] = v
            elif x == "--plugin-dir":
                a["plugin_dirs"].append(v)
            elif x == "--settings":
                a["settings"] = v
            elif x == "--tools":
                a["tools"] = v
            elif x == "--model":
                a["model"] = v
        elif a["prompt"] is None:
            a["prompt"] = x
        i += 1
    return a


def main(argv):
    a = parse(argv)
    if a["help"]:
        drop = os.environ.get("FAKE_HELP_DROP", "")
        sys.stdout.write("Usage: claude [options] [prompt]\n" + "".join("  %s\n" % f for f in FLAGS if f != drop))
        return 0
    if os.environ.get("FAKE_NOT_LOGGED_IN"):
        sys.stdout.write(json.dumps({"type": "result", "is_error": True, "result": "Not logged in · Please run /login",
                                     "session_id": str(uuid.uuid4())}) + "\n")
        return 1
    s = Session(a)
    s.run_hooks("SessionStart", source=s.start_source)
    if os.environ.get("FAKE_WRITE_MEMORY"):
        os.makedirs(os.path.join(s.dir, "memory"), exist_ok=True)
        open(os.path.join(s.dir, "memory", "MEMORY.md"), "a").write("- a note\n")
    text = s.turn(a["prompt"] or "")
    s.run_hooks("SessionEnd", reason="other")
    sys.stdout.write(json.dumps({"type": "result", "subtype": "success", "is_error": False, "result": text,
                                 "session_id": s.sid, "total_cost_usd": 0.0, "usage": s.usage,
                                 "modelUsage": {s.model: dict(s.usage)}}) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
