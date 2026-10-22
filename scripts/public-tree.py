#!/usr/bin/env python3
"""The public-tree check: no file this repository publishes carries a private trace.

Usage (in the repository, or with --root):
  python3 scripts/public-tree.py [--root DIR] [--base REV] [--terms FILE] [--ci]
  python3 scripts/public-tree.py [--root DIR] --write-baseline

What it reads: every tracked file but the root kb/, the paths matching a glob of `public.private` in HEAD's .vibemaestro/sdlc.json
(the `applyTo` glob language, as scripts/export-public.sh reads it) and the allow file. Docs are read like code. A file with NUL
bytes is read too: UTF-32 and UTF-16 decoded, anything else as text with each NUL read as a blank (counted as read as text);
compressed content is not decompressed. A symlink (the export refuses one) and a submodule are skipped and counted. A file whose
working-tree bytes are not its blob although git sees no change (a checkout attribute converted it) is `converted`: red, since
the export ships the blob and every reader here, the term scanner too, reads the working tree. Line endings alone (core.autocrlf,
eol) are not a conversion.

What is a hit, per line (D is an ISO date 20YY-MM-DD that is not part of a name):
  kb     a path into the root kb/ naming a tracked kb file (with or without .md), or the dated base name of one, bare or below a kb
         directory's name (`plans/<name>.md`); not kb/current-state.md or kb/README.md, which every kb has
  ref    an issue, PR or plan-row number: #NN (also after a quote, a backtick or a colon), "issue N", "PR #N", "PR#N", "PR-N",
         "PR: N", "PR N/M", "PR số N", "kit PR N", "kit #N", "row <id>", "owner/repo#N", a /pull/N or /issues/N path. After a
         singular word, digits that go on as a thousands group are a count, not a number; after a plural they are a list.
         "issue: N" is the intent frontmatter key, not a ref. The value of a CSS or SVG colour property is not one.
  diary  D on a line that also holds a diary word (owner, coordinator, measured, decided, approved, agreed, session, đã chốt,
         đã duyệt, ...) or a ref; D right after "chốt" or "duyệt" (a colon between allowed); or "(…, D)". A timestamp (D followed by T) and other date formats are not read.
  mail   an e-mail address, unless its domain is a reserved name of RFC 2606/6761 (.invalid, .test, .example, .localhost,
         example.com, example.net, example.org); user@host followed by `:` and a path with a `/` is an SSH remote, not an e-mail
  home   a home directory path: /home/<name>, /var/home/<name>, /Users/<name>, /mnt/<drive>/Users/<name>, C:\\Users\\<name> in any
         case and with either slash, ~<name>/; not a directory called home inside another path
  term   a private term: scripts/scan-internal-terms.sh with --terms FILE, outside kb/ and public.private (their content and
         names; a directory whose every file is private is one skip; a private path holding a newline is refused), and over the
         decoded text of UTF-16 and UTF-32 files under neutral names (`term decoded tree #N …`, N its place in `git ls-files`);
         never baselined or allowed

Green only when the hits, after the allow file, equal the baseline exactly:
  - a hit line the baseline lacks is `new`; a baseline line with no hit is `stale` (it leaves with its hit, in the same PR);
  - every baseline line must be in the baseline of --base (`grows` otherwise): the baseline only shrinks. A base without this
    script accepts a first baseline; a base with it and no baseline counts as empty.
  scripts/public-tree.baseline: `<path>\\t<classes>\\t<hash>` per hit line, sorted, repeated for identical lines; the hash is the
    first 16 hex of the sha256 of the line with its surrounding blanks stripped, so the file holds no line text. A line is known
    by path and hash; its classes are recorded for the reader (they may change with kb/ while the line does not). `#` lines are
    comments.
  scripts/public-tree.allow: `<path>\\t<class>\\t<exact string>`, for test data a test needs or a well-known public no-reply or
    service address that product code whitelists; never a real person's address (a per-user no-reply address carries a login,
    so it is one) or a private term; the PR adding one says why. A class hit on a line of that path is allowed when every match
    of the class lies inside an occurrence of the string on that line. An entry that covers no hit is `stale-allow`.

Output: one line per finding, `new <path>:<line> <classes>`, `stale <path> <classes> <hash>`, `grows <path> <classes> <hash>`,
`converted <path>`,
`stale-allow <allow file>:<line>`, `term <the scanner's own hit line>`; never the line text, a matched string or a term. Then the
control line and `hits: N baselined, A allowed, K new`. Before the scan a throw-away repository gets one planted line per class,
and each must be found with the same code (`control: 5/5`, or 6/6 with a term file).
--base defaults to `git merge-base HEAD origin/main`. --ci: a term file and --base are required.
Exit: 0 green, 1 a finding, 2 usage or a broken instrument (no public.private, an unreadable input, a control miss).
Standard library only.
"""
import argparse
import collections
import hashlib
import json
import os
import re
import secrets
import subprocess
import sys
import tempfile

