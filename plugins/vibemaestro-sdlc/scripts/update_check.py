#!/usr/bin/env python3
"""The update reminder of a public plugin: one line at session start when a newer public version exists, silent otherwise.

    update_check.py session-start [--root DIR]        the SessionStart hook (DIR: the plugin, default CLAUDE_PLUGIN_ROOT)
    update_check.py refresh --root DIR --data DIR      the read itself; session-start starts it in the background

Shared by vibemaestro-sdlc and vibemaestro-brain (brain depends on sdlc and runs this file with its own root and data). Both
commands exit 0 and print nothing but the reminder: no error, timeout or odd answer ever reaches the session.

The installed version and the public repository come from the plugin's own `.claude-plugin/plugin.json`: `version` and
`repository` (`https://github.com/<owner>/<name>`), which the public export writes. The latest version is the highest
`refs/tags/<plugin>--vX.Y.Z` of that repository, from one unauthenticated read of GitHub's matching-refs API: no token, no cookie,
a fixed User-Agent, no redirect, at most MAX_BODY bytes, DEADLINE seconds for the whole read. A ref that is not exactly that form
is skipped; a version is X.Y.Z (digits, no leading zero, no suffix, 9 digits a part at most), checked again whenever it
is read back.

The cache is `<CLAUDE_PLUGIN_DATA>/update-check.json`: {"v": 1, "checked": epoch, "latest": "X.Y.Z" or null, "shown": epoch,
"repo": url, "plugin": name}. At session start the hook prints the line when the cached latest is above the installed version and
the line was not shown in the last 24 h; when the last check is 24 h old (or the cache is missing, broken, for another plugin or
repository, or dated in the future) it marks the check, then starts `refresh` detached, so the answer shows at the next session. A
read that gets no answer keeps the old latest until the next check; an answer with no tag of the plugin clears it. At most one
read and one line per plugin per 24 h. The project's config is the first `.vibemaestro/sdlc.json` from CLAUDE_PROJECT_DIR up to
the repository's root. A session that has a line to show or a read to start decides it under the lock `update-check.lock` (held by
the read until it ends; one older than STALE is taken over); a session that cannot take it prints and writes nothing. A proxy in
the environment is used as urllib uses it, except for the tests' loopback server.

Silent, with no read: a manifest without a version or a valid repository (a private install); a sandbox pod (INTENT_SLUG and
SEAT); VIBEMAESTRO_NO_UPDATE_CHECK or CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC set (not empty, not 0); `update_check: false` or
`hooks: "off"` in the project's `.vibemaestro/sdlc.json`; no CLAUDE_PLUGIN_DATA.

VIBEMAESTRO_UPDATE_CHECK_API replaces https://api.github.com only when it is http://127.0.0.1:<port> (the tests' fake server).
Standard library only, Python 3.8+.
"""
import json
import os
import re
import sys
import threading
import time

sys.dont_write_bytecode = True

DAY = 86400
DEADLINE = 2.0                                # seconds for the whole read: connect, request, answer
MAX_BODY = 256 * 1024
CACHE = "update-check.json"
LOCK = "update-check.lock"                    # held by the one session whose background read is running
STALE = 60                                    # seconds: a lock older than this is a read that died (a read lasts DEADLINE)
API = "https://api.github.com"
USER_AGENT = "vibemaestro-update-check"
SEMVER = re.compile(r"(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})", re.ASCII)   # X.Y.Z, 9 digits a part at most
NAME = re.compile(r"[a-z0-9][a-z0-9-]{0,63}", re.ASCII)
REPO = re.compile(r"https://github\.com/([A-Za-z0-9](?:[A-Za-z0-9-]{0,38}))/([A-Za-z0-9_.-]{1,100})", re.ASCII)
LOOPBACK = re.compile(r"http://127\.0\.0\.1:[0-9]{1,5}", re.ASCII)
CONFIG_REL = os.path.join(".vibemaestro", "sdlc.json")


def optout(var):
    return os.environ.get(var, "") not in ("", "0")


def api_base():
    v = os.environ.get("VIBEMAESTRO_UPDATE_CHECK_API", "")
    if LOOPBACK.fullmatch(v):
        return v
    return API


def vtuple(v):
    return tuple(int(x) for x in v.split("."))


def semver(v):
    return v if isinstance(v, str) and SEMVER.fullmatch(v) else None


