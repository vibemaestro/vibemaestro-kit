"""Rule packs: the `rules/` of installed plugins that declare a dependency on vibemaestro-sdlc.

The Claude Code plugin registry is `$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json` when the variable is set (and absolute),
else `~/.claude/plugins/installed_plugins.json` (measured in the hook subprocess).
Its `plugins` maps `<name>@<marketplace>` to install entries. A plugin is a PACK when the entry that applies to the session's
project directory (an entry with a `projectPath` applies only there; `local`, then `project`, then the rest) is enabled in the
settings, and its `<installPath>/.claude-plugin/plugin.json` has a `dependencies` item naming vibemaestro-sdlc. Only the registry
decides: the cache directory keeps an uninstalled plugin's copy, so it is never listed.

Everything here is read from files another program wrote, so every read is bounded and contained: the plugins directory, an
install path and a project path are resolved by the kernel (Python's own walk, which costs a stat per part of every link it
follows, runs only without /proc or for a real path over PATH_MAX, and then under the timer), and an install path must
resolve inside the plugins directory; inside a pack nothing is a symlink (the
manifest, `rules/` and each rule file), so they are inside the plugin by construction; a file is opened without blocking, must
be a regular file, and has a size cap; all packs together have a cap on rules and bytes, and the whole load runs under one
timer. A problem never raises: it ignores the registry, the plugin or the file, and adds one warning line. Standard library
only, Python 3.8+; nothing is written.
"""
import json
import os
import stat
import sys

import rules as R

DEPENDENCY = "vibemaestro-sdlc"              # a `dependencies` item naming this makes a plugin a pack
REGISTRY_REL = ("plugins", "installed_plugins.json")
REGISTRY_VERSION = 2
# the settings files of baton.settings_sources, in Claude Code's precedence order (a later file wins): user, project, local, managed
MANAGED_SETTINGS = ("/Library/Application Support/ClaudeCode/managed-settings.json" if sys.platform == "darwin"
                    else "/etc/claude-code/managed-settings.json")
SCOPE_RANK = {"local": 0, "project": 1}      # which entry of a plugin applies when several do; any other scope ranks after
MAX_PATH = 4096                              # characters of a path this module resolves (PATH_MAX)
MAX_ENTRIES = 1000                           # entries of a pack's rules/ that are looked at
MAX_REGISTRY = 1 << 20
MAX_SETTINGS = 1 << 20
MAX_MANIFEST = 64 << 10
MAX_RULE = 16 << 10                          # a pack rule file over this is skipped (the largest sdlc rule is under 6 KiB)
MAX_RULES = 100                              # rule files in one pack
MAX_IDS = 200                                # plugin ids in the registry
MAX_PACK_RULES = 200                         # rules of all packs together
MAX_READ = 2 << 20                           # bytes of all manifests and pack rule files together
LOAD_SECONDS = 1.0                           # the timer of the whole load (rules.bounded): the packs read by then are kept


def config_dir():
    """(Claude Code's configuration directory, warning). A relative `CLAUDE_CONFIG_DIR`, or a home directory that is not an
    absolute path (HOME unset and no password entry), cannot be placed: (None, warning). Unlike baton.claude_config_dir, which
    falls back to `~/.claude`: reading another registry could serve the packs of plugins this session does not run."""
    c = os.environ.get("CLAUDE_CONFIG_DIR", "")
    if not c:
        home = os.path.expanduser("~")
        if not os.path.isabs(home):
            return None, "the home directory is not an absolute path (%s), so the plugin registry cannot be found" % home
        return os.path.join(home, ".claude"), None
    if not os.path.isabs(c):
        return None, "CLAUDE_CONFIG_DIR is not an absolute path (%s), so the plugin registry cannot be found" % c
    return c, None


def _small_int(s):
    """JSON integers as ints, but a long digit string is not converted (quadratic before Python 3.11): it is no count we use."""
    return int(s) if len(s) <= 18 else None


def _json(text):
    return json.loads(text, parse_int=_small_int)


