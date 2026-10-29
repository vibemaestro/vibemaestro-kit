#!/usr/bin/env python3
"""The engine of the kit baton kit:plugin-update: reads the registry files and the marketplace clone, and never writes.

    plugin_update.py layout <claude dir>                 CLONE <path>, LAYOUT kit-own|git-subdir, KIT <owner/name>, REPO
                                                         <owner/name> (the known source's), HEAD <clone commit>, then LOCAL
                                                         <plugin> per marketplace-local plugin in manifest order; or REFUSE
                                                         <why> and exit 3
    plugin_update.py tree <claude dir> <commit or -> <plugin>...
                                                         TREE clean: the clone's HEAD is that commit (- for any), and its
                                                         .claude-plugin and plugins/<plugin> are, file by file and hashed,
                                                         HEAD's tree there; or REFUSE and exit 3
    plugin_update.py installed <claude dir> [<local plugin>...]
                                                         ENTRY <plugin> <gitCommitSha or -> per plugin (sdlc and brain must
                                                         have one user install; a local plugin with none is NONE <plugin>);
                                                         or REFUSE and exit 3
    plugin_update.py check <claude dir> <state> <record dir>
                                                         the post-check of each plugin the record's targets name: CHECK
                                                         lines, then SDLC <new sdlc install>; or FAIL <why> lines and exit 1
    plugin_update.py left <claude dir> <record dir>      LEFT <cache directory> for each install of the record's plugins that
                                                         the old registry (the run's byte copy) does not name
    plugin_update.py others <claude dir> <record dir>    OTHER <file> <keys> and exit 1 when either registry file changed
                                                         outside the record's plugins and the marketplace since the record's
                                                         copy; MOVED <plugin> … and exit 1 when one of those plugins is no
                                                         longer what the run left: the copy's entry, or the entry its update
                                                         left (the record's after-<plugin>)
    plugin_update.py entry <claude dir> <plugin>         the plugin's user-scope entries now, as one JSON line
    plugin_update.py gone <record dir>                   GONE <plugin> <installPath> and exit 1 for each user install of the
                                                         record's plugins that its copy names whose directory is gone

The record's `targets` file holds one line per plugin in scope: <plugin> <old commit or -> <target commit>.

The layouts: (1) the kit's own marketplace, both plugins at `./plugins/<name>`; the kit is the github.com repository that the
known source and the clone's `origin` both name. (2) The git-subdir marketplace, both plugins exactly {"source": "git-subdir",
"url": "https://github.com/<owner>/<name>(.git)", "path": "plugins/<name>", "ref": "main"}, one URL; the kit is that repository.
In both, the known source is {source: github, repo} or {source: git, url} naming a github.com repository (https or ssh), at most
with ref main; each plugin's marketplace entry carries only name, source and description (an entry can add hooks, servers or a
manifest of its own); none of the git variables that point git at another repository or config file (GIT_DIR, GIT_CONFIG,
GIT_CONFIG_PARAMETERS, …) is set in the environment, git's own discovery from the clone lands on its .git (so a clone git does
not trust is refused), and the clone's config, as git reads it there (worktree config and a commondir included; no system or
global file), gives origin one URL, the known source's repository, with no URL rewrite and no include; and the URL git would
really fetch from, with every config level of the owner (global, XDG, system), names that repository too. The clone's transport
keys (a proxy, a pinned address, a branch's remote, a refspec or merge ref onto another ref, TLS checks off) are not read here:
the kit baton refuses them after this layout read. Any other layout, or one that names no kit repository or more than one, is
refused. Every other entry of the manifest is a marketplace-local plugin: exactly {"name", "source": "./plugins/<name>",
"description"}, a name of lower-case letters, digits, dots, dashes and underscores; any other entry is an unknown layout. In
the kit's own layout sdlc and brain are local too. The clone's plugins directory and each local plugin's directory are real
directories. The registry files, the marketplace manifest, the clone's git config, each installed plugin.json and the
launcher template are regular files, and the clone's .git and .claude-plugin and an install's .claude-plugin and scripts are
real directories, not symlinks (the path above them is taken as it resolves); the clone's real path must lie directly in <claude
dir>/plugins/marketplaces.

The post-check, for each plugin's one user-scope entry: `gitCommitSha` is the SHA; `version` is its first 12 hex, alone or with a
dash and 8 lower-case hex; the real path of `installPath` is the directory <claude dir>/plugins/cache/vibemaestro/<plugin>/<version>;
its `.claude-plugin/plugin.json` carries no `version`. Then the new sdlc's launcher template (scripts/baton-launcher.py), loaded
from the new install: its INSTALL_DIR accepts both directories, and its resolve(), pointed at this claude directory, picks the
new sdlc's scripts/baton.py. Standard library and git only, Python 3.8+.
"""
import hashlib, importlib.util, json, os, re, stat, subprocess, sys
MKT, NAMES = "vibemaestro", ("vibemaestro-sdlc", "vibemaestro-brain")
REPO = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\Z")
LOCAL = re.compile(r"^[a-z0-9][a-z0-9._-]*\Z")
SHA = re.compile(r"^[0-9a-f]{40}\Z")
HOST = "github.com"
ENTRY_KEYS = ("name", "source", "description")
MANIFEST_KEYS = ("$schema", "name", "owner", "description", "version", "metadata", "plugins")

