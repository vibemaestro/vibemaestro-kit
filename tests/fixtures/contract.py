#!/usr/bin/env python3
"""Reader of the plugin's consumer contract (plugins/vibemaestro-sdlc/CONTRACT.md) for tests/test-contract.sh.

    contract.py json <CONTRACT.md>                 the tables between the surface markers, as JSON:
                                                   {frozen_at, items:[[id, frozen, proof]], facts:[[id, fact, value]],
                                                    codes:[[entry, rc, meaning]], keys:[key], deps:[[call, holds]]}
    contract.py schema-keys <plugin scripts dir>   the leaf keys of sdlc_config.SCHEMA_TREE, one per line
    contract.py base-check <repo dir> [<base ref>] the change rule of the surface against a base ref (see base_check)
    contract.py version <plugin dir>               the plugin's version: its manifest `version` (a bootstrap-era manifest), else
                                                   its released version (the CHANGELOG's first `## X.Y.Z`), else `unreleased`
    contract.py defaults-config <plugin scripts dir> a schema-1 config that sets every key to the plugin's default, as JSON
    contract.py config-keys <config.json>          the leaf keys a config file sets, one per line (objects recursed)

rc 0 ok, 1 red (base-check: the rule is broken, or CONTRACT_BASE names a ref that does not resolve), 3 base-check did not run
(no CONTRACT_BASE and no origin/main), 64 usage, 65 the contract does not parse. Reads only; the plugin module is imported with bytecode off, so nothing is written next to it.
"""
import json
import os
import re
import subprocess
import sys

CONTRACT_REL = "plugins/vibemaestro-sdlc/CONTRACT.md"
MANIFEST_REL = "plugins/vibemaestro-sdlc/.claude-plugin/plugin.json"
CHANGELOG_REL = "plugins/vibemaestro-sdlc/CHANGELOG.md"
BEGIN, END = "<!-- surface:begin -->", "<!-- surface:end -->"
SECTIONS = {"## Items": "items", "## Facts": "facts", "## Exit codes": "codes", "## Config keys of schema 1": "keys",
            "## Dependent calls": "deps"}
WIDTH = {"items": 3, "facts": 3, "codes": 3, "keys": 1, "deps": 2}
HEADERS = {"items": ["id", "frozen", "proof"], "facts": ["id", "fact", "value"], "codes": ["entry point", "rc", "meaning"],
           "keys": ["key"], "deps": ["call", "holds"]}
OPTIONAL = {"deps"}                 # a base older than the section has none; an empty one is the family's to refuse


class Bad(Exception):
    pass


def surface(text):
    """The text between the two markers (exactly one pair, in order)."""
    if text.count(BEGIN) != 1 or text.count(END) != 1 or text.index(BEGIN) > text.index(END):
        raise Bad("the surface markers are missing, repeated or out of order")
    return text[text.index(BEGIN) + len(BEGIN):text.index(END)]


def cell(c):
    c = c.strip()
    return c[1:-1] if len(c) >= 2 and c[0] == "`" and c[-1] == "`" else c


def parse(text):
    m = re.search(r"^Frozen at: (\d+\.\d+\.\d+)$", text, re.M)
    if not m or len(re.findall(r"^Frozen at:", text, re.M)) != 1:
        raise Bad("no single 'Frozen at: X.Y.Z' line")
    out = {"frozen_at": m.group(1), "items": [], "facts": [], "codes": [], "keys": [], "deps": []}
    sect, seen = None, set()
    for line in surface(text).splitlines():
        if line.startswith("## "):
            sect = SECTIONS.get(line.strip())
            if sect is None:
                raise Bad("unknown section in the surface: %s" % line.strip())
            seen.add(sect)
            continue
        if not line.startswith("|") or sect is None:
            continue
        inner = line.strip().strip("|")
        cells = [cell(c.replace("\\|", "|")) for c in re.split(r"(?<!\\)\|", inner)]   # `\|` is a pipe inside a cell
        if all(re.fullmatch(r":?-+:?", c) for c in cells):
            continue
        if cells == HEADERS[sect]:                            # the section's header row
            continue
        if len(cells) != WIDTH[sect]:
            raise Bad("a %s row has %d cells, not %d: %s" % (sect, len(cells), WIDTH[sect], line.strip()))
        out[sect].append(cells[0] if sect == "keys" else cells)
    missing = set(SECTIONS.values()) - seen - OPTIONAL
    if missing:
        raise Bad("sections missing from the surface: %s" % ", ".join(sorted(missing)))
    return out


