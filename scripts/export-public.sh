#!/bin/bash
# =============================================================================
# Public kit export: the published tree of one rev, read from git objects only, and its one tree digest
# =============================================================================
# Usage (in the repository to export from):
#   bash scripts/export-public.sh <rev> <outdir>
#
#   <rev>     a commit (sha, branch, tag); it is resolved with `rev-parse --end-of-options`, never read as an option
#   <outdir>  created when missing; refused when it exists and is not an empty directory
#
# Writes into <outdir>, from the objects of <rev> (never the work tree, the index or `git archive`):
#   every file of the rev except the root kb/ and the paths that match a glob of `public.private` in the rev's own
#   .vibemaestro/sdlc.json (the repo's private list: the same key the sdlc rule public-tree and the export gate read); and a copy
#   of LICENSE and NOTICE in each plugins/<name>/. A rev whose config does not set `public.private` does not publish: refused.
#   The globs are those of `applyTo`: `*` and `?` inside a segment, `**` across segments, `**/` also zero directories.
# The one file it does not copy byte for byte: each plugins/<name>/.claude-plugin/plugin.json gets the plugin's released version,
#   the first `## X.Y.Z` heading of the same rev's plugins/<name>/CHANGELOG.md (the private repo carries no version),
#   as its `version` after `name`; and each dependency on another plugin
#   of the rev's marketplace that is released at that rev (a bare name, or an object with no `version` and no `marketplace`)
#   becomes {"name": …, "version": ">=0.1.0"}. A manifest that needs neither keeps its bytes; a changed one is written as JSON
#   (indent 2, UTF-8, key order kept) plus a newline, so the same rev still gives the same bytes. A plugin with no released
#   version exports without one and one WARN line: a publish step must refuse that tree.
# stdout: one line, the tree digest: the git tree id that `git init`, `git add -Af` and `git write-tree` give for <outdir> (the one
#   definition the export gate and the publisher compare). It is computed with the git config pinned in HARD
#   below; a plain `git add -Af` under another config (core.autocrlf=true on a CRLF file) can give another id, so compare the printed
#   digest, or recompute it with HARD. stderr: a summary line and any WARN.
# The same rev gives the same tree byte for byte: blobs are read raw (`git cat-file --batch`, and replace refs are off by
#   `-c core.useReplaceRefs=false`, which wins over any config), so no filter, attribute, eol rule or local `git replace` reaches
#   the bytes; files are 0644 or 0755 as git records them, directories 0755; every mtime is the commit's committer time, read from
#   the raw commit, so no log setting such as log.showSignature changes it.
# A rev with no LICENSE or no NOTICE still exports, with one WARN line per missing file and no plugin copy of it: the publish step
#   refuses such a tree, the export does not, so the scan gate and the README check run before the licence lands.
#
# Exit codes:
#   0  exported; the digest is on stdout
#   2  usage: wrong arguments, <rev> is not a commit, <outdir> is empty, cannot be created or is not an empty directory
#   3  refused before writing: the rev's tree holds a path twice (a crafted tree); a manifest's own `version` differs from its
#      CHANGELOG's released version, or a manifest or the marketplace is not a JSON object; an exported path is a symlink, a gitlink or not
#      a plain file, has an empty, ".", ".." or ".git" part, or is one git refuses with core.protectHFS and core.protectNTFS on (a
#      lookalike of .git); README.md or the marketplace is missing; a plugins/<name>/LICENSE or NOTICE is committed (the copy is made
#      here only); the rev's .vibemaestro/sdlc.json is missing, not JSON, or has no `public.private` list of valid globs
#   4  a git call that fails; before writing, a committer time it cannot read (none, or outside 0..2^32); after writing, a file
#      that could not be written (a name this filesystem folds onto another), or a digest of the written directory that differs
#      from the tree id of the git entries (a .gitattributes that rewrites a file on `git add`, a stray file). No digest is
#      printed; after writing, <outdir> holds an unusable tree: discard it.
# =============================================================================
set -uo pipefail
if [ $# -ne 2 ]; then
  echo "usage: bash scripts/export-public.sh <rev> <outdir>" >&2
  exit 2
fi
exec python3 -I -B - "$@" <<'PY'
import os, shutil, subprocess, sys, tempfile

KB = "kb/"                          # the private side of the repo: never exported (the root one only; a fixture's kb/ is a file like any)
CONFIG = ".vibemaestro/sdlc.json"   # the rev's own config: `public.private` lists what else stays private
REQUIRED = ("README.md", ".claude-plugin/marketplace.json")
LICENCE = ("LICENSE", "NOTICE")
GLOB_BAD_CHARS = "[]{}\\"            # what the `applyTo` glob language does not have: refused, never read literally
MANIFEST = ".claude-plugin/plugin.json"
MARKETPLACE = ".claude-plugin/marketplace.json"
DEPENDENCY_RANGE = ">=0.1.0"   # the range the export writes on a released sibling dependency
# The config of every git call that reads or builds the digest: no conversion on `git add`, and git's own path checks of every OS
HARD = ["-c", "core.autocrlf=false", "-c", "core.safecrlf=false", "-c", "core.fileMode=true", "-c", "core.symlinks=true",
        "-c", "core.ignoreCase=false", "-c", "core.precomposeUnicode=false", "-c", "core.protectHFS=true",
        "-c", "core.protectNTFS=true", "-c", "core.attributesFile=" + os.devnull, "-c", "core.excludesFile=" + os.devnull,
        "-c", "core.hooksPath=" + os.devnull, "-c", "core.fsmonitor=false", "-c", "core.useReplaceRefs=false"]


def die(rc, msg):
    sys.stderr.write("export-public: %s\n" % msg)
    sys.exit(rc)


def git(args, env, inp=None, cwd=None):
    return subprocess.run(["git"] + args, input=inp, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def src(args, inp=None):  # a read of the source repository: replace refs off, whatever its config or GIT_CONFIG_* says
    return git(["-c", "core.useReplaceRefs=false"] + args, None, inp=inp)


def read_blobs(oids):
    """{oid: raw bytes} of blobs of the source repository: cat-file --batch applies no filter, no attribute, no eol rule."""
    oids = sorted(set(oids))
    r = src(["cat-file", "--batch"], inp="".join(o + "\n" for o in oids).encode())
    if r.returncode != 0:
        die(4, "git cat-file failed: %s" % r.stderr.decode("utf-8", "replace").strip())
    blobs, buf, at = {}, r.stdout, 0
    for o in oids:
        nl = buf.index(b"\n", at)
        head = buf[at:nl].decode().split(" ")
        if len(head) != 3 or head[0] != o or head[1] != "blob":
            die(4, "object %s: unexpected cat-file answer %r" % (o, " ".join(head)))
        size = int(head[2])
        blobs[o] = buf[nl + 1:nl + 1 + size]
        at = nl + 1 + size + 1
    return blobs


def released_of(raw):
    """The released version a CHANGELOG records: its first `## ` heading when that is X.Y.Z (as release.py reads it), else None."""
    import re
    for line in (raw or b"").decode("utf-8", "replace").split("\n"):
        if line.startswith("## "):
            v = line[3:].strip()
            return v if re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", v, re.ASCII) else None
    return None


def public_manifests(keep):
    """{manifest path: new bytes} for the manifests the export rewrites (see the header); refuses (rc 3) what cannot be read."""
    import json
    oid = {p: o for p, _, o in keep}
    names = sorted({p.split("/")[1] for p in oid if p.startswith("plugins/") and p.endswith("/" + MANIFEST) and p.count("/") == 3})
    paths = [MARKETPLACE] + ["plugins/%s/%s" % (n, f) for n in names for f in (MANIFEST, "CHANGELOG.md")]
    raw = read_blobs([oid[p] for p in paths if p in oid])
    blob = lambda p: raw.get(oid[p]) if p in oid else None
    try:
        market = json.loads(blob(MARKETPLACE).decode("utf-8"))
        manifests = {n: json.loads(blob("plugins/%s/%s" % (n, MANIFEST)).decode("utf-8")) for n in names}
    except (ValueError, AttributeError) as e:
        die(3, "refused %s: a manifest or the marketplace is not JSON: %s" % (sha, e))
    entries = market.get("plugins") if isinstance(market, dict) else None
    siblings = {e.get("name") for e in entries if isinstance(e, dict)} if isinstance(entries, list) else set()
    released, problems = {}, []
    for n in names:
        m, rel = manifests[n], released_of(blob("plugins/%s/CHANGELOG.md" % n))
        if not isinstance(m, dict):
            problems.append("plugins/%s/%s is not a JSON object" % (n, MANIFEST))
        elif "version" in m and rel is not None and m["version"] != rel:
            problems.append("plugins/%s/%s says version %r, its CHANGELOG.md released %s" % (n, MANIFEST, m["version"], rel))
        released[n] = m.get("version") if isinstance(m, dict) and isinstance(m.get("version"), str) else rel
    if problems:
        die(3, "refused %s:\n  " % sha + "\n  ".join(problems))
    out = {}
    for n in names:
        m = manifests[n]
        new = {}
        for k, v in m.items():
            new[k] = v
            if k == "name" and "version" not in m and released[n]:
                new["version"] = released[n]
        if "version" not in new and released[n]:
            new["version"] = released[n]
        deps = new.get("dependencies")
        if isinstance(deps, list):
            fixed = []
            for d in deps:
                name = d if isinstance(d, str) else d.get("name") if isinstance(d, dict) and "version" not in d and "marketplace" not in d else None
                if isinstance(name, str) and name in siblings and released.get(name):
                    d = dict(d, version=DEPENDENCY_RANGE) if isinstance(d, dict) else {"name": name, "version": DEPENDENCY_RANGE}
                fixed.append(d)
            new["dependencies"] = fixed
        if not released[n]:
            sys.stderr.write("export-public: WARN plugins/%s has no released version at %s (no `## X.Y.Z` first in its "
                             "CHANGELOG.md): exported without one; the publish step refuses this tree\n" % (n, sha))
        if new != m or list(new) != list(m):
            out["plugins/%s/%s" % (n, MANIFEST)] = (json.dumps(new, indent=2, ensure_ascii=False) + "\n").encode("utf-8")
    return out


def out_of(r, what):
    if r.returncode != 0:
        die(4, "%s failed: %s" % (what, r.stderr.decode("utf-8", "replace").strip()))
    return r.stdout.decode().strip()


def glob_regex(g):
    """A glob of `public.private` as one anchored regex (the `applyTo` language), or None when the glob is not valid in it."""
    import re
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


def private_list(entries):
    """The compiled globs of `public.private` in the rev's config (entries: {path: (mode, kind, oid)}); refuses (rc 3) otherwise."""
    import json
    e = entries.get(CONFIG)
    if not e or e[1] != "blob" or e[0] == "120000":
        die(3, "refused %s: no %s, so the rev does not say what it publishes (set public.private)" % (sha, CONFIG))
    try:
        cfg = json.loads(read_blobs([e[2]])[e[2]].decode("utf-8"))
    except (ValueError, UnicodeDecodeError) as x:
        die(3, "refused %s: %s is not JSON: %s" % (sha, CONFIG, x))
    pub = cfg.get("public") if isinstance(cfg, dict) else None
    globs = pub.get("private") if isinstance(pub, dict) else None
    if not isinstance(globs, list):
        die(3, "refused %s: %s has no public.private list, so the rev does not publish" % (sha, CONFIG))
    rx = [glob_regex(g) for g in globs]
    bad = ["public.private[%d]" % i for i, x in enumerate(rx) if x is None]
    if bad:
        die(3, "refused %s: not a glob of the applyTo language: %s" % (sha, ", ".join(bad)))
    return rx


rev, outdir = sys.argv[1], sys.argv[2]
r = src(["rev-parse", "--verify", "--quiet", "--end-of-options", rev + "^{commit}"])
if r.returncode != 0:
    die(2, "not a commit: %r" % rev)
sha = r.stdout.decode().strip()
raw_commit = src(["cat-file", "commit", sha]).stdout.split(b"\n\n", 1)[0].split(b"\n")
try:
    ct = int(next(l for l in raw_commit if l.startswith(b"committer ")).rsplit(b" ", 2)[1])
    if not 0 <= ct < 2 ** 32:
        raise ValueError(ct)
except (StopIteration, IndexError, ValueError):
    die(4, "cannot read a committer time in 0..2^32 from commit %s" % sha)
fmt = out_of(src(["rev-parse", "--show-object-format"]), "reading the object format")

if os.path.lexists(outdir) and (not os.path.isdir(outdir) or os.listdir(outdir)):
    die(2, "outdir %s exists and is not an empty directory" % outdir)

# ── the entries of the rev that are published: all but the root kb/ and public.private ───────────────────────────────────────
r = src(["ls-tree", "-r", "-t", "-z", "--full-tree", sha])
if r.returncode != 0:
    die(4, "git ls-tree failed: %s" % r.stderr.decode("utf-8", "replace").strip())
keep, problems, root, seen, entries = [], [], {}, set(), []
for rec in r.stdout.split(b"\0"):
    if not rec:
        continue
    meta, raw = rec.split(b"\t", 1)
    mode, kind, oid = meta.decode().split(" ")
    path = raw.decode("utf-8", "surrogateescape")
    if path in seen:   # a tree with two entries of one name (git fsck: duplicateEntries); ls-tree -r would walk both
        problems.append("%r appears twice in the tree" % path)
    seen.add(path)
    if kind != "tree":
        entries.append((path, mode, kind, oid))
private = private_list({p: (m, k, o) for p, m, k, o in entries})
for path, mode, kind, oid in entries:
    if path in LICENCE:
        root[path] = (mode, oid)
    if path.startswith(KB) or any(rx.match(path) for rx in private):
        continue
    if any(p in ("", ".", "..") or p.lower() == ".git" for p in path.split("/")):
        problems.append("%r has an empty, '.', '..' or '.git' part" % path)
    elif mode == "120000":
        problems.append("%s is a symlink" % path)
    elif kind != "blob" or not mode.startswith("100"):
        problems.append("%s is not a plain file (mode %s, %s)" % (path, mode, kind))
    keep.append((path, "100755" if mode == "100755" else "100644", oid))
paths = {p for p, _, _ in keep}
problems += ["%s is missing at %s" % (n, sha) for n in REQUIRED if n not in paths]
plugins = sorted({p.split("/")[1] for p in paths if p.startswith("plugins/") and p.count("/") >= 2})
for name in plugins:
    for f in LICENCE:
        if "plugins/%s/%s" % (name, f) in paths:
            problems.append("plugins/%s/%s is committed: the plugin copy is made at export time only" % (name, f))
if problems:
    die(3, "refused %s:\n  " % sha + "\n  ".join(problems))
for f in LICENCE:
    if f in root:
        keep += [("plugins/%s/%s" % (name, f), "100755" if root[f][0] == "100755" else "100644", root[f][1]) for name in plugins]
    else:
        sys.stderr.write("export-public: WARN no %s at %s: exported without it and without a copy in plugins/<name>/; "
                         "the publish step refuses this tree\n" % (f, sha))
keep.sort(key=lambda e: os.fsencode(e[0]))
rewrite = public_manifests(keep)

scratch = tempfile.mkdtemp(prefix="export-public.")
try:
    # ── the tree id of the entries, before anything is written: a path git refuses (protectHFS/NTFS) is dropped from the index ───
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": scratch, "XDG_CONFIG_HOME": scratch, "LC_ALL": "C",
           "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull, "GIT_ATTR_NOSYSTEM": "1",
           "GIT_DIR": os.path.join(scratch, "repo")}
    out_of(git(["init", "-q", "--template=", "--object-format=" + fmt], env), "git init")
    made_blobs = {}
    for i, (path, mode, oid) in enumerate(keep):
        if path in rewrite:
            new_oid = out_of(git(["hash-object", "-w", "--stdin"], env, inp=rewrite[path]), "git hash-object")
            made_blobs[new_oid] = rewrite[path]
            keep[i] = (path, mode, new_oid)
    ienv = dict(env, GIT_INDEX_FILE=os.path.join(scratch, "expected.index"))
    info = b"".join(b"%s blob %s\t%s\0" % (m.encode(), o.encode(), os.fsencode(p)) for p, m, o in keep)
    out_of(git(HARD + ["update-index", "-z", "--index-info"], ienv, inp=info), "git update-index")
    r = git(HARD + ["ls-files", "-z"], ienv)
    if r.returncode != 0:
        die(4, "git ls-files failed: %s" % r.stderr.decode("utf-8", "replace").strip())
    listed = set(r.stdout.split(b"\0"))
    refused = [p for p, _, _ in keep if os.fsencode(p) not in listed]
    if refused:
        die(3, "refused %s: git refuses these paths (core.protectHFS, core.protectNTFS):\n  %s" % (sha, "\n  ".join(map(repr, refused))))
    want = out_of(git(HARD + ["write-tree", "--missing-ok"], ienv), "git write-tree of the entries")

    # ── raw blobs: cat-file --batch applies no filter, no attribute, no eol rule; the rewritten manifests are already here ──────
    blobs = read_blobs([o for _, _, o in keep if o not in made_blobs])
    blobs.update(made_blobs)

    # ── write ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────
    try:
        os.makedirs(outdir, exist_ok=True)
    except OSError as e:
        die(2, "cannot create outdir %s: %s" % (outdir, e))
    out = os.path.realpath(outdir)
    made = [out]
    try:
        for path, mode, oid in keep:
            parts = path.split("/")
            d = out
            for p in parts[:-1]:
                d = os.path.join(d, p)
                if not os.path.lexists(d):
                    os.mkdir(d)
                    made.append(d)
                elif os.path.islink(d) or not os.path.isdir(d):
                    raise OSError("%s exists and is not a directory" % d)
            fd = os.open(os.path.join(out, path), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            try:
                data = memoryview(blobs[oid])
                while data:
                    data = data[os.write(fd, data):]
                os.fchmod(fd, 0o755 if mode == "100755" else 0o644)
            finally:
                os.close(fd)
            os.utime(os.path.join(out, path), (ct, ct), follow_symlinks=False)
        for d in sorted(made, key=len, reverse=True):
            os.chmod(d, 0o755)
            os.utime(d, (ct, ct), follow_symlinks=False)
    except OSError as e:
        die(4, "could not write the export (a name this filesystem folds onto another?): %s" % e)

    # ── the plan's digest (git add -Af of the dir) must be the tree id of the entries ─────────────────────────────────────────
    wenv = dict(env, GIT_WORK_TREE=out)
    out_of(git(HARD + ["add", "-Af", "--", "."], wenv, cwd=out), "git add -Af")
    digest = out_of(git(HARD + ["write-tree"], wenv), "git write-tree")
    if digest != want:
        diff = git(HARD + ["diff-tree", "-r", "--name-status", want, digest], env).stdout.decode("utf-8", "replace").splitlines()
        die(4, "the written tree %s differs from the git entries %s of %s (A: only on disk, M: bytes changed):\n  %s"
            % (digest, want, sha, "\n  ".join(diff[:20])))
finally:
    shutil.rmtree(scratch, ignore_errors=True)

sys.stderr.write("export-public: rev=%s files=%d digest=%s\n" % (sha, len(keep), digest))
print(digest)
PY