def out(*a):
    print(" ".join(str(x) for x in a))

def refuse(why, rc=3):
    out("REFUSE", why)
    sys.exit(rc)

def irregular(path):
    """Why the path is no regular file (missing, a symlink, another kind), or None."""
    try:
        st = os.lstat(path)
    except OSError as e:
        return "cannot be read: %s" % e.strerror
    if not stat.S_ISREG(st.st_mode):
        return "is not a regular file (a symlink or another kind): %s" % path
    return None

def unreal(path):
    """Why the path is no real directory (missing, a symlink, another kind), or None."""
    try:
        st = os.lstat(path)
    except OSError as e:
        return "cannot be read: %s" % e.strerror
    if not stat.S_ISDIR(st.st_mode):
        return "is not a directory (a symlink or another kind): %s" % path
    return None

def load(path, what):
    why = irregular(path)
    if why:
        refuse("%s %s" % (what, why))
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError) as e:
        refuse("%s is not JSON: %s" % (what, e))

def gh_repo(url, https_only=False):
    """owner/name, lower-cased, of a github.com URL (https; ssh too unless https_only), else None."""
    if not isinstance(url, str):
        return None
    for pre in ("https://%s/" % HOST,) + (() if https_only else ("git@%s:" % HOST, "ssh://git@%s/" % HOST)):
        if url.startswith(pre):
            r = url[len(pre):]
            r = r[:-4] if r.endswith(".git") else r
            r = r.rstrip("/")
            return r.lower() if REPO.match(r) and ".." not in r else None
    return None

GIT_ENV = ("GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_CONFIG", "GIT_CONFIG_PARAMETERS", "GIT_OBJECT_DIRECTORY",
           "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_NAMESPACE", "GIT_INDEX_FILE")

