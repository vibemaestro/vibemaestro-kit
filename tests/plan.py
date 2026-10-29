#!/usr/bin/env python3
# =============================================================================
# Which suites does a diff need? — ONE planner for CI (test.yml), run-all.sh --changed and a worker's local run
# =============================================================================
#   python3 tests/plan.py <base> [<head>]   the suites to run, one name per line (the `X` of tests/test-X.sh), sorted
#                                           no <head>: the working tree (uncommitted and untracked files included) against
#                                           the merge-base of <base> and HEAD
#   python3 tests/plan.py @merge-parent:<pr head> [<head>]
#                                           the same from the first parent of <head> (or HEAD), which must be a merge commit of
#                                           exactly two parents whose second is <pr head>: on a PR, GitHub's merge commit of the PR
#                                           head into the current main, so the plan is the PR's own change against that main
#                                           (test.yml passes the event's head.sha). Any other commit, a worker's own merge of main
#                                           into its branch included, or no <pr head>: full
#   python3 tests/plan.py --paths           read paths on stdin (one per line), print `<path>\t<suite> <suite>…` per path:
#                                           what each path wakes on its own (tests/test-plan.sh checks every tracked file)
#   python3 tests/plan.py --check           the coverage guard: rc 0 when the map covers the tree, rc 1 with one line per problem
#   python3 tests/plan.py --suites [--woken] [--old <dir>]
#                                           the merge guard's contract (gates/merge_guard.py --behind auto, merge.planner): read
#                                           repo paths NUL-separated on stdin, print what plan() plans for a diff of exactly those
#                                           paths, less the suite-file check, one suite per line, or one line `@full <reason>`; rc 1
#                                           when the map or the exclusion list does not parse. --woken leaves out the @always set a
#                                           plan holds for no path (a suite a path wakes stays); <dir> holds the map from before the
#                                           change (tests/suites.map under it) for option B below: without it a changed map is
#                                           @full, as in any plan. Reads only the map and the exclusion list (and <dir>'s map): no
#                                           git, no suite file, no PATH (the guard runs the base's copy in an empty directory)
#
# The map is tests/suites.map (the only place that says which paths wake which suite), read from the working tree; the list of
# documents and files no suite reads is tests/map-exclusions.txt, and a path it matches wakes no suite even when a suite line also
# matches it (a document inside a whole-plugin group). stderr says `plan: <N>/<M> suites — <reason>` or `plan: full — <reason>`; a full
# plan prints every tests/test-*.sh. Fail closed: anything the planner cannot decide is the full suite, never a smaller one.
#   - the diff is `git diff --name-only --no-renames --ignore-submodules=none <merge-base> <head>`: a rename counts as both names,
#     and a gitlink bump counts even when .gitmodules says `ignore = all` (as in tests/fixtures/plugin_version.py);
#   - full when: a ref does not resolve, @merge-parent on a commit that is not a merge of two parents (one parent, a root, an
#     octopus, a shallow clone's graft) or whose second parent is not the PR head, no merge-base, git fails, the map or the
#     exclusion list does not parse, a path matches `@full` (it wins over an exclusion), a path matches no suite and no exclusion,
#     a planned suite has no file;
#   - a change to the map itself: the suites whose expanded line differs
#     between the merge-base and the head run, plus what the other paths wake under either map; a changed `@always`/`@full` line,
#     or a map that does not parse at the merge-base, is full.
# Why only the planned suites: a PR runs what its diff reaches, which keeps CI short; the scheduled full run catches the rest.
# =============================================================================
import fnmatch
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
MAP_REL = "tests/suites.map"
EXCL_REL = "tests/map-exclusions.txt"
SUITE_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")
GLOB_RE = re.compile(r"^[A-Za-z0-9._*?\[\]-][A-Za-z0-9._*?\[\]/@+-]*$")
GROUP_RE = re.compile(r"^%[a-z0-9][a-z0-9-]*$")
# the coverage guard's reference check only follows references INTO these trees (code a suite runs or sources)
REF_ROOTS = ("plugins/", "tests/fixtures/")
# What a published tree (the export: scripts/export-public.sh) lacks or makes: the root kb/, this repository's public.private (the same
# list as `.vibemaestro/sdlc.json`; test-plan.sh holds the two equal) and the plugin licence copies the export writes. The planner reads
# them alike in either tree: a name of one is never a fixture's file by its tail, and a glob that only reaches them may match nothing.
PRIVATE_FILES = (".vibemaestro/sdlc.json",)
EXPORT_MADE = re.compile(r"^plugins/[^/]+/(LICENSE|NOTICE)$")


def published_only(t):
    """True for a path the private tree has but a published one lacks (or the other way round): see PRIVATE_FILES."""
    return t.startswith("kb/") or t in PRIVATE_FILES or EXPORT_MADE.match(t) is not None
