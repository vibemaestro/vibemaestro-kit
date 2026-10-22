#!/usr/bin/env python3
"""Versions of a plugin marketplace repo: an ordinary PR records a change file, only a release or a hotfix changes a version.

  release.py check [--repo DIR] [--base REF]            rc 0 ok, 1 red, 3 the check did not run, 64 usage
  release.py plan  [--repo DIR] [--hotfix]              read-only: what a cut would do here; rc 0, 1 a change file is broken
  release.py cut   [--repo DIR] [--hotfix] [--base REF] edits the working tree into a release (or a hotfix); rc 0, 1 refused

Why: a plugin's version exists only in the public release. The private repo
carries no plugin version: no manifest and no marketplace entry has a `version` key, so Claude Code keys an install by the
commit and every change reaches it. A plugin's RELEASED version is the first `## ` heading of its `CHANGELOG.md` when that
heading is a version X.Y.Z; any other first heading (the private history kept under one heading) or no CHANGELOG means it was never
released. The public export (scripts/export-public.sh) writes that version into each exported manifest. A PR that changes
`plugins/<name>/` adds one change file `.changes/<slug>.md`; a release PR (skill `release`) turns every pending change file into
one CHANGELOG section per plugin; a hotfix PR into the branch `release` adds a patch section; a back-merge PR brings a hotfix from
`release` to main; after a release or a hotfix merges, `release` moves to it, and the repository publishes it its own way (the
public tags are `<plugin>--v<version>`; the private repository has none).

The base is `--base`, else `origin/$GITHUB_BASE_REF` (the PR's base in CI), else `origin/main`. The change is the merge-base of HEAD
and the base against the working tree (committed, staged, unstaged and untracked), so a local run sees what CI will. The kind of the
change is read from the base and the diff, in this order:

  bootstrap  the history of the base never held `.changes/README.md`: the rule before change files, each plugin with changed files
             has a manifest version above the base's (numbers: 2.10.0 is above 2.9.0); a plugin new on the base passes, one removed
             whole passes. Once `.changes/README.md` reached the base, this kind is gone for good (deleting it later changes nothing).
  hotfix     the base is the branch `release`: each plugin with changed files goes exactly one patch above the base's released
             version (a hotfix adds no plugin and patches only a released one); each change file the PR's commits added is
             `level: patch`, names only raised plugins, and its line is in the raised plugin's `CHANGELOG.md` under `## <version>`;
             each raised plugin is named by one; no change file is left in `.changes/`; the marketplace does not change. (A
             `CONTRACT.md` surface change is red: tests/test-contract.sh.)
  back-merge `origin/release` exists and the commit the PR brings (HEAD, or the second parent of CI's test merge whose first parent
             is the base) is on `origin/release` and not on the base, with a clean working tree: every released version equals
             `origin/release`'s; no change file is needed (the hotfix consumed its own).
  release    a released version here is not the merge-base's (a new first `## X.Y.Z` heading):
             - every change file pending on the base tip is consumed and none is left or added in `.changes/`;
             - each plugin they name goes up exactly one step from the base's released version at the highest level naming it (a
               `major` on a 0.x plugin is a minor), or to 0.1.0 when it was never released; no other plugin's version moves;
             - each raised plugin's `CHANGELOG.md` has `## <version>` holding `- <level>: <line>` for each consumed file naming it;
             - the change touches only `CHANGELOG.md` files, the consumed change files and a `CONTRACT.md`'s `Frozen at` line (no
               manifest, no kb page: no version number is written anywhere else);
             - when `origin/release` exists it is an ancestor of HEAD (hotfixes are back-merged first).
  ordinary   otherwise:
             - no released version differs from the merge-base's (only a release moves one), except on a base whose manifests still
               carry a `version` (the PR that retires them resets the CHANGELOGs too);
             - the marketplace changes only in `description` texts and in entries appended after the merge-base's, with no
               duplicate name (a removed, reordered or redirected entry, or another key such as `metadata`, ships something else);
             - each plugin with changed files is named by a change file this change ADDS;
             - each added change file is a regular file `.changes/<a-z0-9 . _ ->.md` (not README.md, no subdirectory, no symlink),
               with the frontmatter `plugins:` (marketplace names, comma-separated; `plugins/<name>/` names when there is no
               marketplace) and `level: patch|minor|major`, and a body of one line;
             - no change file of the merge-base is edited or deleted (only a release consumes them); `.changes/README.md` is not
               deleted or replaced by a symlink (editing its text is fine);
             - a plugin removed whole is the one exception: a marketplace entry of the merge-base may go when `plugins/<name>/`
               holds no file and its source is `./plugins/<name>`; then each pending change file naming a removed plugin
               must go: deleted when it names only removed plugins, else edited so that `plugins:` loses exactly the removed
               names, the level stays and the body names no removed plugin (its name or the part after its first `-`, as a
               word, in any case); the removed plugin needs no change file;
             - nothing under `plugins/` is a symlink or a submodule (their content would change without a path under `plugins/`).
In every kind but bootstrap, a `version` key in a manifest here or anywhere in `.claude-plugin/marketplace.json` is red: the
private repo carries none (Claude Code then takes the commit as the version).

`plan` reads the change files in the working tree and prints, per plugin, `old -> new (level)` (`unreleased -> 0.1.0` for a
plugin never released), and each `CONTRACT.md` whose surface differs from `origin/release`'s (the base's when there is no
`release`) or whose plugin is released for the first time. `cut` does it: it writes the CHANGELOG sections, removes the change
files and sets `Frozen at`; it writes no manifest and no kb page. It refuses a dirty working tree, a detached HEAD, the branch
`release` or the base's own branch, a HEAD that does not descend from the base (`origin/main`, or `origin/release` with --hotfix),
a release whose HEAD lacks `origin/release`, nothing pending, and with --hotfix a level other than patch, a surface change, a
plugin never released, or a base whose manifests still carry a `version` (a `release` cut before the reset: release from main).

A manifest is `plugins/<name>/.claude-plugin/plugin.json`; a symlink or a non-JSON file is red for a plugin the change touches. A
version is X.Y.Z (digits, no leading zero, no suffix). In the bootstrap kind the manifest `version` still decides, as it did. When the base does not resolve, or shares no history with HEAD (a
shallow clone), the check cannot run: rc 3 locally, red when GITHUB_ACTIONS is set (a check that did not run must not pass a PR).
Standard library only, Python 3.8+.
"""
import json
import os
import re
import subprocess
import sys