def load_config_module(scripts_dir):
    sys.dont_write_bytecode = True
    sys.path.insert(0, scripts_dir)
    import sdlc_config  # noqa: E402  (the copy under test)
    return sdlc_config


def schema_keys(scripts_dir):
    sdlc_config = load_config_module(scripts_dir)
    keys = []

    def walk(tree, prefix):
        for k, node in tree.items():
            if isinstance(node, tuple) and node and node[0] == "obj":
                walk(node[1], prefix + k + ".")
            else:
                keys.append(prefix + k)
    walk(sdlc_config.SCHEMA_TREE, "")
    return keys


def defaults_config(scripts_dir):
    """The plugin's own defaults, written out: every key of the schema set, so a type change of any key is seen by the
    config check (a missing file would only read defaults and never type-check them)."""
    return load_config_module(scripts_dir).defaults()


def config_keys(data, prefix=""):
    """Leaf keys a config sets: every non-empty dict is recursed, every other value is a leaf. That matches the schema's
    leaves for the defaults config today (a `null`-or-object key is null by default); a key whose default became a non-empty
    dict, or an object whose default is `{}`, would make the suite's comparison fail, which is loud, not silent."""
    out = []
    for k, v in data.items():
        if isinstance(v, dict) and v:
            out += config_keys(v, prefix + k + ".")
        else:
            out.append(prefix + k)
    return out


def vtuple(v):
    if not re.fullmatch(r"\d+\.\d+\.\d+", v or ""):
        raise Bad("not a version X.Y.Z: %r" % (v,))
    return tuple(int(x) for x in v.split("."))


def git(repo, *args):
    p = subprocess.run(["git", "-C", repo] + list(args), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    return p.returncode, p.stdout.decode("utf-8", "replace")


def released_of(text):
    """The released version a CHANGELOG records: its first `## ` heading when that is X.Y.Z, else None (as release.py reads it)."""
    for line in (text or "").split("\n"):
        if line.startswith("## "):
            v = line[3:].strip()
            return v if re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", v) else None
    return None


def plugin_version(manifest_text, changelog_text):
    """The manifest's `version` when it carries one (before the version reset), else the CHANGELOG's released version, else None."""
    try:
        m = json.loads(manifest_text) if manifest_text else None
    except ValueError:
        m = None
    if isinstance(m, dict) and isinstance(m.get("version"), str):
        return m["version"]
    return released_of(changelog_text)


def version_at(repo, rev):
    """plugin_version of the contract's plugin at `rev`, or "" when the manifest is not there."""
    rc, man = git(repo, "show", "%s:%s" % (rev, MANIFEST_REL))
    if rc != 0:
        return ""
    rc, cl = git(repo, "show", "%s:%s" % (rev, CHANGELOG_REL))
    return plugin_version(man, cl if rc == 0 else None)


def version_here(repo):
    texts = []
    for rel in (MANIFEST_REL, CHANGELOG_REL):
        try:
            with open(os.path.join(repo, rel), encoding="utf-8") as f:
                texts.append(f.read())
        except OSError:
            texts.append(None)
    return plugin_version(*texts)


def base_ref_name(given):
    """The base ref: CONTRACT_BASE (given), else origin/$GITHUB_BASE_REF (the PR's base in CI, `release` for a hotfix), else origin/main."""
    return given or ("origin/" + os.environ["GITHUB_BASE_REF"] if os.environ.get("GITHUB_BASE_REF") else "origin/main")


def resolve_base(repo, given):
    """CONTRACT_BASE (given) > merge-base of HEAD and the base ref (base_ref_name) > the base ref's tip (a depth-1 CI checkout of a
    PR merge ref, where the merge base is not in the history but the merge ref IS the base plus the PR) > none."""
    full = lambda r: "refs/remotes/" + r if r.startswith("origin/") else r     # never a tag named origin/<x>
    if given:
        rc, out = git(repo, "rev-parse", "--verify", "--quiet", full(given) + "^{commit}")
        return (out.strip(), "CONTRACT_BASE=%s" % given) if rc == 0 else ("", "CONTRACT_BASE=%s does not resolve" % given)
    ref = base_ref_name(given)
    rc, out = git(repo, "merge-base", "HEAD", full(ref))
    if rc == 0 and out.strip():
        return out.strip(), "merge-base of HEAD and %s" % ref
    rc, out = git(repo, "rev-parse", "--verify", "--quiet", full(ref) + "^{commit}")
    if rc == 0 and out.strip():
        return out.strip(), "%s tip (no merge base in this history)" % ref
    return None, "%s does not resolve" % ref


def identities(t):
    """What a breaking change removes: item ids, (id, fact, value) facts, (entry, rc) codes, keys, (call, holds) dependent calls.
    Wording is not identity, except for a dependent call: what it holds is what a dependent relies on."""
    return {("item", r[0]) for r in t["items"]} | {("fact",) + tuple(r) for r in t["facts"]} | \
        {("code", r[0], r[1]) for r in t["codes"]} | {("key", k) for k in t["keys"]} | {("dep",) + tuple(r) for r in t["deps"]}


LEVELS = ("patch", "minor", "major")


def release_module(repo):
    """The plugin's own release.py (change files, the kinds of a change), so this check and it never disagree."""
    import importlib.util
    path = os.path.join(repo, "plugins", "vibemaestro-sdlc", "scripts", "release.py")
    if not os.path.isfile(path):        # a scratch repo holding only the contract and the manifest: this checkout's release.py
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "plugins", "vibemaestro-sdlc", "scripts", "release.py")
    spec = importlib.util.spec_from_file_location("release_for_contract", path)
    mod = importlib.util.module_from_spec(spec)
    sys.dont_write_bytecode = True
    spec.loader.exec_module(mod)
    return mod


