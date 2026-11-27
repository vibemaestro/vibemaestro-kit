#!/usr/bin/env python3
"""The size of the source files under plugins/ and the pure decision layer.

Usage: python3 tests/fixtures/size_lint.py [--root DIR]

  --root DIR  the git work tree to read (default: the repository this script lives in)

Rule 1, file size. Every tracked regular `.py` and `.sh` file under `plugins/` (paths from the index, text from the work tree).
Lines = newline bytes, plus one when the last byte is not a newline. Over 1000 lines is red unless the file is in the oversize list
`tests/fixtures/oversize-list.txt` (`<lines> <path>` per line, "#" starts a comment line). A listed file must have exactly its
number: more is red, fewer is red with the number to lower it to, 1000 or fewer is red with "remove its line". An entry for a path
the rule does not read, a bad line or a path twice is red. Against the list at the base (the merge-base of HEAD and origin/main):
an entry the base does not list (a renamed or moved file counts as new) or a number above the base's is red. A base that cannot be
read is red when CI is set (GitHub sets CI=true) and, on a machine, one line on stderr says the comparison was skipped; a base with
no list yet (before this lint merged) is one line on stderr too.

Rule 2, the pure decision layer. A tracked `.py` file under a directory named `domain` (anywhere under plugins/) imports only
another `domain` module or a standard module of PURE below; it uses none of the names of BARE (a call, or the builtin taken under
another name) and refers to none of the input/output calls of IO (process, file, clock and network calls; no path method, since
`.replace` is also a str method), a name bound by `import … as` or `from … import` resolved first
(`from datetime import datetime as dt` makes `dt.now` the clock). Every level of the syntax tree is read; a file that does not parse
is red. Tell-based like planted_lint.py: `getattr` with a string name, or a clock module put in a plain variable (`D = datetime`), slips through; a
parameter named like an I/O module (`time`) is red, rename it; the review reads the diff.

Exit 0 clean, 1 a finding, 2 the scan could not run (not a repository, no file under plugins/ read).
"""
import argparse
import ast
import os
import subprocess
import sys

LIMIT = 1000
LIST = "tests/fixtures/oversize-list.txt"

PURE = {"__future__", "abc", "base64", "binascii", "bisect", "collections", "copy", "dataclasses", "datetime", "decimal",
        "difflib", "enum", "fnmatch", "fractions", "functools", "hashlib", "heapq", "hmac", "ipaddress", "itertools", "json",
        "keyword", "math", "numbers", "operator", "re", "shlex", "statistics", "string", "struct", "textwrap", "typing",
        "unicodedata"}
BARE = {"open", "print", "input", "__import__", "exec", "eval", "compile", "__builtins__"}  # I/O, or an import no line shows
IO = ("subprocess.", "os.system", "os.popen", "os.exec",
      "os.remove", "os.unlink", "os.rename", "os.replace", "os.makedirs", "os.mkdir", "os.listdir", "os.scandir", "os.walk",
      "os.stat", "os.chmod", "os.path.exists", "os.path.isfile", "os.path.isdir", "os.path.getmtime", "os.path.getsize",
      "shutil.", "tempfile.", "glob.", "fcntl.",
      "time.time", "time.monotonic", "time.sleep", "time.localtime", "time.gmtime", "time.strftime", "datetime.datetime.now", "datetime.datetime.today",
      "datetime.now", "datetime.today", "datetime.datetime.utcnow", "datetime.utcnow", "datetime.date.today", "date.today",
      "urllib.", "socket.", "http.client.", "ssl.")


def git(root, *args):
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    return subprocess.run(["git", "-C", root] + list(args), capture_output=True, env=env)


def count_lines(data):
    return data.count(b"\n") + (1 if data and not data.endswith(b"\n") else 0)


def read_list(text, where):
    """({path: lines}, [problem])"""
    entries, problems = {}, []
    for n, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        count, _, name = line.partition(" ")
        name = name.strip()
        if not count.isdigit() or not name:
            problems.append("%s:%d: '%s' is not '<lines> <path>'" % (where, n, line))
        elif name in entries:
            problems.append("%s:%d: lists '%s' twice" % (where, n, name))
        else:
            entries[name] = int(count)
    return entries, problems


def base_list(root):
    """(base sha or None, {path: lines} or None, a line saying why there is nothing to compare, or None)"""
    p = git(root, "merge-base", "HEAD", "origin/main")
    if p.returncode != 0:
        return None, None, "no merge-base of HEAD and origin/main (%s)" % (p.stderr.decode(errors="replace").strip() or "rc %d" % p.returncode)
    sha = p.stdout.decode().strip()
    tree = git(root, "ls-tree", sha, "--", LIST)
    if tree.returncode != 0:
        return None, None, "the base %s cannot be read (rc %d)" % (sha[:12], tree.returncode)
    if not tree.stdout.strip():
        return sha, None, None
    blob = git(root, "cat-file", "blob", "%s:%s" % (sha, LIST))
    if blob.returncode != 0:
        return None, None, "the list at the base %s cannot be read (rc %d)" % (sha[:12], blob.returncode)
    return sha, read_list(blob.stdout.decode("utf-8", "replace"), "%s:%s" % (sha[:12], LIST))[0], None


def dotted(node):
    if isinstance(node, ast.Name):
        return node.id
    if isinstance(node, ast.Attribute):
        return dotted(node.value) + "." + node.attr
    return "?"


