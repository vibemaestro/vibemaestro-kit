#!/bin/bash
# =============================================================================
# Export gate: the public kit's export of one rev, scanned for internal terms and secrets before anything is published
# =============================================================================
# Usage (in the repository to export from):
#   bash scripts/export-gate.sh --rev <rev> --terms <file> [--gitleaks-tarball <file>] [--pins <file>]
#
#   --rev <rev>                the commit to export; resolved with `rev-parse --end-of-options`, printed back as its full sha
#   --terms <file>             the internal-term list (in CI the KIT_TERMS secret, written to a 0600 file); it must hold a term
#   --gitleaks-tarball <file>  a gitleaks release tarball already on disk, used instead of the download and verified the same way
#   --pins <file>              the pinned gitleaks release (default: export-gate.pins beside this script)
#
# Steps:
#   1. gitleaks: the release tarball of the pinned version for this platform; its sha256 must equal the pin and the binary's
#      `version` the pinned version, or nothing is scanned.
#   2. export: export-public.sh (beside this script) writes the rev into a fresh work dir under $TMPDIR, refused inside a repository.
#   3. the export becomes its own repository (a separate git dir, `git add -Af`, the export's pinned git config); its tree must equal
#      the digest export-public printed, so the index the term scanner reads is the export, file for file.
#   4. no exported path under the root kb/ or matching a glob of `public.private` in the rev's own .vibemaestro/sdlc.json, read
#      here from git, not from the export: the gate does not trust the exporter's own selection.
#   5. two controls, planted in the export only: a plain file, and one under a name that a .gitignore planted beside it ignores (so
#      plain `git add -A` would drop it) and that gitleaks' default rules skip unread (an image); each holds a per-run canary term and
#      a fake token. After `git add -Af` the index must differ from the digest by those three paths and nothing else.
#   6. scan-internal-terms.sh --ci --tree in the export, with the term file and the gate's own control term file (the canary, then
#      SENTINEL); gitleaks dir with the config beside this script, an empty ignore file, --ignore-gitleaks-allow and --redact, over
#      the export dir (the plain control must be found) and over a mirror where every file has a neutral name (both must be found).
# Output: one line per finding, never a term, a secret, a path a term may be in, or the size of the term list (the scanner's
#   `terms: N` line is dropped): term hits are the scanner's own index lines, gitleaks findings `gitleaks: <rule> file #N line L`
#   (N: the position in the export's `git ls-files`, as the scanner numbers a withheld path); a forbidden path by `kb/` or by its
#   glob's index (`public.private[i]`) only.
#   Green only, last: `export-gate: rev=<full sha> digest=<tree id>`, the export's digest before the controls (the publisher reads it).
# Exit codes: 0 green; 1 a finding (term hit, gitleaks finding, forbidden path); 2 usage (arguments, not a commit, a work dir inside
#   a repository); 3 the instrument failed (no usable terms, checksum, version, export refused, digest, a control missed, output of a
#   scanner it cannot read): a gate that did not scan never passes.
# =============================================================================
set -uo pipefail
exec python3 -I -B - "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)" "$@" <<'PY'
import hashlib, io, json, os, platform, re, secrets, shutil, string, subprocess, sys, tarfile, tempfile

HERE = sys.argv[1]
# a term no export may hold; spelled in two parts because this file is exported too, and its literal would be a hit of its own
SENTINEL = "-".join(("vmkit-export-gate", "sentinel-4b1e9c"))
CONTROL_TEXT = "export-gate control, planted in the export only and never published\ncanary %(canary)s\ntoken = \"%(token)s\"\n"
CTL_DIR = "export-gate-control"
CTL_PLAIN, CTL_HIDDEN, CTL_IGNORE = CTL_DIR + "/plain.txt", CTL_DIR + "/hidden.svg", CTL_DIR + "/.gitignore"
KB = "kb/"
CONFIG = ".vibemaestro/sdlc.json"   # `public.private`: the repo's private list, the same key export-public.sh and rule public-tree read
URL = "https://github.com/gitleaks/gitleaks/releases/download/v%(v)s/gitleaks_%(v)s_%(k)s.tar.gz"
# the git config of export-public.sh: no conversion on `git add`, so the tree here is comparable with its digest
HARD = ["-c", "core.autocrlf=false", "-c", "core.safecrlf=false", "-c", "core.fileMode=true", "-c", "core.symlinks=true",
        "-c", "core.ignoreCase=false", "-c", "core.precomposeUnicode=false", "-c", "core.protectHFS=true",
        "-c", "core.protectNTFS=true", "-c", "core.attributesFile=" + os.devnull, "-c", "core.excludesFile=" + os.devnull,
        "-c", "core.hooksPath=" + os.devnull, "-c", "core.fsmonitor=false", "-c", "core.useReplaceRefs=false"]