def added_changes(repo, base, plugin):
    """(level, line) of each change file under .changes/ that the working tree has and the base has not, naming `plugin`.
    A change file is read by the plugin's own release.py (`read_change`), so the two never disagree on its form."""
    mod = release_module(repo)
    d = os.path.join(repo, ".changes")
    found = []
    for name in sorted(os.listdir(d)) if os.path.isdir(d) else []:
        rel = ".changes/" + name
        if name == "README.md" or not name.endswith(".md") or git(repo, "cat-file", "-e", "%s:%s" % (base, rel))[0] == 0:
            continue
        if os.path.islink(os.path.join(d, name)):         # a symlink's record could change with no change to it: not counted
            continue
        try:
            with open(os.path.join(d, name), encoding="utf-8") as f:
                plugins, level, line = mod.read_change(f.read())
        except (OSError, ValueError, mod.Bad):
            continue
        if plugin in plugins:
            found.append((level, line))
    return found


def base_check(repo, given):
    """The change rule of the surface. On a base whose history ever held `.changes/README.md` (as release.py decides it): a surface
    that differs from the base's needs a change file added by this change that names the plugin at `minor` or above, `major`
    when it lost an identity (a removed or renamed item, fact, code or key), and `Frozen at` stays the base's (the release moves
    it). On a base without `.changes/` (the bootstrap): the surface needs a manifest version above the base's and `Frozen at`
    equal to it, a higher MAJOR when it lost an identity. A base without a contract has an empty surface (the contract starts
    at the version that adds it). A change file that is a symlink is not counted."""
    base, how = resolve_base(repo, given)
    if base == "":                              # an explicit base that does not resolve is a mistake, not a missing base
        print("red: %s" % how)
        return 1
    if base is None:
        print("base check not run: %s" % how)
        return 3
    with open(os.path.join(repo, CONTRACT_REL), encoding="utf-8") as f:
        cur_text = f.read()
    cur_ver = version_here(repo)
    cur = parse(cur_text)
    rc, base_text = git(repo, "show", "%s:%s" % (base, CONTRACT_REL))
    base_t = parse(base_text) if rc == 0 else None
    base_ver = version_at(repo, base)
    if base_ver == "":
        print("red: the base %s has no %s" % (base[:12], MANIFEST_REL))
        return 1
    print("base: %s (%s), version %s -> %s" % (base[:12], how, base_ver or "unreleased", cur_ver or "unreleased"))
    same = base_t is not None and surface(base_text).strip() == surface(cur_text).strip()
    lost = sorted(identities(base_t) - identities(cur)) if base_t else []
    if git(repo, "log", "-1", "--full-history", "--format=%H", base, "--", ".changes/README.md")[1].strip():
        ref = base_ref_name(given)
        mod = release_module(repo)
        kind = mod.kind_of(repo, ref, mod.resolve(repo, ref) or base, base)
        print("kind: %s" % kind)
        if kind in ("hotfix", "back-merge"):
            return carried_check(kind, cur, base_t, same)
        if kind == "release":
            return release_check(repo, base, cur, cur_text, cur_ver, base_t, base_ver)
        return change_file_check(repo, base, cur, cur_ver, base_t, base_ver, same, lost)
    if same:
        print("ok: the surface is the base's")
        return 0
    bad = []
    if vtuple(cur_ver)[:2] <= vtuple(base_ver)[:2]:
        bad.append("the surface changed without at least a minor version bump (manifest %s, base %s)" % (cur_ver, base_ver))
    if cur["frozen_at"] != cur_ver:
        bad.append("the surface changed and 'Frozen at' is %s, not the manifest version %s" % (cur["frozen_at"], cur_ver))
    if lost and vtuple(cur_ver)[0] <= vtuple(base_ver)[0]:
        bad.append("the surface lost %d row(s) without a major bump, first: %s" % (len(lost), " ".join(lost[0])))
    for b in bad:
        print("red: " + b)
    if not bad:
        print("ok: the surface changed with a version bump to %s and 'Frozen at' %s" % (cur_ver, cur["frozen_at"]))
    return 1 if bad else 0


