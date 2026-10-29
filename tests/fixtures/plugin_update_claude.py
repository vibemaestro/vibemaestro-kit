#!/usr/bin/env python3
"""A stub `claude` for tests/test-baton-plugin-update.sh: records each call and does what Claude Code would to a scratch claude
directory (CLAUDE_CONFIG_DIR, else $HOME/.claude), never the machine's own.

  plugin marketplace update vibemaestro        known_marketplaces.json's lastUpdated moves, the clone gets a new file and
                                                  its branch is reset to the marketplace's main (`main` for the kit's own
                                                  marketplace, `mmain` for the git-subdir one) when that commit exists there
  plugin update <name>@vibemaestro --scope user  sdlc or brain: a cache directory <12 hex of kit main>[-<8 hex>] with the
                                                  plugin's manifest (and, for sdlc, the launcher template); a local plugin:
                                                  <12 hex of the clone's HEAD> with a manifest of its name; and the user
                                                  entry in the registry

The world is the directory FAKE_WORLD: `main` (kit main, as the fake gh reports it), `mmain` (the git-subdir marketplace's
main), `shape` (own or subdir), `claude.log` (one line per call). A file of these names there changes what a call does:
  race        a plugin update moves kit main to OTHER first and installs that (a git-subdir source fetches the newest main)
  race-mkt    the marketplace update moves kit main to OTHER
  mkt-next    the marketplace update writes this file as the clone's marketplace.json (the layout changes)
  badversion  the install records version 1.2.3
  versioned   the installed plugin.json carries a version
  elsewhere   the registry's installPath is a same-named directory outside the cache (a forged record)
  old-launcher  the installed launcher template accepts X.Y.Z only
  shadow      a later project-scope sdlc entry points at another install (the launcher resolves to it)
  other       a plugin update also records another plugin, other@elsewhere (another session's install meanwhile)
  gc          a plugin update removes the directory of the user install it replaces
  other-known a plugin update also records another marketplace, elsewhere, in known_marketplaces.json
  stale-head  the marketplace update leaves the clone's HEAD where it was
  race-mmain  the marketplace update moves the marketplace's main to the commit named in this file, and the clone with it
  race-local  a local plugin update installs OTHER (not the clone's HEAD)
  meddle      a local plugin update also moves sdlc's user entry to MEDDLE (another session's update meanwhile)
  fail-local  a local plugin update records its entry, then exits 1 (a marketplace-declared command that failed)
  eat-stdin   a plugin update reads its standard input to the end
  dirty-at-sdlc  the sdlc update also writes an untracked file into the clone's plugins/acme-ops
  swap-at-sdlc   the sdlc update also swaps the clone's plugins/acme-ops for a symlink to a copy of it
Any other call: exit 2.
"""
import json
import os
import shutil
import subprocess
import sys

OTHER = "c0ffee" + "0" * 34
MEDDLE = "4" * 40
SUFFIX = {"vibemaestro-sdlc": "be49dd83", "vibemaestro-brain": "adc9e2e3"}
W = os.environ["FAKE_WORLD"]
SRC = os.environ["STUB_SRC"]                # the kit's plugins/ directory: manifests and the launcher template come from it
CFG = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.environ["HOME"], ".claude")
PLUGINS = os.path.join(CFG, "plugins")


def flag(name):
    return os.path.exists(os.path.join(W, name))


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def dump(path, data):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)


def stamp():
    n = len(open(os.path.join(W, "claude.log")).read().splitlines())
    return "2026-10-24T12:00:%02d.000Z" % n


with open(os.path.join(W, "claude.log"), "a") as f:
    f.write(" ".join(sys.argv[1:]) + "\n")
args = sys.argv[1:]

if args == ["plugin", "marketplace", "update", "vibemaestro"]:
    kp = os.path.join(PLUGINS, "known_marketplaces.json")
    known = load(kp)
    known["vibemaestro"]["lastUpdated"] = stamp()
    dump(kp, known)
    clone = known["vibemaestro"]["installLocation"]
    open(os.path.join(clone, "updated"), "w").write("new marketplace head\n")
    if flag("race-mmain"):
        shutil.copyfile(os.path.join(W, "race-mmain"), os.path.join(W, "mmain"))
    shape = open(os.path.join(W, "shape")).read().strip()
    target = open(os.path.join(W, "main" if shape == "own" else "mmain")).read().strip()
    if not flag("stale-head") and subprocess.call(["git", "-C", clone, "cat-file", "-e", target + "^{commit}"],
                                                  stderr=subprocess.DEVNULL) == 0:
        subprocess.check_call(["git", "-C", clone, "reset", "-q", "--hard", target])
    if flag("mkt-next"):
        shutil.copyfile(os.path.join(W, "mkt-next"), os.path.join(clone, ".claude-plugin", "marketplace.json"))
    if flag("race-mkt"):
        open(os.path.join(W, "main"), "w").write(OTHER + "\n")
    sys.exit(0)