KB = "kb/"
KB_COMMON = {"kb/current-state.md", "kb/README.md"}    # in every kb: the plugin's own concept, not a pointer to this repo's notes
CONFIG = ".vibemaestro/sdlc.json"
BASELINE = "scripts/public-tree.baseline"
ALLOW = "scripts/public-tree.allow"
SELF = "scripts/public-tree.py"
SCANNER = "scripts/scan-internal-terms.sh"
CLASSES = ("kb", "ref", "diary", "mail", "home")      # the order of the classes column; `term` is the scanner's
GLOB_BAD_CHARS = "[]{}\\"            # the same as scripts/export-public.sh (the suite compares the two readings)

DATE = r"(?<![\w/.-])20\d\d-[01]\d-[0-3]\d(?![\w-])"
DATE_RX = re.compile(DATE)
KB_RX = re.compile(r"(?<![\w.-])kb/[0-9A-Za-z._/-]+")
STEM_RX = re.compile(r"(?<![\w.-])20\d\d-[01]\d-[0-3]\d-[0-9a-z-]*[0-9a-z]")   # after a `/` only below a kb directory's name
# a singular word form followed by a thousands group (,ddd) is a count, not a number; after a plural it is a list
WORD_REF_RX = re.compile(r"(?<![\w-])(issues?|PRs?|pull requests?|kit PR|kit issue)(?:\s+số)?(?:\s*#\s*|(?<=[sR]):\s*|\s+|-)\d+[a-z]?"
                         r"(?![\w-]|/(?!\d))", re.I)
REF_RX = re.compile(
    r"(?:^|(?<=[\s(\[,\"'`:]))#\d{2,}(?![\w-])"
    r"|(?<![\w-])[\w.-]+/[\w.-]+#\d+(?![\w-])"
    r"|/(?:pull|issues)/\d+(?![\w-])"
    r"|(?<![\w-])(?:plan row|rows?|kit row)\s+[A-Z]?\d+[a-z]?(?![\w-])"
    r"|(?<![\w-])kit #\d+(?![\w-])", re.I)
# a colour is not a number: 3, 4, 6 or 8 digits that are a CSS or SVG colour value. Before them: a declaration of a colour
# property (any prefix: box-shadow, stop-color, a --custom one, a -vendor- one) and only CSS value words (numbers with units,
# keywords, other colours, functions such as linear-gradient(); or the stops of a gradient; after them: the end of the value.
# A prose heading (`Background:`) and prose words (`fill: tracked in`) are not a declaration.
_CSS_VAL = (r"(?:-?\d*\.?\d+(?:px|em|rem|ex|ch|%|deg|turn|rad|pt|vh|vw|vmin|vmax|s|ms)?|#[0-9A-Fa-f]{3,8}|!important"
            r"|solid|dashed|dotted|double|groove|ridge|inset|outset|none|transparent|currentcolor|inherit|initial"
            r"|to|left|right|top|bottom|center|circle|ellipse|closest-side|farthest-corner|repeat|no-repeat"
            r"|url\([^()]*\)|(?:rgba?|hsla?)\([^()]*\)|[\w-]*gradient\(|drop-shadow\()")