BASE_DEFAULT = "origin/main"
MANIFEST = ".claude-plugin/plugin.json"
MARKETPLACE = ".claude-plugin/marketplace.json"
CHANGES = ".changes"
RELEASE = "release"
RELEASE_REF = "origin/" + RELEASE
CHANGELOG = "CHANGELOG.md"
CONTRACT = "CONTRACT.md"
SURFACE = ("<!-- surface:begin -->", "<!-- surface:end -->")
FROZEN = re.compile(r"^Frozen at: .*$", re.M)
LEVELS = ("patch", "minor", "major")
VERSION = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", re.ASCII)
CHANGE_NAME = re.compile(r"[a-z0-9][a-z0-9._-]*\.md", re.ASCII)
FIRST_RELEASE = "0.1.0"


class Bad(Exception):
    pass


def git(repo, *args):
    p = subprocess.run(["git", "-C", repo] + list(args), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    return p.returncode, p.stdout


def vtuple(v):
    if not isinstance(v, str) or not VERSION.fullmatch(v):
        raise Bad("not a version X.Y.Z: %r" % (v,))
    return tuple(int(x) for x in v.split("."))


def changed(repo, mb):
    """(paths that differ between the merge-base and the working tree plus untracked files, the subset ADDED since the merge-base)."""
    rc, out = git(repo, "diff", "--name-status", "-z", "--no-renames", "--ignore-submodules=none", mb)
    if rc != 0:
        raise Bad("git diff against %s failed" % mb[:12])
    rc2, out2 = git(repo, "ls-files", "-z", "--others", "--exclude-standard")
    fields = out.decode("utf-8", "surrogateescape").split("\0")
    paths, added = set(), set()
    for status, path in zip(fields[0::2], fields[1::2]):
        if path:
            paths.add(path)
            if status == "A":
                added.add(path)
    untracked = set(p for p in out2.decode("utf-8", "surrogateescape").split("\0") if p)
    return sorted(paths | untracked), added | untracked


def plugins_touched(paths):
    return sorted(set(p.split("/")[1] for p in paths if len(p.split("/")) >= 3 and p.startswith("plugins/") and p.split("/")[1]))


def show(repo, rev, path):
    rc, out = git(repo, "show", "%s:%s" % (rev, path))
    return out if rc == 0 else None


def ever_had(repo, rev, path):
    """Whether the history of `rev` ever held `path` (deleting it later does not bring the bootstrap back)."""
    rc, out = git(repo, "log", "-1", "--full-history", "--format=%H", rev, "--", path)
    return rc == 0 and out.strip() != b""


def read_manifest(repo, name):
    """(exists, version) of the working-tree manifest; red on a symlink, a broken file or a missing version."""
    path = os.path.join(repo, "plugins", name, *MANIFEST.split("/"))
    if os.path.islink(path):
        raise Bad("plugins/%s/%s is a symlink: its version is whatever it points at" % (name, MANIFEST))
    if not os.path.isfile(path):
        return False, None
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError) as e:
        raise Bad("plugins/%s/%s cannot be read as JSON: %s" % (name, MANIFEST, e))
    if not isinstance(data, dict) or "version" not in data:
        raise Bad("plugins/%s/%s has no version" % (name, MANIFEST))
    return True, data["version"]


def rev_version(repo, rev, name):
    out = show(repo, rev, "plugins/%s/%s" % (name, MANIFEST))
    if out is None:
        return None
    try:
        data = json.loads(out.decode("utf-8", "replace"))
    except ValueError:
        raise Bad("plugins/%s/%s on %s is not JSON" % (name, MANIFEST, rev[:12]))
    return data.get("version") if isinstance(data, dict) else None


def manifest_here(repo, name):
    """(exists, data) of the working-tree manifest; red on a symlink or a broken file. No version is asked of it."""
    path = os.path.join(repo, "plugins", name, *MANIFEST.split("/"))
    if os.path.islink(path):
        raise Bad("plugins/%s/%s is a symlink: what it says is whatever it points at" % (name, MANIFEST))
    if not os.path.isfile(path):
        return False, None
    try:
        with open(path, encoding="utf-8") as f:
            return True, json.load(f)
    except (OSError, ValueError) as e:
        raise Bad("plugins/%s/%s cannot be read as JSON: %s" % (name, MANIFEST, e))


def released_of(text):
    """The released version a CHANGELOG text records: its first `## ` heading when that is X.Y.Z, else None."""
    for line in (text or "").split("\n"):
        if line.startswith("## "):
            v = line[3:].strip()
            return v if VERSION.fullmatch(v) else None
    return None


def released_here(repo, name):
    path = os.path.join(repo, "plugins", name, CHANGELOG)
    if os.path.islink(path):
        raise Bad("plugins/%s/%s is a symlink: its released version is whatever it points at" % (name, CHANGELOG))
    return released_of(text_here(repo, "plugins/%s/%s" % (name, CHANGELOG)))


def released_at(repo, rev, name):
    return released_of(text_at(repo, rev, "plugins/%s/%s" % (name, CHANGELOG)))


def carries_version(data):
    return isinstance(data, dict) and "version" in data


def base_carries_versions(repo, rev):
    """The plugins whose manifest at `rev` has a `version` key (a base from before the version reset)."""
    out = []
    for name in plugin_names_at(repo, rev):
        if carries_version(json_or_none(show(repo, rev, "plugins/%s/%s" % (name, MANIFEST)) or b"null")):
            out.append(name)
    return out


def release_ref(repo):
    """origin/release, unless its manifests still carry a version: a `release` cut before the version reset (the first public
    release not promoted yet) records no released version to compare with; last_release_commit stands in for it."""
    rel = resolve(repo, RELEASE_REF)
    return rel if rel and not base_carries_versions(repo, rel) else None


def last_release_commit(repo, rev, name):
    """The commit on `rev` that wrote the plugin's released version (its `## X.Y.Z` heading, the oldest commit whose diff of the
    CHANGELOG touches that line), or None when the plugin is unreleased there."""
    v = released_at(repo, rev, name)
    if not v:
        return None
    rc, out = git(repo, "log", "--format=%H", "-G", "^## %s$" % re.escape(v), rev, "--", "plugins/%s/%s" % (name, CHANGELOG))
    found = out.decode().split() if rc == 0 else []
    return found[-1] if found else None


def check_no_versions(repo, bad):
    """The private repo carries no version: a `version` key in a manifest here, or anywhere in the marketplace, is red."""
    for name in sorted(plugin_dirs(repo)):
        try:
            exists, data = manifest_here(repo, name)
        except Bad as e:
            bad.append(str(e))
            continue
        keys = version_keys(data) if exists else []
        if keys:
            bad.append("plugins/%s/%s carries a version at %s (%s): the private repo carries none, not even a dependency range "
                       "(a range against a commit-keyed version fails to load); the public export writes them"
                       % (name, MANIFEST, keys[0][0], keys[0][1]))
    path = os.path.join(repo, MARKETPLACE)
    if os.path.isfile(path):
        keys = version_keys(json_or_none(open(path, "rb").read()))
        if keys:
            bad.append("%s carries a version key (%s): the private repo carries none" % (MARKETPLACE, keys[0][0]))