if len(args) == 5 and args[:2] == ["plugin", "update"] and args[3:] == ["--scope", "user"] and args[2].endswith("@vibemaestro"):
    name = args[2][: -len("@vibemaestro")]
    if flag("eat-stdin"):
        sys.stdin.read()
    kp = os.path.join(PLUGINS, "known_marketplaces.json")
    clone = load(kp)["vibemaestro"]["installLocation"]
    local = name not in SUFFIX                  # sdlc and brain install kit main, as a git-subdir source does
    if local and not os.path.isdir(os.path.join(clone, "plugins", name)):
        sys.exit(2)
    if flag("race") and not local:
        open(os.path.join(W, "main"), "w").write(OTHER + "\n")
    sha = open(os.path.join(W, "main")).read().strip()
    if local:
        sha = OTHER if flag("race-local") else subprocess.check_output(["git", "-C", clone, "rev-parse", "HEAD"]).decode().strip()
    shape = open(os.path.join(W, "shape")).read().strip()
    v = "1.2.3" if flag("badversion") else sha[:12] + ("-" + SUFFIX[name] if shape == "subdir" and not local else "")
    d = os.path.join(PLUGINS, "cache", "vibemaestro", name, v)
    os.makedirs(os.path.join(d, ".claude-plugin"), exist_ok=True)
    man = {"name": name, "description": "a local plugin"} if local else load(os.path.join(SRC, name, ".claude-plugin", "plugin.json"))
    man.pop("version", None)
    if flag("versioned"):
        man["version"] = "9.9.9"
    dump(os.path.join(d, ".claude-plugin", "plugin.json"), man)
    if name == "vibemaestro-sdlc":
        os.makedirs(os.path.join(d, "scripts"), exist_ok=True)
        tpl = open(os.path.join(SRC, name, "scripts", "baton-launcher.py"), encoding="utf-8").read()
        if flag("old-launcher"):
            tpl = tpl.replace("|[0-9a-f]{12}(?:-[0-9a-f]{8})?|unknown)", ")")
        open(os.path.join(d, "scripts", "baton-launcher.py"), "w", encoding="utf-8").write(tpl)
        open(os.path.join(d, "scripts", "baton.py"), "w").write("# stub\n")
    path = d
    if flag("elsewhere"):
        path = os.path.join(W, "forged", v)
        shutil.copytree(d, path)
    rp = os.path.join(PLUGINS, "installed_plugins.json")
    reg = load(rp)
    key = name + "@vibemaestro"
    rest = [e for e in reg["plugins"].get(key, []) if e.get("scope") != "user"]
    if flag("gc"):
        for e in reg["plugins"].get(key, []):
            if e.get("scope") == "user" and os.path.isdir(e.get("installPath", "")):
                shutil.rmtree(e["installPath"])
    entry = {"scope": "user", "installPath": path, "version": v, "installedAt": stamp(), "lastUpdated": stamp(),
             "gitCommitSha": sha}
    reg["plugins"][key] = rest + [entry]
    if flag("meddle") and local:
        for e in reg["plugins"]["vibemaestro-sdlc@vibemaestro"]:
            if e.get("scope") == "user":
                e["gitCommitSha"] = MEDDLE
    if flag("other-known"):
        kp = os.path.join(PLUGINS, "known_marketplaces.json")
        known = load(kp)
        known["elsewhere"] = {"source": {"source": "github", "repo": "acme/elsewhere"}, "installLocation": "/example/elsewhere"}
        dump(kp, known)
    if flag("other"):
        reg["plugins"]["other@elsewhere"] = [{"scope": "user", "installPath": "/example/other", "version": "1.0.0",
                                              "lastUpdated": stamp(), "gitCommitSha": "0" * 40}]
    if flag("shadow") and name == "vibemaestro-sdlc":
        old = os.path.join(PLUGINS, "cache", "vibemaestro", name, "0" * 12)
        os.makedirs(os.path.join(old, "scripts"), exist_ok=True)
        open(os.path.join(old, "scripts", "baton.py"), "w").write("# another install\n")
        reg["plugins"][key].append({"scope": "project", "projectPath": "/example", "installPath": old, "version": "0" * 12,
                                    "lastUpdated": "2099-01-01T00:00:00.000Z", "gitCommitSha": "0" * 40})
    dump(rp, reg)
    if flag("dirty-at-sdlc") and name == "vibemaestro-sdlc":
        open(os.path.join(clone, "plugins", "acme-ops", "late.sh"), "w").write("echo late\n")
    if flag("swap-at-sdlc") and name == "vibemaestro-sdlc":
        ops, copy = os.path.join(clone, "plugins", "acme-ops"), os.path.join(W, "ops-copy")
        shutil.copytree(ops, copy)
        shutil.rmtree(ops)
        os.symlink(copy, ops)
    sys.exit(1 if flag("fail-local") and local else 0)

sys.stderr.write("stub claude: unexpected call: %s\n" % " ".join(args))
sys.exit(2)
