"""vibemaestro-brain matrix: what the brain holds, cell by cell, and what it did in this session (`brain matrix [--json]`).

Seven rows, one per cell of the two axes (Know/Do × hot/warm/cold; Do·warm is two rows: the Workbench, and code intelligence
(external)), each ≤ 300 bytes like a `kb.py find` line:
    cell | store | size chars (≈tokens) | loaded when | forgetting rule | last consolidated | survives compaction | warnings
then "this session": hook lines per event, characters injected, compactions, the last loss score and cost line, the ops that
bend the anti-collapse guard. Read-only: it writes nothing. Tokens are characters ÷ 4 (not calibrated).
"""
import json
import os
import re
import sys

import brain_hook as h
import brain_store as s

ROW_MAX = 300
COLUMNS = ("cell", "store", "size", "loaded", "forgetting", "consolidated", "survives", "warnings")
HEADER = ("Brain Matrix · Know (left) / Do (right) × hot / warm / cold\n"
          "cell | store | size chars (≈tokens) | loaded when | forgetting rule | last consolidated | survives compaction | "
          "warnings")


def nbytes(t):
    return len(t.encode("utf-8"))


def size(chars):
    return "%s (≈%s)" % ("{:,}".format(chars), "{:,}".format(chars // 4))


def fit(fields):
    """Join the fields; while the row is over ROW_MAX bytes, cut its longest field and end it with `…`."""
    fields = [s.clean_line(f) for f in fields]
    while nbytes(" | ".join(fields)) > ROW_MAX:
        i = max(range(len(fields)), key=lambda k: nbytes(fields[k]))
        keep = max(0, nbytes(fields[i]) - (nbytes(" | ".join(fields)) - ROW_MAX) - nbytes("…"))
        fields[i] = fields[i].encode("utf-8")[:keep].decode("utf-8", "ignore") + "…"
    return fields


def listing(names, room):
    """`a, b, c +N` in at most `room` bytes."""
    shown = []
    for i, n in enumerate(names):
        rest = len(names) - i - 1
        cand = ", ".join(shown + [n]) + (" +%d" % rest if rest else "")
        if nbytes(cand) > room:
            break
        shown.append(n)
    more = len(names) - len(shown)
    return ", ".join(shown) + (" +%d" % more if more else "") if shown else ("+%d" % more if more else "none enabled")


def code_intelligence(project):
    """Enabled plugins that bring a language server: named `*-lsp`, with `.lsp.json` or `lspServers`, or serena."""
    out = []
    for name, path in sorted(h.enabled_plugins(s, project).items()):
        if name.endswith("-lsp") or name == "serena" or os.path.isfile(os.path.join(path, ".lsp.json")):
            out.append(name)
        elif "lspServers" in (s._json_file(os.path.join(path, ".claude-plugin", "plugin.json")) or {}):
            out.append(name)
    return out


def lines_of(p):
    try:
        with open(p, "rb") as f:
            return sum(1 for _ in f), os.path.getsize(p)
    except OSError:
        return 0, 0


def kb_count(root, sub):
    d = os.path.join(root, "kb", sub)
    n = b = 0
    for dirpath, _, files in os.walk(d):
        for f in files:
            if f.endswith(".md"):
                n += 1
                try:
                    b += os.path.getsize(os.path.join(dirpath, f))
                except OSError:
                    pass
    return n, b


def episodes(d):
    out = []
    try:
        with open(os.path.join(d, "episodes.jsonl"), encoding="utf-8", errors="replace") as f:
            for raw in f:
                try:
                    o = json.loads(raw)
                except ValueError:
                    continue
                if isinstance(o, dict):
                    out.append(o)
    except OSError:
        pass
    return out


def rows(cwd):
    d = s.state_dir(cwd)
    project = os.environ.get("CLAUDE_PROJECT_DIR") or s.project_root(cwd)
    st, warn_hot, hot_chars = None, [], 0
    if os.path.isfile(os.path.join(d, "hot.jsonl")):
        try:
            _, st = s.load(d)
            parts = s.render_parts(st)
            hot_chars = len(s.join_parts(parts))
            over = [p for p, _ in s.PARTS                      # in UTF-16 units, as the SessionStart cut counts
                    if len(parts[p].encode("utf-16-le")) // 2 > (s.RENDER_CAP if p == "hot" else s.STRING_MAX)]
            if over:                                   # first: the row keeps ≤ 300 bytes, and the end of a field is cut
                warn_hot.append("over: " + ", ".join(over))
            for letter, title in s.SECTIONS:
                n = len(s.live(st, letter))
                if n >= s.WARN_RATIO * s.CAPS[letter]:
                    warn_hot.append("%s %d/%d" % (title.split(" ")[0], n, s.CAPS[letter]))
        except s.Refused:
            warn_hot.append("the chain is broken: brain doctor")
    else:
        warn_hot.append("no state yet")
    out = [["Know·hot", "Hot Memory hot.md" + "; repo index (shared; sdlc injects it at SessionStart when current_state.inject is on)", size(hot_chars),
            "SessionStart, every source", "owner supersede or unpin; windows expire; others closed",
            "never (Sleep pass: B2.3)", "re-injected", ", ".join(warn_hot)],
           ["Do·hot", "Artifact Index: not built (B2.1)", "—", "—", "PR merged or closed (B2.2)", "—",
            "re-injected (from B2.1)", ""]]
    shelf = h.shelf_index(s, project)
    m = re.search(r"\((\d+) more skills? not listed\)", shelf)
    out.append(["Know·warm", "Shelf: skills, rules, kb.py find (sdlc); the Shelf index", size(len(shelf)),
                "skills on demand; the index at SessionStart", "owned by sdlc", "—",
                "the Shelf index re-injected; skill bodies to the docs' caps", "%s skills not listed" % m.group(1) if m else ""])
    root = os.path.dirname(s.state_root())
    bn, bb = lines_of(os.path.join(root, "baton", "log.tsv"))
    mn, mb = lines_of(os.path.join(root, "merge-log.jsonl"))
    out.append(["Do·warm", "Workbench: baton log %d lines, merge log %d lines" % (bn, mn), "%s on disk" % "{:,}".format(bb + mb),
                "on demand (baton log, merge guard)", "—", "—", "nothing", ""])
    if os.environ.get("CLAUDE_CODE_REMOTE") == "true":
        ci = ["Do·warm", "code intelligence (external): not started (cloud session)", "—", "on use (tools)", "—", "—",
              "tools; nothing held in context", ""]
    else:
        ci = ["Do·warm", "code intelligence (external): ", "—", "on use (tools)", "—", "—", "tools; nothing held in context", ""]
        names = code_intelligence(project)
        room = ROW_MAX - nbytes(" | ".join(fit(ci)))
        ci[1] += listing(names, room)
    out.append(ci)
    dn, db = kb_count(project, "decisions")
    sn, sb = kb_count(project, "specs")
    out.append(["Know·cold", "Library: kb/decisions %d, kb/specs %d" % (dn, sn), "%s on disk" % "{:,}".format(db + sb),
                "read on demand, never whole", "superseded in place", "—", "on disk", "" if os.path.isdir(
                    os.path.join(project, "kb")) else "no kb/"])
    en, eb = lines_of(os.path.join(d, "episodes.jsonl"))
    sums = len([f for f in (os.listdir(os.path.join(d, "summaries")) if os.path.isdir(os.path.join(d, "summaries")) else [])
                if f.endswith(".md")])
    out.append(["Do·cold", "Episode Log: episodes.jsonl %d lines, summaries %d" % (en, sums),
                "%s on disk" % "{:,}".format(eb), "never (pointers)", "summaries: newest 200 kept", "—", "on disk", ""])
    return [fit(r) for r in out], d, st


def did(d, st):
    """What the brain did in this session (CLAUDE_CODE_SESSION_ID), else in all sessions."""
    sid = s.session_id() or None
    eps = episodes(d)
    mine = [e for e in eps if sid is None or e.get("session") == sid]
    kinds = ("session-start", "pre-compact", "compact", "session-end", "owner-call", "cost")
    counts = dict((k, sum(1 for e in mine if e.get("kind") == k)) for k in kinds)
    inj = [e.get("injected") for e in mine if e.get("kind") == "session-start" and isinstance(e.get("injected"), int)]
    comp = [e for e in mine if e.get("kind") == "compact"]
    loss = [e.get("loss") for e in comp if e.get("loss") is not None]
    cost = [e for e in mine if e.get("kind") == "cost"]
    flags = {"bulk": 0, "shorter": 0, "drop-anchor": 0}
    if st is not None:
        try:
            for op in s.verify(d)[1]:
                if sid is not None and (op.get("by") or {}).get("session") != sid:
                    continue
                flags["bulk"] += bool(op.get("bulk"))
                flags["shorter"] += bool(op.get("shorter"))
                flags["drop-anchor"] += bool(op.get("drop"))
        except s.Refused:
            pass
    return {"scope": "this session" if sid else "all sessions", "hooks": counts,
            "injected_last": inj[-1] if inj else None, "injected_total": sum(inj),
            "compactions": len(comp), "last_trigger": comp[-1].get("trigger") if comp else None,
            "context_before": comp[-1].get("context_before") if comp else None,
            "loss": loss[-1] if loss else None, "cost": {k: cost[-1].get(k) for k in ("calls", "units", "split", "through")}
            if cost else None, "sleep": "not built (B2.3)", "artifact_index": "not built (B2.1)", "flags": flags}


def did_text(w):
    n = lambda x: "—" if x is None else "{:,}".format(x)
    out = ["%s:" % w["scope"],
           "  hooks: " + " · ".join("%s %d" % (k, v) for k, v in w["hooks"].items()),
           "  injected last %s · total %s characters" % (n(w["injected_last"]), n(w["injected_total"])),
           "  compactions %d%s" % (w["compactions"], " (last %s, context before %s)" % (w["last_trigger"], n(
               w["context_before"])) if w["compactions"] else ""),
           "  loss %s (last)" % ("—" if w["loss"] is None else w["loss"])]
    c = w["cost"]
    if c:
        units = (c.get("units") or {}).get("total")
        sp = c.get("split") or {}
        out.append("  cost (last line): %s calls · %s units · read %s · write %s · output %s · through %s" % (
            c.get("calls"), n(int(round(units))) if isinstance(units, (int, float)) else "—",
            *["%.0f%%" % (sp[k] * 100) if isinstance(sp.get(k), (int, float)) else "—" for k in ("read", "write", "output")],
            c.get("through")))
    else:
        out.append("  cost: no line yet (SessionEnd after a compaction writes one)")
    out.append("  Sleep pass: %s · Artifact Index: %s" % (w["sleep"], w["artifact_index"]))
    out.append("  --bulk %d · --shorter %d · --drop-anchor %d" % (w["flags"]["bulk"], w["flags"]["shorter"],
                                                                   w["flags"]["drop-anchor"]))
    return out


def main(as_json):
    rs, d, st = rows(None)                                 # this session's project, else the working directory's
    w = did(d, st)
    if as_json:
        sys.stdout.write(json.dumps({"header": HEADER, "rows": [dict(zip(COLUMNS, r), line=" | ".join(r)) for r in rs],
                                     "did": w}) + "\n")
        return None
    out = HEADER.split("\n") + [" | ".join(r) for r in rs] + [""] + did_text(w)
    sys.stdout.write("".join(s.printable(l) + "\n" for l in out))
    return None