COLOUR_RX = re.compile(r"(?:(?:^|[;{\"'\s])(?:--[\w-]+|-?(?:[a-z][a-z-]*-)?(?:colou?r|fill|stroke|background|border|outline|shadow|filter)(?:-[a-z-]+)?)"
                       r"\s*[:=]\s*[\"']?|(?:^|[^\w-])[\w-]*gradient\()(?:" + _CSS_VAL + r"[\s,()]*)*$")
COLOUR_END_RX = re.compile(r"\s*(?:$|[;}\"',)/]|!important|" + _CSS_VAL + r")")
DIARY_WORD_RX = re.compile(r"(?<!\w)(?:owner|coordinator|measured|decided|decision|approved|agreed|pre-registered|session"
                           r"|round)s?(?!\w)|quyết định|đã đo|đã chốt|chốt ngày|đã duyệt|duyệt ngày|đồng ý|(?<!\w)vòng(?!\w)", re.I)
DIARY_PRE_RX = re.compile(r"(?:chốt|duyệt)\s*:?\s*$", re.I)   # "Chốt 2026-…:", "duyệt: 2026-…"
DIARY_TAIL_RX = re.compile(r", " + DATE + r"\)")
# the domain is taken whole, then judged (an SSH remote `user@host:dir/x` is checked after the match, so nothing backtracks);
# `_` may follow it (markdown italic)
MAIL_RX = re.compile(r"[A-Za-z0-9._%+-]+@([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+)(?![A-Za-z0-9-])")
MAIL_TLD_RX = re.compile(r"\.[A-Za-z]{2,}$")
MAIL_OK_RX = re.compile(r"(?:^|\.)(?:invalid|test|example|localhost)$|(?:^|\.)example\.(?:com|net|org)$", re.I)
SSH_TAIL_RX = re.compile(r":[\w.~-]*/")
HOME_RX = re.compile(r"(?<![\w.$}~-])/(?:var/)?home/[A-Za-z_]|(?<![\w.$}~-])/Users/[A-Za-z_]|/mnt/[A-Za-z]/(?i:users)/[A-Za-z_]"
                     r"|(?i:(?<![A-Za-z])[a-z]:[\\/]{1,2}users[\\/]{1,2}[a-z_])|(?<![\w$~/])~[a-z_][a-z0-9_-]*/")
SCANNER_HIT = re.compile(r"^(tree|name) (.+) term=(\d+):(\d+)$")