def marketplace_entries(data):
    """{name: source as canonical JSON} of a marketplace document."""
    out = {}
    plugins = data.get("plugins") if isinstance(data, dict) else None
    for p in plugins if isinstance(plugins, list) else []:
        if isinstance(p, dict) and isinstance(p.get("name"), str):
            out[p["name"]] = json.dumps(p.get("source"), sort_keys=True)
    return out


def _no_description(v):
    if isinstance(v, dict):
        return {k: _no_description(x) for k, x in v.items() if not (k == "description" and isinstance(x, str))}
    if isinstance(v, list):
        return [_no_description(x) for x in v]
    return v


def marketplace_drift(old, now, removed=()):
    """What an ordinary PR may not do to the marketplace: anything but `description` texts (string values), entries appended
    at the end and the entries of plugins `removed` whole. Names are compared exactly: `Alpha` and `alpha` are two names."""
    if not isinstance(now, dict):
        return ["%s is not a JSON object" % MARKETPLACE] if now is not None or old is not None else []
    out = []
    names = [p.get("name") for p in now.get("plugins", []) if isinstance(p, dict)] if isinstance(now.get("plugins"), list) else []
    names = [json.dumps(n, sort_keys=True) if not isinstance(n, str) else n for n in names]     # an odd name is still compared
    dups = sorted(set(n for n in names if names.count(n) > 1))
    if dups:
        out.append("%s: the entry name %s appears more than once" % (MARKETPLACE, ", ".join(map(str, dups))))
    if not isinstance(old, dict):
        return out
    o, n = _no_description(old), _no_description(now)
    op, np_ = o.pop("plugins", None), n.pop("plugins", None)
    if o != n:
        keys = sorted(set(o) | set(n))
        out.append("%s: %s changed in an ordinary PR (only descriptions and appended entries may)"
                   % (MARKETPLACE, ", ".join(k for k in keys if o.get(k) != n.get(k))))
    op = [e for e in op if not (isinstance(e, dict) and isinstance(e.get("name"), str) and e["name"] in removed)] if isinstance(op, list) else []
    if not isinstance(np_, list) or np_[:len(op)] != op:
        out.append("%s: an entry of the merge-base is removed, moved or changed (a source, a ref): it would ship something "
                   "else; an ordinary PR only appends entries" % MARKETPLACE)
    return out


def plugin_dirs(repo):
    d = os.path.join(repo, "plugins")
    return set(n for n in os.listdir(d) if os.path.isfile(os.path.join(d, n, *MANIFEST.split("/")))) if os.path.isdir(d) else set()


SAFE_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*", re.ASCII)


def holds_file(repo, rel):
    """`rel` holds a file the check sees: the path itself or a file under it, tracked and on disk, or untracked and not ignored
    (what CI's checkout would hold; an ignored __pycache__ does not count). True when git cannot say."""
    rc, out = git(repo, "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", rel)
    if rc != 0:
        return True
    return any(p and os.path.lexists(os.path.join(repo, p)) for p in out.decode("utf-8", "surrogateescape").split("\0"))


def removed_plugins(repo, mb):
    """The plugins removed whole: entries of the merge-base's marketplace that are gone here, whose source is `./plugins/<name>`
    (a source elsewhere, or a directory of another name, is never a removal) and whose plugins/<name>/ holds no file."""
    raw = show(repo, mb, MARKETPLACE)
    old = marketplace_entries(json_or_none(raw)) if raw is not None else {}
    path = os.path.join(repo, MARKETPLACE)
    now = marketplace_entries(json_or_none(open(path, "rb").read())) if os.path.isfile(path) else {}
    out = set()
    for n, src in old.items():
        src = json.loads(src)
        if n in now or not SAFE_NAME.fullmatch(n) or ".." in n:
            continue
        if not isinstance(src, str) or os.path.normpath(src).replace(os.sep, "/") != "plugins/" + n:
            continue
        if not holds_file(repo, "plugins/" + n):
            out.add(n)
    return out


def names_removed(line, removed):
    """The removed plugins a change file's line still names: the name, or the part after its first `-`, as a word in any case
    (`gamma` is named in `the gamma kit`, not in `gammaray`)."""
    low = line.lower()
    out = []
    for n in sorted(removed):
        terms = [n.lower()] + ([n.split("-", 1)[1].lower()] if "-" in n else [])
        if any(re.search(r"(?<![a-z0-9])%s(?![a-z0-9])" % re.escape(t), low) for t in terms):
            out.append(n)
    return out


def pending_left(repo, mb, paths, removed, bad):
    """A pending change file of the merge-base that this change leaves as it was while it names a removed plugin: red, since no
    later ordinary PR may delete or edit it and a release cannot ship a plugin with no manifest."""
    rc, out = git(repo, "ls-tree", "-r", "-z", "--name-only", mb, "--", CHANGES)
    for p in out.decode("utf-8", "surrogateescape").split("\0") if rc == 0 else []:
        if not p or p in paths or p == CHANGES + "/README.md":
            continue
        try:
            plugins = read_change(show(repo, mb, p).decode("utf-8", "replace"))[0]
        except Bad:
            continue
        gone = [x for x in plugins if x in removed]
        if gone:
            bad.append("%s still names the removed plugin %s: delete it when it names only removed plugins, else drop the name "
                       "from its plugins: line" % (p, ", ".join(gone)))


def judge_pending(repo, mb, p, removed, bad):
    """A pending change file of the merge-base that this change deletes or edits: red unless a plugin removed whole allows it."""
    try:
        old_plugins, old_level, _old_line = read_change(show(repo, mb, p).decode("utf-8", "replace"))
    except Bad:
        old_plugins, old_level = [], None
    gone = [x for x in old_plugins if x in removed]
    full = os.path.join(repo, p)
    if not gone:
        bad.append("%s is a pending change file of the base: only a release consumes it (add a new one instead)" % p)
        return
    if not os.path.lexists(full):
        if len(gone) != len(old_plugins):
            bad.append("%s is deleted, but it also names %s, which stay: drop only the removed plugins from its plugins: line"
                       % (p, ", ".join(x for x in old_plugins if x not in removed)))
        else:
            print("change file %s: names only %s, removed whole: deleted" % (p, ", ".join(gone)))
        return
    if os.path.islink(full) or not os.path.isfile(full):
        bad.append("%s: a change file is a regular file, not a symlink: its record must change only by a change to it" % p)
        return
    try:
        with open(full, encoding="utf-8") as f:
            plugins, level, line = read_change(f.read())
    except (OSError, UnicodeDecodeError) as e:
        bad.append("%s: cannot be read: %s" % (p, e))
        return
    except Bad as e:
        bad.append("%s: %s" % (p, e))
        return
    want = [x for x in old_plugins if x not in removed]
    if plugins != want:
        bad.append("%s: plugins: %s; a pending change file that loses a plugin removed whole keeps the others as they were: %s"
                   % (p, ", ".join(plugins), ", ".join(want)))
    if level != old_level:
        bad.append("%s: level %s, the base's is %s: dropping a removed plugin does not change the level" % (p, level, old_level))
    for n in names_removed(line, removed):
        bad.append("%s: the body still names the removed plugin %s" % (p, n))
    print("change file %s: %s removed whole, now %s, %s: %s" % (p, ", ".join(gone), ", ".join(plugins), level, line))