def change_file_check(repo, base, cur, cur_ver, base_t, base_ver, same, lost):
    bad = []
    if base_t is not None and cur["frozen_at"] != base_t["frozen_at"] and cur_ver == base_ver:
        bad.append("'Frozen at' moved from %s to %s outside a release: the release that ships the change moves it"
                   % (base_t["frozen_at"], cur["frozen_at"]))
    if not same:
        need = "major" if lost else "minor"
        with open(os.path.join(repo, MANIFEST_REL), encoding="utf-8") as f:
            plugin = json.load(f)["name"]
        changes = added_changes(repo, base, plugin)
        levels = [level for level, _ in changes]
        best = max(levels, key=LEVELS.index) if levels else None
        if best is None or LEVELS.index(best) < LEVELS.index(need):
            why = ("lost %d row(s), first: %s" % (len(lost), " ".join(lost[0]))) if lost else "changed"
            bad.append("the surface %s and no change file added under .changes/ names %s at %s or above (found: %s)"
                       % (why, plugin, need, ", ".join(levels) or "none"))
        else:
            print("ok: the surface changed and a change file names %s at %s (needs %s)" % (plugin, best, need))
        for call in unnamed_calls(lost, [line for _, line in changes]):
            bad.append("the dependent call `%s` was removed or changed and no change file added under .changes/ names it "
                       "(its line holds the call in backticks)" % call)
    elif not bad:
        print("ok: the surface is the base's")
    for b in bad:
        print("red: " + b)
    return 1 if bad else 0


def unnamed_calls(lost, lines):
    """The calls of the lost dependent-call rows that no added change file's line names in backticks, each once, in order."""
    out = []
    for ident in lost:
        call = ident[1] if ident[0] == "dep" else None
        if call is not None and call not in out and not any("`%s`" % call in line for line in lines):
            out.append(call)
    return out


def carried_check(kind, cur, base_t, same):
    """A hotfix (into `release`) and a back-merge (from it) carry no surface change and leave `Frozen at` alone: a surface change
    waits for the next release."""
    bad = []
    if not same:
        bad.append("the surface changed in a %s: a contract change ships in a release, not a %s" % (kind, kind))
    if base_t is not None and cur["frozen_at"] != base_t["frozen_at"]:
        bad.append("'Frozen at' moved from %s to %s in a %s" % (base_t["frozen_at"], cur["frozen_at"], kind))
    for b in bad:
        print("red: " + b)
    if not bad:
        print("ok: a %s with the base's surface and 'Frozen at'" % kind)
    return 1 if bad else 0