def read_capped(path, cap, nofollow=False):
    """(text, problem) of a regular file of at most `cap` bytes, opened without blocking (a FIFO answers at once), and with
    `nofollow` never through a symlink. A missing file is (None, None); any other refusal is (None, why)."""
    flags = os.O_RDONLY | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_NOCTTY", 0)
    try:
        fd = os.open(path, flags | (getattr(os, "O_NOFOLLOW", 0) if nofollow else 0))
    except FileNotFoundError:
        return None, None
    except (OSError, ValueError) as e:
        return None, "cannot be opened (%s)" % (getattr(e, "strerror", None) or type(e).__name__)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            return None, "is not a regular file"
        if st.st_size > cap:
            return None, "is larger than %d bytes" % cap
        chunks, size = [], 0
        while size <= cap:
            b = os.read(fd, cap + 1 - size)
            if not b:
                break
            chunks.append(b)
            size += len(b)
        if size > cap:
            return None, "is larger than %d bytes" % cap
        return b"".join(chunks).decode("utf-8", "replace"), None
    except OSError as e:
        return None, "cannot be read (%s)" % (e.strerror or type(e).__name__)
    finally:
        os.close(fd)


def real(path):
    """(real path, problem) of a path from a file this plugin does not control, resolved by the kernel: the name of an open
    descriptor in /proc/self/fd (Linux); without /proc, or when that name is over PATH_MAX, `os.path.realpath` of a path the
    kernel opened (at most 40 symlinks), which the load's timer bounds. A missing path is (None, None). When the timer fires
    between an open and its `try`, one descriptor stays open until the hook exits, milliseconds later."""
    if not isinstance(path, str) or len(path) > MAX_PATH or "\0" in path:
        return None, "is not a usable path"
    try:
        fd = os.open(path, getattr(os, "O_PATH", os.O_RDONLY) | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_NOCTTY", 0))
    except FileNotFoundError:
        return None, None
    except (OSError, ValueError) as e:
        return None, "cannot be resolved (%s)" % (getattr(e, "strerror", None) or type(e).__name__)
    try:
        try:
            p = os.readlink("/proc/self/fd/%d" % fd)
            if os.path.isabs(p) and os.path.exists(p):
                return p, None
        except OSError:
            pass
        return os.path.realpath(path), None
    finally:
        os.close(fd)


def plain(path):
    """`file`, `dir`, `other` or None (missing) for a path inside a pack, never following a symlink; a symlink is `link`."""
    try:
        st = os.lstat(path)
    except (OSError, ValueError):
        return None
    return ("link" if stat.S_ISLNK(st.st_mode) else "dir" if stat.S_ISDIR(st.st_mode)
            else "file" if stat.S_ISREG(st.st_mode) else "other")


def _inside(path, root):
    """`path` is strictly below `root` (both real paths)."""
    return path.startswith(root.rstrip(os.sep) + os.sep)


def applicable_entry(entries, project):
    """The install entry of one plugin that applies to the session's project directory (a real path), None when none does,
    or the string `bad` for a value that is not a list of entries."""
    if not isinstance(entries, list):
        return "bad"
    best = None
    for e in entries:
        if not isinstance(e, dict):
            continue
        pp = e.get("projectPath")
        if pp is not None and real(pp)[0] != project:
            continue
        scope = e.get("scope")
        rank = SCOPE_RANK.get(scope, len(SCOPE_RANK)) if isinstance(scope, str) else len(SCOPE_RANK)
        if best is None or rank < best[0]:
            best = (rank, e)
    return best[1] if best else None


def enabled_map(cfg, project):
    """{plugin id: bool} of `enabledPlugins` in the user, project, local and managed settings, a later file winning; the
    project files are those of the session's project directory (measured: Claude Code reads them there, not at the git root).
    An unreadable or malformed settings file names nothing here (Claude Code reports it)."""
    out = {}
    for path in (os.path.join(cfg, "settings.json"), os.path.join(project, ".claude", "settings.json"),
                 os.path.join(project, ".claude", "settings.local.json"), MANAGED_SETTINGS):
        text, _p = read_capped(path, MAX_SETTINGS)
        if text is None:
            continue
        try:
            d = _json(text)
        except Exception:
            continue
        ep = d.get("enabledPlugins") if isinstance(d, dict) else None
        if isinstance(ep, dict):
            out.update((k, v) for k, v in ep.items() if isinstance(v, bool))
    return out


def depends_on_sdlc(manifest):
    """The manifest declares a dependency on vibemaestro-sdlc: a `dependencies` item that is the name (bare or `@<marketplace>`)
    or an object whose `name` is."""
    deps = manifest.get("dependencies") if isinstance(manifest, dict) else None
    if not isinstance(deps, list):
        return False
    for d in deps:
        n = d if isinstance(d, str) else d.get("name") if isinstance(d, dict) else None
        if isinstance(n, str) and (n == DEPENDENCY or n.startswith(DEPENDENCY + "@")):
            return True
    return False


def load(troot, project=None):
    """(packs, warnings). `project` is the session's project directory (default: CLAUDE_PROJECT_DIR, else `troot`). `packs` is
    [(plugin id, real path of its rules directory, [(file name, text)])] sorted by plugin id, rules sorted by name, live rules
    only; `warnings` is [one line] per problem. Never raises; runs under one timer of LOAD_SECONDS (rules.bounded), and keeps
    the packs read when it fires."""
    packs, warnings = [], []
    try:
        if not R.bounded(lambda: _load(troot, project or os.environ.get("CLAUDE_PROJECT_DIR") or troot, packs, warnings),
                         LOAD_SECONDS):
            warnings.append("reading the rule packs took over %.0f s and was stopped; %d pack(s) read before that are served"
                            % (LOAD_SECONDS, len(packs)))
    except Exception as e:                      # a bug here costs the packs not read yet, never the hook
        warnings.append("rule packs were not all read (internal error %s)" % type(e).__name__)
    return packs, warnings


def _load(troot, project, packs, warnings):
    """Fills `packs` and `warnings` (see `load`) one plugin at a time, so what is done when the timer fires is kept."""
    cfg, w = config_dir()
    if w:
        warnings.append(w)
        return
    plugins = os.path.join(cfg, REGISTRY_REL[0])
    reg = os.path.join(plugins, REGISTRY_REL[1])
    text, prob = read_capped(reg, MAX_REGISTRY)
    if text is None:
        warnings.extend(["the plugin registry %s %s; it is ignored" % (reg, prob)] if prob else [])
        return
    try:
        d = _json(text)
    except Exception:
        warnings.append("the plugin registry %s is not valid JSON; it is ignored" % reg)
        return
    if not isinstance(d, dict) or d.get("version") != REGISTRY_VERSION or not isinstance(d.get("plugins"), dict):
        warnings.append("the plugin registry %s is not a version-%d registry with a `plugins` object; it is ignored"
                        % (reg, REGISTRY_VERSION))
        return
    ids = d["plugins"]
    if len(ids) > MAX_IDS:
        warnings.append("the plugin registry %s lists %d plugins, more than %d; it is ignored" % (reg, len(ids), MAX_IDS))
        return
    root, _p = real(plugins)
    if not root:
        return
    project = real(project)[0] or project
    budget = {"rules": MAX_PACK_RULES, "read": MAX_READ}
    enabled, unread = None, []
    for pid in sorted(ids):                     # sorted, never the registry's order: the first id wins a shared rule name
        if pid.split("@", 1)[0] == DEPENDENCY:
            continue
        try:
            entry = applicable_entry(ids[pid], project)
            if entry is None:
                continue
            if entry == "bad":
                warnings.append("%s: its registry value is not a list of install entries; it is ignored" % pid)
                continue
            if enabled is None:
                enabled = enabled_map(cfg, project)
            if enabled.get(pid) is not True:    # measured: a plugin no settings file enables is not enabled
                continue
            if budget["rules"] <= 0 or budget["read"] <= 0:
                unread.append(pid)
                continue
            pack, warn = _pack(pid, entry.get("installPath"), root, budget)
        except Exception as e:                  # one malformed entry costs that plugin, never the others
            pack, warn = None, "%s: its install entry cannot be read (%s); it is ignored" % (pid, type(e).__name__)
        if warn:
            warnings.append(warn)
        if pack:
            packs.append(pack)
    if unread:
        warnings.append("the rule packs reached their limit (%d rule files, %d bytes in all); %d plugin(s) were not read, from %s"
                        % (MAX_PACK_RULES, MAX_READ, len(unread), unread[0]))


COORDINATED_MARKER = "sdlc-coordinated"     # a file at a plugin's root: sessions where it is enabled are coordinated (rule coordinated-work)
KNOWN_MARKETPLACES = "known_marketplaces.json"   # beside the registry: each marketplace's `installLocation`


def sdlc_marketplace(sdlc_root, cfg=None):
    """The marketplace of the running sdlc copy, else None. An installed copy at <plugins>/cache/<marketplace>/vibemaestro-sdlc/<version>
    names it in its path. Otherwise it is the entry of <cfg>/plugins/known_marketplaces.json whose real `installLocation` holds the
    copy (the deepest one when several nest; the location itself is not inside it): measured on Claude Code 2.1.290, a marketplace added
    from a directory runs the plugin from inside that location. A copy outside the cache and outside every known marketplace's
    installLocation (a checkout, a `--plugin-dir` copy) is in no marketplace, so no plugin is of the same one."""
    me = os.path.realpath(sdlc_root)
    parent = os.path.dirname(me)
    mdir = os.path.dirname(parent)
    if os.path.basename(parent) == DEPENDENCY and os.path.basename(os.path.dirname(mdir)) == "cache":
        return os.path.basename(mdir)
    if not cfg:
        return None
    text, _p = read_capped(os.path.join(cfg, REGISTRY_REL[0], KNOWN_MARKETPLACES), MAX_REGISTRY)
    try:
        known = _json(text) if text is not None else None
    except Exception:
        return None
    best = None
    for name in sorted(known) if isinstance(known, dict) else []:
        loc = known[name].get("installLocation") if isinstance(known[name], dict) else None
        real_loc = real(loc)[0] if isinstance(loc, str) and os.path.isabs(loc) else None
        if real_loc and _inside(me, real_loc) and (best is None or len(real_loc) > len(best[1])):
            best = (name, real_loc)
    return best[0] if best else None


def coordinated(sdlc_root, project=None):
    """The id of an enabled plugin that makes this session a coordinated one, or None: a plugin of the running sdlc copy's own
    marketplace, whose install entry applies to the session's project and which a settings file enables (as for a pack), whose
    manifest declares the dependency on vibemaestro-sdlc, and which ships the regular file COORDINATED_MARKER at its real install
    root, inside the plugins directory. Names no plugin. Never raises; bounded by the same timer as `load`; no warning (the pack
    load already says what is wrong with an entry)."""
    found = []
    try:
        R.bounded(lambda: found.append(_coordinated(sdlc_root, project or os.environ.get("CLAUDE_PROJECT_DIR") or "")),
                  LOAD_SECONDS)
    except Exception:
        return None
    return found[0] if found else None


def _coordinated(sdlc_root, project):
    cfg, w = config_dir()
    market = None if w else sdlc_marketplace(sdlc_root, cfg)
    if not market:
        return None
    plugins = os.path.join(cfg, REGISTRY_REL[0])
    text, _p = read_capped(os.path.join(plugins, REGISTRY_REL[1]), MAX_REGISTRY)
    if text is None:
        return None
    try:
        d = _json(text)
    except Exception:
        return None
    ids = d.get("plugins") if isinstance(d, dict) and d.get("version") == REGISTRY_VERSION else None
    root = real(plugins)[0]
    if not isinstance(ids, dict) or len(ids) > MAX_IDS or not root:
        return None
    project = real(project)[0] or project
    enabled = None
    for cid in sorted(ids):
        name, _sep, m = cid.partition("@")
        if m != market or name == DEPENDENCY:
            continue
        entry = applicable_entry(ids[cid], project)
        if not isinstance(entry, dict):
            continue
        if enabled is None:
            enabled = enabled_map(cfg, project)
        if enabled.get(cid) is not True:
            continue
        inst = entry.get("installPath")
        real_inst = real(inst)[0] if isinstance(inst, str) and os.path.isabs(inst) else None
        if not real_inst or not _inside(real_inst, root) or plain(os.path.join(real_inst, ".claude-plugin")) != "dir":
            continue
        man, _p = read_capped(os.path.join(real_inst, ".claude-plugin", "plugin.json"), MAX_MANIFEST, nofollow=True)
        try:
            ok = man is not None and depends_on_sdlc(_json(man))
        except Exception:
            ok = False
        if ok and plain(os.path.join(real_inst, COORDINATED_MARKER)) == "file":
            return cid
    return None


def _pack(pid, inst, root, budget):
    """((plugin id, rules dir, rules) or None, warning or None) for one applicable, enabled plugin; `budget` is what all packs
    may still read ({"rules": n, "read": bytes}) and is spent here."""
    if not isinstance(inst, str) or not os.path.isabs(inst):
        return None, "%s: its installPath is not an absolute path; it is ignored" % pid
    real_inst, prob = real(inst)
    if prob:
        return None, "%s: its installPath %s; it is ignored" % (pid, prob)
    if not real_inst:
        return None, None                       # a stale entry: Claude Code itself reports the plugin as failed to load
    if not _inside(real_inst, root):
        return None, "%s: its installPath resolves outside %s; it is ignored" % (pid, root)
    if not real_inst.isprintable():             # its paths are printed in reminders: one line, no escape codes
        return None, "%s: its installPath is not printable; it is ignored" % pid
    if not os.path.isdir(real_inst):
        return None, None
    # inside a pack nothing is a symlink, so every path below the real install path is inside it as written
    if plain(os.path.join(real_inst, ".claude-plugin")) == "link":
        return None, "%s: its .claude-plugin/ is a symlink; it is ignored" % pid
    man = os.path.join(real_inst, ".claude-plugin", "plugin.json")
    kind = plain(man)
    if kind is None:
        return None, None
    if kind != "file":
        return None, "%s: its .claude-plugin/plugin.json is %s; it is ignored" % (pid, "a symlink" if kind == "link" else "not a file")
    text, prob = read_capped(man, MAX_MANIFEST, nofollow=True)
    if text is None:
        return None, ("%s: its .claude-plugin/plugin.json %s; it is ignored" % (pid, prob)) if prob else None
    budget["read"] -= len(text)
    try:
        manifest = _json(text)
    except Exception:
        return None, "%s: its .claude-plugin/plugin.json is not valid JSON; it is ignored" % pid
    if not depends_on_sdlc(manifest):
        return None, None                       # not a pack: nothing else of it is opened
    rdir = os.path.join(real_inst, R.RULES_DIR)
    kind = plain(rdir)
    if kind == "link":
        return None, "%s: its %s/ is a symlink; it is ignored" % (pid, R.RULES_DIR)
    if kind != "dir":
        return None, None
    names, links, seen = [], [], 0
    try:
        with os.scandir(rdir) as it:
            for e in it:
                seen += 1
                if seen > MAX_ENTRIES:
                    return None, "%s: its %s/ has more than %d entries; the pack is ignored" % (pid, R.RULES_DIR, MAX_ENTRIES)
                if e.name.endswith(R.RULE_SUFFIX):
                    (links if e.is_symlink() else names).append(e.name)
    except OSError:
        return None, None
    names.sort()
    if len(names) + len(links) > MAX_RULES:
        return None, "%s: %d rule files, more than %d; the pack is ignored" % (pid, len(names) + len(links), MAX_RULES)
    if len(names) > budget["rules"]:
        return None, "%s: its %d rule files are over what is left of the limit for all packs (%d rule files); the pack is ignored" % (
            pid, len(names), MAX_PACK_RULES)
    budget["rules"] -= len(names)               # every file read counts, live or not
    out, skipped = [], ["%s is a symlink" % (n if n.isprintable() else "a file") for n in sorted(links)]
    for n in names:
        if not n.isprintable():                 # a name is printed in reminders and the catalogue: one line, no escape codes
            skipped.append("with a name that is not printable")
            continue
        t, prob = read_capped(os.path.join(rdir, n), MAX_RULE, nofollow=True)
        if t is None:
            if prob:
                skipped.append("%s %s" % (n, prob))
            continue
        budget["read"] -= len(t)
        if budget["read"] < 0:
            return None, "%s: its rule files are over what is left of the limit for all packs (%d bytes); the pack is ignored" % (
                pid, MAX_READ)
        if R.live(t):
            out.append((n, t))
    warn = ("%s: rule file %s; skipped" % (pid, "; ".join(skipped))) if skipped else None
    return (pid, rdir, out), warn