def change_names(repo):
    """The names a change file may give: the marketplace's entries, or `plugins/<name>/` with a manifest when there is none."""
    path = os.path.join(repo, MARKETPLACE)
    if os.path.isfile(path):
        return set(marketplace_entries(json_or_none(open(path, "rb").read())))
    return plugin_dirs(repo)


def version_keys(data, at=""):
    """Every `version` key of a JSON value, as (path, value) pairs."""
    out = []
    if isinstance(data, dict):
        for k, v in data.items():
            p = "%s.%s" % (at, k) if at else k
            if k == "version":
                out.append((p, json.dumps(v, sort_keys=True)))
            out += version_keys(v, p)
    elif isinstance(data, list):
        for i, v in enumerate(data):
            out += version_keys(v, "%s[%d]" % (at, i))
    return out


def json_or_none(raw):
    try:
        return json.loads(raw if isinstance(raw, str) else raw.decode("utf-8", "replace"))
    except ValueError:
        return None


def read_change(text):
    """(plugins, level, line) of a change file's text; raises Bad with the reason."""
    lines = text.replace("\r\n", "\n").split("\n")
    if not lines or lines[0].strip() != "---":
        raise Bad("no frontmatter (it starts with ---)")
    try:
        end = lines.index("---", 1)
    except ValueError:
        raise Bad("the frontmatter is not closed with ---")
    head = {}
    for line in lines[1:end]:
        k, sep, v = line.partition(":")
        if not sep or k.strip() in head:
            raise Bad("frontmatter line %r is not one `key: value`" % line)
        head[k.strip()] = v.strip().strip('"')
    if set(head) != {"plugins", "level"}:
        raise Bad("the frontmatter has %s, not exactly plugins and level" % ", ".join(sorted(head)) or "nothing")
    plugins = [p.strip() for p in head["plugins"].split(",")]
    if not plugins or not all(plugins):
        raise Bad("plugins: is empty or has an empty name")
    if head["level"] not in LEVELS:
        raise Bad("level: %r is not one of %s" % (head["level"], "|".join(LEVELS)))
    body = [l for l in lines[end + 1:] if l.strip()]
    if len(body) != 1:
        raise Bad("the body has %d non-empty lines, not one" % len(body))
    return plugins, head["level"], body[0].strip()


def judge_bootstrap(repo, base, base_ref, name, bad):
    exists, head = read_manifest(repo, name)
    old = rev_version(repo, base, name)
    if old is None:
        if exists:
            print("plugin %s: new on %s, version %s: ok" % (name, base_ref, head))
        return
    if not exists:
        d = os.path.join(repo, "plugins", name)
        if os.path.isdir(d) and os.listdir(d):
            bad.append("plugin %s lost its manifest and still has files" % name)
        else:
            print("plugin %s: removed: ok" % name)
        return
    if vtuple(head) <= vtuple(old):
        bad.append("plugin %s changed but its version %s is not above %s on %s: raise it (bootstrap: %s has no %s/ yet)"
                   % (name, head, old, base_ref, base_ref, CHANGES))
    else:
        print("plugin %s: %s -> %s: ok (bootstrap)" % (name, old, head))


def special_under_plugins(repo):
    """Paths under plugins/ that are a symlink or a submodule, in the index or untracked in the tree."""
    rc, out = git(repo, "ls-files", "-s", "-z", "--", "plugins")
    found = []
    for entry in out.decode("utf-8", "surrogateescape").split("\0"):
        meta, _, path = entry.partition("\t")
        if meta.split(" ")[0] in ("120000", "160000"):
            found.append(path)
    rc, out = git(repo, "ls-files", "-z", "--others", "--exclude-standard", "--", "plugins")
    found += [p for p in out.decode("utf-8", "surrogateescape").split("\0") if p and os.path.islink(os.path.join(repo, p))]
    return sorted(set(found))


def judge_ordinary(repo, mb, paths, added, touched, bad):
    known = change_names(repo)
    removed = removed_plugins(repo, mb) if MARKETPLACE in paths else set()
    for name in sorted(removed):
        print("plugin %s: removed whole (its marketplace entry and every file of plugins/%s/)" % (name, name))
    named = set()
    for p in sorted(added):
        if not p.startswith(CHANGES + "/"):
            continue
        rest = p[len(CHANGES) + 1:]
        if rest == "README.md":
            continue
        if "/" in rest or not CHANGE_NAME.fullmatch(rest):
            bad.append("%s: a change file is %s/<a-z0-9 . _ ->.md, directly in %s/" % (p, CHANGES, CHANGES))
            continue
        if os.path.islink(os.path.join(repo, p)) or not os.path.isfile(os.path.join(repo, p)):
            bad.append("%s: a change file is a regular file, not a symlink: its record must change only by a change to it" % p)
            continue
        try:
            with open(os.path.join(repo, p), encoding="utf-8") as f:
                plugins, level, line = read_change(f.read())
        except (OSError, UnicodeDecodeError) as e:
            bad.append("%s: cannot be read: %s" % (p, e))
            continue
        except Bad as e:
            bad.append("%s: %s" % (p, e))
            continue
        unknown = [x for x in plugins if x not in known]
        if unknown:
            bad.append("%s: plugins: %s is not a plugin of this repo" % (p, ", ".join(unknown)))
        named |= set(plugins)
        print("change file %s: %s, %s: %s" % (p, ", ".join(plugins), level, line))
    for p in paths:
        if p == CHANGES + "/README.md" and (os.path.islink(os.path.join(repo, p)) or not os.path.isfile(os.path.join(repo, p))):
            bad.append("%s is gone or a symlink: it stays a regular file in %s/" % (p, CHANGES))
        elif p.startswith(CHANGES + "/") and p not in added and p != CHANGES + "/README.md" and show(repo, mb, p) is not None:
            judge_pending(repo, mb, p, removed, bad)
    if removed:
        pending_left(repo, mb, paths, removed, bad)
    for p in special_under_plugins(repo):
        bad.append("%s is a symlink or a submodule: what it points at would change with no path under plugins/ in a diff" % p)
    reset = base_carries_versions(repo, mb)
    for name in plugin_names(repo, mb):
        old, now = released_at(repo, mb, name), released_here(repo, name)
        if old != now and not reset and name not in removed:
            bad.append("plugin %s: released version %s here, %s on the merge-base: only a release PR moves the first `## ` heading "
                       "of plugins/%s/%s" % (name, now or "none", old or "none", name, CHANGELOG))
    if reset:
        print("the merge-base's manifests carry a version (%s): this PR retires them, the CHANGELOGs may reset" % ", ".join(reset))
    for name in touched:
        if name in removed:
            continue
        exists, _data = manifest_here(repo, name)
        had = show(repo, mb, "plugins/%s/%s" % (name, MANIFEST)) is not None
        if not exists and had:
            d = os.path.join(repo, "plugins", name)
            if os.path.isdir(d) and os.listdir(d):
                bad.append("plugin %s lost its manifest and still has files" % name)
        if name not in named:
            bad.append("plugin %s changed and no change file added by this change names it: add %s/<slug>.md "
                       "(plugins: %s, level: patch|minor|major, one line)" % (name, CHANGES, name))
        elif exists:
            print("plugin %s: %s, recorded in a change file: ok" % (name, "new" if not had else "changed"))
    if MARKETPLACE in paths:
        now = json_or_none(open(os.path.join(repo, MARKETPLACE), "rb").read()) if os.path.isfile(os.path.join(repo, MARKETPLACE)) else None
        raw = show(repo, mb, MARKETPLACE)
        old = json_or_none(raw) if raw is not None else None
        bad.extend(marketplace_drift(old, now, removed))


