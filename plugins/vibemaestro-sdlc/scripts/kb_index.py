#!/usr/bin/env python3
"""Find what is in `kb/` without reading it: `find`, `list`, `outline` and the lifecycle `check` behind `kb.py`.

Read-only: nothing here writes a file, calls the network or prints a document body. Every call reads `kb/` again (no index
file on disk), which costs well under a second on a few hundred documents.

Indexed documents: `kb/**/*.md` except `kb/README.md` and the current-state file. Each one gives one line:

    <path> | <type> | <status> | <date> | <description>[ | superseded_by: <path>]

    type    from the directory: intent/ -> intent, specs/ -> spec, plans/ -> plan, decisions/ -> decision; any other
            directory gives its own name (for example `ports`)
    status  the frontmatter `status`; absent means `live`, and the legacy `active` of decisions is read as `live`
    date    the `YYYY-MM-DD` that starts the file name, `-` when there is none

Lifecycle (frontmatter): `status: live | superseded | done | draft`, `supersedes:` and `superseded_by:` (paths under kb/,
comma-separated when there are several). What each status means per type is in the kb README that `kb.py init` writes.

Standard library only, Python 3.8+.
"""
import os
import posixpath
import re
import sys
import unicodedata

STATUSES = ("live", "superseded", "done", "draft")
LEGACY = {"active": "live"}                  # decisions said `status: active` before the lifecycle existed
HIDDEN = ("superseded", "done")              # `find` leaves these out unless --all
TYPES = {"intent": "intent", "specs": "spec", "plans": "plan", "decisions": "decision"}
TYPE_ARGS = ("intent", "spec", "plan", "decision")
DESC_MAX = 140                               # characters of the description on a line
LINE_MAX = 300                               # bytes of a `find`/`list` line: the description is cut further to fit
HEAD_MAX = 100                               # characters of a heading in `outline`
ROW_MAX = 150                                # bytes of an `outline` row: the heading is cut further to fit
FIND_LIMIT = 10
DATE_RX = re.compile(r"^(\d{4}-\d{2}-\d{2})-")
# ATX heading: up to 3 spaces, 1-6 `#`, then a space or the end; a closing run of `#` only counts after a space (`## C#` is "C#")
HEADING_RX = re.compile(r"^ {0,3}(#{1,6})(?:[ \t]+(.*?))?(?:[ \t]+#+)?[ \t]*$")
FENCE_RX = re.compile(r"^ {0,3}(`{3,}|~{3,})(.*)$")


# ── reading one document ───────────────────────────────────────────────────────────────────────────
def front_block(lines):
    """({key: value}, number of frontmatter lines) of the leading `---` block; plain `key: value` lines, quotes removed. A key
    with no value followed by `  - item` lines (a YAML block list) gets its items joined by commas."""
    if not lines or lines[0].strip() != "---":
        return {}, 0
    out, last = {}, None
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            return out, i + 1
        item = re.match(r"^\s+-\s+(.*?)\s*$", lines[i])
        if item and last is not None:
            out[last] = (out[last] + ", " if out[last] else "") + item.group(1)
            continue
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*):\s*(.*?)\s*$", lines[i])
        last = None
        if m:
            v = m.group(2)
            if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
                v = v[1:-1]
            out[m.group(1)] = v
            last = m.group(1) if not v else None
    return {}, 0                                 # an unclosed block is not frontmatter


def paths_of(value):
    """The paths of a `supersedes` / `superseded_by` value: comma-separated, `[a, b]` accepted, normalised (`./`, `a/../`)."""
    v = (value or "").strip()
    if v.startswith("[") and v.endswith("]"):
        v = v[1:-1]
    out = []
    for p in v.split(","):
        p = p.strip().strip("\"'")
        if p:
            out.append(posixpath.normpath(p))
    return out


def headings(lines, start=0):
    """[(line number 1-based, level, text)] of the ATX headings outside fenced code, from line index `start`."""
    out, fence = [], None                        # fence: (character, length) of the open fence
    for i in range(start, len(lines)):
        m = FENCE_RX.match(lines[i])
        if m:
            run = m.group(1)
            if fence is None:
                fence = (run[0], len(run))
            elif run[0] == fence[0] and len(run) >= fence[1] and not m.group(2).strip():
                fence = None                     # only a run of the same character, at least as long, with nothing after, closes
            continue
        if fence:
            continue
        h = HEADING_RX.match(lines[i])
        if h:
            out.append((i + 1, len(h.group(1)), (h.group(2) or "").strip()))
    return out