def manifest(root):
    """(name, installed version, owner, repository name) of the plugin at root, or None when any is missing or not plain."""
    try:
        with open(os.path.join(root, ".claude-plugin", "plugin.json"), encoding="utf-8") as f:
            m = json.load(f)
    except (OSError, ValueError):
        return None
    if not isinstance(m, dict):
        return None
    name, installed, repo = m.get("name"), m.get("version"), m.get("repository")
    if not isinstance(name, str) or not NAME.fullmatch(name):
        return None
    installed = installed if isinstance(installed, str) else ""
    if not SEMVER.fullmatch(installed or ""):
        return None
    hit = REPO.fullmatch(repo) if isinstance(repo, str) else None
    if not hit or hit.group(2) in (".", ".."):
        return None
    return name, installed, hit.group(1), hit.group(2)


def project_root():
    """The repository the session runs in: from CLAUDE_PROJECT_DIR (else the working directory) up to the first directory that
    holds `.vibemaestro/sdlc.json` or `.git`; the start itself when none does."""
    start = os.path.abspath(os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd())
    d = start
    while True:
        if os.path.lexists(os.path.join(d, CONFIG_REL)) or os.path.lexists(os.path.join(d, ".git")):
            return d
        up = os.path.dirname(d)
        if up == d:
            return start
        d = up


def config_off():
    """The project's config turns the reminder off (`update_check: false`, or `hooks: "off"`); read raw, so a config another key
    makes invalid still turns it off."""
    root = project_root()
    try:
        with open(os.path.join(root, CONFIG_REL), encoding="utf-8") as f:
            cfg = json.loads(f.read(1024 * 1024))
    except (OSError, ValueError):
        return False
    return isinstance(cfg, dict) and (cfg.get("update_check") is False or cfg.get("hooks") == "off")


def silent():
    if os.environ.get("INTENT_SLUG") and os.environ.get("SEAT"):
        return True
    if optout("VIBEMAESTRO_NO_UPDATE_CHECK") or optout("CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"):
        return True
    return config_off()


def read_cache(data, key):
    """The cache for this plugin and repository, its fields checked; a fresh one when it is missing, broken or someone else's."""
    fresh = {"v": 1, "checked": 0, "latest": None, "shown": 0, "repo": key[1], "plugin": key[0]}
    try:
        with open(os.path.join(data, CACHE), encoding="utf-8") as f:
            c = json.loads(f.read(64 * 1024))
    except (OSError, ValueError):
        return fresh
    if not isinstance(c, dict) or (c.get("plugin"), c.get("repo")) != key:
        return fresh
    out = dict(fresh)
    for k in ("checked", "shown"):
        if isinstance(c.get(k), int) and not isinstance(c.get(k), bool):
            out[k] = c[k]
    out["latest"] = semver(c.get("latest"))
    return out


def write_cache(data, c):
    tmp = os.path.join(data, "%s.%d.tmp" % (CACHE, os.getpid()))
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(c, f)
        os.replace(tmp, os.path.join(data, CACHE))
        return True
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        return False


def claim(data, now):
    """Take the read lock (one background read at a time across sessions); a stale lock is taken over once."""
    p = os.path.join(data, LOCK)
    for _ in range(2):
        try:
            os.close(os.open(p, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600))
            return True
        except FileExistsError:
            try:
                if abs(now - os.lstat(p).st_mtime) < STALE:  # now is whole seconds: a lock of this second is fresh
                    return False
                os.unlink(p)
            except OSError:
                return False
        except OSError:
            return False
    return False


def release(data):
    try:
        os.unlink(os.path.join(data, LOCK))
    except OSError:
        pass


def due(cache, now):
    return not 0 <= now - cache["checked"] < DAY


def line(name, installed, latest, owner, repo):
    return ("%s %s is available (installed %s): run /plugin, update it from Marketplaces, then /reload-plugins. "
            "Release notes: https://github.com/%s/%s/releases/tag/%s--v%s" % (name, latest, installed, owner, repo, name, latest))


def spawn(root, data):
    import subprocess
    kw = {"stdin": subprocess.DEVNULL, "stdout": subprocess.DEVNULL, "stderr": subprocess.DEVNULL, "close_fds": True, "cwd": data}
    if os.name == "nt":
        kw["creationflags"] = 0x00000008 | 0x00000200          # DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP
    else:
        kw["start_new_session"] = True
    subprocess.Popen([sys.executable, "-B", os.path.abspath(__file__), "refresh", "--root", root, "--data", data], **kw)