def full_ref(ref):
    """`origin/<x>` as the full remote-tracking ref: a pushed tag named `origin/<x>` (refs/tags/origin/<x>) must not stand in
    for the branch, and git resolves the short name to the tag first."""
    return "refs/remotes/" + ref if ref.startswith("origin/") else ref


def default_ref(repo):
    """The remote's default branch as `origin/<name>` (origin/HEAD when the clone records it, else origin/main)."""
    rc, out = git(repo, "symbolic-ref", "-q", "refs/remotes/origin/HEAD")       # the full name: --short can print a tag's spelling
    name = out.decode().strip()[len("refs/remotes/"):] if rc == 0 and out.startswith(b"refs/remotes/origin/") else ""
    return name or BASE_DEFAULT


def resolve(repo, ref):
    rc, out = git(repo, "rev-parse", "--verify", "--quiet", full_ref(ref) + "^{commit}")
    return out.decode().strip() if rc == 0 and out.strip() else None


def is_ancestor(repo, a, b):
    return git(repo, "merge-base", "--is-ancestor", a, b)[0] == 0


def branch_of(ref):
    """The branch a base ref names: `origin/release`, `refs/remotes/origin/release` and `release` are all `release`."""
    for prefix in ("refs/remotes/", "refs/heads/"):
        if ref.startswith(prefix):
            ref = ref[len(prefix):]
    return ref[len("origin/"):] if ref.startswith("origin/") else ref


def bump(v, level):
    """One step of `v` at `level`; a major on a 0.x version is a minor (SemVer lets 0.x break in a minor)."""
    x, y, z = vtuple(v)
    if level == "major" and x > 0:
        return "%d.0.0" % (x + 1)
    if level in ("major", "minor"):
        return "%d.%d.0" % (x, y + 1)
    return "%d.%d.%d" % (x, y, z + 1)


def plugin_names_at(repo, rev):
    """The plugin directories with a manifest at `rev`."""
    rc, out = git(repo, "ls-tree", "-r", "--name-only", "-z", rev, "--", "plugins")
    return sorted(set(p.split("/")[1] for p in out.decode("utf-8", "surrogateescape").split("\0")
                      if p.count("/") == 3 and p.endswith("/" + MANIFEST)))


def plugin_names(repo, rev):
    """The plugin directories with a manifest in the working tree and at `rev`."""
    return sorted(set(plugin_names_at(repo, rev)) | plugin_dirs(repo))


def any_version_moved(repo, rev):
    """Whether a plugin of the merge-base records a released version here that the merge-base does not (a new first `## X.Y.Z`): a
    release. Losing one (the reset, or a broken CHANGELOG), or a plugin new here, is not a release; the ordinary kind judges it."""
    for name in plugin_names_at(repo, rev):
        try:
            now = released_here(repo, name)
        except Bad:
            continue
        if now is not None and now != released_at(repo, rev, name):
            return True
    return False


def back_merge_tip(repo, base):
    """The commit a back-merge brings: HEAD, or the second parent of CI's test merge (a merge whose first parent is the base)."""
    rc, out = git(repo, "rev-list", "--parents", "-n", "1", "HEAD")
    parts = out.decode().split()
    if len(parts) == 3 and parts[1] == base:
        return parts[2]
    return parts[0] if parts else None


def worktree_clean(repo):
    rc, out = git(repo, "status", "--porcelain", "--untracked-files=normal", "--ignore-submodules=none")
    return rc == 0 and not out.strip()


def kind_of(repo, base_ref, base, mb):
    """bootstrap, hotfix, back-merge, release or ordinary (the docstring of this file says how each is told)."""
    if not ever_had(repo, base, CHANGES + "/README.md"):
        return "bootstrap"
    if branch_of(base_ref) == RELEASE:
        return "hotfix"
    rel = resolve(repo, RELEASE_REF)
    if rel:
        tip = back_merge_tip(repo, base)
        if tip and tip != mb and is_ancestor(repo, tip, rel) and not is_ancestor(repo, tip, base) and worktree_clean(repo):
            return "back-merge"
    return "release" if any_version_moved(repo, mb) else "ordinary"


def pending_on(repo, rev):
    """{path: text} of the change files `rev` holds (not README.md)."""
    rc, out = git(repo, "ls-tree", "-z", "--name-only", rev, CHANGES + "/")
    found = {}
    for p in out.decode("utf-8", "surrogateescape").split("\0"):
        if p and p != CHANGES + "/README.md":
            raw = show(repo, rev, p)
            found[p] = raw.decode("utf-8", "replace") if raw is not None else ""
    return found


def change_files_here(repo):
    """The paths under .changes/ in the working tree, README.md aside (whatever their form)."""
    d = os.path.join(repo, CHANGES)
    return sorted(CHANGES + "/" + n for n in os.listdir(d) if n != "README.md") if os.path.isdir(d) else []