def split_lines(data):
    """(lines as text without the line end, size in bytes of each line with its end). Only `\n` ends a line, as for `grep -n`
    and the Read tool's offset; a `\r` before it stays in the size; a last line without `\n` has no end byte."""
    raw = data.split(b"\n")
    if raw[-1] == b"":
        raw.pop()
        ends = [1] * len(raw)
    else:
        ends = [1] * (len(raw) - 1) + [0]
    return ([r.decode("utf-8", "replace").rstrip("\r") for r in raw], [len(r) + e for r, e in zip(raw, ends)])


def read_doc(root, rel):
    """One document as a dict, or None when it cannot be read."""
    try:
        with open(os.path.join(root, *rel.split("/")), "rb") as f:
            data = f.read()
    except OSError:
        return None
    lines = split_lines(data)[0]
    fm, flen = front_block(lines)
    parts = rel.split("/")
    sub = parts[1] if len(parts) > 2 else ""
    raw = fm.get("status", "").strip()
    m = DATE_RX.match(parts[-1])
    return {
        "path": rel,
        "type": TYPES.get(sub, sub or "kb"),
        "status": LEGACY.get(raw, raw) or "live",
        "status_raw": raw,
        "has_status": "status" in fm,
        "date": m.group(1) if m else "-",
        "description": " ".join(fm.get("description", "").split()),
        "supersedes": paths_of(fm.get("supersedes")),
        "superseded_by": paths_of(fm.get("superseded_by")),
        "headings": [t for _n, _l, t in headings(lines, flen)],
        "bytes": len(data),
    }


def index(root, exclude=()):
    """Every indexed document under `<root>/kb`, in path order."""
    kb = os.path.join(root, "kb")
    skip = {"kb/README.md"} | set(exclude)
    rels = []
    for d, dirs, files in os.walk(kb):
        dirs[:] = sorted(x for x in dirs if not x.startswith("."))
        for n in files:
            if n.endswith(".md") and not n.startswith("."):
                rel = os.path.relpath(os.path.join(d, n), root).replace(os.sep, "/")
                if rel not in skip:
                    rels.append(rel)
    docs = [read_doc(root, r) for r in sorted(rels)]
    return [d for d in docs if d]


# ── one line per document ──────────────────────────────────────────────────────────────────────────
def cut(text, n):
    return text if len(text) <= n else text[:n - 1].rstrip() + "…"


def cut_bytes(text, n):
    """`text` cut so that it takes at most `n` bytes in UTF-8 (Vietnamese letters take 2-3), ending in `…` when cut."""
    if len(text.encode("utf-8")) <= n:
        return text
    t = text
    while t and len((t + "…").encode("utf-8")) > n:
        t = t[:-1]
    return t.rstrip() + "…"


def line(doc):
    head = "%s | %s | %s | %s | " % (doc["path"], doc["type"], doc["status"], doc["date"])
    tail = (" | superseded_by: " + ", ".join(doc["superseded_by"])) if doc["superseded_by"] else ""
    desc = cut(doc["description"], DESC_MAX) if doc["description"] else "(no description)"
    room = LINE_MAX - len((head + tail).encode("utf-8"))
    return head + cut_bytes(desc, max(room, 20)) + tail


# ── find ───────────────────────────────────────────────────────────────────────────────────────────
def fold(text):
    """Lower case without accents, so `hien trang` finds `Hiện trạng`."""
    t = unicodedata.normalize("NFD", (text or "").lower().replace("đ", "d"))
    return "".join(c for c in t if not unicodedata.combining(c))


def score(doc, words):
    """(words matched, weighted score): path 3, description 2, each heading that holds the word 1 (at most 3 per word)."""
    path, desc = fold(doc["path"]), fold(doc["description"])
    heads = [fold(h) for h in doc["headings"]]
    matched = total = 0
    for w in words:
        s = (3 if w in path else 0) + (2 if w in desc else 0) + min(3, sum(1 for h in heads if w in h))
        if s:
            matched += 1
            total += s
    return matched, total