TOKEN_RE = re.compile(r"[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)+/?")
IMPORT_RE = re.compile(r"^\s*(?:from\s+([A-Za-z_]\w*)|import\s+([A-Za-z_]\w*))", re.M)
VAR_RE = re.compile(r"""^\s*(?:local\s+|export\s+)?([A-Z_][A-Z0-9_]*)=["']?\$\{?SRC_ROOT\}?/(plugins/[A-Za-z0-9_.-]+)/?["']?\s*(?:$|[;#])""", re.M)
NAME_RE = re.compile(r"(?<![\w.-])([A-Za-z0-9_][\w.-]*\.(?:py|sh|json|yml|yaml))\b")
# shell functions: a definition `name() {`, a source line `. <…>/x.sh`, and a call: the name as a word anywhere in the code (comments
# dropped first), not followed by `.<ext>` (`capped.sh` is a file, not a call). A word catches eval, trap, quoted names and a name kept
# in a variable; a name built at run time from parts is not seen.
SH_DEF_RE = re.compile(r"(^|(?<=[\s;&|(){]))(?:function[ \t]+)?([A-Za-z_][A-Za-z0-9_]*)[ \t]*\(\)\s*\{", re.M)
SH_SOURCE_RE = re.compile(r"^[ \t]*(?:\.|source)[ \t]+(.*)$", re.M)
SH_CALL = r"(?<![\w.-])(?:%s)(?![\w-]|\.\w)"
SH_HEREDOC_RE = re.compile(r"<<-?[ \t]*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")


class MapError(Exception):
    pass


def suite_file(name):
    return "tests/test-%s.sh" % name


def disk_suites():
    d = os.path.join(ROOT, "tests")
    return sorted(f[5:-3] for f in os.listdir(d) if f.startswith("test-") and f.endswith(".sh"))


# ── the map ────────────────────────────────────────────────────────────────────────────────────────────────────────
class Map:
    def __init__(self):
        self.suites = {}      # name → tuple of globs, groups expanded, sorted (the suite's own file is implied, not listed)
        self.always = ()
        self.full = ()
        self.with_ = {}       # suite → tuple of suites planned with it


def _tokens(text):
    for n, line in enumerate(text.splitlines(), 1):
        line = line.split("#", 1)[0].strip()
        if line:
            yield n, line.split()


def parse_map(text):
    groups, raw, m = {}, {}, Map()
    seen_at = set()
    for n, words in _tokens(text):
        head, rest = words[0], words[1:]
        if head in ("@always", "@full"):
            if head in seen_at:
                raise MapError("line %d: %s given twice" % (n, head))
            seen_at.add(head)
            if not rest:
                raise MapError("line %d: %s is empty" % (n, head))
            if head == "@always":
                bad = [w for w in rest if not SUITE_RE.match(w)]
                if bad:
                    raise MapError("line %d: @always names `%s`, not a suite name" % (n, bad[0]))
                m.always = tuple(sorted(set(rest)))
            else:
                raw["@full"] = rest
            continue
        if head == "@with":
            if len(rest) < 2 or any(not SUITE_RE.match(w) for w in rest):
                raise MapError("line %d: @with needs a suite and the suites planned with it" % n)
            if rest[0] in m.with_:
                raise MapError("line %d: @with %s given twice" % (n, rest[0]))
            m.with_[rest[0]] = tuple(sorted(set(rest[1:])))
            continue
        if GROUP_RE.match(head):
            if head in groups:
                raise MapError("line %d: group %s defined twice" % (n, head))
            if not rest:
                raise MapError("line %d: group %s is empty" % (n, head))
            groups[head] = rest
            continue
        if head.startswith(("@", "%")) or not SUITE_RE.match(head):
            raise MapError("line %d: `%s` is not a suite name, a group (%%name) or @always/@full" % (n, head))
        if head in raw:
            raise MapError("line %d: suite `%s` mapped twice" % (n, head))
        raw[head] = rest

    def expand(words, stack):
        out = []
        for w in words:
            if w.startswith("%"):
                if w not in groups:
                    raise MapError("unknown group %s" % w)
                if w in stack:
                    raise MapError("group %s includes itself" % w)
                out += expand(groups[w], stack + (w,))
            elif not GLOB_RE.match(w) or w.startswith("/") or "/../" in "/%s/" % w or "//" in w:
                raise MapError("glob `%s` is not a plain repository path pattern" % w)
            else:
                out.append(w)
        return out

    for name, words in raw.items():
        globs = tuple(sorted(set(expand(words, ()))))
        if name == "@full":
            m.full = globs
        else:
            m.suites[name] = globs
    if not m.suites:
        raise MapError("no suite is mapped")
    if not m.full:
        raise MapError("@full is missing")
    for s in m.always:
        if s not in m.suites:
            raise MapError("@always names `%s`, which has no map line" % s)
    for s, others in m.with_.items():
        for o in (s,) + others:
            if o not in m.suites:
                raise MapError("@with names `%s`, which has no map line" % o)
    m.groups = groups
    return m