def changelog_section(repo, name, version):
    """The lines under `## <version>` in plugins/<name>/CHANGELOG.md, or None when that heading is not there."""
    path = os.path.join(repo, "plugins", name, CHANGELOG)
    if os.path.islink(path) or not os.path.isfile(path):
        return None
    with open(path, encoding="utf-8", errors="replace") as f:
        lines = f.read().split("\n")
    try:
        at = lines.index("## " + version)
    except ValueError:
        return None
    out = []
    for line in lines[at + 1:]:
        if line.startswith("## "):
            break
        out.append(line.rstrip())
    return out


def entry(level, line):
    return "- %s: %s" % (level, line)


def same_but(old, new, pattern):
    """Whether two texts are equal once every match of `pattern` (a compiled regex) is blanked, line count included."""
    if old is None or new is None:
        return False
    return pattern.sub("", old) == pattern.sub("", new) and old.count("\n") == new.count("\n")


def text_at(repo, rev, path):
    raw = show(repo, rev, path)
    return raw.decode("utf-8", "replace") if raw is not None else None


def text_here(repo, path):
    full = os.path.join(repo, path)
    if os.path.islink(full) or not os.path.isfile(full):
        return None
    with open(full, encoding="utf-8", errors="replace") as f:
        return f.read()


def release_scope(repo, mb, paths, bad):
    """A release PR changes only what a release changes (the docstring's list)."""
    for p in paths:
        parts = p.split("/")
        if p.startswith(CHANGES + "/"):
            if p != CHANGES + "/README.md" and not os.path.lexists(os.path.join(repo, p)):
                continue                                    # a consumed change file
            bad.append("%s: a release adds or edits no change file, it only consumes them" % p)
        elif len(parts) == 3 and parts[0] == "plugins" and parts[2] == CHANGELOG:
            if os.path.islink(os.path.join(repo, p)):
                bad.append("%s is a symlink" % p)
        elif len(parts) == 3 and parts[0] == "plugins" and parts[2] == CONTRACT:
            if not same_but(text_at(repo, mb, p), text_here(repo, p), FROZEN):
                bad.append("%s: a release changes only its `Frozen at` line" % p)
        else:
            bad.append("%s: a release PR changes only CHANGELOG.md, the consumed change files and `Frozen at` (no manifest, no "
                       "kb page); ship this change in an ordinary PR first" % p)


def judge_release(repo, base_ref, base, mb, paths, bad):
    rel = resolve(repo, RELEASE_REF)
    if rel and not is_ancestor(repo, rel, "HEAD"):
        bad.append("%s is not an ancestor of HEAD: a hotfix on it is not on main yet; merge its back-merge PR first, then "
                   "branch the release again" % RELEASE_REF)
    levels, lines = {}, {}
    for p, text in sorted(pending_on(repo, base).items()):
        try:
            plugins, level, line = read_change(text)
        except Bad as e:
            bad.append("%s on %s: %s" % (p, base_ref, e))
            continue
        for name in plugins:
            levels[name] = max(levels.get(name, level), level, key=LEVELS.index)
            lines.setdefault(name, []).append(entry(level, line))
        print("ships %s: %s, %s: %s" % (p, ", ".join(plugins), level, line))
    for p in change_files_here(repo):
        bad.append("%s is in .changes/: a release consumes every pending change file and adds none (when main moved, merge "
                   "it and cut again)" % p)
    readme = os.path.join(repo, CHANGES, "README.md")
    if os.path.islink(readme) or not os.path.isfile(readme):
        bad.append("%s/README.md is gone or a symlink: it stays" % CHANGES)
    names = plugin_names(repo, base)
    for name in sorted(set(levels) - set(names)):
        bad.append("a pending change file names %s, which has no plugins/%s/ manifest: a release cannot ship it (fix the change "
                   "file, or add the plugin, in an ordinary PR)" % (name, name))
    for name in names:
        old, now = released_at(repo, base, name), released_here(repo, name)
        exists = manifest_here(repo, name)[0]
        if name in levels:
            if show(repo, base, "plugins/%s/%s" % (name, MANIFEST)) is None or not exists:
                bad.append("plugin %s: a change file names it but it has no manifest on %s and here" % (name, base_ref))
                continue
            want = bump(old, levels[name]) if old else FIRST_RELEASE
            if now != want:
                bad.append("plugin %s: %s -> %s; the change files ask %s: %s" % (
                    name, old or "unreleased", now or "unreleased",
                    "one %s step" % levels[name] if old else "its first release", want))
                continue
            section = changelog_section(repo, name, now)
            if section is None:
                bad.append("plugins/%s/%s has no `## %s` entry" % (name, CHANGELOG, now))
                continue
            missing = [l for l in lines[name] if l not in section]
            if missing:
                bad.append("plugins/%s/%s `## %s` lacks %d shipped line(s), first: %s" % (name, CHANGELOG, now, len(missing), missing[0]))
            else:
                print("plugin %s: %s -> %s (%s), %d line(s) in its CHANGELOG: ok"
                      % (name, old or "unreleased", now, levels[name], len(lines[name])))
        elif now != old:
            bad.append("plugin %s: %s -> %s, and no pending change file names it: a release raises only what it ships"
                       % (name, old or "unreleased", now or "unreleased"))
    release_scope(repo, mb, paths, bad)
    for p in special_under_plugins(repo):
        bad.append("%s is a symlink or a submodule" % p)


def added_in_commits(repo, mb):
    """[(path, text)] of each change file a commit in mb..HEAD added (merges are not diffed), with its last text: the one before
    the commit that removed it (the cut), else the working tree's."""
    rc, out = git(repo, "log", "--format=", "--diff-filter=A", "--name-only", "--no-renames", "%s..HEAD" % mb, "--", CHANGES + "/")
    found = []
    for p in sorted(set(l for l in out.decode("utf-8", "surrogateescape").split("\n") if l.strip() and l != CHANGES + "/README.md")):
        rc, gone = git(repo, "log", "-1", "--format=%H", "--diff-filter=D", "--no-renames", "%s..HEAD" % mb, "--", p)
        text = show(repo, gone.decode().strip() + "^", p) if gone.strip() else (text_here(repo, p) or "").encode()
        found.append((p, (text or b"").decode("utf-8", "replace")))
    return found


def main_commits(repo, base):
    """How many commits HEAD holds that are on the default branch and not on `base` (a hotfix branched from main carries them)."""
    main = resolve(repo, default_ref(repo))
    if not main:
        print("hotfix base check not run: %s does not resolve (no origin/HEAD and no origin/main here)" % default_ref(repo))
        return 0
    counts = [git(repo, "rev-list", "--count", "HEAD", "^" + base, *extra)[1].decode().strip() for extra in ((), ("^" + main,))]
    return int(counts[0] or 0) - int(counts[1] or 0)