def find(docs, words, kind=None, show_all=False, limit=FIND_LIMIT):
    """(lines to print, number cut by the limit, number hidden by status)."""
    words = [w for w in (fold(x) for x in words) if len(w) >= 2]
    hits, hidden = [], 0
    for d in docs:
        if kind and d["type"] != kind:
            continue
        m, s = score(d, words)
        if not m:
            continue
        if d["status"] in HIDDEN and not show_all:
            hidden += 1
            continue
        hits.append((m, s, d))
    hits.sort(key=lambda h: h[2]["path"])
    hits.sort(key=lambda h: h[2]["date"], reverse=True)
    hits.sort(key=lambda h: (h[0], h[1]), reverse=True)
    return [line(d) for _m, _s, d in hits[:limit]], max(0, len(hits) - limit), hidden


# ── outline ────────────────────────────────────────────────────────────────────────────────────────
def outline(data):
    """[(start, end, bytes, level, heading)] of the bytes of a file; a section runs to the line before the next heading of the
    same or higher level. A preamble before the first heading (frontmatter, title-less text) is level 0."""
    lines, sizes = split_lines(data)
    heads = headings(lines, front_block(lines)[1])
    out = []
    first = heads[0][0] if heads else len(lines) + 1
    if first > 1 and any(ln.strip() for ln in lines[:first - 1]):
        out.append((1, first - 1, sum(sizes[:first - 1]), 0, "(preamble)"))
    for i, (n, lvl, t) in enumerate(heads):
        end = len(lines)
        for n2, lvl2, _t in heads[i + 1:]:
            if lvl2 <= lvl:
                end = n2 - 1
                break
        out.append((n, end, sum(sizes[n - 1:end]), lvl, t))
    return out, len(lines), sum(sizes)


def render_outline(rel, data):
    rows, nlines, nbytes = outline(data)
    out = ["%s: %d lines, %dB; read one section with offset=<start> limit=<end-start+1>" % (rel, nlines, nbytes)]
    for s, e, b, lvl, t in rows:
        head = "L%d-%d %dB %s%s" % (s, e, b, "  " * max(0, lvl - 1), ("#" * lvl + " ") if lvl else "")
        out.append(head + cut_bytes(cut(t, HEAD_MAX), max(ROW_MAX - len(head.encode("utf-8")), 20)))
    return out


# ── lifecycle check ────────────────────────────────────────────────────────────────────────────────
def lifecycle(root, docs, strict=False, spec_warn=None):
    """(problems, warnings): [(path, reason)] each. Problems fail `kb.py check`; warnings (size) do not."""
    probs, warns = [], []

    def target(p):
        """The frontmatter links of the document at `p`, or None when there is no such file."""
        full = os.path.join(root, *p.split("/"))
        if not os.path.isfile(full):
            return None
        d = read_doc(root, p)
        return d if d else None

    for d in docs:
        p = d["path"]
        if d["status_raw"] and d["status_raw"] not in STATUSES and d["status_raw"] not in LEGACY:
            probs.append((p, "unknown status '%s' (one of: %s)" % (d["status_raw"], ", ".join(STATUSES))))
        if d["status"] == "superseded" and not d["superseded_by"]:
            probs.append((p, "status is superseded but superseded_by names no document"))
        if d["superseded_by"] and d["status"] != "superseded":
            probs.append((p, "superseded_by is set but status is '%s', not superseded" % d["status"]))
        for key, back in (("superseded_by", "supersedes"), ("supersedes", "superseded_by")):
            for q in d[key]:
                if q.startswith("/") or not q.startswith("kb/"):
                    probs.append((p, "%s must be a repo-relative path under kb/: %s" % (key, q)))
                    continue
                if q == p:
                    probs.append((p, "%s points to the document itself" % key))
                    continue
                t = target(q)
                if t is None:
                    probs.append((p, "%s points to a missing file: %s" % (key, q)))
                elif p not in t[back]:
                    probs.append((p, "%s: %s does not point back (its %s does not list %s)" % (key, q, back, p)))
        if strict:
            if not d["description"]:
                probs.append((p, "no description (--strict)"))
            if not d["has_status"]:
                probs.append((p, "no status (--strict)"))
        if spec_warn and d["type"] == "spec" and d["bytes"] > spec_warn:
            warns.append((p, "%dB, over kb.spec_warn_bytes (%d): read it by section (kb.py outline), or split it"
                          % (d["bytes"], spec_warn)))
    return probs, warns


# ── command line (called by kb.py) ─────────────────────────────────────────────────────────────────
USAGE = ("kb.py find <words...> [--type intent|spec|plan|decision] [--all] [--limit N] | "
         "kb.py list [--type T] [--status S] | kb.py outline <file> | kb.py check [--strict]")