def git(args, env, what, raw=False):
    try:
        r = subprocess.run(["git"] + args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    except OSError as e:
        refuse("git cannot %s: %s" % (what, e.strerror))
    if r.returncode != 0:
        err = r.stderr.decode("utf-8", "replace").strip().splitlines()
        refuse("git cannot %s: %s" % (what, err[0] if err else "rc %d" % r.returncode))
    return r.stdout if raw else r.stdout.decode("utf-8", "replace")

def shown(path):
    """A path as a printable line: a name that is not UTF-8 shows its bytes as U+FFFD."""
    return path.encode("utf-8", "surrogateescape").decode("utf-8", "replace")

def clone_env(clone):
    """git's environment for reading the clone alone: GIT_DIR pinned to its .git, no system or global file, no replace ref (one
    would make a commit read as another's content)."""
    return dict(os.environ, GIT_DIR=os.path.join(clone, ".git"), GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
                GIT_NO_REPLACE_OBJECTS="1")

def head(clone):
    """The clone's HEAD commit, read with the clone's own config only."""
    h = git(["-C", clone, "rev-parse", "--verify", "--quiet", "HEAD^{commit}"], clone_env(clone), "read the clone's HEAD").strip()
    if not SHA.match(h):
        refuse("the clone's HEAD is %r, not a commit" % h)
    return h

def origin_url(clone):
    """The clone's one origin URL. Claude Code's git runs in this environment, so: none of GIT_ENV (the variables that point
    git at another repository or config file) set, even empty, and GIT_CONFIG_COUNT unset or 0; git's own discovery from the clone (the owner's safe.directory included) lands on its .git; then the
    clone's config as git reads it there (its worktree config and commondir too, includes followed, no system or global file).
    Refuses a rewrite, an include or another count."""
    named = [k for k in GIT_ENV if k in os.environ]
    if os.environ.get("GIT_CONFIG_COUNT", "0") not in ("", "0"):
        named.append("GIT_CONFIG_COUNT")
    if named:
        refuse("the environment sets %s: claude's git would read another repository or config than the clone checked here"
               % ", ".join(named))
    for d in (".git", ".claude-plugin"):
        why = unreal(os.path.join(clone, d))
        if why:
            refuse("the clone's %s %s" % (d, why))
    why = irregular(os.path.join(clone, ".git", "config"))
    if why:
        refuse("the clone's git config %s" % why)
    found = git(["-C", clone, "rev-parse", "--absolute-git-dir"], os.environ, "read the clone as a repository").strip()
    if os.path.realpath(found) != os.path.realpath(os.path.join(clone, ".git")):
        refuse("git reads the clone's repository at %s, not its .git" % found)
    listing = git(["config", "-z", "--list"], clone_env(clone), "read the clone's git config")
    urls = []
    for item in listing.split("\0"):
        key, _, val = item.partition("\n")
        if key.startswith(("include.", "includeif.")) or (key.startswith("url.") and key.endswith(("insteadof", "pushinsteadof"))):
            refuse("the clone's git config has %s (an include or a URL rewrite): its origin is not what it says" % key)
        if key == "remote.origin.url":
            urls.append(val)
    if len(urls) != 1:
        refuse("the clone's origin has %d URLs, not one: %s" % (len(urls), ", ".join(urls) or "none"))
    return urls[0]

def layout(cfg):
    plugins = os.path.join(os.path.realpath(cfg), "plugins")
    known = load(os.path.join(plugins, "known_marketplaces.json"), "known_marketplaces.json")
    ent = known.get(MKT) if isinstance(known, dict) else None
    if not isinstance(ent, dict):
        refuse("known_marketplaces.json has no marketplace %s" % MKT)
    src = ent.get("source") if isinstance(ent.get("source"), dict) else {}
    kind = src.get("source")
    if kind == "github":
        r = src.get("repo")
        known_repo, keys = (r.lower() if isinstance(r, str) and REPO.match(r) else None), {"source", "repo", "ref"}
    elif kind == "git":
        known_repo, keys = gh_repo(src.get("url")), {"source", "url", "ref"}
    else:
        refuse("marketplace %s is a %r source, not a git one (github or git): a layout this kit does not know" % (MKT, kind))
    if set(src) - keys or src.get("ref", "main") != "main":
        refuse("marketplace %s's known source %s is not {source, %s} at most with ref main: a layout this kit does not know"
               % (MKT, json.dumps(src, sort_keys=True), "repo" if kind == "github" else "url"))
    if known_repo is None:
        refuse("marketplace %s's known source %s names no %s repository (https or ssh)" % (MKT, json.dumps(src, sort_keys=True), HOST))
    loc = ent.get("installLocation")
    if not isinstance(loc, str) or not os.path.isabs(loc):
        refuse("marketplace %s has no absolute installLocation" % MKT)
    clone = os.path.realpath(loc)
    if os.path.dirname(clone) != os.path.join(plugins, "marketplaces") or not os.path.isdir(os.path.join(clone, ".git")):
        refuse("the clone of %s (%s, real path %s) is not a git clone under %s/marketplaces" % (MKT, loc, clone, plugins))
    origin = origin_url(clone)
    if gh_repo(origin) != known_repo:
        refuse("the clone's origin %s is not the known source's repository %s" % (origin, known_repo))
    # the URL git really fetches from, in this environment: a rewrite in the owner's global, XDG or system config counts too
    fetch = git(["-C", clone, "ls-remote", "--get-url", "origin"], os.environ, "tell the clone's fetch URL").strip()
    if gh_repo(fetch) != known_repo:
        refuse("git would fetch the clone's origin from %s (a URL rewrite in the git config), not the known source's "
               "repository %s" % (fetch, known_repo))
    man = load(os.path.join(clone, ".claude-plugin", "marketplace.json"), "the marketplace manifest")
    if not isinstance(man, dict) or man.get("name") != MKT or not isinstance(man.get("plugins"), list):
        refuse("the marketplace manifest is not marketplace %s with a plugin list" % MKT)
    extra = sorted(set(man) - set(MANIFEST_KEYS))
    if extra:
        refuse("the marketplace manifest carries %s beyond %s: a layout this kit does not know" % (", ".join(extra), ", ".join(MANIFEST_KEYS)))
    if isinstance(man.get("metadata"), dict) and "pluginRoot" in man["metadata"]:
        refuse("the marketplace manifest's metadata sets pluginRoot: a local source would resolve outside ./plugins/<name>")
    srcs, local, seen = {}, [], set()
    for p in man["plugins"]:
        name = p.get("name") if isinstance(p, dict) else None
        if not isinstance(name, str) or name in seen:
            refuse("the marketplace manifest has an entry %s with no name or a name listed twice" % json.dumps(p, sort_keys=True))
        seen.add(name)
        extra = sorted(set(p) - set(ENTRY_KEYS))
        if extra:
            refuse("the marketplace manifest's %s entry carries %s beyond %s (an entry can add hooks, servers or a manifest "
                   "of its own): a layout this kit does not know" % (name, ", ".join(extra), ", ".join(ENTRY_KEYS)))
        if name in NAMES:
            srcs[name] = p.get("source")
        elif LOCAL.match(name) and ".." not in name and p.get("source") == "./plugins/" + name:
            local.append(name)
        else:
            refuse("the marketplace manifest's %s entry has the source %s, not ./plugins/<its name> (a name of lower-case "
                   "letters, digits, dots, dashes and underscores): a layout this kit does not know"
                   % (json.dumps(name), json.dumps(p.get("source"))))
    for name in NAMES:
        if name not in srcs:
            refuse("the marketplace manifest lists %s 0 times, not once" % name)
    if all(srcs[n] == "./plugins/" + n for n in NAMES):
        lay = "kit-own"
        cands = {known_repo}
        why = "the known source and the clone's origin (%s)" % known_repo
        local = list(NAMES) + local
    elif all(isinstance(srcs[n], dict) for n in NAMES):
        lay = "git-subdir"
        for n in NAMES:
            s = srcs[n]
            want = {"source": "git-subdir", "url": s.get("url"), "path": "plugins/" + n, "ref": "main"}
            if s != want:
                refuse("%s's source %s is not {source: git-subdir, url, path: plugins/%s, ref: main} with nothing else "
                       "(a pinned sha, another ref or path): a layout this kit does not know" % (n, json.dumps(s, sort_keys=True), n))
        cands = {gh_repo(srcs[n]["url"], https_only=True) for n in NAMES}
        why = "the plugins' URLs (%s)" % ", ".join(str(srcs[n]["url"]) for n in NAMES)
    else:
        refuse("the sources %s are neither the kit's own marketplace (./plugins/<name>) nor the git-subdir marketplace "
               "(git-subdir): a layout this kit does not know" % json.dumps([srcs[n] for n in NAMES]))
    if None in cands or len(cands) != 1:
        refuse("layout %s names %s kit repository: %s" % (lay, "no" if None in cands else "more than one", why))
    for sub in ["plugins"] + [os.path.join("plugins", n) for n in local]:
        why = unreal(os.path.join(clone, sub))
        if why:
            refuse("the clone's %s %s: claude would install what it points at" % (sub, why))
    commit = head(clone)
    out("CLONE", clone)
    out("LAYOUT", lay)
    out("KIT", cands.pop())
    out("REPO", known_repo)
    out("HEAD", commit)
    for n in local:
        out("LOCAL", n)

def tree(cfg, want, names):
    """The clone at the commit `want` (- for any), and its .claude-plugin and plugins/<name> real directories holding exactly
    HEAD's tree there: each file read and hashed as a git blob (SHA-1: head() refuses any other object id), with its
    executable bit, against `git ls-tree` of HEAD; a directory that cannot be listed or a file that cannot be read is refused; no file HEAD lacks (untracked,
    ignored, a repository inside), none missing, and no symlink or submodule in HEAD there. The index, its stat data and the
    clone's config keys that steer `git status` are not trusted, and no git command here runs a filter or hook of the clone;
    a filter in the clone's config is refused all the same, since claude's own checkout would run it."""
    plugins = os.path.join(os.path.realpath(cfg), "plugins")
    known = load(os.path.join(plugins, "known_marketplaces.json"), "known_marketplaces.json")
    clone = os.path.realpath(known[MKT]["installLocation"])
    env = clone_env(clone)
    have = head(clone)
    if want != "-" and have != want:
        refuse("the clone's HEAD is %s, not the marketplace's main %s: claude would install another commit" % (have, want))
    for item in git(["config", "-z", "--list"], env, "read the clone's git config").split("\0"):
        key = item.partition("\n")[0]
        if key.startswith("filter."):
            refuse("the clone's git config has %s, a filter: claude's checkout would run its command" % key)
    paths = [".claude-plugin"] + ["plugins/" + n for n in names]
    for sub in ["plugins"] + paths:
        why = unreal(os.path.join(clone, sub))
        if why and (sub != "plugins" or names):
            refuse("the clone's %s, read again for the tree, %s" % (sub, why))
    # names as the file system spells them (os.fsdecode), so a name that is not UTF-8 compares byte for byte
    tracked, bad = {}, []
    for e in git(["-C", clone, "ls-tree", "-r", "-z", have, "--"] + paths, env, "list the clone's HEAD", raw=True).split(b"\0"):
        if e:
            meta, _, path = e.partition(b"\t")
            mode, _kind, oid = meta.decode("ascii").split(" ")
            tracked[os.fsdecode(path)] = (mode, oid)
    found = {}
    def unreadable(err):
        refuse("the clone's %s cannot be read: %s" % (shown(os.path.relpath(err.filename, clone)), err.strerror))
    for p in paths:
        for d, dirs, files in os.walk(os.path.join(clone, p), onerror=unreadable):
            for name in sorted(dirs + files):
                full = os.path.join(d, name)
                rel = os.path.relpath(full, clone).replace(os.sep, "/")
                st = os.lstat(full)
                if stat.S_ISDIR(st.st_mode):
                    continue
                if not stat.S_ISREG(st.st_mode):
                    found[rel] = ("120000" if stat.S_ISLNK(st.st_mode) else "other", "")
                    continue
                try:
                    with open(full, "rb") as f:
                        data = f.read()
                except OSError as err:
                    refuse("the clone's %s cannot be read: %s" % (shown(rel), err.strerror))
                found[rel] = ("100755" if st.st_mode & stat.S_IXUSR else "100644",
                              hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest())
    for path in sorted(tracked):
        mode, oid = tracked[path]
        if mode not in ("100644", "100755"):
            bad.append("%s (mode %s in HEAD: a symlink or a submodule, whose content is not the commit's)" % (shown(path), mode))
        elif path not in found:
            bad.append("%s (missing)" % shown(path))
        elif found[path] != (mode, oid):
            bad.append("%s (differs from HEAD)" % shown(path))
    bad += ["%s (not in HEAD)" % shown(path) for path in sorted(set(found) - set(tracked))]
    if bad:
        refuse("the clone's work tree under %s is not its HEAD %s: %s (claude installs the work tree, not the commit)"
               % (", ".join(paths), have, ", ".join(bad[:5])))
    out("TREE clean at", have)

def user_entries(reg, name):
    plugs = reg.get("plugins") if isinstance(reg, dict) else None
    if not isinstance(plugs, dict):
        refuse("installed_plugins.json has no plugin map")
    v = plugs.get("%s@%s" % (name, MKT))
    return [e for e in (v if isinstance(v, list) else []) if isinstance(e, dict) and e.get("scope") == "user"]

def entries(path, names=NAMES):
    """{plugin: its one user-scope entry} of the registry file; refuses a plugin with none or several."""
    reg = load(path, "installed_plugins.json")
    got = {}
    for n in names:
        user = user_entries(reg, n)
        if len(user) != 1:
            refuse("%s@%s has %d user-scope installs, not one" % (n, MKT, len(user)))
        got[n] = user[0]
    return got

def registry(cfg):
    return os.path.join(os.path.realpath(cfg), "plugins", "installed_plugins.json")

def commit_of(e):
    sha = e.get("gitCommitSha")
    return sha if isinstance(sha, str) and SHA.match(sha) else "-"

def installed(cfg, local):
    reg = load(registry(cfg), "installed_plugins.json")
    for n, e in entries(registry(cfg)).items():
        out("ENTRY", n, commit_of(e))
    for n in local:
        user = user_entries(reg, n)
        if len(user) > 1:
            refuse("%s@%s has %d user-scope installs, not one" % (n, MKT, len(user)))
        if user:
            out("ENTRY", n, commit_of(user[0]))
        else:
            out("NONE", n)

def targets(rec):
    """[(plugin, old commit or -, target commit)] of the run record's targets file; refuses a record without one."""
    path = os.path.join(rec, "targets")
    why = irregular(path)
    if why:
        refuse("the run record's targets %s" % why)
    got = []
    with open(path, encoding="utf-8") as f:
        for line in f.read().splitlines():
            t = line.split(" ")
            if len(t) != 3 or not LOCAL.match(t[0]) or not (t[1] == "-" or SHA.match(t[1])) or not SHA.match(t[2]):
                refuse("the run record's targets has a line that is not <plugin> <old commit or -> <target>: %r" % line)
            got.append(tuple(t))
    if not got:
        refuse("the run record's targets names no plugin")
    return got

def check(cfg, state, rec):
    plugins = os.path.join(os.path.realpath(cfg), "plugins")
    try:
        want = targets(rec)
        got = entries(registry(cfg), [n for n, _o, _t in want])
    except SystemExit:
        sys.exit(1)
    bad, dirs = [], {}
    for n, old, sha in want:
        e = got[n]
        v, p = e.get("version"), e.get("installPath")
        if e.get("gitCommitSha") != sha:
            bad.append("%s records gitCommitSha %s, not %s" % (n, e.get("gitCommitSha"), sha))
        if not isinstance(v, str) or not re.match(r"^%s(?:-[0-9a-f]{8})?\Z" % sha[:12], v):
            bad.append("%s's version %r is not %s or %s-<8 hex>" % (n, v, sha[:12], sha[:12]))
            continue
        want_dir = os.path.join(plugins, "cache", MKT, n, v)
        if not isinstance(p, str) or not os.path.isabs(p) or os.path.realpath(p) != want_dir:
            bad.append("%s's installPath %r is not the directory %s" % (n, p, want_dir))
            continue
        pj = os.path.join(want_dir, ".claude-plugin", "plugin.json")
        why = unreal(os.path.dirname(pj)) or irregular(pj)
        if why:
            bad.append("%s's plugin.json %s" % (n, why))
            continue
        try:
            with open(pj, encoding="utf-8") as f:
                man = json.load(f)
        except (OSError, ValueError) as err:
            bad.append("%s's plugin.json cannot be read: %s" % (n, err))
            continue
        if not isinstance(man, dict) or "version" in man:
            bad.append("%s's plugin.json carries a version (%r): the kit's manifests carry none" % (n, man.get("version") if isinstance(man, dict) else man))
            continue
        dirs[n] = want_dir
        out("CHECK", n, "at", v, "commit", sha, "(was %s)" % old, "in", want_dir)
    sdlc = dirs.get("vibemaestro-sdlc")
    if sdlc:
        tpl = os.path.join(sdlc, "scripts", "baton-launcher.py")
        try:
            why = unreal(os.path.dirname(tpl)) or irregular(tpl)
            if why:
                raise ValueError(why)
            spec = importlib.util.spec_from_file_location("kit_plugin_update_launcher", tpl)
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            for n, d in dirs.items():
                if not mod.INSTALL_DIR.match(os.path.basename(d)):
                    bad.append("the launcher template refuses %s's directory %s" % (n, os.path.basename(d)))
            mod.CLAUDE_DIR, mod.STATE_HOME = cfg, state
            picked = mod.resolve()
            if picked != os.path.join(sdlc, "scripts", "baton.py"):
                bad.append("the launcher template resolves to %s, not the new sdlc" % picked)
            else:
                out("CHECK the launcher template accepts every directory and resolves to", picked)
        except Exception as err:
            bad.append("the launcher template %s refuses the install: %s" % (tpl, err))
    elif "vibemaestro-sdlc" not in {n for n, _o, _t in want}:
        bad.append("the run record's targets do not name vibemaestro-sdlc")
    for b in bad:
        out("FAIL", b)
    if bad or len(dirs) != len(want):
        sys.exit(1)
    out("SDLC", sdlc)

def left(cfg, rec):
    try:
        names = [n for n, _o, _t in targets(rec)]
        with open(os.path.join(rec, "installed_plugins.json"), encoding="utf-8") as f:
            before = json.load(f)
        reg = load(registry(cfg), "installed_plugins.json")
    except (OSError, ValueError, SystemExit):
        return
    def paths(d):
        out_ = set()
        for n in names:
            for e in ((d.get("plugins") or {}).get("%s@%s" % (n, MKT)) or []) if isinstance(d, dict) else []:
                if isinstance(e, dict) and e.get("scope") == "user" and isinstance(e.get("installPath"), str):
                    out_.add(e["installPath"])
        return out_
    for p in sorted(paths(reg) - paths(before)):
        out("LEFT the cache directory %s (Claude Code's; the restored registry no longer points at it)" % p)

def rest_installed(d, names):
    """installed_plugins.json without the named plugins' user-scope entries, flat: what this run must not change."""
    if not isinstance(d, dict):
        return {"(the file)": d}
    r = {k: v for k, v in d.items() if k != "plugins"}
    p = d.get("plugins")
    if isinstance(p, dict):
        ours = {"%s@%s" % (n, MKT) for n in names}
        r.update({"plugins/" + k: v for k, v in p.items() if k not in ours})
        for k in ours & set(p):
            v = p[k]
            r["plugins/%s (other scopes)" % k] = ([e for e in v if not (isinstance(e, dict) and e.get("scope") == "user")]
                                                  if isinstance(v, list) else v)
    else:
        r["plugins"] = p
    return r

def rest_known(d):
    """known_marketplaces.json without the vibemaestro marketplace."""
    return {k: v for k, v in d.items() if k != MKT} if isinstance(d, dict) else {"(the file)": d}

def others(cfg, rec):
    plugins = os.path.join(os.path.realpath(cfg), "plugins")
    want = targets(rec)
    names = [n for n, _o, _t in want]
    moved = False
    for f, rest in (("installed_plugins.json", lambda d: rest_installed(d, names)), ("known_marketplaces.json", rest_known)):
        a = rest(load(os.path.join(rec, f), "the byte copy of " + f))
        b = rest(load(os.path.join(plugins, f), f))
        keys = sorted(k for k in set(a) | set(b) if a.get(k, None) != b.get(k, None) or (k in a) != (k in b))
        if keys:
            moved = True
            out("OTHER", f, "changed outside this run since the copy:", ", ".join(keys))
    # each plugin of the run is still what the run left: the copy's own entry (its update never ran), or the entry its update
    # left (after-<plugin>, read right after the update); an update with no such record is not told apart from another hand
    copy = load(os.path.join(rec, "installed_plugins.json"), "the byte copy of installed_plugins.json")
    now = load(os.path.join(plugins, "installed_plugins.json"), "installed_plugins.json")
    for n, _old, _sha in want:
        a, b = user_entries(copy, n), user_entries(now, n)
        after = os.path.join(rec, "after-" + n)
        left_ = load(after, "the run record's after-" + n) if os.path.lexists(after) else None
        if b != a and b != left_:
            moved = True
            out("MOVED", n, "records %s, neither the copy's entry nor the one this run's update left: another hand changed it"
                % (", ".join(commit_of(e) for e in b) or "no user install"))
    if moved:
        sys.exit(1)

def gone(rec):
    miss = False
    for n, e in entries(os.path.join(rec, "installed_plugins.json"), [n for n, _o, _t in targets(rec)]).items():
        p = e.get("installPath")
        if not isinstance(p, str) or not os.path.isdir(p):
            miss = True
            out("GONE", n, p)
    if miss:
        sys.exit(1)

mode = sys.argv[1] if len(sys.argv) > 1 else "--help"
if mode in ("-h", "--help"):
    print(__doc__.strip())
    sys.exit(0)
if mode == "layout":
    layout(sys.argv[2])
elif mode == "tree":
    tree(sys.argv[2], sys.argv[3], sys.argv[4:])
elif mode == "installed":
    installed(sys.argv[2], sys.argv[3:])
elif mode == "check":
    check(sys.argv[2], sys.argv[3], sys.argv[4])
elif mode == "left":
    left(sys.argv[2], sys.argv[3])
elif mode == "others":
    others(sys.argv[2], sys.argv[3])
elif mode == "entry":
    print(json.dumps(user_entries(load(registry(sys.argv[2]), "installed_plugins.json"), sys.argv[3]), sort_keys=True))
elif mode == "gone":
    gone(sys.argv[2])
else:
    sys.stderr.write("plugin_update.py: unknown mode %r (--help lists them)\n" % mode)
    sys.exit(64)