def judge_hotfix(repo, base_ref, base, mb, paths, touched, bad):
    carried = main_commits(repo, base)
    if carried:
        bad.append("HEAD holds %d commit(s) of %s that %s lacks: a hotfix branches from %s, so unreleased work never rides it"
                   % (carried, default_ref(repo), base_ref, base_ref))
    named = {}
    for p, text in added_in_commits(repo, mb):
        try:
            plugins, level, line = read_change(text)
        except Bad as e:
            bad.append("%s: %s" % (p, e))
            continue
        if level != "patch":
            bad.append("%s: level %s; a hotfix is a patch (a feature waits for the next release)" % (p, level))
        for name in plugins:
            named.setdefault(name, []).append(entry(level, line))
        print("hotfix change file %s: %s, %s: %s" % (p, ", ".join(plugins), level, line))
    for p in change_files_here(repo):
        if show(repo, base, p) is None:
            bad.append("%s is left in .changes/: the hotfix consumes its change file into the CHANGELOG (release.py cut --hotfix)" % p)
    for name in touched:
        if show(repo, base, "plugins/%s/%s" % (name, MANIFEST)) is None:
            bad.append("plugin %s is not on %s: a hotfix adds no plugin" % (name, base_ref))
            continue
        if not manifest_here(repo, name)[0]:
            bad.append("plugin %s lost its manifest in a hotfix" % name)
            continue
        old, now = released_at(repo, base, name), released_here(repo, name)
        if old is None:
            bad.append("plugin %s was never released on %s: a hotfix patches a release" % (name, base_ref))
            continue
        want = bump(old, "patch")
        if now != want:
            bad.append("plugin %s changed: a hotfix raises it one patch above %s on %s, to %s (it is %s)" % (name, old, base_ref, want, now))
            continue
        if name not in named:
            bad.append("plugin %s: no change file of this hotfix names it" % name)
            continue
        section = changelog_section(repo, name, now) or []
        missing = [l for l in named[name] if l not in section]
        if missing:
            bad.append("plugins/%s/%s `## %s` lacks: %s" % (name, CHANGELOG, now, missing[0]))
        else:
            print("plugin %s: %s -> %s (hotfix): ok" % (name, old, now))
    for name in sorted(set(named) - set(touched)):
        bad.append("a hotfix change file names %s, which this hotfix does not change" % name)
    if MARKETPLACE in paths:
        bad.append("%s changes in a hotfix: a hotfix only fixes" % MARKETPLACE)
    for p in special_under_plugins(repo):
        bad.append("%s is a symlink or a submodule" % p)


def judge_back_merge(repo, bad):
    rel = resolve(repo, RELEASE_REF)
    for name in sorted(plugin_dirs(repo)):
        theirs, now = released_at(repo, rel, name), released_here(repo, name)
        if theirs is not None and now != theirs:
            bad.append("plugin %s: %s here, %s on %s: a back-merge brings %s's versions" % (name, now, theirs, RELEASE_REF, RELEASE_REF))
        elif theirs is not None:
            print("plugin %s: %s, as on %s: ok" % (name, now, RELEASE_REF))


def check(repo, given):
    base_ref = given or (("origin/" + os.environ["GITHUB_BASE_REF"]) if os.environ.get("GITHUB_BASE_REF") else BASE_DEFAULT)
    base = resolve(repo, base_ref)
    if base is None:
        if given:
            print("red: base ref %s does not resolve" % given)
            return 1
        return not_run("%s does not resolve" % base_ref)
    rc, out = git(repo, "merge-base", "HEAD", base)
    if rc != 0 or not out.strip():
        return not_run("HEAD and %s share no history (a shallow clone?)" % base_ref)
    mb = out.decode().strip()
    paths, added = changed(repo, mb)
    touched = plugins_touched(paths)
    bad = []
    kind = kind_of(repo, base_ref, base, mb)
    if kind == "bootstrap":
        print("kind: bootstrap (the history of %s never held %s/README.md)" % (base_ref, CHANGES))
        for name in touched:
            try:
                judge_bootstrap(repo, base, base_ref, name, bad)
            except Bad as e:
                bad.append("plugin %s: %s" % (name, e))
    else:
        print({"hotfix": "kind: hotfix (into %s)",
               "back-merge": "kind: back-merge (%s brings " + RELEASE_REF + ")",
               "release": "kind: release (a released version moves against %s; only a release PR, skill `release`, moves one)",
               "ordinary": "kind: ordinary (against %s)"}[kind] % base_ref)
        try:
            if kind == "hotfix":
                judge_hotfix(repo, base_ref, base, mb, paths, touched, bad)
            elif kind == "back-merge":
                judge_back_merge(repo, bad)
            elif kind == "release":
                judge_release(repo, base_ref, base, mb, paths, bad)
            else:
                judge_ordinary(repo, mb, paths, added, touched, bad)
        except Bad as e:
            bad.append(str(e))
        check_no_versions(repo, bad)
    for b in bad:
        print("red: " + b)
    if not bad and not touched:
        print("ok: no file under plugins/<name>/ changed against %s" % base_ref)
    return 1 if bad else 0


def not_run(why):
    if os.environ.get("GITHUB_ACTIONS"):
        print("red: the version check cannot run (%s), and in CI a check that did not run must not pass" % why)
        return 1
    print("version check not run: %s" % why)
    return 3


class Refused(Exception):
    pass


def surface_of(text):
    if text is None or text.count(SURFACE[0]) != 1 or text.count(SURFACE[1]) != 1:
        return None
    return text[text.index(SURFACE[0]) + len(SURFACE[0]):text.index(SURFACE[1])].strip()


