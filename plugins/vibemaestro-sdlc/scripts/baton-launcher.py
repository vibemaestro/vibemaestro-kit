#!/usr/bin/env -S python3 -I
"""baton launcher of vibemaestro-sdlc: the one fixed command the owner's permission rules name.

`baton.py permissions --install-launcher` writes this file, once per machine, to <state-dir>/bin/baton (the state directory of
baton.py, outside every repository), with CLAUDE_DIR and STATE_HOME below set to that machine's paths. The rules then name that
path, which no plugin upgrade moves. It runs the baton.py of the installed vibemaestro-sdlc that the registry updated last, and
nothing else:

  <claude-dir>/plugins/cache/vibemaestro/vibemaestro-sdlc/<version>/scripts/baton.py

<version> is the directory Claude Code names after the version it computed (measured):
X.Y.Z (a manifest version, the public kit), X.Y.Z-<12 hex> (a dependency resolved at a tag), <12 hex> (a git marketplace whose
plugin carries no version: the private kit), <12 hex>-<8 hex> (a git-subdir plugin source with no version: the commit, then a
hash per plugin; measured: sdlc at 3d15f5b67818-be49dd83) or `unknown` (a local directory marketplace without git),
lower-case hex and nothing after it, not even a newline. The entries come from
<claude-dir>/plugins/installed_plugins.json and the one with the latest `lastUpdated` runs (the first one on a tie): numbers are
not compared, since a SHA has no order and the public numbering restarted at 0.1.0. The launcher refuses, with the reason on stderr
and exit 2, when that file cannot be read, when any of its entries points anywhere else, when a real path leaves that shape (a
symlink in plugins/, cache/ or the version directory, or a baton.py that is a symlink), and when no entry is left: version
directories without baton.py are skipped. The paths are fixed at install, not
read from HOME, CLAUDE_CONFIG_DIR or XDG_STATE_HOME, and baton.py runs with XDG_STATE_HOME set to the installed one: a variable
cannot point the launcher at other files. The owner's deny rules keep the plugins directory and the state directory out of reach
of Claude Code's write tools; the launcher trusts nothing else.

It runs isolated (`python3 -I`: no PYTHON* variables, no user site, not its own directory on the import path), from the first
line, and re-executes itself so when started as `python3 <file>`. It rarely changes; when it does, `baton.py permissions --check`
reports the installed copy as STALE (it compares the bytes). Python 3.8+, standard library only.
"""
import sys

if not sys.flags.isolated:
    import os                                   # already loaded by the interpreter's start-up, not read from this directory
    os.execv(sys.executable, [sys.executable, "-I", os.path.realpath(__file__)] + sys.argv[1:])

import json  # noqa: E402
import os  # noqa: E402
import re  # noqa: E402

CLAUDE_DIR = None    # set by --install-launcher
STATE_HOME = None    # set by --install-launcher
MARKETPLACE, PLUGIN = "vibemaestro", "vibemaestro-sdlc"
INSTALL_DIR = re.compile(r"^(?:(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-[0-9a-f]{12})?|[0-9a-f]{12}(?:-[0-9a-f]{8})?|unknown)\Z")


class Refused(Exception):
    pass


def resolve():
    """The real path of the baton.py of the registry's latest usable entry, or Refused with the reason."""
    if not CLAUDE_DIR or not STATE_HOME:
        raise Refused("this copy was not written by `baton.py permissions --install-launcher`")
    plugins = os.path.join(os.path.realpath(CLAUDE_DIR), "plugins")
    base = os.path.join(plugins, "cache", MARKETPLACE, PLUGIN)
    if os.path.realpath(base) != base:
        raise Refused("%s is reached through a symlink (it resolves to %s)" % (base, os.path.realpath(base)))
    registry = os.path.join(plugins, "installed_plugins.json")
    try:
        with open(registry, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError) as e:
        raise Refused("cannot read %s: %s" % (registry, e))
    entries = (data.get("plugins") or {}).get("%s@%s" % (PLUGIN, MARKETPLACE)) if isinstance(data, dict) else None
    if not isinstance(entries, list) or not entries:
        raise Refused("%s lists no %s@%s" % (registry, PLUGIN, MARKETPLACE))
    best, skipped = None, []
    for e in entries:
        path = e.get("installPath") if isinstance(e, dict) else None
        if not isinstance(path, str) or not os.path.isabs(path):
            raise Refused("%s has a %s entry without an absolute installPath" % (registry, PLUGIN))
        real = os.path.realpath(path)
        parent, version = os.path.split(real)
        if parent != base or not INSTALL_DIR.match(version):
            raise Refused("%s points to %s (real path %s), not to %s/<version>" % (registry, path, real, base))
        script = os.path.join(real, "scripts", "baton.py")
        if os.path.realpath(script) != script:
            raise Refused("%s is a symlink to %s" % (script, os.path.realpath(script)))
        stamp = e.get("lastUpdated") if isinstance(e.get("lastUpdated"), str) else ""
        if not os.path.isfile(script):
            skipped.append("%s has no scripts/baton.py" % version)
        elif best is None or stamp > best[0]:
            best = (stamp, script)
    if best is None:
        raise Refused("no usable %s in %s (%s)" % (PLUGIN, registry, "; ".join(skipped)))
    return best[1]


def main(argv):
    try:
        script = resolve()
    except Refused as e:
        sys.stderr.write("baton launcher: refused: %s\n" % e)
        return 2
    os.execve(sys.executable, [sys.executable, "-I", script] + argv, dict(os.environ, XDG_STATE_HOME=STATE_HOME))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