def release_check(repo, base, cur, cur_text, cur_ver, base_t, base_ver):
    """A release, against the last release (origin/release, else the base): a surface that differs needs the version raised at
    least a minor above it (a major when it lost an identity) and 'Frozen at' set to the new version; a surface that does not
    leaves 'Frozen at' as the base has it. The first public release (the base has no released version: the numbering restarted)
    is compared with nothing before it: it sets 'Frozen at' to its own version."""
    if not base_ver:
        if cur_ver != cur["frozen_at"]:
            print("red: a first release (the base has no released version) sets 'Frozen at' to its version %s; it is %s"
                  % (cur_ver, cur["frozen_at"]))
            return 1
        print("ok: a first release, 'Frozen at' %s" % cur_ver)
        return 0
    rc, ref = git(repo, "rev-parse", "--verify", "--quiet", "refs/remotes/origin/release^{commit}")
    ref, what = (ref.strip(), "origin/release") if rc == 0 and ref.strip() else (base, "the base")
    rc, rel_manifest = git(repo, "show", "%s:%s" % (ref, MANIFEST_REL))
    if what == "origin/release" and rc == 0 and '"version"' in rel_manifest:
        # origin/release predates the version reset (its number is not a released version): the last release is the commit that
        # wrote the base's released version
        last = release_module(repo).last_release_commit(repo, base, "vibemaestro-sdlc")
        ref, what = (last, "the last release %s" % last[:12]) if last else (base, "the base")
    rc, ref_text = git(repo, "show", "%s:%s" % (ref, CONTRACT_REL))
    ref_t = parse(ref_text) if rc == 0 else None
    ref_ver = version_at(repo, ref)
    if ref_ver == "":
        print("red: %s has no %s" % (what, MANIFEST_REL))
        return 1
    ref_ver = ref_ver or base_ver
    bad = []
    if ref_t is not None and surface(ref_text).strip() == surface(cur_text).strip():
        if base_t is not None and cur["frozen_at"] != base_t["frozen_at"]:
            bad.append("'Frozen at' moved to %s, and the surface is %s's: it moves only with the surface" % (cur["frozen_at"], what))
        elif not bad:
            print("ok: a release with the surface of %s" % what)
    else:
        lost = sorted(identities(ref_t) - identities(cur)) if ref_t else []
        if lost and vtuple(cur_ver)[0] <= vtuple(ref_ver)[0]:
            bad.append("the surface lost %d row(s) since %s (%s), first: %s; the release needs a major above it, it is %s"
                       % (len(lost), what, ref_ver, " ".join(lost[0]), cur_ver))
        elif vtuple(cur_ver)[:2] <= vtuple(ref_ver)[:2]:
            bad.append("the surface changed since %s (%s); the release needs at least a minor above it, it is %s" % (what, ref_ver, cur_ver))
        if cur["frozen_at"] != cur_ver:
            bad.append("the surface changed since %s and 'Frozen at' is %s, not the release's version %s" % (what, cur["frozen_at"], cur_ver))
        if not bad:
            print("ok: the surface changed since %s (%s) and the release is %s with 'Frozen at' %s" % (what, ref_ver, cur_ver, cur["frozen_at"]))
    for b in bad:
        print("red: " + b)
    return 1 if bad else 0


def main(argv):
    try:
        if len(argv) == 2 and argv[0] == "json":
            with open(argv[1], encoding="utf-8") as f:
                print(json.dumps(parse(f.read())))
            return 0
        if len(argv) == 2 and argv[0] == "schema-keys":
            print("\n".join(schema_keys(argv[1])))
            return 0
        if len(argv) in (2, 3) and argv[0] == "base-check":
            return base_check(argv[1], argv[2] if len(argv) == 3 else "")
        if len(argv) == 2 and argv[0] == "defaults-config":
            print(json.dumps(defaults_config(argv[1])))
            return 0
        if len(argv) == 2 and argv[0] == "config-keys":
            with open(argv[1], encoding="utf-8") as f:
                print("\n".join(config_keys(json.load(f))))
            return 0
        if len(argv) == 2 and argv[0] == "version":
            texts = []
            for rel in (".claude-plugin/plugin.json", "CHANGELOG.md"):
                try:
                    with open(os.path.join(argv[1], rel), encoding="utf-8") as f:
                        texts.append(f.read())
                except OSError:
                    texts.append(None)
            print(plugin_version(*texts) or "unreleased")
            return 0
    except Bad as e:
        print("contract: %s" % e, file=sys.stderr)
        return 65
    sys.stderr.write(__doc__)
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