HIT = re.compile(r"^(tree|name) (.+) term=(\d+):(\d+)$")
USAGE = "usage: bash scripts/export-gate.sh --rev <rev> --terms <file> [--gitleaks-tarball <file>] [--pins <file>]"


def say(msg):
    sys.stdout.write(msg + "\n")
    sys.stdout.flush()


def stop(rc, msg):
    say("export-gate: %s%s" % ({2: "usage: ", 3: "broken: "}.get(rc, ""), msg))
    sys.exit(rc)


def run(cmd, env=None, cwd=None):
    return subprocess.run(cmd, env=env, cwd=cwd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def text(b):
    return b.decode("utf-8", "replace")


def crash(kind, exc, tb):  # an error this script did not foresee: exit 3 (a broken instrument), never 1 (a finding)
    say("export-gate: broken: an unexpected %s" % kind.__name__)   # the type only: its text may name an exported path
    os._exit(3)   # the work dir is gone already: `finally` ran while the error unwound


sys.excepthook = crash


def glob_regex(g):
    """A glob of `public.private` as one anchored regex (the `applyTo` language: `*`, `?`, `**`, `**/`), or None when invalid."""
    if not isinstance(g, str) or not g or g.startswith("/") or any(c in g for c in "[]{}\\") or any(c < " " for c in g):
        return None
    segs = g.split("/")
    if any(x in ("", ".", "..") for x in segs) or any("**" in x and x != "**" for x in segs):
        return None
    out, i = [], 0
    while i < len(g):
        for tok, rx in (("**/", r"(?:[^/]+/)*"), ("**", r".*"), ("*", r"[^/]*"), ("?", r"[^/]")):
            if g.startswith(tok, i):
                out.append(rx)
                i += len(tok)
                break
        else:
            out.append(re.escape(g[i]))
            i += 1
    return re.compile("".join(out) + r"\Z", re.S)


# ── arguments ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────
opts, args, i = {}, sys.argv[2:], 0
while i < len(args):
    if args[i] in ("-h", "--help"):
        say(USAGE)
        sys.exit(0)
    if args[i] not in ("--rev", "--terms", "--gitleaks-tarball", "--pins") or i + 1 >= len(args):
        stop(2, USAGE)
    opts[args[i]] = args[i + 1]
    i += 2
if "--rev" not in opts or "--terms" not in opts:
    stop(2, USAGE)

r = run(["git", "rev-parse", "--show-toplevel"])
if r.returncode != 0:
    stop(2, "not inside a git repository: run it in the repository to export from")
tops = [os.path.realpath(text(r.stdout).strip())]
r = run(["git", "-C", HERE, "rev-parse", "--show-toplevel"])
if r.returncode == 0:
    tops.append(os.path.realpath(text(r.stdout).strip()))
r = run(["git", "-c", "core.useReplaceRefs=false", "rev-parse", "--verify", "--quiet", "--end-of-options", opts["--rev"] + "^{commit}"])
if r.returncode != 0:
    stop(2, "not a commit: %r" % opts["--rev"])
sha = text(r.stdout).strip()
fmt = text(run(["git", "rev-parse", "--show-object-format"]).stdout).strip() or "sha1"
tmp = os.path.realpath(tempfile.gettempdir())
if any(tmp == t or tmp.startswith(t.rstrip(os.sep) + os.sep) for t in tops):
    stop(2, "the work dir would be inside a repository (TMPDIR=%s): the export must be scanned outside the checkout" % tmp)

terms = os.path.abspath(opts["--terms"])   # the scanner runs in the export dir
try:
    usable = any(line.strip() for line in open(terms, "rb").read().decode("utf-8", "replace").splitlines())
except OSError:
    usable = False
if not usable:
    stop(3, "the term file is missing, unreadable, empty or blank: a gate with no terms must not pass (is KIT_TERMS set?)")

pins, pins_file = {}, opts.get("--pins", os.path.join(HERE, "export-gate.pins"))
try:
    for line in open(pins_file).read().splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            k, v = line.split()
            pins[k] = v
except (OSError, ValueError):
    stop(3, "cannot read the pins file %s" % pins_file)
mach = platform.machine().lower()
key = "%s_%s" % (platform.system().lower(), {"x86_64": "x64", "amd64": "x64", "aarch64": "arm64"}.get(mach, mach))
version, pin = pins.get("version", ""), pins.get(key, "")
if not re.fullmatch(r"\d+\.\d+\.\d+", version) or not re.fullmatch(r"[0-9a-f]{64}", pin):
    stop(3, "no pinned gitleaks version and sha256 for %s in %s" % (key, pins_file))

W = tempfile.mkdtemp(prefix="export-gate.")
try:
    E, G, home = os.path.join(W, "export"), os.path.join(W, "git"), os.path.join(W, "home")
    os.mkdir(home)
    os.mkdir(os.path.join(W, "tmp"))
    genv = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": home, "XDG_CONFIG_HOME": home, "LC_ALL": "C",
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull, "GIT_ATTR_NOSYSTEM": "1"}

    def eg(*a):
        return run(["git"] + HARD + ["-C", E] + list(a), env=genv)

    def eg_out(what, *a):
        r = eg(*a)
        if r.returncode != 0:   # git's message is not printed: it may name an exported path
            stop(3, "%s failed in the export repository (exit %d)" % (what, r.returncode))
        return r.stdout

    # ── 1. the pinned gitleaks ─────────────────────────────────────────────────────────────────────────────────────────────────
    tarball = opts.get("--gitleaks-tarball")
    if not tarball:
        tarball = os.path.join(W, "gitleaks.tar.gz")
        r = run(["curl", "-fsSL", "--proto", "=https", "--tlsv1.2", "--retry", "3", "--max-time", "300", "-o", tarball,
                 URL % {"v": version, "k": key}])
        if r.returncode != 0:
            stop(3, "could not download gitleaks %s for %s (curl exit %d)" % (version, key, r.returncode))
    try:
        data = open(tarball, "rb").read()
    except OSError:
        stop(3, "cannot read the gitleaks tarball %s" % tarball)
    got = hashlib.sha256(data).hexdigest()
    if got != pin:
        stop(3, "checksum mismatch: gitleaks %s %s has sha256 %s, the pin is %s" % (version, key, got, pin))
    gl = os.path.join(W, "gitleaks")
    try:
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as tf:
            m = tf.getmember("gitleaks")
            if not m.isfile():
                raise KeyError("gitleaks")
            with open(gl, "wb") as f:
                f.write(tf.extractfile(m).read())
    except (KeyError, tarfile.TarError, OSError) as e:
        stop(3, "no gitleaks binary in the verified tarball: %s" % e)
    os.chmod(gl, 0o755)
    r = run([gl, "version"], env=genv)
    if r.returncode != 0 or text(r.stdout).strip() != version:
        stop(3, "the verified binary does not say it is gitleaks %s" % version)
    say("export-gate: gitleaks %s %s, sha256 matches the pin" % (version, key))

    # ── 2. the export, outside the checkout ────────────────────────────────────────────────────────────────────────────────────
    r = run(["bash", os.path.join(HERE, "export-public.sh"), sha, E])
    for line in text(r.stderr).splitlines():   # its summary and WARN lines; a refusal names paths, so it stays unprinted
        if line.startswith(("export-public: WARN ", "export-public: rev=")):
            say(line)
    digest = text(r.stdout).strip()
    if r.returncode != 0 or not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", digest):
        stop(3, "export-public.sh did not export %s (exit %d; run it on that rev for the reason)" % (sha, r.returncode))

    # ── 3. its own repository, whose tree is the digest ────────────────────────────────────────────────────────────────────────
    r = run(["git", "init", "-q", "--template=", "--object-format=" + fmt, "--separate-git-dir=" + G, E], env=genv)
    if r.returncode != 0:
        stop(3, "git init of the export failed (exit %d)" % r.returncode)
    eg_out("git add -Af", "add", "-Af", "--", ".")
    tree = text(eg_out("git write-tree", "write-tree")).strip()
    if tree != digest:
        stop(3, "the export's tree %s is not the digest %s that export-public.sh printed" % (tree, digest))
    exported = [p for p in text(eg_out("git ls-files", "ls-files", "-z")).split("\0") if p]

    # ── 4. nothing private in what was exported: the root kb/ and the rev's public.private, read from git here ─────────────────
    r = run(["git", "-c", "core.useReplaceRefs=false", "cat-file", "blob", "%s:%s" % (sha, CONFIG)])
    try:
        pub = json.loads(text(r.stdout)).get("public") if r.returncode == 0 else None
        globs = pub.get("private") if isinstance(pub, dict) else None
    except (ValueError, AttributeError):
        globs = None
    rxs = [glob_regex(g) for g in globs] if isinstance(globs, list) else [None]
    if any(x is None for x in rxs):
        stop(3, "%s at %s has no public.private list of valid globs: the gate cannot tell what must stay private" % (CONFIG, sha))
    forbidden = {}
    for p in exported:
        keys = ([KB] if p.startswith(KB) else []) + ["public.private[%d]" % i for i, x in enumerate(rxs) if x.match(p)]
        for k in keys:
            forbidden[k] = forbidden.get(k, 0) + 1

    # ── 5. the controls, in the export only ────────────────────────────────────────────────────────────────────────────────────
    if os.path.lexists(os.path.join(E, CTL_DIR)):
        stop(3, "the export already holds %s/: the controls cannot be planted" % CTL_DIR)
    os.mkdir(os.path.join(E, CTL_DIR))
    canary = "egc" + secrets.token_hex(12)
    alnum = string.ascii_letters + string.digits
    body = CONTROL_TEXT % {"canary": canary, "token": "ghp_" + "".join(secrets.choice(alnum) for _ in range(36))}
    for p, content in ((CTL_IGNORE, "*.svg\n"), (CTL_PLAIN, body), (CTL_HIDDEN, body)):
        with open(os.path.join(E, p), "w") as f:
            f.write(content)
    if eg("check-ignore", "-q", "--no-index", "--", CTL_HIDDEN).returncode != 0 or \
            eg("check-ignore", "-q", "--no-index", "--", CTL_PLAIN).returncode == 0:
        stop(3, "the planted .gitignore does not ignore exactly the hidden control: that control would prove nothing")
    eg_out("git add -Af", "add", "-Af", "--", ".")
    tree2 = text(eg_out("git write-tree", "write-tree")).strip()
    added = text(eg_out("git diff-tree", "diff-tree", "-r", "-z", "--name-only", "--no-renames", tree, tree2))
    added = sorted(p for p in added.split("\0") if p)
    if added != sorted((CTL_PLAIN, CTL_HIDDEN, CTL_IGNORE)):
        stop(3, "the index holds %d new path(s) where the three control files were planted: a control is not scanned" % len(added))
    # no exclude rule given, so `--others` lists ignored files too; `diff` compares the work tree with the index
    if text(eg_out("git ls-files", "ls-files", "-z", "--others")) or text(eg_out("git diff", "diff", "--name-only", "-z")):
        stop(3, "the export dir holds a file its index does not: the scanner would not see it")
    files = [p for p in text(eg_out("git ls-files", "ls-files", "-z")).split("\0") if p]
    controls = {CTL_PLAIN, CTL_HIDDEN, CTL_IGNORE}

    # ── 6a. the internal-term scan ─────────────────────────────────────────────────────────────────────────────────────────────
    ctl_terms = os.path.join(W, "control.terms")
    with open(ctl_terms, "w") as f:
        f.write(canary + "\n" + SENTINEL + "\n")
    senv = dict(genv, TMPDIR=os.path.join(W, "tmp"))
    r = run(["bash", os.path.join(HERE, "scan-internal-terms.sh"), "--ci", "--terms", terms, "--terms", ctl_terms, "--tree"],
            env=senv, cwd=E)
    for line in text(r.stderr).splitlines():
        say(line)
    if r.returncode not in (0, 1):
        stop(3, "the term scanner failed (exit %d)" % r.returncode)
    lines = text(r.stdout).splitlines()
    term_hits, term_ctl, nhits, unknown = [], set(), 0, 0
    for line in lines:
        if line.startswith("terms: "):
            continue
        m = HIT.match(line)
        if m:
            nhits += 1
            kind, place, k, t = m.group(1), m.group(2), int(m.group(3)), int(m.group(4))
            w = re.fullmatch(r"\(path withheld; file #(\d+)\)" if kind == "tree" else r"#(\d+)", place)
            path = files[int(w.group(1)) - 1] if w and 0 < int(w.group(1)) <= len(files) else (place if kind == "tree" and not w else None)
            if path in controls:   # a file the gate made: its canary hit is the control; a term matching its random text is noise
                if kind == "tree" and k == 2 and t == 1:
                    term_ctl.add(path)
                continue
            term_hits.append(line)
            say(line)
            continue
        say(line)
        if not (line.startswith("scanned files: ") or line.startswith("control: ")):
            unknown += 1
    scanned = next((l for l in lines if l.startswith("scanned files: ")), "")
    m = re.fullmatch(r"scanned files: (\d+); binary files read as text: \d+", scanned)
    if unknown or not lines or lines[-1] != "control: found 1/1; hits: %d" % nhits or not m or int(m.group(1)) != len(files):
        stop(3, "the term scanner's output is not what this gate reads (an unknown line, a count that differs, no control line)")

    # ── 6b. gitleaks, twice: over the export dir (rules that look at a path), and over a mirror of it where every file has a
    #    neutral name, because the default rules skip whole paths (images, lockfiles, node_modules/, a *gitleaks.toml) unread
    ign = os.path.join(W, "empty.gitleaksignore")
    open(ign, "w").close()
    M = os.path.join(W, "mirror")
    os.mkdir(M)
    for n, p in enumerate(files, 1):
        shutil.copyfile(os.path.join(E, p), os.path.join(M, "f%06d" % n))

    def leaks(target, report):  # the findings of one gitleaks run, as (exported path or None, rule, line)
        r = run([gl, "dir", target, "--config", os.path.join(HERE, "export-gate.gitleaks.toml"), "--gitleaks-ignore-path", ign,
                 "--ignore-gitleaks-allow", "--redact", "--no-banner", "--no-color", "--log-level", "warn", "--report-format", "json",
                 "--report-path", report, "--exit-code", "1"], env=genv, cwd=W)
        try:
            found = json.load(open(report))
            if not isinstance(found, list):
                raise ValueError("not a list")
        except (OSError, ValueError) as e:
            stop(3, "gitleaks wrote no report it can read (exit %d): %s" % (r.returncode, e))
        if r.returncode != (1 if found else 0):
            stop(3, "gitleaks exited %d with %d finding(s)" % (r.returncode, len(found)))
        top, out = os.path.realpath(target), []
        for f in found:
            p = str(f.get("File", ""))
            rel = os.path.relpath(os.path.realpath(p if os.path.isabs(p) else os.path.join(W, p)), top)
            if target == M:
                m = re.fullmatch(r"f(\d{6})", rel)
                rel = files[int(m.group(1)) - 1] if m and 0 < int(m.group(1)) <= len(files) else None
            rule = str(f.get("RuleID", "?"))
            out.append((rel if rel in files else None, rule if re.fullmatch(r"[A-Za-z0-9._-]{1,80}", rule) else "?",
                        int(f.get("StartLine", 0) or 0)))
        return out

    in_dir, in_mirror = leaks(E, os.path.join(W, "gitleaks-dir.json")), leaks(M, os.path.join(W, "gitleaks-mirror.json"))
    # the plain control proves the dir scan; the hidden one, under a name the default rules skip, proves the mirror scan
    gl_ctl = {p for p, _, _ in in_dir if p == CTL_PLAIN} | {p for p, _, _ in in_mirror if p == CTL_HIDDEN}
    gl_hits = []
    for p, rule, line in sorted(set(in_dir + in_mirror), key=lambda h: (files.index(h[0]) if h[0] else -1, h[2], h[1])):
        if p in controls:
            continue
        gl_hits.append("gitleaks: %s %s line %d" % (rule, "file #%d" % (files.index(p) + 1) if p else "(not an exported file)", line))
        say(gl_hits[-1])

    for k in sorted(forbidden):
        say("forbidden: %d exported path(s) %s %s" % (forbidden[k], "under" if k == KB else "matching", k))
    if len(term_ctl) != 2 or len(gl_ctl) != 2:
        stop(3, "a control was missed: terms %d/2, gitleaks %d/2" % (len(term_ctl), len(gl_ctl)))
    say("controls: terms 2/2, gitleaks 2/2")
    if term_hits or gl_hits or forbidden:
        say("export-gate: red rev=%s digest=%s: %d term hit(s), %d gitleaks finding(s), %d forbidden path(s)"
            % (sha, digest, len(term_hits), len(gl_hits), sum(forbidden.values())))
        sys.exit(1)
    say("export-gate: rev=%s digest=%s" % (sha, digest))
finally:
    shutil.rmtree(W, ignore_errors=True)
PY
