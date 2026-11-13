#!/usr/bin/env python3
"""Gate signing-rules: a PR that changes who signs is an owner merge.

It judges what lands: the head merged into the base tip (`git merge-tree --write-tree`, git 2.38 or newer; a conflict or an
older git cannot conclude, rc 2), so a change main made after the branch point is main's, never the PR's.
Red when the merge changes (`git diff <base tip> <merged tree>`, renames as a delete and an add):
  - changes a baton's Stops as `stops_of` (scripts/baton.py) parses them, in a file under a baton directory (`baton_dirs`);
  - adds a file under a baton directory;
  - changes a name of `lists` (a list or limit that decides who signs), or a file of `files` (the gate itself, its helper, its job).
  - adds a symlink or a submodule anywhere (one can stand in for a baton directory; the kit tracks none).
A deleted baton passes, and so does any other line of a baton. Directory names are compared case-folded.
With `--touches FILE`, once every cause is judged, it writes the findings for the merge guard's `touches` (plan-approved merges):
`trust-touches v1`, one JSON line `[kind, path, object, stops]` per cause, then `end <n>`. A Stops change or a new baton is `baton`
with the Stops it lands with; every other cause, and a baton that lands with no Stops line, is `other` (a list's object is its name). A
green run writes `end 0`; a run that stops early writes no `end` line.

A name is compared by its signature in the parsed file (`ast`, no line numbers), at the base tip and in the merged tree: every statement that
uses it other than as a plain read, anywhere in the file (a binding of any kind, a store into it, a method call that is not a known
read, an alias, an argument of a function that is not a known pure one, a keyword or an attribute of that name, the name as a string),
every statement of the file that reaches names at run time (`exec`, `eval`, `globals()`, `setattr`, `__dict__`, `sys.modules`), and,
transitively, the signature of each top-level name those statements read. A name absent in the merged tree only (the PR removes it),
or a file that does not parse, is red; a listed name or file absent at the base tip is an invalid list (rc 65): it would protect nothing.

It is a tripwire for slips, as baton is. A plain read (`if w in STOP_WORDS`, `len(STOP_WORDS)`, `STOP_WORDS[0]`) passes, and so does a
change to a condition (`allowed()`, `merge_guard.py`), to a baton's body or to code in another file: the review is the gate for code.

The list is the one at the base: the default below, which CI runs from the base checkout, or `--list FILE`, a JSON file
`{"baton_dirs": [...], "lists": {"<path>": ["<name>", ...]}, "files": [...]}` read at <base> (never from the working tree); a change to
that file is red too.

Use:
    signing_rules.py <base> <head> [--list FILE] [--cwd DIR] [--touches FILE]

rc 0 green, 1 red (an owner merge), 2 could not conclude, 64 usage, 65 invalid list. Standard library only, Python 3.8+.
"""
import argparse
import ast
import importlib.util
import json
import keyword
import os
import sys

try:
    import gate_common as gc
except ImportError as e:     # a partial copy must not read as "red" (a traceback exits 1)
    sys.stderr.write("signing_rules.py: could not conclude: %s\n" % e)
    sys.exit(2)

PLUGIN_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BATON = "plugins/vibemaestro-sdlc/scripts/baton.py"
DEFAULT = {
    "baton_dirs": ["batons", "templates/baton-kinds"],
    "lists": {
        BATON: ["STOP_WORDS", "SIGN_AGAIN_STOPS", "PLAN_SECRETS_KITS", "parse_header", "stops_of", "KIT_ROOT", "KINDS_DIR", "KINDS_REAL",
                "APPROVAL_LIFE_MAX", "CHARTER_LIFE_MAX", "CHARTER_KINDS"],
        "plugins/vibemaestro-sdlc/scripts/sdlc_config.py": ["MERGE_DENY_DEFAULT"],
        "plugins/vibemaestro-sdlc/scripts/kb_plan.py": ["TOUCH_KINDS", "TOUCH_OBJECT_KINDS", "TOUCH_JUDGES", "TOUCH_JUDGE_DIRS",
                                                       "parse_touches", "touch_kind", "judges", "is_judge"],
    },
    "files": ["plugins/vibemaestro-sdlc/gates/signing_rules.py", "plugins/vibemaestro-sdlc/gates/gate_common.py",
              ".github/workflows/signing-rules.yml", "plugins/vibemaestro-sdlc/gates/baton.py"],   # the last: a copy there would shadow scripts/
}
# a use of a listed name that only reads it: an argument of these, a method of these, an operand, a test, an iteration, a format
PURE_CALLS = {"len", "sorted", "set", "frozenset", "tuple", "list", "dict", "any", "all", "repr", "str", "print", "enumerate", "min",
              "max", "iter", "reversed", "bool", "isinstance"}