def parse_exclusions(text):
    out = []
    for n, words in _tokens(text):
        g = words[0]
        if not GLOB_RE.match(g) or g.startswith("/"):
            raise MapError("%s line %d: `%s` is not a plain repository path pattern" % (EXCL_REL, n, g))
        if len(words) < 3:
            raise MapError("%s line %d: `%s` has no reason (a few words after the pattern)" % (EXCL_REL, n, g))
        out.append(g)
    return out


def hit(path, globs):
    return any(fnmatch.fnmatchcase(path, g) for g in globs)


def wakes(m, path):
    return {s for s, globs in m.suites.items() if path == suite_file(s) or hit(path, globs)}


def read(rel):
    with open(os.path.join(ROOT, rel), encoding="utf-8") as f:
        return f.read()


# ── git ────────────────────────────────────────────────────────────────────────────────────────────────────────────
GIT_ENV = {k: v for k, v in os.environ.items()
           if k not in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY")}


def git(*args):
    r = subprocess.run(["git", "-C", ROOT, "-c", "core.quotepath=off"] + list(args),
                       capture_output=True, env=GIT_ENV)
    if r.returncode != 0:
        raise RuntimeError("git %s: %s" % (" ".join(args[:2]), r.stderr.decode(errors="replace").strip()[:200]))
    return r.stdout


def zsplit(b):
    return [p for p in b.decode("utf-8", errors="surrogateescape").split("\0") if p]


class Full(Exception):
    pass


def resolve(ref, what):
    if not ref:
        raise Full("%s is empty" % what)
    try:
        return git("rev-parse", "--verify", "--quiet", ref + "^{commit}").decode().strip()
    except RuntimeError:
        raise Full("%s `%s` does not resolve to a commit" % (what, ref))


MERGE_PARENT = "@merge-parent"


def merge_parent(base, h, name):
    """`base` is `@merge-parent:<pr head>`: the first parent of `h`, which must be a merge commit of exactly two parents whose second
    is <pr head> (GitHub's merge commit of that head into main); anything else is the full suite. Why not `h^1` of any commit: on
    another checkout the first parent is the PR's own previous commit, and on a worker's own merge of main into its branch it is the
    branch, so the diff is main's change, not the PR's: a narrower plan."""
    want = base[len(MERGE_PARENT) + 1:] if base.startswith(MERGE_PARENT + ":") else ""
    if not want:
        raise Full("`%s` names no PR head (%s:<sha>): no base to plan from" % (base, MERGE_PARENT))
    pr = resolve(want, "the PR head")
    try:
        parents = git("rev-list", "--parents", "-n", "1", h).decode().split()[1:]
    except RuntimeError as e:
        raise Full(str(e))
    what = "head `%s`" % name if name != "HEAD" else "HEAD"
    if len(parents) != 2:
        raise Full("%s is not a merge commit of two parents (%d parent%s): %s has no base"
                   % (what, len(parents), "" if len(parents) == 1 else "s", MERGE_PARENT))
    if parents[1] != pr:
        raise Full("the second parent of %s is not the PR head `%s`: not GitHub's merge commit of the PR" % (what, want))
    return resolve(parents[0], "the first parent of %s" % what)


def changed(base, head):
    h = resolve(head, "head") if head else resolve("HEAD", "HEAD")
    b = merge_parent(base, h, head or "HEAD") if base.startswith(MERGE_PARENT) else resolve(base, "base")
    try:
        mb = git("merge-base", b, h).decode().strip()
    except RuntimeError:
        raise Full("no merge-base between `%s` and `%s`" % (base, head or "HEAD"))
    try:
        if head:
            paths = zsplit(git("diff", "--name-only", "-z", "--no-renames", "--no-ext-diff", "--ignore-submodules=none", mb, h, "--"))
        else:
            paths = zsplit(git("diff", "--name-only", "-z", "--no-renames", "--no-ext-diff", "--ignore-submodules=none", mb, "--"))
            paths += zsplit(git("ls-files", "-z", "--others", "--exclude-standard"))
    except RuntimeError as e:
        raise Full(str(e))
    return mb, sorted(set(paths))


def with_closure(m, suites):
    """`suites` plus every suite an @with line plans beside one of them, transitively."""
    out, todo = set(suites), list(suites)
    while todo:
        for o in m.with_.get(todo.pop(), ()):
            if o not in out:
                out.add(o)
                todo.append(o)
    return out


# ── the plan ───────────────────────────────────────────────────────────────────────────────────────────────────────
def plan(paths, m, excl, base_map_text=None, always=True, check_files=True):
    """→ (suites, reason); raises Full. base_map_text: the map at the merge-base, needed only when the diff holds the map.
    always=False leaves out the @always set a plan holds for no path (a suite a path wakes stays) and check_files=False the
    suite-file check (--suites, run with no tree)."""
    out = set(m.always) if always else set()
    old = None
    if MAP_REL in paths:
        if base_map_text is None:
            raise Full("%s is new at this head (no map at the merge-base to compare)" % MAP_REL)
        try:
            old = parse_map(base_map_text)
        except MapError as e:
            raise Full("%s at the merge-base does not parse: %s" % (MAP_REL, e))
        if old.always != m.always:
            raise Full("the @always line of %s changed" % MAP_REL)
        if old.full != m.full:
            raise Full("the @full line of %s changed" % MAP_REL)
        if old.with_ != m.with_:
            raise Full("an @with line of %s changed" % MAP_REL)
        for s in set(old.suites) | set(m.suites):
            if old.suites.get(s) != m.suites.get(s) and s in m.suites:
                out.add(s)
    for p in paths:
        if hit(p, m.full):
            raise Full("`%s` decides what runs (@full)" % p)
        if p == MAP_REL or hit(p, excl):
            continue
        w = wakes(m, p)
        if old is not None:
            w |= {s for s in wakes(old, p) if s in m.suites}
        if not w:
            raise Full("`%s` matches no suite and no exclusion" % p)
        out |= w
    out = with_closure(m, out)
    have = set(disk_suites()) if check_files else out
    missing = sorted(s for s in out if s not in have)
    if missing:
        raise Full("planned suite without a file: %s" % ", ".join(missing))
    return sorted(out), "%d changed path%s" % (len(paths), "" if len(paths) == 1 else "s")


def main_plan(base, head):
    total = disk_suites()
    try:
        try:
            m = parse_map(read(MAP_REL))
            excl = parse_exclusions(read(EXCL_REL))
        except (MapError, OSError) as e:
            raise Full("%s" % e)
        mb, paths = changed(base, head)
        base_text = None
        if MAP_REL in paths:
            try:
                base_text = git("show", "%s:%s" % (mb, MAP_REL)).decode("utf-8")
            except RuntimeError:
                base_text = None
        suites, why = plan(paths, m, excl, base_text)
        print("plan: %d/%d suites — %s" % (len(suites), len(total), why), file=sys.stderr)
    except Full as e:
        suites = total
        print("plan: full — %s" % e, file=sys.stderr)
    for s in suites:
        print(s)
    return 0


def main_suites(woken=False, old_dir=None):
    """--suites: plan() of a diff of exactly the paths on stdin, less the suite-file check (the merge guard asks it of the base's
    side with `woken` and of the PR's without: the PR's CI ran the @always set, the base's side counts only what its paths wake).
    `old_dir` holds the map from before the change (the guard gives the merge base's for the base's side): a changed map then
    wakes the suites whose line differs. Without it a changed map is @full (the PR's side: the guard never reads the PR's map)."""
    paths = [p for p in sys.stdin.buffer.read().decode("utf-8", "surrogateescape").split("\0") if p]
    try:
        m = parse_map(read(MAP_REL))
        excl = parse_exclusions(read(EXCL_REL))
        old_text = None
        if old_dir is not None and MAP_REL in paths and os.path.isfile(os.path.join(old_dir, MAP_REL)):
            with open(os.path.join(old_dir, MAP_REL), encoding="utf-8") as f:
                old_text = f.read()
    except (MapError, OSError) as e:
        print("plan --suites: %s: %s" % (MAP_REL, e), file=sys.stderr)
        return 1
    try:
        out, _why = plan(paths, m, excl, old_text, always=not woken, check_files=False)
    except Full as e:
        print("@full %s" % e)
        return 0
    if woken and MAP_REL in paths:                      # plan() reads the map for what moved; its own line reads the map too
        out = sorted(with_closure(m, set(out) | wakes(m, MAP_REL)))
    for s in out:
        print(s)
    return 0


def main_paths():
    m = parse_map(read(MAP_REL))
    excl = parse_exclusions(read(EXCL_REL))
    for p in sys.stdin.read().splitlines():
        if p:
            print("%s\t%s" % (p, "" if hit(p, excl) else " ".join(sorted(wakes(m, p)))))
    return 0


# ── the coverage guard ─────────────────────────────────────────────────────────────────────────────────────────────
def tracked():
    files = zsplit(git("ls-files", "-z", "--cached", "--others", "--exclude-standard"))
    return sorted(f for f in set(files) if os.path.lexists(os.path.join(ROOT, f)))


class Refs:
    """References a file makes to files under REF_ROOTS: repository paths and path tails it names, Python imports, and (inside a
    plugin) the file names of that plugin it mentions. Over-approximate on purpose: an extra reference only widens a map line."""

    def __init__(self, files):
        self.files = files
        self.fileset = set(files)
        self.inside = [f for f in files if f.startswith(REF_ROOTS)]
        self.by_name = {}
        for f in self.inside:
            self.by_name.setdefault(os.path.basename(f), []).append(f)
        self.cache = {}

    def token(self, t):
        # `$CP/scripts/kb.py` is read as the token `CP/scripts/kb.py`: try the token, then its tails of two or more components
        while t.startswith("./"):
            t = t[2:]
        parts = [x for x in t.rstrip("/").split("/") if x not in ("", ".")]
        for i in range(0, len(parts) - 1):
            if published_only("/".join(parts[i:])):
                return []   # its shorter tails would reach the same file through a fixture or a published copy
            out = self._token("/".join(parts[i:]))
            if out:
                return out
        return []

    def _token(self, t):
        while t.startswith("./"):
            t = t[2:]
        if published_only(t):
            return []   # the repository's own kb/, config or a licence copy, present or not: never a fixture's file by its tail
        if t in self.fileset:
            return [t] if t.startswith(REF_ROOTS) else []
        if re.match(r"^(plugins(/[^/]+)?|tests(/fixtures)?)$", t):
            return []   # a whole plugin (or all fixtures) copied as setup: what the suite runs in it is named on its own
        pre = t + "/"
        out = [f for f in self.inside if f.startswith(pre)]
        if out:
            return out
        tail = "/" + t
        out = [f for f in self.inside if f.endswith(tail)]
        if out:
            return out
        return [f for f in self.inside if tail + "/" in "/" + f]

    def text(self, f):
        try:
            with open(os.path.join(ROOT, f), encoding="utf-8", errors="replace") as fh:
                return fh.read()
        except (OSError, IsADirectoryError):
            return ""

    def named(self, f):
        """Every file under REF_ROOTS whose path (or a tail of it) the text of `f` names: what a suite file points at. A plugin
        file's names stay inside plugins/ (plugin code never runs a test fixture; `.vibemaestro/sdlc.json` is not the fixture's)."""
        out = set()
        text = self.text(f)
        # `PLUGIN="$SRC_ROOT/plugins/vibemaestro-sdlc"` then `$PLUGIN/gates`: put the plugin path in place of the variable, so a
        # directory named through it (one name after the variable) is read as that plugin's directory
        for var, path in VAR_RE.findall(text):
            text = re.sub(r"\$\{?%s\}?/" % re.escape(var), path.rstrip("/") + "/", text)
        for t in set(TOKEN_RE.findall(text)):
            out.update(c for c in self.token(t) if not f.startswith("plugins/") or c.startswith("plugins/"))
        out.discard(f)
        return out

    def of(self, f):
        """The code `f` runs: Python imports (modules and packages, beside it or in a plugin), and for shell, JSON and YAML files
        (the wiring: hooks.json, adapters, workflows) every file they name. Names inside Python text (help strings, config docs)
        are not followed: they made every line hold the whole plugin."""
        if f in self.cache:
            return self.cache[f]
        out = set()
        text = self.text(f)
        if f.endswith(".py"):
            plug = "/".join(f.split("/")[:2]) + "/" if f.startswith("plugins/") else "plugins/"
            d = os.path.dirname(f) + "/"
            for a, b in IMPORT_RE.findall(text):
                mod = a or b
                for c in self.inside:
                    if not (c.startswith(d) or c.startswith(plug)):
                        continue
                    if os.path.basename(c) == mod + ".py" or ("/%s/" % mod in c and c.endswith(".py")):
                        out.add(c)
        elif f.endswith((".sh", ".json", ".yml", ".yaml")):
            out = self.named(f)
            if f.startswith("plugins/"):
                plug = "/".join(f.split("/")[:2]) + "/"
                for n in set(NAME_RE.findall(text)):
                    out.update(c for c in self.by_name.get(n, []) if c.startswith(plug))
        out.discard(f)
        self.cache[f] = out
        return out

    def closure(self, start, stop=()):
        """Everything `start` reaches. A file matching a `stop` glob is reached but not followed: `@full` helpers such as lib.sh
        run every suite when they change, and following their references would put everything they mention on every line."""
        seen, todo = set(start), [f for f in start if not hit(f, stop)]
        while todo:
            for d in self.of(todo.pop()):
                if hit(d, stop):
                    seen.add(d)
                    continue
                if d not in seen:
                    seen.add(d)
                    todo.append(d)
        return seen


def arith_at(text, i):
    """True when the `((` at `i` is arithmetic, not a subshell in a subshell (`((a) && (b))`): the first time its parentheses close
    back to one level, the next character closes the other too (`))`)."""
    depth, j, n = 2, i + 2, len(text)
    while j < n:
        c = text[j]
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 1:
                return text[j + 1:j + 2] == ")"
        j += 1
    return False


def shell_scan(text):
    """→ (code, braces): shell text with its comments dropped, as bash reads them, and the offsets in it of the braces that group
    commands (`name() {`, `{ …; }`), not those in a quote, a `${…}`, arithmetic or a brace expansion. A nesting stack follows quotes,
    `$'…'`, `$( )`, `${ }`, `(( ))`/`$(( ))`, subshells, `case … esac` and backticks, across lines; a `#` starts a comment only at the
    start of a word in code (after a blank, `;`, `|`, `&` or `(`, not after `)` or an escaped blank). A heredoc's body is kept as it
    is; `<<<` and a shift inside arithmetic open none. When the scan is unsure (an odd quote), it keeps text: more words, never
    fewer."""
    out, braces, stack, pending = [], [], [], []
    olen = 0                                        # the length of the code so far (a running count: summing `out` is quadratic)
    i, n, word_start = 0, len(text), True
    code_ctx = (None, "cmd", "sub", "case")

    def put(s):
        nonlocal olen
        out.append(s)
        olen += len(s)

    while i < n:
        c = text[i]
        ctx = stack[-1] if stack else None
        if c == "\n":
            put(c)
            i += 1
            word_start = True
            if pending and ctx not in ("sq", "dq", "ansi"):
                for delim in pending:                       # heredoc bodies, kept raw, up to each delimiter line
                    while i < n:
                        j = text.find("\n", i)
                        j = n if j < 0 else j
                        line = text[i:j]
                        put(text[i:j + 1])
                        i = j + 1
                        if line.strip() == delim:
                            break
                pending = []
            continue
        two, was_start, word_start = text[i:i + 2], word_start, False
        if ctx == "sq":
            if c == "'":
                stack.pop()
        elif ctx == "ansi":
            if c == "\\":
                put(text[i:i + 2]); i += 2; continue
            if c == "'":
                stack.pop()
        elif ctx == "dq":
            if c == "\\":
                put(text[i:i + 2]); i += 2; continue
            if c == '"':
                stack.pop()
            elif text.startswith("$((", i):
                stack.append("arith"); put("$(("); i += 3; continue
            elif two == "$(":
                stack.append("cmd"); put(two); i += 2; word_start = True; continue
            elif two == "${":
                stack.append("brace"); put(two); i += 2; continue
            elif c == "`":
                stack.append("bt")
        elif ctx in ("arith", "apar"):                      # arithmetic: no comment, no heredoc, no grouping brace
            if c == "(":
                stack.append("apar")
            elif c == ")" and ctx == "apar":
                stack.pop()
            elif two == "))":
                stack.pop(); put(two); i += 2; continue
            elif two == "$(" and not text.startswith("$((", i):
                stack.append("cmd"); put(two); i += 2; word_start = True; continue
        else:                                               # code: the top level, $( ), ( ), case, ${ }, backticks
            if c == "\\":
                put(text[i:i + 2]); i += 2; continue
            if two == "$'":
                stack.append("ansi"); put(two); i += 2; continue
            if text.startswith("$((", i):
                stack.append("arith"); put("$(("); i += 3; continue
            if two == "$(":
                stack.append("cmd"); put(two); i += 2; word_start = True; continue
            if two == "${":
                stack.append("brace"); put(two); i += 2; continue
            if ctx in code_ctx and was_start and two == "((" and arith_at(text, i):
                stack.append("arith"); put(two); i += 2; continue
            if ctx in code_ctx and was_start and re.match(r"case\s", text[i:i + 5]):
                stack.append("case"); put("case"); i += 4; continue
            if ctx == "case" and was_start and re.match(r"esac(?:$|[\s;)&|])", text[i:i + 5]):
                stack.pop(); put("esac"); i += 4; continue
            if c == "'":
                stack.append("sq")
            elif c == '"':
                stack.append("dq")
            elif c == "`":
                if ctx == "bt":
                    stack.pop()
                else:
                    stack.append("bt")
            elif ctx == "brace":
                if c == "}":
                    stack.pop()
            elif c == "(":
                stack.append("sub")
                word_start = True
            elif c == ")":
                if ctx in ("cmd", "sub"):
                    stack.pop()                             # in a case, `)` ends a pattern: it closes nothing
            elif c == "#" and ctx in code_ctx and was_start:
                j = text.find("\n", i)
                i = n if j < 0 else j                       # a comment: dropped up to the end of its line
                continue
            elif c in " \t;|&" and ctx in code_ctx:
                word_start = True
            elif c in "{}" and ctx in code_ctx:
                nxt = text[i + 1] if i + 1 < n else "\n"
                if (c == "{" and nxt in " \t\n") or (c == "}" and was_start):
                    braces.append((olen, c))
            elif two == "<<" and ctx in code_ctx and text[i:i + 3] != "<<<" and text[i - 1:i] != "<":
                m = SH_HEREDOC_RE.match(text, i)
                if m:
                    pending.append(m.group(2))
        put(c)
        i += 1
    return "".join(out), braces


def shell_code(text):
    """Shell text without its comments, so a name in a comment is no call."""
    return shell_scan(text)[0]


def calls(text, names):
    """The names of `names` that `text` (shell code) uses as a word: a call, an eval or trap string, a name kept in a variable."""
    if not names:
        return set()
    return set(re.findall(SH_CALL % "|".join(re.escape(n) for n in sorted(names, key=len, reverse=True)), text))


def shell_functions(text):
    """{name: body} of every function defined in shell text (nested, several on a line, in a heredoc: each), plus LOAD: the
    top-level code (what runs when the file is sourced). A body runs from its definition to the brace that closes the one it
    opens, by the grouping braces of shell_scan; no such brace (a definition inside a heredoc, an odd quote): to the end of its
    line, or of the file when its brace groups. A name defined twice gets both bodies."""
    code, braces = shell_scan(text)
    at = {pos: k for k, (pos, _c) in enumerate(braces)}
    out, spans = {}, []
    for m in SH_DEF_RE.finditer(code):
        start, open_ = m.start(2), m.end() - 1
        k = at.get(open_)
        if k is None:
            nl = code.find("\n", open_)
            end = len(code) if nl < 0 else nl
        else:
            depth, end = 0, len(code)
            for pos, ch in braces[k:]:
                depth += 1 if ch == "{" else -1
                if depth == 0:
                    end = pos + 1
                    break
            spans.append((start, end))
        out[m.group(2)] = (out[m.group(2)] + "\n" if m.group(2) in out else "") + code[start:end]
    top, last = [], 0
    for start, end in sorted(spans):
        if start >= last:
            top.append(code[last:start])
            last = end
        else:
            last = max(last, end)
    top.append(code[last:])
    out[LOAD] = "".join(top)
    return out


LOAD = "(load)"   # the pseudo function of a fixture's top-level code: a suite that sources the file runs it


def hidden_fixtures(m, refs):
    """{fixture: the @full file that sources it}: shell fixtures an @full shell file sources that are not @full themselves. The
    closure stops at an @full file, so a suite never names them; it reaches them only by calling their functions."""
    out = {}
    for f in refs.files:
        if not (f.endswith(".sh") and hit(f, m.full)):
            continue
        for rest in SH_SOURCE_RE.findall(shell_code(refs.text(f))):
            names = re.findall(r"([\w.-]+\.sh)\b", rest)
            c = os.path.normpath(os.path.join(os.path.dirname(f), names[-1])) if names else None
            if c in refs.fileset and not hit(c, m.full):
                out.setdefault(c, f)
    return out


def function_reach(refs, hidden):
    """{hidden fixture: {(file, function)}}: the functions of the shell fixtures that use, directly or through other fixture
    functions, a function the hidden fixture defines (its own functions included); (file, LOAD) when a fixture's top-level code
    does."""
    bodies = {f: shell_functions(refs.text(f)) for f in refs.files if f.startswith("tests/fixtures/") and f.endswith(".sh")}
    out = {}
    for h in hidden:
        reach = {(h, n) for n in bodies.get(h, {}) if n != LOAD}
        grown = True
        while grown:
            grown = False
            names = {n for _f, n in reach if n != LOAD}
            for f, fns in bodies.items():
                for n, body in fns.items():
                    if (f, n) not in reach and f != h and calls(body, names):
                        reach.add((f, n))
                        grown = True
        out[h] = reach
    return out


def check():
    problems = []
    try:
        m = parse_map(read(MAP_REL))
    except (MapError, OSError) as e:
        print("plan --check: %s: %s" % (MAP_REL, e))
        return 1
    try:
        excl = parse_exclusions(read(EXCL_REL))
    except (MapError, OSError) as e:
        print("plan --check: %s" % e)
        return 1
    files = tracked()
    on_disk = disk_suites()
    for s in on_disk:
        if s not in m.suites:
            problems.append("suite `%s` (tests/test-%s.sh) has no line in %s" % (s, s, MAP_REL))
    for s in sorted(m.suites):
        if s not in on_disk:
            problems.append("%s maps `%s`, but tests/test-%s.sh does not exist" % (MAP_REL, s, s))
    def side_only(g):   # a glob that only reaches what one of the two trees lacks (see PRIVATE_FILES)
        return g.startswith("kb/") or any(fnmatch.fnmatchcase(p, g) for p in PRIVATE_FILES)
    globs = {g for gl in m.suites.values() for g in gl} | set(m.full)
    for g in sorted(globs):
        if side_only(g) and not any(fnmatch.fnmatchcase(f, g) for f in files if published_only(f)):
            continue   # its files are absent from this tree (a published one)
        if not any(fnmatch.fnmatchcase(f, g) for f in files):
            problems.append("%s: `%s` matches no tracked file" % (MAP_REL, g))
    for g in excl:
        if side_only(g) and not any(fnmatch.fnmatchcase(f, g) for f in files if published_only(f)):
            continue   # a published tree has no kb/: its exclusions there have nothing to match
        if not any(fnmatch.fnmatchcase(f, g) for f in files):
            problems.append("%s: `%s` matches no tracked file" % (EXCL_REL, g))
    for f in files:
        if not wakes(m, f) and not hit(f, m.full) and not hit(f, excl):
            problems.append("`%s` is mapped to no suite and not excluded (add it to a suite's line in %s, or to %s with a reason)"
                            % (f, MAP_REL, EXCL_REL))
    refs = Refs(files)
    hidden = hidden_fixtures(m, refs)
    reach = function_reach(refs, hidden)
    for s in sorted(m.suites):
        if s not in on_disk:
            continue
        covered = {f for f in files if f == suite_file(s) or hit(f, m.suites[s])}
        start = refs.named(suite_file(s))
        reached = refs.closure(start, m.full)
        need = {f for f in reached if f.startswith(REF_ROOTS)}
        # a function of a fixture an @full file sources: what the suite calls of it, among the fixtures it can call (those it
        # reaches, and those an @full file it reaches sources)
        if hidden:
            text = shell_code(refs.text(suite_file(s)))
            can = reached | {h for h, src in hidden.items() if src in reached}
            for h in sorted(hidden):
                if h not in can or h in covered:
                    continue
                via = sorted((n, f) for f, n in reach[h] if f in can and n != LOAD)
                hits = calls(text, {n for n, _f in via})
                loads = sorted(f for f, n in reach[h] if n == LOAD and f in reached)
                if loads:
                    problems.append("suite `%s` sources %s, whose top-level code reaches %s that %s sources, but its line in %s does not cover %s"
                                    % (s, loads[0], h, hidden[h], MAP_REL, h))
                elif hits:
                    n = min(hits)
                    f = min(f for nn, f in via if nn == n)
                    problems.append("suite `%s` calls `%s` (%s), which reaches %s that %s sources, but its line in %s does not cover %s"
                                    % (s, n, f, h, hidden[h], MAP_REL, h))
        missing = sorted(f for f in need - covered if not hit(f, m.full))
        if missing:
            more = " (and %d more)" % (len(missing) - 8) if len(missing) > 8 else ""
            problems.append("suite `%s` uses %s but its line in %s does not cover %s%s"
                            % (s, "these files", MAP_REL, " ".join(missing[:8]), more))
        # an excluded path wakes nothing, so a file a suite runs or names must not be excluded: it is code, not a document. Blind
        # outside REF_ROOTS and to paths a script builds at run time (see the header of tests/map-exclusions.txt)
        for f in sorted(f for f in need if hit(f, excl) and not hit(f, m.full)):
            problems.append("suite `%s` uses `%s`, which %s excludes: a file a suite runs or names is not a document" % (s, f, EXCL_REL))
    for p in problems:
        print("plan --check: %s" % p)
    if problems:
        print("plan --check: %d problem%s" % (len(problems), "" if len(problems) == 1 else "s"))
        return 1
    print("plan --check: ok (%d tracked files, %d suites)" % (len(files), len(m.suites)))
    return 0


def main(argv):
    if argv == ["--check"]:
        return check()
    if argv == ["--paths"]:
        return main_paths()
    if argv[:1] == ["--suites"]:
        rest, woken, old = argv[1:], False, None
        if rest[:1] == ["--woken"]:
            rest, woken = rest[1:], True
        if len(rest) == 2 and rest[0] == "--old" and rest[1] and not rest[1].startswith("-"):
            rest, old = [], rest[1]
        if not rest:
            return main_suites(woken, old)
    if len(argv) in (1, 2) and not argv[0].startswith("-"):
        return main_plan(argv[0], argv[1] if len(argv) == 2 else None)
    print("usage: plan.py <base>|@merge-parent:<pr head> [<head>] | --paths | --check | --suites [--woken] [--old <dir>]", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