# a throw-away commit: no signing, no hook, a fixed identity, so the user's git config cannot break the instrument
COMMIT = ("-c", "user.email=c" + "@" + "c.invalid", "-c", "user.name=c", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=" + os.devnull)


class Broken(Exception):
    """An input or the instrument is unusable: exit 2."""


def git(root, *args, check=True):
    env = {k: v for k, v in os.environ.items()
           if k not in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY")}
    r = subprocess.run(["git", "-C", root] + list(args), capture_output=True, env=env)
    if check and r.returncode != 0:
        raise Broken("git %s: %s" % (" ".join(args[:2]), r.stderr.decode("utf-8", "replace").strip()))
    return r


def glob_regex(g):
    """A glob of `public.private` as one anchored regex (the `applyTo` language), or None when not valid in it.
    The same reading as glob_regex of scripts/export-public.sh."""
    if not isinstance(g, str):
        return None
    segs = g.split("/")
    if (not g or g.startswith("/") or any(c in g for c in GLOB_BAD_CHARS) or any(c < " " for c in g)
            or any(x in ("", ".", "..") for x in segs) or any("**" in x and x != "**" for x in segs)):
        return None
    out, i = [], 0
    while i < len(g):
        if g.startswith("**/", i):
            out.append(r"(?:[^/]+/)*")
            i += 3
        elif g.startswith("**", i):
            out.append(r".*")
            i += 2
        elif g[i] == "*":
            out.append(r"[^/]*")
            i += 1
        elif g[i] == "?":
            out.append(r"[^/]")
            i += 1
        else:
            out.append(re.escape(g[i]))
            i += 1
    return re.compile("".join(out) + r"\Z", re.S)


def private_globs(root):
    """The compiled globs of `public.private` in HEAD's config (what is committed, as the export reads the rev's own)."""
    r = git(root, "show", "HEAD:" + CONFIG, check=False)
    try:
        cfg = json.loads(r.stdout.decode("utf-8")) if r.returncode == 0 else None
    except ValueError:
        cfg = None
    if cfg is None:
        raise Broken("HEAD:%s missing or not JSON: the repository does not say what it publishes" % CONFIG)
    pub = cfg.get("public") if isinstance(cfg, dict) else None
    globs = pub.get("private") if isinstance(pub, dict) else None
    if not isinstance(globs, list):
        raise Broken("%s has no public.private list: the repository does not publish its tree" % CONFIG)
    rx = [glob_regex(g) for g in globs]
    bad = [i for i, x in enumerate(rx) if x is None]
    if bad:
        raise Broken("public.private[%d] is not a valid glob" % bad[0])
    return rx


class Classes:
    """The line classifier: knows the repository's kb files."""

    def __init__(self, kb_files):
        self.kb = set(kb_files) - KB_COMMON
        self.stems = {os.path.basename(p)[:-3] for p in self.kb if p.endswith(".md")}
        self.dirs = {p.split("/")[1].lower() for p in self.kb if p.count("/") >= 2}   # specs, plans, …: `plans/<stem>.md`

    def spans(self, line):
        """{class: [(start, end), ...]} of the matches on one line."""
        out = collections.defaultdict(list)
        for m in KB_RX.finditer(line):
            tok = m.group(0).rstrip(".,:;)`'\"")
            if tok in self.kb or tok + ".md" in self.kb:
                out["kb"].append((m.start(), m.start() + len(tok)))
        for m in STEM_RX.finditer(line):
            if m.group(0) not in self.stems:
                continue
            if m.start() and line[m.start() - 1] == "/":
                seg = re.search(r"([\w.-]+)/$", line[:m.start()])
                if not seg or seg.group(1).lower() not in self.dirs:
                    continue
            out["kb"].append(m.span())
        refs = []
        for m in WORD_REF_RX.finditer(line):
            if not m.group(1).lower().endswith("s") and re.match(r",\d{3}(?!\d)", line[m.end():]):
                continue
            refs.append(m.span())
        for m in REF_RX.finditer(line):
            if (line[m.start()] == "#" and len(m.group(0)) - 1 in (3, 4, 6, 8) and COLOUR_RX.search(line[:m.start()])
                    and COLOUR_END_RX.match(line, m.end())):
                continue
            refs.append(m.span())
        if refs:
            out["ref"] = refs
        dates = [m.span() for m in DATE_RX.finditer(line)]
        if dates and (refs or DIARY_WORD_RX.search(line)
                      or any(DIARY_PRE_RX.search(line[:a]) for a, _ in dates)):
            out["diary"] = dates
        else:
            tail = [(m.start() + 2, m.end() - 1) for m in DIARY_TAIL_RX.finditer(line)]
            if tail:
                out["diary"] = tail
        mails = [m.span() for m in MAIL_RX.finditer(line)
                 if MAIL_TLD_RX.search(m.group(1)) and not MAIL_OK_RX.search(m.group(1))
                 and not SSH_TAIL_RX.match(line, m.end())]
        if mails:
            out["mail"] = mails
        homes = [m.span() for m in HOME_RX.finditer(line)]
        if homes:
            out["home"] = homes
        return out


def line_hash(raw):
    return hashlib.sha256(raw.strip()).hexdigest()[:16]


def text_lines(data):
    """(kind, [(text, bytes to hash)]) of a file's content. A file with a NUL byte is still read: UTF-32 and UTF-16 (a BOM, or NUL
    bytes in the places that encoding puts them) are decoded; anything else is read as UTF-8 with each NUL read as a blank, so
    text inside a mostly-binary file is seen and line numbers stay right. Compressed content (an archive) is not decompressed."""
    enc = None
    if data.startswith((b"\xff\xfe\x00\x00", b"\x00\x00\xfe\xff")):
        enc = "utf-32"
    elif data.startswith((b"\xff\xfe", b"\xfe\xff")):
        enc = "utf-16"
    elif b"\0" in data and len(data) >= 8:
        cols = [data[i::4] for i in range(4)]
        nul = [c.count(0) / max(1, len(c)) for c in cols]
        if nul[1] > .9 and nul[2] > .9 and nul[3] > .9 and nul[0] < .1:
            enc = "utf-32-le"
        elif nul[0] > .9 and nul[1] > .9 and nul[2] > .9 and nul[3] < .1:
            enc = "utf-32-be"
        else:
            even, odd = data[0::2], data[1::2]
            if odd.count(0) > 0.4 * len(odd) and even.count(0) < 0.1 * len(even):
                enc = "utf-16-le"
            elif even.count(0) > 0.4 * len(even) and odd.count(0) < 0.1 * len(odd):
                enc = "utf-16-be"
    if enc:
        kind = enc[:6]
        raws = [t.encode("utf-8", "surrogatepass") for t in data.decode(enc, "replace").split("\n")]
    elif b"\0" in data:
        kind = "binary"
        raws = data.replace(b"\0", b" ").split(b"\n")
    else:
        kind = "text"
        raws = data.split(b"\n")
    if raws and raws[-1] == b"":
        raws.pop()
    return kind, [(raw.decode("utf-8", "replace"), raw) for raw in raws]


def blob_id(data, fmt):
    return hashlib.new(fmt, b"blob %d\0" % len(data) + data).hexdigest()


def converted(root, read):
    """The paths whose working-tree bytes are not their index blob although git sees no change: a checkout attribute
    (working-tree-encoding, ident, a filter) converted them. The export ships the blob, so the check must read the same bytes.
    `read` is [(path, blob id, working-tree bytes)]. Line endings alone (core.autocrlf, eol) are not a conversion: no class and no
    term reads them."""
    if not read:
        return []
    r = git(root, "rev-parse", "--show-object-format", check=False)
    fmt = r.stdout.decode().strip() if r.returncode == 0 else "sha1"
    if fmt not in ("sha1", "sha256"):
        raise Broken("unknown object format %r" % fmt)
    edited = set(filter(None, git(root, "diff", "--name-only", "-z").stdout.decode("utf-8", "surrogateescape").split("\0")))
    return [p for p, oid, data in read if p not in edited and blob_id(data, fmt) != oid
            and blob_id(data.replace(b"\r\n", b"\n"), fmt) != oid]


def tracked(root):
    """[(mode, path, blob id)] of the index."""
    out = git(root, "ls-files", "-z", "-s").stdout.decode("utf-8", "surrogateescape")
    files = []
    for ent in filter(None, out.split("\0")):
        meta, path = ent.split("\t", 1)
        files.append((meta.split()[0], path, meta.split()[1]))
    return files


def scan(root, allow_entries=()):
    """(hits, allowed, used_allow, skipped, decoded, read): hits is a list of (path, lineno, classes tuple, hash) after the allow
    entries; decoded maps a UTF-16 or UTF-32 path to its text (the term scanner reads bytes); read lists (path, blob id, bytes)."""
    files = tracked(root)
    private = private_globs(root)
    cls = Classes(p for _, p, _ in files if p.startswith(KB))
    allow = collections.defaultdict(list)          # path -> [(index, class, string)]
    for i, (p, c, s) in enumerate(allow_entries):
        allow[p].append((i, c, s))
    hits, allowed, used, skipped, decoded, read = [], 0, set(), collections.Counter(), {}, []
    for mode, path, oid in files:
        if path.startswith(KB) or path == ALLOW or any(rx.match(path) for rx in private):
            continue
        if mode == "120000":
            skipped["symlink"] += 1
            continue
        if mode == "160000":
            skipped["submodule"] += 1
            continue
        full = os.path.join(root, path)
        try:
            with open(full, "rb") as f:
                data = f.read()
        except OSError:
            raise Broken("a tracked file is missing from the working tree: %s" % path)
        read.append((path, oid, data))
        kind, lines = text_lines(data)
        if kind != "text":
            skipped[kind + " read as text"] += 1
        if kind.startswith("utf-"):
            decoded[path] = "\n".join(t for t, _ in lines) + "\n"
        for n, (line, raw) in enumerate(lines, 1):
            sp = cls.spans(line)
            if not sp:
                continue
            left = []
            for c in CLASSES:
                if c not in sp:
                    continue
                covers = []
                for i, ac, s in allow.get(path, ()):
                    if ac != c:
                        continue
                    at = line.find(s)
                    while at >= 0 and s:
                        covers.append((at, at + len(s), i))
                        at = line.find(s, at + 1)
                ok = all(any(a <= st and en <= b for a, b, _ in covers) for st, en in sp[c])
                if ok:
                    used.update(i for a, b, i in covers if any(a <= st and en <= b for st, en in sp[c]))
                else:
                    left.append(c)
            if left:
                hits.append((path, n, tuple(left), line_hash(raw)))
            else:
                allowed += 1
    return hits, allowed, used, skipped, decoded, read


def parse_baseline(text, where):
    rows = []
    for n, line in enumerate(text.split("\n"), 1):
        if not line.strip() or line.startswith("#"):
            continue
        parts = line.split("\t")
        if (len(parts) != 3 or not parts[0] or not re.fullmatch(r"[0-9a-f]{16}", parts[2])
                or not parts[1] or any(c not in CLASSES for c in parts[1].split(","))):
            raise Broken("%s:%d is not `<path>\\t<classes>\\t<hash>`" % (where, n))
        rows.append((parts[0], tuple(parts[1].split(",")), parts[2]))
    return rows


def parse_allow(text, where):
    rows = []
    for n, line in enumerate(text.split("\n"), 1):
        if not line.strip() or line.startswith("#"):
            continue
        parts = line.split("\t", 2)
        if len(parts) != 3 or not parts[0] or not parts[2]:
            raise Broken("%s:%d is not `<path>\\t<class>\\t<exact string>`" % (where, n))
        if parts[1] not in CLASSES:
            raise Broken("%s:%d: class %r cannot be allowed (one of %s; a term never)" % (where, n, parts[1], ", ".join(CLASSES)))
        rows.append((n, (parts[0], parts[1], parts[2])))
    return rows


def read_text(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except FileNotFoundError:
        return ""
    except (OSError, UnicodeDecodeError) as e:
        raise Broken("%s unreadable (%s)" % (path, e.__class__.__name__))


HEADER = ("# public-tree baseline: hit lines recorded when the check started; it only shrinks. One line per hit line:\n"
          "# <path>\\t<classes>\\t<first 16 hex of sha256 of the stripped line>. Written by scripts/public-tree.py --write-baseline.\n")


def write_baseline(root, hits):
    rows = sorted("%s\t%s\t%s" % (p, ",".join(c), h) for p, _, c, h in hits)
    with open(os.path.join(root, BASELINE), "w", encoding="utf-8") as f:
        f.write(HEADER + "".join(r + "\n" for r in rows))
    return len(rows)


def run_scanner(root, terms, skips=()):
    """[hit lines] of the term scanner over root's tree minus kb/ and the `skips` paths (public.private: never published; the
    scanner skips their content and their names); Broken unless it ran with its control found."""
    sh = os.path.join(os.path.dirname(os.path.abspath(__file__)), "scan-internal-terms.sh")
    args = ["bash", sh, "--ci", "--terms", terms]
    for p in skips:
        args += ["--skip", p]
    r = subprocess.run(args + ["--exclude", "kb/", "--tree"], cwd=root, capture_output=True)
    out = r.stdout.decode("utf-8", "replace").splitlines()
    if r.returncode not in (0, 1) or not out or not out[-1].startswith("control: found 1/1; hits: "):
        raise Broken("the term scanner did not run (exit %d)" % r.returncode)
    hits = [x for x in out if SCANNER_HIT.match(x)]
    if (r.returncode == 1) != bool(hits) or out[-1] != "control: found 1/1; hits: %d" % len(hits):
        raise Broken("the term scanner's output does not add up")
    return hits


def private_skips(files, private):
    """The scanner's --skip list for the public.private paths outside kb/: a directory whose every tracked file is private is one
    entry (the scanner's cost is files x skips). A private path holding a newline is refused: the scanner's list is lines."""
    priv = {p for p in files if not p.startswith(KB) and any(rx.match(p) for rx in private)}
    if any("\n" in p for p in priv):
        raise Broken("a public.private path holds a newline: the term scanner cannot skip it")
    total, mine = collections.Counter(), collections.Counter()
    for p in files:
        parts = p.split("/")[:-1]
        for i in range(1, len(parts) + 1):
            total["/".join(parts[:i])] += 1
            if p in priv:
                mine["/".join(parts[:i])] += 1
    skips = set()
    for p in priv:
        parts = p.split("/")[:-1]
        top = next(("/".join(parts[:i]) for i in range(1, len(parts) + 1)
                    if total["/".join(parts[:i])] == mine["/".join(parts[:i])]), p)
        skips.add(top)
    return sorted(skips)


def decoded_terms(decoded, terms, order):
    """[hit lines] of the term scanner over the decoded text of UTF-16 and UTF-32 files (it reads bytes, so it cannot see them).
    Each file goes in under a neutral name (no decoded .gitignore or .gitattributes can hide or convert one) and its hits name it
    as `#N`, its position in `git ls-files` (`order`), as the scanner names a path it withholds."""
    if not decoded:
        return []
    names = {}
    with tempfile.TemporaryDirectory() as d:
        git(d, "init", "-q")
        for i, (p, t) in enumerate(sorted(decoded.items())):
            names["f%06d.txt" % i] = p
            with open(os.path.join(d, "f%06d.txt" % i), "w", encoding="utf-8", errors="surrogateescape") as f:
                f.write(t)
        git(d, "-c", "core.excludesFile=" + os.devnull, "add", "-A", "-f")
        git(d, *COMMIT, "commit", "-qm", "decoded")
        out = []
        for x in run_scanner(d, terms):
            m = SCANNER_HIT.match(x)
            if m.group(2) not in names:
                raise Broken("the term scanner named a decoded file it was not given")
            out.append("%s #%d term=%s:%s" % (m.group(1), order[names[m.group(2)]], m.group(3), m.group(4)))
        return out


def control(with_terms):
    """Plant one line per class in a throw-away repository and find each with the same code; the count found."""
    with tempfile.TemporaryDirectory() as d:
        git(d, "init", "-q")
        os.makedirs(os.path.join(d, "kb", "specs"))
        os.makedirs(os.path.join(d, ".vibemaestro"))
        stem = "-".join(("2000", "01", "02", "ctl"))
        with open(os.path.join(d, "kb", "specs", stem + ".md"), "w") as f:
            f.write("x\n")
        with open(os.path.join(d, CONFIG), "w") as f:
            f.write('{"public": {"private": []}}\n')
        canary = "ctl" + secrets.token_hex(8)
        lines = {"kb": "see " + "k" + "b/specs/" + stem + ".md", "ref": "is" + "sue #" + "12",
                 "diary": "the " + "owner (" + "-".join(("2000", "01", "02")) + ")", "mail": "a" + "@" + "b.io",
                 "home": "/" + "home/" + "a/x"}
        with open(os.path.join(d, "planted.txt"), "w") as f:
            f.write("".join(lines[c] + "\n" for c in CLASSES) + canary + "\n")
        git(d, "add", "-A")
        # no signing, no hook, a fixed identity: the user's git config must not break the instrument
        git(d, *COMMIT, "commit", "-qm", "c")
        hits = scan(d)[0]
        found = {c for _, n, cs, _ in hits for c in cs if n == CLASSES.index(c) + 1}
        if with_terms:
            tf = os.path.join(d, ".git", "ctl-terms")
            with open(tf, "w") as f:
                f.write(canary + "\n")
            if any("planted.txt" in h for h in run_scanner(d, tf)):
                found.add("term")
        return len(found)


def main():
    ap = argparse.ArgumentParser(description="the public-tree check (see the module docstring)")
    ap.add_argument("--root", default=None)
    ap.add_argument("--base", default=None)
    ap.add_argument("--terms", default=None)
    ap.add_argument("--ci", action="store_true")
    ap.add_argument("--write-baseline", action="store_true")
    a = ap.parse_args()
    try:
        root = a.root or git(os.getcwd(), "rev-parse", "--show-toplevel").stdout.decode().strip()
        root = os.path.abspath(root)
        allow_rows = parse_allow(read_text(os.path.join(root, ALLOW)), ALLOW)
        if a.write_baseline:
            hits = scan(root, [e for _, e in allow_rows])[0]
            print("public-tree: wrote %d line(s) to %s" % (write_baseline(root, hits), BASELINE))
            return 0
        if a.ci and not (a.terms and a.base):
            raise Broken("--ci needs --terms (the KIT_TERMS secret) and --base: a check that did not scan must not pass")
        if a.terms is not None and not os.path.isfile(a.terms):
            raise Broken("the term file does not exist")
        base = a.base or git(root, "merge-base", "HEAD", "origin/main").stdout.decode().strip()
        r = git(root, "rev-parse", "--verify", "--quiet", "--end-of-options", base + "^{commit}", check=False)
        if r.returncode != 0:
            raise Broken("the base %r is not a commit here" % base)
        base = r.stdout.decode().strip()

        n_classes = len(CLASSES) + (1 if a.terms else 0)
        got = control(bool(a.terms))
        if got != n_classes:
            raise Broken("control: found %d of %d planted classes: the instrument is broken" % (got, n_classes))

        hits, allowed, used, skipped, decoded, read = scan(root, [e for _, e in allow_rows])
        baseline = parse_baseline(read_text(os.path.join(root, BASELINE)), BASELINE)
        # a line is known by path and hash: its classes may change with kb/ or the allow file while its text does not
        have = collections.Counter((p, h) for p, _, h in baseline)
        recorded = {(p, h): c for p, c, h in baseline}
        out = []
        for p, n, c, h in sorted(hits):
            if have[(p, h)] > 0:
                have[(p, h)] -= 1
            else:
                out.append("new %s:%d %s" % (p, n, ",".join(c)))
        for (p, h), k in sorted(have.items()):
            out += ["stale %s %s %s" % (p, ",".join(recorded[(p, h)]), h)] * k
        for i, (n, _) in enumerate(allow_rows):
            if i not in used:
                out.append("stale-allow %s:%d" % (ALLOW, n))
        first = git(root, "cat-file", "-e", "%s:%s" % (base, SELF), check=False).returncode != 0
        if first:
            print("public-tree: the base has no check: the baseline is accepted as the first baseline")
        else:
            r = git(root, "show", "%s:%s" % (base, BASELINE), check=False)
            prev = collections.Counter((p, h) for p, _, h in (parse_baseline(r.stdout.decode("utf-8", "replace"), "base:" + BASELINE)
                                                              if r.returncode == 0 else []))
            for (p, h), k in sorted(collections.Counter((p, h) for p, _, h in baseline).items()):
                out += ["grows %s %s %s" % (p, ",".join(recorded[(p, h)]), h)] * max(0, k - prev[(p, h)])
        out += ["converted %s" % p for p in converted(root, read)]
        terms = []
        if a.terms:
            files = [p for _, p, _ in tracked(root)]
            terms = ["term " + x for x in run_scanner(root, a.terms, private_skips(files, private_globs(root)))]
            order = {p: i for i, p in enumerate(files, 1)}
            terms += ["term decoded " + x for x in decoded_terms(decoded, a.terms, order)]
        for x in out + terms:
            print(x)
        print("control: %d/%d" % (got, n_classes) + ("" if a.terms else "; terms: not checked"))
        if skipped:
            print("skipped: " + ", ".join("%d %s" % (k, w) for w, k in sorted(skipped.items())))
        n_new = sum(1 for x in out if x.startswith("new "))
        print("hits: %d baselined, %d allowed, %d new" % (len(hits) - n_new, allowed, n_new))
        return 1 if out or terms else 0
    except Broken as e:
        print("public-tree: %s" % e, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