PURE_METHODS = {"join", "format", "startswith", "endswith"}     # a method of another object that takes the name as an argument
# an attribute of the name that changes it in place: any other attribute (`X.get`, `re.compile`) reads it
MUTATORS = {"append", "extend", "insert", "remove", "pop", "clear", "update", "setdefault", "add", "discard", "popitem", "sort",
            "reverse", "__setitem__", "__delitem__", "__iadd__", "__ior__", "__init__", "__setattr__", "difference_update", "intersection_update",
            "symmetric_difference_update"}
# a name reached at run time: every statement holding one of these is part of every name's signature
DYNAMIC_CALLS = {"exec", "eval", "compile", "globals", "vars", "locals", "setattr", "delattr", "__import__"}
DYNAMIC_ATTRS = {"__dict__", "modules", "__builtins__", "__globals__"}
SCOPES = (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef, ast.Lambda)
LINKS = ("120000", "160000")     # a symlink and a gitlink (submodule)


def load_stops_of():
    beside = os.path.join(os.path.dirname(os.path.abspath(__file__)), "baton.py")    # a vendored copy (.vibemaestro/gates/) carries it
    spec = importlib.util.spec_from_file_location("baton_for_signing_rules",
                                                  beside if os.path.isfile(beside) else os.path.join(PLUGIN_ROOT, "scripts", "baton.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.stops_of


def repo_path(v):
    """A relative repository path with no `.`, `..` or empty part, or None."""
    if not isinstance(v, str) or not v or v.startswith("/") or "\\" in v or "\0" in v:
        return None
    return v if all(p not in ("", ".", "..") for p in v.split("/")) else None


def check_list(d, where):
    if not isinstance(d, dict) or set(d) != set(DEFAULT):
        raise gc.ConfigError("%s: an object with exactly the keys %s" % (where, ", ".join(sorted(DEFAULT))))
    for key in ("baton_dirs", "files"):
        if not isinstance(d[key], list) or not all(repo_path(v) for v in d[key]):
            raise gc.ConfigError("%s: %s must be a list of relative repository paths (no `..`, no leading `/`)" % (where, key))
    if not isinstance(d["lists"], dict):
        raise gc.ConfigError("%s: lists must be an object of path to names" % where)
    for path, names in d["lists"].items():
        if not repo_path(path):
            raise gc.ConfigError("%s: lists key %r is not a relative repository path" % (where, path))
        if not isinstance(names, list) or not names or not all(
                isinstance(n, str) and n.isidentifier() and not keyword.iskeyword(n) for n in names):
            raise gc.ConfigError("%s: lists[%r] must be a non-empty list of Python names" % (where, path))
    return d


def changes(base, head, cwd):
    """[(status letter, new mode, path)] of `git diff --raw --no-renames <base> <head>`."""
    parts = gc.must(["diff", "--no-renames", "--no-ext-diff", "--raw", "-z", base, head], cwd).split("\0")
    out = []
    for i in range(0, len(parts) - 1, 2):
        meta = parts[i].split()          # :<old mode> <new mode> <old sha> <new sha> <status>
        out.append((meta[4][:1], meta[1], parts[i + 1]))
    return out


def in_baton_dir(path, dirs):
    parent = path.casefold().split("/")[:-1]
    for d in dirs:
        dp = d.casefold().split("/")
        if any(parent[i:i + len(dp)] == dp for i in range(len(parent) - len(dp) + 1)):
            return True
    return False


def top_names(tree):
    """The names bound at module level (inside `if`/`try`/`with` too, not inside a def, class or lambda)."""
    out = set()

    def visit(node):
        for ch in ast.iter_child_nodes(node):
            if isinstance(ch, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                out.add(ch.name)
            elif isinstance(ch, (ast.Import, ast.ImportFrom)):
                out.update((a.asname or a.name).split(".")[0] for a in ch.names)
            elif isinstance(ch, ast.Name) and isinstance(ch.ctx, ast.Store):
                out.add(ch.id)
            elif not isinstance(ch, ast.Lambda):
                visit(ch)
    visit(tree)
    return out


class Module:
    def __init__(self, text):
        self.tree = ast.parse(text)
        self.parent = {}
        for node in ast.walk(self.tree):
            for ch in ast.iter_child_nodes(node):
                self.parent[ch] = node
        self.top = top_names(self.tree)
        self.dynamic = [n for n in ast.walk(self.tree)
                        if isinstance(n, ast.Call) and isinstance(n.func, ast.Name) and n.func.id in DYNAMIC_CALLS
                        or isinstance(n, ast.Attribute) and n.attr in DYNAMIC_ATTRS]

    def stmt_of(self, node):
        while not isinstance(node, ast.stmt):
            node = self.parent[node]
        return node

    def read_only(self, node):
        """True when this Load of a name only reads it (see PURE_CALLS and PURE_METHODS)."""
        p = self.parent[node]
        if isinstance(p, (ast.Compare, ast.BinOp, ast.UnaryOp, ast.FormattedValue, ast.Starred)):
            return True
        if isinstance(p, (ast.If, ast.While, ast.IfExp, ast.Assert)) and p.test is node:
            return True
        if isinstance(p, (ast.For, ast.AsyncFor, ast.comprehension)) and p.iter is node:
            return True
        if isinstance(p, ast.Subscript) and p.value is node and isinstance(p.ctx, ast.Load):
            return True
        if isinstance(p, (ast.Tuple, ast.List)) and isinstance(self.parent[p], ast.BinOp):
            return True                                         # "%s %s" % (X, y)
        if isinstance(p, ast.Call) and p.func is node:
            return True                                         # a call of it: parse_header(lines)
        if isinstance(p, ast.Call) and node in p.args:
            f = p.func
            return isinstance(f, ast.Name) and f.id in PURE_CALLS or isinstance(f, ast.Attribute) and f.attr in PURE_METHODS
        if isinstance(p, ast.Attribute) and p.value is node and isinstance(p.ctx, ast.Load):
            return p.attr not in MUTATORS                       # X.get(k), re.compile(…); X.clear() and f = X.clear are not
        return False

    def top_level(self, st):
        """True for a statement of the module itself, inside `if`/`try`/`with` too, not inside a def, class or lambda."""
        node = self.parent.get(st)
        while node is not None and not isinstance(node, ast.Module):
            if isinstance(node, SCOPES):
                return False
            node = self.parent.get(node)
        return node is not None

    def hits(self, name):
        """The statements that use `name` other than as a plain read, and those that reach names at run time, in source order."""
        found = {}
        for node in ast.walk(self.tree):
            if isinstance(node, ast.Name) and node.id == name:
                hit = not isinstance(node.ctx, ast.Load) or not self.read_only(node)
            elif isinstance(node, ast.alias):
                hit = (node.asname or node.name).split(".")[0] == name
            elif isinstance(node, (ast.Global, ast.Nonlocal)):
                hit = name in node.names
            elif isinstance(node, ast.keyword):
                hit = node.arg == name                          # globals().update(X=…)
            elif isinstance(node, ast.Attribute):
                hit = node.attr == name                         # sys.modules[__name__].X = …
            elif isinstance(node, ast.Constant):
                hit = node.value == name and isinstance(node.value, str)
            else:
                hit = getattr(node, "name", None) == name       # def, class, `except … as`, a match capture
            if hit:
                found[id(node)] = node
        stmts = {}
        for node in list(found.values()) + (self.dynamic if found else []):
            st = node if isinstance(node, ast.stmt) else self.stmt_of(node)
            stmts[id(st)] = st
        return sorted(stmts.values(), key=lambda st: (st.lineno, st.col_offset))

    def signature(self, name, seen=None):
        seen = set() if seen is None else seen
        seen.add(name)
        stmts = self.hits(name)
        sig = [ast.dump(s) for s in stmts]
        # what its value is built from: the names its top-level statements read (not every use elsewhere, which would pull in the module)
        deps = sorted({n.id for s in stmts if self.top_level(s) for n in ast.walk(s)
                       if isinstance(n, ast.Name) and isinstance(n.ctx, ast.Load) and n.id in self.top and n.id not in seen})
        for d in deps:
            if d not in seen:
                sig += ["<%s>" % d] + self.signature(d, seen)
        return sig


def other(path, obj="-"):
    """The finding of a cause no plan row declares (merge_guard's `touches`)."""
    return ["other", path, obj, "-"]


def show(cwd, rev, path):
    """`path`'s text at `rev`, a commit or the merged tree (gc.read_at takes commits only), None when it is not there."""
    if gc.git(["cat-file", "-e", "%s:%s" % (rev, path)], cwd)[0] != 0:
        return None
    return gc.must(["show", "%s:%s" % (rev, path)], cwd)


def merged_tree(base, head, cwd):
    """The tree that merging `head` into the base tip gives: what lands."""
    rc, out, err = gc.git(["merge-tree", "--write-tree", "--no-messages", base, head], cwd)
    if rc == 1:
        raise gc.Infra("the head does not merge cleanly into the base tip (a conflict): merge the base into the branch")
    if rc != 0 or not out.split():
        old = "; a git older than 2.38 has no merge-tree --write-tree" if rc == 129 else ""    # 129: git's usage exit
        raise gc.Infra("git merge-tree --write-tree failed (rc %d%s): %s" % (rc, old, err[:120]))
    return out.split()[0]


def parse_at(text, path, side, red):
    if text is None:
        red.append(("%s: not found at the %s" % (path, side), other(path)))
        return None
    try:
        return Module(text)
    except (SyntaxError, ValueError, RecursionError) as e:
        red.append(("%s: does not parse at the %s (%s)" % (path, side, getattr(e, "lineno", None) or type(e).__name__), other(path)))
        return None


def judge(base, head, list_file, cwd):
    """(red causes, each (text, finding), names compared, baton files compared)."""
    for ref in (base, head):
        if not gc.ref_ok(ref, cwd):
            raise gc.Infra("ref `%s` does not read" % ref)
    if list_file is None:
        rules = DEFAULT
    else:
        text = gc.read_at(cwd, base, list_file)
        if text is None:
            raise gc.ConfigError("--list %s is not on the base %s: the PR that adds it is an owner merge" % (list_file, base))
        try:
            rules = check_list(json.loads(text), "--list %s at %s" % (list_file, base))
        except ValueError as e:
            raise gc.ConfigError("--list %s at %s is not JSON: %s" % (list_file, base, e))
    tree = merged_tree(base, head, cwd)
    red, stops_of, batons = [], None, 0
    trip = set(rules["files"]) | ({list_file} if list_file else set())
    for status, mode, path in changes(base, tree, cwd):
        if path in trip:
            red.append(("%s: the gate or its list changed" % path, other(path)))
        if status != "D" and mode in LINKS:
            red.append(("%s: a %s added: it can stand in for a baton directory" % (path, "symlink" if mode == LINKS[0] else "submodule"),
                        other(path)))
            continue
        if not in_baton_dir(path, rules["baton_dirs"]) or status == "D":
            continue
        batons += 1
        stops_of = stops_of or load_stops_of()
        new = stops_of(show(cwd, tree, path) or "")
        found = ["baton", path, "-", new] if new is not None else other(path)
        if status == "A":
            red.append(("%s: a new file under a baton directory" % path, found))
            continue
        old = stops_of(gc.read_at(cwd, base, path) or "")
        if old != new:
            red.append(("%s: Stops %s → %s" % (path, "'%s'" % old if old is not None else "None",
                                                "'%s'" % new if new is not None else "None"), found))
    names = 0
    for path, wanted in sorted(rules["lists"].items()):
        text = gc.read_at(cwd, base, path)
        if text is None:
            raise gc.ConfigError("the list names %s, which is not at the base tip %s: an invalid list" % (path, base))
        a, b = parse_at(text, path, "base tip", red), parse_at(show(cwd, tree, path), path, "merged tree", red)
        if a is None or b is None:
            continue
        absent = [n for n in wanted if not a.signature(n)]
        if absent:
            raise gc.ConfigError("the list names %s in %s, not found at the base tip %s: an invalid list" % (", ".join(absent), path, base))
        for n in wanted:
            names += 1
            if a.signature(n) != b.signature(n):
                red.append(("%s: %s changed (it decides who signs)" % (path, n), other(path, n)))
    return red, names, batons


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("base")
    ap.add_argument("head")
    ap.add_argument("--list")
    ap.add_argument("--cwd", default=".")
    ap.add_argument("--touches")
    try:
        a = ap.parse_args(argv)
    except SystemExit as e:
        return gc.USAGE if e.code else 0
    if a.list is not None and not repo_path(a.list):
        sys.stderr.write("signing-rules: --list must be a relative repository path (no `..`, no leading `/`)\n")
        return gc.USAGE
    red, names, batons = judge(a.base, a.head, a.list, a.cwd)
    if a.touches:                                       # written only now: a run that stops before this leaves no `end` line
        with open(a.touches, "w", encoding="utf-8") as f:
            f.write("".join(["trust-touches v1\n"] + [json.dumps(fd) + "\n" for _t, fd in red] + ["end %d\n" % len(red)]))
    for line, _f in red:
        print("RED " + line)
    if red:
        print("signing-rules: red, an owner merge (%d cause%s)" % (len(red), "" if len(red) == 1 else "s"))
        return gc.RED
    print("signing-rules: green (%d names, %d baton file%s changed)" % (names, batons, "" if batons == 1 else "s"))
    return gc.OK


if __name__ == "__main__":
    sys.exit(gc.run_gate("signing-rules", main))