def io_name(name):
    return any(name == k or (k.endswith(".") and name.startswith(k)) or name.startswith(k + ".") for k in IO)


def domain_faults(path, text):
    """[problem] of one file under a `domain` directory."""
    try:
        tree = ast.parse(text, path)
    except (SyntaxError, ValueError, RecursionError) as e:
        return ["%s:%s: does not parse (%s): rule 2 cannot read it" % (path, getattr(e, "lineno", 0) or 0, e.__class__.__name__)]
    here = path.split("/")[:-1]
    out, bound = [], {}  # bound: a name an import binds -> the dotted name it stands for
    for node in ast.walk(tree):
        targets = []  # (the name as written, its parts; a relative import resolved against this file's directory)
        if isinstance(node, ast.Import):
            targets = [(a.name, a.name.split(".")) for a in node.names]
            bound.update((a.asname, a.name) for a in node.names if a.asname)
        elif isinstance(node, ast.ImportFrom):
            mod = node.module.split(".") if node.module else []
            base = here[:len(here) - node.level + 1] + mod if node.level else mod
            targets = [("." * node.level + (node.module or a.name), base + [a.name]) for a in node.names]
            if not node.level:
                bound.update((a.asname or a.name, "%s.%s" % (node.module, a.name)) for a in node.names)
        for shown, parts in targets:
            if "domain" not in parts and not (parts and parts[0] in PURE):
                out.append("%s:%d: imports '%s': a domain file imports only another domain module or a pure standard module"
                           % (path, node.lineno, shown))
    for node in ast.walk(tree):
        if isinstance(node, ast.Name) and node.id in BARE and node.id not in bound:  # `from re import compile` is not the builtin
            out.append("%s:%d: uses '%s': a domain file does no input/output and no dynamic import" % (path, node.lineno, node.id))
        elif isinstance(node, ast.Attribute):
            head, _, rest = dotted(node).partition(".")
            name = bound.get(head, head) + "." + rest
            if io_name(name):
                out.append("%s:%d: uses '%s': a domain file makes no input/output call" % (path, node.lineno, name))
    return list(dict.fromkeys(out))


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--root", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
    root = os.path.abspath(ap.parse_args(argv).root)
    p = git(root, "ls-files", "-z", "--stage", "--", "plugins")
    if p.returncode != 0:
        print("size_lint: cannot list the tracked files of %s (not a git work tree?)" % root, file=sys.stderr)
        return 2
    sizes, problems = {}, []
    for rec in p.stdout.split(b"\0"):
        meta, _, raw = rec.partition(b"\t")
        path = os.fsdecode(raw)
        if not rec or meta.split()[0] not in (b"100644", b"100755") or not path.endswith((".py", ".sh")):
            continue
        try:
            with open(os.path.join(root, path), "rb") as f:
                data = f.read()
        except OSError:
            continue
        sizes[path] = count_lines(data)
        if path.endswith(".py") and "domain" in path.split("/")[:-1]:
            problems += domain_faults(path, data.decode("utf-8", "replace"))
    if not sizes:
        print("size_lint: no .py or .sh file under plugins/ read in %s" % root, file=sys.stderr)
        return 2
    try:
        listed, bad = read_list(open(os.path.join(root, LIST), encoding="utf-8").read(), LIST)
    except FileNotFoundError:
        listed, bad = {}, []
    problems += bad
    for path, n in sorted(sizes.items()):
        if path not in listed:
            if n > LIMIT:
                problems.append("%s: %d lines, over the limit of %d and not in %s" % (path, n, LIMIT, LIST))
        elif n <= LIMIT:
            problems.append("%s: %d lines, at or under %d: remove its line from %s" % (path, n, LIMIT, LIST))
        elif n > listed[path]:
            problems.append("%s: %d lines, %d over its number %d in %s" % (path, n, n - listed[path], listed[path], LIST))
        elif n < listed[path]:
            problems.append("%s: %d lines, under its number %d in %s: lower the number to %d" % (path, n, listed[path], LIST, n))
    for path in sorted(set(listed) - set(sizes)):
        problems.append("%s: '%s' is not a tracked .py or .sh file the rule reads: remove its line" % (LIST, path))
    sha, base, why = base_list(root)
    if why:
        if os.environ.get("CI", "") not in ("", "0", "false"):
            problems.append("%s: the comparison with the base cannot run in CI: %s" % (LIST, why))
        else:
            print("size_lint: comparison with the base skipped: %s" % why, file=sys.stderr)
    elif base is None:
        print("size_lint: the base %s has no %s yet: nothing to compare" % (sha[:12], LIST), file=sys.stderr)
    else:
        for path, n in sorted(listed.items()):
            if path not in base:
                problems.append("%s: '%s' is not listed at the base %s: the list takes no new line (a renamed or moved file counts as new)"
                                % (LIST, path, sha[:12]))
            elif n > base[path]:
                problems.append("%s: '%s' raised from %d at the base %s to %d: a number only goes down" % (LIST, path, base[path], sha[:12], n))
    for line in problems:
        print(line)
    print("size_lint: %d files under plugins/ read, %d in the oversize list, base %s, %d problem(s)"
          % (len(sizes), len(listed), sha[:12] if sha else "none", len(problems)), file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