def compute(repo, hotfix, base):
    """What a cut does here: ({name: (old, new, level, [entry lines])}, [change file paths], {contract path: new Frozen at}).
    Raises Refused with the reason when a change file is broken, names an unknown plugin, or a hotfix asks more than a patch."""
    known = change_names(repo)
    files, by = [], {}
    for p in change_files_here(repo):
        full = os.path.join(repo, p)
        name = p[len(CHANGES) + 1:]
        if os.path.islink(full) or not os.path.isfile(full) or not CHANGE_NAME.fullmatch(name):
            raise Refused("%s is not a change file (%s/<a-z0-9 . _ ->.md, a regular file)" % (p, CHANGES))
        try:
            with open(full, encoding="utf-8") as f:
                plugins, level, line = read_change(f.read())
        except (Bad, OSError, UnicodeDecodeError) as e:
            raise Refused("%s: %s" % (p, e))
        unknown = [x for x in plugins if x not in known]
        if unknown:
            raise Refused("%s names %s, not a plugin of this repo" % (p, ", ".join(unknown)))
        if hotfix and level != "patch":
            raise Refused("%s: level %s; a hotfix is a patch" % (p, level))
        files.append(p)
        for n in plugins:
            by.setdefault(n, []).append((level, line))
    plan = {}
    for n, items in sorted(by.items()):
        if not manifest_here(repo, n)[0]:
            raise Refused("plugin %s is named by a change file and has no manifest here" % n)
        old = released_here(repo, n)
        if hotfix and old is None:
            raise Refused("plugin %s was never released: a hotfix patches a release" % n)
        level = max((l for l, _ in items), key=LEVELS.index)
        plan[n] = (old, bump(old, level) if old else FIRST_RELEASE, level, [entry(l, t) for l, t in items])
    frozen = {}
    released_ref = release_ref(repo)
    for n in sorted(plugin_dirs(repo)):
        ref = released_ref or last_release_commit(repo, base, n) or base
        rel = "plugins/%s/%s" % (n, CONTRACT)
        here = surface_of(text_here(repo, rel))
        if here is None:
            continue
        if n in plan and plan[n][0] is None:
            frozen[rel] = plan[n][1]                    # the first release freezes the contract anew, whatever came before
            continue
        if here == surface_of(text_at(repo, ref, rel)):
            continue
        if hotfix:
            raise Refused("%s: the surface differs from %s; a hotfix does not change the contract" % (rel, RELEASE_REF))
        if n not in plan or plan[n][2] == "patch":
            raise Refused("%s: the surface differs from %s, and no change file names %s at minor or above"
                          % (rel, RELEASE_REF if ref != base else "the base", n))
        frozen[rel] = plan[n][1]
    return plan, files, frozen


def show_plan(plan, files, frozen):
    for p in files:
        print("consume %s" % p)
    for n, (old, new, level, lines) in sorted(plan.items()):
        print("plugin %s: %s -> %s (%s), %d CHANGELOG line(s)" % (n, old or "unreleased", new, level if old else "first release",
                                                                 len(lines)))
    for rel, v in sorted(frozen.items()):
        print("%s: Frozen at -> %s (the surface moved since the last release, or the first release)" % (rel, v))


def base_for(hotfix, given):
    return given or (RELEASE_REF if hotfix else BASE_DEFAULT)


def do_plan(repo, hotfix, given):
    base_ref = base_for(hotfix, given)
    base = resolve(repo, base_ref) or "HEAD"
    try:
        plan, files, frozen = compute(repo, hotfix, base)
    except (Refused, Bad) as e:
        print("red: %s" % e)
        return 1
    if not files:
        print("nothing pending: no change file in %s/" % CHANGES)
        return 0
    show_plan(plan, files, frozen)
    print("plan only: nothing written (release.py cut%s does it)" % (" --hotfix" if hotfix else ""))
    return 0


def write_changelog(repo, name, version, lines):
    path = os.path.join(repo, "plugins", name, CHANGELOG)
    block = "## %s\n\n%s\n\n" % (version, "\n".join(lines))
    if os.path.isfile(path):
        with open(path, encoding="utf-8") as f:
            text = f.read()
        m = re.search(r"^## ", text, re.M)
        text = text[:m.start()] + block + text[m.start():] if m else text.rstrip("\n") + "\n\n" + block
    else:
        text = "# Changelog of %s\n\nNewest first.\n\n%s" % (name, block)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text.rstrip("\n") + "\n")


def do_cut(repo, hotfix, given):
    base_ref = base_for(hotfix, given)
    try:
        base = resolve(repo, base_ref)
        if base is None:
            raise Refused("%s does not resolve: fetch it first" % base_ref)
        if not worktree_clean(repo):
            raise Refused("the working tree is not clean: commit or remove what is there first")
        rc, out = git(repo, "symbolic-ref", "--short", "-q", "HEAD")
        branch = out.decode().strip()
        if rc != 0 or not branch:
            raise Refused("HEAD is detached: cut on a branch of its own")
        default = branch_of(default_ref(repo))
        if branch in (RELEASE, branch_of(base_ref), default):
            raise Refused("on branch %s: cut on a branch of its own, cut from %s" % (branch, base_ref))
        if not is_ancestor(repo, base, "HEAD"):
            raise Refused("HEAD does not hold the tip of %s: branch from it (or merge it) and cut again" % base_ref)
        if hotfix and base_carries_versions(repo, base):
            raise Refused("the manifests on %s carry a version (%s): that %s predates the version reset; the first public "
                          "release comes from main" % (base_ref, ", ".join(base_carries_versions(repo, base)), RELEASE))
        if hotfix and main_commits(repo, base):
            raise Refused("HEAD holds commits of %s that %s lacks: branch the hotfix from %s" % (default_ref(repo), base_ref, base_ref))
        rel = resolve(repo, RELEASE_REF)
        if not hotfix and rel and not is_ancestor(repo, rel, "HEAD"):
            raise Refused("%s holds a hotfix that HEAD lacks: merge its back-merge PR into main first" % RELEASE_REF)
        plan, files, frozen = compute(repo, hotfix, base)
        if not files:
            raise Refused("nothing pending: no change file in %s/" % CHANGES)
    except (Refused, Bad) as e:
        print("cut refused: %s" % e)
        return 1
    show_plan(plan, files, frozen)
    for n, (old, new, level, lines) in sorted(plan.items()):
        write_changelog(repo, n, new, lines)
    for p in files:
        os.remove(os.path.join(repo, p))
    for rel, v in frozen.items():
        full = os.path.join(repo, rel)
        with open(full, encoding="utf-8") as f:
            text = f.read()
        with open(full, "w", encoding="utf-8") as f:
            f.write(FROZEN.sub("Frozen at: " + v, text, count=1))
    print("cut: written, nothing committed. Next: release.py check --base %s, then commit and open the PR (skill release)" % base_ref)
    return 0


def main(argv):
    sys.stdout.reconfigure(errors="backslashreplace")       # a plugin directory whose name is not UTF-8 is still named, not a crash
    if not argv or argv[0] not in ("check", "plan", "cut"):
        sys.stderr.write(__doc__)
        return 64
    cmd, repo, base, hotfix, rest = argv[0], ".", "", False, argv[1:]
    while rest:
        if rest[0] in ("--repo", "--base") and len(rest) >= 2 and not (cmd == "plan" and rest[0] == "--base"):
            if rest[0] == "--repo":
                repo = rest[1]
            else:
                base = rest[1]
            rest = rest[2:]
        elif rest[0] == "--hotfix" and cmd != "check":
            hotfix, rest = True, rest[1:]
        else:
            sys.stderr.write(__doc__)
            return 64
    try:
        if cmd == "plan":
            return do_plan(repo, hotfix, base)
        if cmd == "cut":
            return do_cut(repo, hotfix, base)
        return check(repo, base)
    except Bad as e:
        print("red: %s" % e)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