def _die(msg, rc):
    sys.stderr.write("kb: %s\n" % msg)
    return rc


def _opts(args, flags, valued):
    """(positional, {option: value or True}) or raises ValueError naming the bad argument."""
    pos, opts, i = [], {}, 0
    while i < len(args):
        a = args[i]
        if a in flags:
            opts[a] = True
            i += 1
        elif a in valued:
            if i + 1 >= len(args):
                raise ValueError("%s needs a value" % a)
            opts[a], i = args[i + 1], i + 2
        elif a.startswith("--"):
            raise ValueError("unknown option %s" % a)
        else:
            pos.append(a)
            i += 1
    return pos, opts


def _type(opts, docs):
    """The --type value: one of the four kinds, or the name of another kb/ directory that holds documents (`ports`)."""
    t = opts.get("--type")
    if t is None:
        return None
    if t not in TYPE_ARGS and t not in {d["type"] for d in docs}:
        raise ValueError("--type must be one of %s (or a kb/ directory that holds documents)" % ", ".join(TYPE_ARGS))
    return t


def main(root, cmd, args, cfg):
    """rc 0 done · 1 `find` matched nothing · 64 bad arguments · 65 lifecycle problems · 66 `outline` cannot read the file."""
    exclude = (cfg["current_state"]["path"],)
    try:
        if cmd == "find":
            pos, o = _opts(args, ("--all",), ("--type", "--limit"))
            docs = index(root, exclude)
            kind = _type(o, docs)
            limit = o.get("--limit", FIND_LIMIT)
            if not re.match(r"^[0-9]+$", str(limit)) or int(limit) < 1:
                raise ValueError("--limit must be a positive integer")
            if not any(len(fold(w)) >= 2 for w in pos):
                raise ValueError("find needs at least one word of two or more characters")
            out, more, hidden = find(docs, pos, kind, o.get("--all", False), int(limit))
            for ln in out:
                sys.stdout.write(ln + "\n")
            if more:
                sys.stdout.write("(%d more; raise --limit)\n" % more)
            if hidden:
                sys.stdout.write("(%d superseded/done hidden; --all shows them)\n" % hidden)
            if not out:
                return _die("no live document matches: %s" % " ".join(pos), 1)
            return 0
        if cmd == "list":
            pos, o = _opts(args, (), ("--type", "--status"))
            docs = index(root, exclude)
            kind = _type(o, docs)
            st = o.get("--status")
            if pos:
                raise ValueError("list takes no words (use find)")
            if st is not None and st not in STATUSES:
                raise ValueError("--status must be one of %s" % ", ".join(STATUSES))
            for d in docs:
                if (kind is None or d["type"] == kind) and (st is None or d["status"] == st):
                    sys.stdout.write(line(d) + "\n")
            return 0
        if cmd == "outline":
            pos, _o = _opts(args, (), ())
            if len(pos) != 1:
                raise ValueError("outline takes one file")
            path = pos[0] if os.path.isabs(pos[0]) else os.path.join(os.getcwd(), pos[0])
            try:
                with open(path, "rb") as f:
                    data = f.read()
            except OSError:
                return _die("cannot read %s" % pos[0], 66)
            rel = os.path.relpath(os.path.realpath(path), root).replace(os.sep, "/")
            for ln in render_outline(rel if not rel.startswith("..") else pos[0], data):
                sys.stdout.write(ln + "\n")
            return 0
        if cmd == "check":
            pos, o = _opts(args, ("--strict",), ())
            if pos:
                raise ValueError("check takes no target here (check spec <x> and check current-state are separate)")
            docs = index(root, exclude)
            probs, warns = lifecycle(root, docs, o.get("--strict", False), cfg["kb"]["spec_warn_bytes"])
            for p, why in warns:
                sys.stdout.write("WARNING %s: %s\n" % (p, why))
            if probs:
                sys.stderr.write("kb: lifecycle check failed (%d problem(s)):\n%s\n"
                                 % (len(probs), "\n".join("- %s: %s" % pw for pw in probs)))
                return 65
            sys.stdout.write("kb/: %d documents, lifecycle ok%s\n" % (len(docs), ", %d size warning(s)" % len(warns) if warns else ""))
            return 0
    except ValueError as e:
        return _die("%s (usage: %s)" % (e, USAGE), 64)
    return _die("usage: " + USAGE, 64)
