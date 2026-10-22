#!/usr/bin/env python3
"""Committed merge-conflict markers in the tracked text files of a git work tree.

Usage: python3 tests/fixtures/conflict_markers.py [--root DIR] [--allow FILE]

  --root DIR    the git work tree to read (default: the repository this script lives in)
  --allow FILE  the allow list (default: DIR/tests/conflict-marker-allow.txt; a missing default file is an empty list)

One pass over `git ls-files`. Per regular file (a symlink, a submodule and a file with a NUL byte are skipped; a trailing CR and a BOM before line 1 are ignored):
  a line starting "<<<<<<< " or ">>>>>>> "       a marker, reported as path:line
  a line that is exactly "======="               a marker only between a "<<<<<<< " line before it and a ">>>>>>> " line after it;
                                                 alone it is a Markdown setext heading or prose and is left alone
Allow list, one line per file that needs markers as a fixture:  <tracked path> <reason>   ("#" starts a comment line).
An entry with no reason, a path git does not track, or a file with no marker is itself reported, so the list cannot rot.

Exit 0 clean, 1 a marker or a bad allow entry, 2 the scan could not run (not a repository, no tracked file read).
The marker strings are built, not written out, so this file is no hit for itself.
"""
import argparse
import os
import subprocess
import sys

LT, GT = b"<" * 7 + b" ", b">" * 7 + b" "
MID = b"=" * 7
BOM = b"\xef\xbb\xbf"


def tracked(root):
    """[(path, mode)] of every tracked entry; None when git cannot list them."""
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    p = subprocess.run(["git", "-C", root, "ls-files", "-z", "--stage"], capture_output=True, env=env)
    if p.returncode != 0:
        return None
    out = []
    for rec in p.stdout.split(b"\0"):
        if rec:
            meta, _, path = rec.partition(b"\t")
            out.append((os.fsdecode(path), meta.split()[0]))
    return out


def markers(data):
    """[(line number, text)] of the markers in one file's bytes; [] when it has none or is binary."""
    if (b"<<<<<<<" not in data and b">>>>>>>" not in data) or b"\0" in data:
        return []
    lines = [ln.rstrip(b"\r") for ln in data.split(b"\n")]
    if lines[0].startswith(BOM):   # an editor-saved file: the BOM sits before the marker of line 1
        lines[0] = lines[0][len(BOM):]
    starts = [i for i, ln in enumerate(lines) if ln.startswith(LT)]
    ends = [i for i, ln in enumerate(lines) if ln.startswith(GT)]
    hits = sorted(set(starts) | set(ends))
    if starts and ends:
        hits = sorted(set(hits) | {i for i, ln in enumerate(lines) if ln == MID and starts[0] < i < ends[-1]})
    return [(i + 1, lines[i][:7].decode()) for i in hits]


def read_allow(path):
    """({path: reason}, [problem])"""
    allow, problems = {}, []
    try:
        text = open(path, encoding="utf-8").read()
    except FileNotFoundError:
        return allow, problems
    for n, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        name, _, reason = line.partition(" ")
        if not reason.strip():
            problems.append("%s:%d: allow entry '%s' has no reason" % (path, n, name))
        allow[name] = reason.strip()
    return allow, problems


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--root", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
    ap.add_argument("--allow")
    a = ap.parse_args(argv)
    root = os.path.abspath(a.root)
    entries = tracked(root)
    if not entries:
        print("conflict_markers: no tracked file listed in %s (not a git work tree?)" % root, file=sys.stderr)
        return 2
    allow, problems = read_allow(a.allow or os.path.join(root, "tests", "conflict-marker-allow.txt"))
    seen, used, read = 0, set(), 0
    for path, mode in entries:
        seen += 1
        if mode != b"100644" and mode != b"100755":
            continue
        try:
            with open(os.path.join(root, path), "rb") as f:
                data = f.read()
        except OSError:
            continue
        read += 1
        found = markers(data)
        if not found:
            continue
        if path in allow:
            used.add(path)
            continue
        problems += ["%s:%d: conflict marker '%s'" % (path, n, t) for n, t in found]
    for name in sorted(set(allow) - used):
        listed = any(p == name for p, _ in entries)
        problems.append("allow entry '%s': %s" % (name, "the file has no marker" if listed else "not a tracked path"))
    if not read:
        print("conflict_markers: %d tracked entries but no file could be read in %s" % (seen, root), file=sys.stderr)
        return 2
    for p in problems:
        print(p)
    print("conflict_markers: %d tracked files read, %d problem(s)" % (read, len(problems)), file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