def session_start(root):
    data = os.environ.get("CLAUDE_PLUGIN_DATA", "")
    if not data or not os.path.isdir(data) or silent():
        return 0
    m = manifest(root)
    if m is None:
        return 0
    name, installed, owner, repo = m
    key = (name, "https://github.com/%s/%s" % (owner, repo))
    now = int(time.time())

    def plan(cache):
        latest = cache["latest"]
        show = bool(latest) and vtuple(latest) > vtuple(installed) and not 0 <= now - cache["shown"] < DAY
        return show, due(cache, now)

    show, start = plan(read_cache(data, key))
    if not (show or start):
        return 0                                   # the common case: nothing to say, nothing to read, no lock taken
    if not claim(data, now):
        return 0                                   # another session holds the lock: it prints or reads, this one stays silent
    cache = read_cache(data, key)                  # read again under the lock: only this copy decides and is written
    show, start = plan(cache)
    if show:
        cache["shown"] = now
    if start:
        cache["checked"] = now                     # marked before the read: a later session within 24 h does not read again
    if not (show or start) or not write_cache(data, cache):
        release(data)                              # a cache it cannot write would repeat the line and the read every session
        return 0
    if show:
        try:
            sys.stdout.write(json.dumps({"systemMessage": line(name, installed, cache["latest"], owner, repo)}) + "\n")
            sys.stdout.flush()
        except Exception:                          # noqa: BLE001 — a closed stdout: the lock is still released below
            pass
    if not start:
        release(data)
        return 0
    try:
        spawn(root, data)                          # the child releases the lock when its read ends
    except Exception:                              # noqa: BLE001 — no read this time; the line is already out
        release(data)
    return 0


def fetch(url):
    """The JSON the URL answers, or None: no redirect, no credentials, MAX_BODY bytes at most."""
    import urllib.error
    import urllib.request

    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            raise urllib.error.HTTPError(req.full_url, code, "redirect refused", headers, fp)

    handlers = [NoRedirect]
    if api_base() != API:
        handlers.insert(0, urllib.request.ProxyHandler({}))   # the tests' loopback server: never through a proxy
    opener = urllib.request.build_opener(*handlers)
    req = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json", "User-Agent": USER_AGENT})
    with opener.open(req, timeout=DEADLINE) as r:
        if r.status != 200:
            return None
        body = r.read(MAX_BODY + 1)
    if len(body) > MAX_BODY:
        return None
    return json.loads(body.decode("utf-8"))


def newest(refs, name):
    if not isinstance(refs, list):
        return None
    want = re.compile(r"refs/tags/%s--v(%s)" % (re.escape(name), SEMVER.pattern), re.ASCII)
    found = []
    for r in refs:
        ref = r.get("ref") if isinstance(r, dict) else None
        hit = want.fullmatch(ref) if isinstance(ref, str) else None
        if hit:
            found.append(hit.group(1))
    return max(found, key=vtuple) if found else None


def refresh(root, data):
    try:
        return read_latest(root, data)
    finally:
        release(data)


def read_latest(root, data):
    m = manifest(root)
    if m is None or silent():
        return 0
    name, _installed, owner, repo = m
    url = "%s/repos/%s/%s/git/matching-refs/tags/%s--v" % (api_base(), owner, repo, name)
    got = {}

    def run():
        try:
            refs = fetch(url)
            if isinstance(refs, list):             # an answer: its newest tag of this plugin, or none (a tag deleted since)
                got["latest"] = newest(refs, name)
                got["answer"] = True
        except Exception:                          # noqa: BLE001 — offline, refused, odd answer: all mean "no answer"
            pass

    t = threading.Thread(target=run, daemon=True)
    t.start()
    t.join(DEADLINE)
    if t.is_alive() or not got.get("answer"):
        return 0                                   # no answer: the cached latest stays until the next check
    latest = semver(got.get("latest"))
    key = (name, "https://github.com/%s/%s" % (owner, repo))
    cache = read_cache(data, key)
    cache["latest"] = latest
    if not cache["checked"]:
        cache["checked"] = int(time.time())
    write_cache(data, cache)
    return 0


def main(argv):
    try:
        if argv[:1] == ["session-start"]:
            root = argv[2] if argv[1:2] == ["--root"] and len(argv) > 2 else os.environ.get("CLAUDE_PLUGIN_ROOT", "")
            return session_start(root) if root else 0
        if argv[:1] == ["refresh"] and len(argv) == 5 and argv[1] == "--root" and argv[3] == "--data":
            return refresh(argv[2], argv[4])
    except Exception:                              # noqa: BLE001 — the reminder never fails a session
        pass
    return 0


if __name__ == "__main__":
    code = main(sys.argv[1:])
    try:
        sys.stdout.flush()
    except Exception:                              # noqa: BLE001 — a closed stdout is no reason to fail the session
        pass
    os._exit(code)                                 # a read still hanging past the deadline ends with the process
