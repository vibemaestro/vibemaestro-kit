#!/usr/bin/env python3
"""The config-compatibility checks of tests/test-config-compat.sh (rule config-compat).

    compat_check.py <family> <plugin dir> <floor dir> <fixtures dir> <repo config>

One line per check on stdout: `ok\t<label>` or `FAIL\t<label>`; the suite turns them into its ok/bad. Families:
  forward     a config written for a newer plugin, read by the floor reader and by the plugin's: unknown keys are notes, a
              wrong-typed known key and a newer schema still refuse
  backward    an old config read by the plugin's reader: every schema key has a default, every key of the floor's schema is still
              read (or is in DEPRECATED), DEPRECATED is well formed
  deprecated  a deprecated key in its window: read, moved to its new key, noted with the new key's name
  migrate     MIGRATIONS carry a config up to SCHEMA; a missing step and a newer schema refuse
  deny        the default deny globs (`MERGE_DENY_DEFAULT`, what `kb.py init` writes and the bootstrap floor adds) deny a sample of
              each glob the floor's default holds, except `.vibemaestro/batons/**`; a config that sets its own list keeps it
The floor reader is a snapshot (one stdlib file); `floor.txt` holds its sha256, checked first.
"""
import copy
import hashlib
import importlib.util
import json
import os
import sys

sys.dont_write_bytecode = True
UPDATE = "claude plugin update vibemaestro-sdlc@vibemaestro"


def say(cond, label):
    sys.stdout.write("%s\t%s\n" % ("ok" if cond else "FAIL", label))


def module(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def leaves(tree, prefix="", nullable=False):
    """{dotted key: (node, under a null-default object)} of every key of a schema tree, the keys inside objects that default to
    null included (their keys need no default: the object itself is null until a repo sets it)."""
    out = {}
    for k, node in tree.items():
        key = prefix + k
        out[key] = (node, nullable)
        if node[0] in ("obj", "objnull"):
            out.update(leaves(node[1], key + ".", nullable or node[0] == "objnull"))
    return out


def keys_of(notes):
    return sorted(k for k, _w in notes)


def fam_forward(C, F, fx, repo_cfg):
    # repo_cfg "": the public export, which carries no repo config (it is private): the readers get {}, what a public clone reads
    what = "this repo's .vibemaestro/sdlc.json" if repo_cfg else "the export's config (none: {})"
    for name, R in (("floor", F), ("plugin", C)):
        data = json.load(open(repo_cfg, encoding="utf-8")) if repo_cfg else {}
        probs, notes = R.check(data)
        say(probs == [], "[F] %s reader: %s has no problem (%s)" % (name, what, probs[:2]))
        if name == "plugin":
            say(notes == [], "[F] plugin reader: %s uses no key the plugin does not know (%s)" % (what, keys_of(notes)))
        data = json.load(open(os.path.join(fx, "future-keys.json"), encoding="utf-8"))
        probs, notes = R.check(data)
        say(probs == [], "[F] %s reader: a config with keys of a newer plugin is valid (%s)" % (name, probs[:2]))
        say(keys_of(notes) == ["current_state.forbid_patterns[0].future_item_key", "future_section", "merge.future_merge_key",
                               "pr.future_key"],
            "[F] %s reader: one note per unknown key, top level, nested, under merge and in a list item (%s)" % (name, keys_of(notes)))
        say(all(R.UNKNOWN_NOTE == w for _k, w in notes), "[F] %s reader: …each says the key is ignored" % name)
        eff = R.effective(data)
        say("future_section" not in eff and "future_key" not in eff["pr"], "[F] %s reader: …and is dropped from the effective config" % name)
        say(eff["current_state"]["forbid_patterns"] == [{"id": "diary", "regex": "x"}],
            "[F] %s reader: …a list item's unknown key too" % name)
        say(eff["pr"]["draft"] is True, "[F] %s reader: …while the known keys beside them still apply" % name)
        data = json.load(open(os.path.join(fx, "wrong-type.json"), encoding="utf-8"))
        probs, _n = R.check(data)
        say([k for k, _w in probs] == ["pr.draft"], "[F] %s reader: a known key with a wrong type still refuses (%s)" % (name, probs[:2]))
        probs, _n = R.check({"schema": R.SCHEMA + 1, "pr": {"draft": True}})
        say(len(probs) == 1 and probs[0][0] == "schema", "[F] %s reader: a newer schema major refuses" % name)
        say(bool(probs) and UPDATE in probs[0][1], "[F] %s reader: …naming the update to run (%s)" % (name, UPDATE))
    say(C.problems({"bogus": 1}, strict=True) != [], "[F] plugin reader: a config being written (strict) refuses an unknown key")
    probs, notes = C.check({"a\nb": 1, "::error::x" + "y" * 300: 1})
    say(all(k.isprintable() and len(k) <= 120 for k, _w in notes), "[F] plugin reader: a key is printed with its control characters escaped, and cut")
    probs, _n = C.check({"current_state": {"tables": [{"heading": "^A$", "columns": ["a"], "enums": {"x\ny": ["1"]}}]}})
    say(probs != [] and all(k.isprintable() for k, _w in probs), "[F] plugin reader: …a problem key from the file too (%s)" % probs[:1])
    import io
    import tempfile
    err, old = io.StringIO(), sys.stderr
    sys.stderr = err
    try:
        for _ in range(3):
            d = tempfile.mkdtemp()
            os.makedirs(os.path.join(d, ".vibemaestro"))
            with open(os.path.join(d, ".vibemaestro", "sdlc.json"), "w") as f:
                f.write('{"zz_once": 1}')
            C.load(d)
    finally:
        sys.stderr = old
    say(err.getvalue().count("zz_once") == 1, "[F] plugin reader: a note is printed once per process, from however many copies (%d)"
        % err.getvalue().count("zz_once"))


def fam_backward(C, F, fx, repo_cfg):
    tree, dflt = leaves(C.SCHEMA_TREE), C.DEFAULTS
    missing = []
    for key, (node, nullable) in tree.items():
        if nullable:
            continue
        cur, ok_ = dflt, True
        for part in key.split("."):
            if not isinstance(cur, dict) or part not in cur:
                ok_ = False
                break
            cur = cur[part]
        if not ok_:
            missing.append(key)
    say(missing == [], "[B] every schema key has a default (missing: %s)" % missing[:5])
    for fixture in ("old-schema-1.json", "old-kit-config.json"):
        data = json.load(open(os.path.join(fx, fixture), encoding="utf-8"))
        probs, notes = C.check(data)
        say(probs == [] and C._check_effective(C.effective(data)) == [],
            "[B] an old config (%s) is valid for the plugin's reader (%s)" % (fixture, probs[:2]))
    floor = leaves(F.SCHEMA_TREE)
    gone = sorted(k for k in floor if k not in tree and not (C.DEPRECATED.get(k) or {}).get("removed"))
    say(gone == [], "[B] a key the floor reader knows is still in the schema, or listed in DEPRECATED as removed (%s)" % gone[:5])
    retyped = sorted(k for k in floor if k in tree and _kind(floor[k][0]) != _kind(tree[k][0]) and k not in C.DEPRECATED)
    say(retyped == [], "[B] a key the floor reader knows keeps its type, or is listed in DEPRECATED (%s)" % retyped[:5])
    items = sorted("%s.%s" % (kind, f) for kind, fields in F.ITEM_FIELDS.items() for f in fields
                   if f not in C.ITEM_FIELDS.get(kind, ()))
    say(items == [], "[B] a key of a list item (a table, a flow line, a pattern) the floor reader knows is still read (%s)" % items)
    bad = []
    for k, d in C.DEPRECATED.items():
        if not isinstance(d, dict) or not isinstance(d.get("since"), str) or set(d) - {"since", "use", "note", "note_key", "removed"}:
            bad.append(k + ": shape")
            continue
        if d.get("removed"):
            if k in tree:
                bad.append(k + ": removed but still in the schema")
            if d.get("use") and d["use"] not in floor:
                bad.append(k + ": removed while the floor reader does not read " + d["use"])
        elif k not in tree:
            bad.append(k + ": in its window but not in the schema (the old form must still be read)")
        if d.get("use") and d["use"] not in tree:
            bad.append(k + ": its new key " + d["use"] + " is not in the schema")
    say(bad == [], "[B] every DEPRECATED entry is well formed (%s)" % bad[:3])


def _kind(node):
    """A key's type as a reader sees it: the node without the fields of an object (those are keys of their own)."""
    if node[0] in ("obj", "objnull"):
        return (node[0],) + tuple(node[2:])
    return node


def fam_deprecated(C, F, fx, repo_cfg):
    C.DEPRECATED.clear()
    C.DEPRECATED.update({
        "agents.search_model": {"since": "2026-10-20", "use": "agents.worker_model", "note": "planted by the suite"},
        "pr.draft": {"since": "2026-10-20", "use": None},
    })
    probs, notes = C.check({"agents": {"search_model": "fable"}, "pr": {"draft": True}})
    say(probs == [], "[P] a deprecated key in its window is still valid (%s)" % probs[:2])
    n = dict(notes)
    say("agents.worker_model" in n.get("agents.search_model", ""), "[P] its note names the new key (%s)" % n.get("agents.search_model"))
    say("does nothing" in n.get("pr.draft", ""), "[P] a deprecated key with no new form: the note says it does nothing now")
    eff = C.effective({"agents": {"search_model": "fable"}})
    say(eff["agents"]["worker_model"] == "fable", "[P] the old key's value moves to the new key (both forms are read)")
    eff = C.effective({"agents": {"search_model": "fable", "worker_model": "haiku"}})
    say(eff["agents"]["worker_model"] == "haiku", "[P] …and the new key wins when both are set")
    C.DEPRECATED["kb.spec_warn_bytes"] = {"since": "2026-10-20", "use": "agents.review_model"}
    probs, _n = C.check({"kb": {"spec_warn_bytes": 5}})
    say([k for k, _w in probs] == ["agents.review_model"], "[P] a moved value is checked against the new key's type (%s)" % probs[:2])
    C.DEPRECATED["agents.review_model"] = {"since": "2026-10-20", "use": "merge.image_bump.registry.host"}
    del C.DEPRECATED["kb.spec_warn_bytes"]
    try:
        probs, _n = C.check({"agents": {"review_model": "opus"}, "merge": {"image_bump": {"registry": None}}})
        eff = C.effective({"agents": {"review_model": "opus"}, "merge": {"image_bump": {"registry": None}}})
        say(probs == [] and eff["merge"]["image_bump"]["registry"] is None,
            "[P] a new key under an object set to null: the null stands, nothing crashes")
    except Exception as e:  # noqa: BLE001 - the check is that nothing raises
        say(False, "[P] a new key under an object set to null: the null stands, nothing crashes (%s)" % type(e).__name__)
    del C.DEPRECATED["agents.review_model"]
    C.DEPRECATED["agents.plan_model"] = {"since": "2026-10-20", "use": "agents.worker_model", "removed": True}
    probs, notes = C.check({"agents": {"plan_model": "opus"}})
    say(probs == [] and "agents.worker_model" in dict(notes).get("agents.plan_model", ""),
        "[P] a removed key: still not a problem, and its note names the new key")


def fam_migrate(C, F, fx, repo_cfg):
    out, steps = C.migrate({"schema": C.SCHEMA, "pr": {"draft": True}})
    say(steps == [] and out == {"schema": C.SCHEMA, "pr": {"draft": True}}, "[M] a config at the plugin's schema is left as it is")
    base = C.SCHEMA
    C.SCHEMA = base + 1
    C.MIGRATIONS.clear()
    C.MIGRATIONS[base] = lambda d: dict(d, moved=True)
    out, steps = C.migrate({"schema": base})
    say(steps == [base + 1] and out.get("schema") == base + 1 and out.get("moved") is True,
        "[M] a planted step carries a config up one schema (%s)" % (steps,))
    C.MIGRATIONS.clear()
    try:
        C.migrate({"schema": base})
        say(False, "[M] a missing step refuses")
    except ValueError as e:
        say("no migration" in str(e), "[M] a missing step refuses")
    try:
        C.migrate({"schema": base + 2})
        say(False, "[M] a newer schema refuses, naming the update")
    except ValueError as e:
        say(UPDATE in str(e), "[M] a newer schema refuses, naming the update")
    # kb.py config migrate --write with a planted step: a valid result is written whole, an invalid one writes nothing
    import io
    import tempfile
    sys.path.insert(0, os.path.dirname(C.__file__))
    sys.modules["sdlc_config"] = C
    K = module(os.path.join(os.path.dirname(C.__file__), "kb.py"), "plugin_kb")
    d = tempfile.mkdtemp()
    os.makedirs(os.path.join(d, ".vibemaestro"))
    cfgp = os.path.join(d, ".vibemaestro", "sdlc.json")
    for label, step, want_rc, want in (("valid", lambda x: dict(x, hooks="off"), 0, "off"),
                                       ("invalid", lambda x: dict(x, hooks=1), 65, None)):
        with open(cfgp, "w") as f:
            f.write('{"schema": %d}' % base)
        C.MIGRATIONS[base] = step
        out, old_out, old_err = io.StringIO(), sys.stdout, sys.stderr
        sys.stdout, sys.stderr = out, out
        try:
            rc = K.cmd_config_migrate(d, True)
        finally:
            sys.stdout, sys.stderr = old_out, old_err
        got = json.load(open(cfgp))
        left = sorted(os.listdir(os.path.join(d, ".vibemaestro")))
        if want_rc == 0:
            say(rc == 0 and got.get("hooks") == "off" and got.get("schema") == base + 1 and left == ["sdlc.json"],
                "[M] config migrate --write writes the migrated config, and no temp file is left (%s, %s)" % (rc, left))
        else:
            say(rc == 65 and got == {"schema": base} and left == ["sdlc.json"],
                "[M] config migrate --write with a result that would be invalid: rc 65 and the file is untouched (%s, %s)" % (rc, got))
    C.MIGRATIONS.clear()


# (path, denied by the floor's default, denied by the plugin's): a sample for each glob of the floor's default, then the paths it
# leaves the same; only the project batons leave the default (BatonRun row d, Q2a)
DENY_SAMPLES = ((".github/workflows/ci.yml", True, True), (".github/workflows/a/b.yml", True, True),
                (".vibemaestro/sdlc.json", True, True), (".vibemaestro/x", True, True), (".vibemaestro/gates/x.py", True, True),
                (".vibemaestro/rules/a.instructions.md", True, True), ("deploy/a-secret.txt", True, True), ("secret", True, True),
                (".vibemaestro/batons/merge-x.sh", True, False), (".vibemaestro/batons/a/b.sh", True, False),
                ("src/main.py", False, False), (".github/actions/a.yml", False, False))


def fam_deny(C, F, fx, repo_cfg):
    def denied(R, p):
        return any(R.glob_match(g, p) for g in R.MERGE_DENY_DEFAULT)
    for p, old, new in DENY_SAMPLES:
        say(denied(F, p) == old, "[D] instrument: the floor's default %s %s" % ("denies" if old else "leaves", p))
        say(denied(C, p) == new, "[D] the default %s %s" % ("denies" if new else "leaves", p))
    for g in F.MERGE_DENY_DEFAULT:
        say(any(F.glob_match(g, p) and p not in (".vibemaestro/batons/merge-x.sh", ".vibemaestro/batons/a/b.sh")
                for p, _o, _n in DENY_SAMPLES), "[D] a sample for the floor's glob %s" % g)
    say(all(C.glob_ok(g) for g in C.MERGE_DENY_DEFAULT) and all(F.glob_ok(g) for g in C.MERGE_DENY_DEFAULT),
        "[D] every default glob is a glob the floor reader accepts")
    own = json.load(open(os.path.join(fx, "old-kit-config.json"), encoding="utf-8"))
    want = own["merge"]["deny_globs"]
    for name, R in (("floor", F), ("plugin", C)):
        got = R.effective(copy.deepcopy(own))["merge"]["deny_globs"]
        say(got == want, "[D] %s reader: a config that sets merge.deny_globs keeps exactly its list (%s)" % (name, got))
    say(".vibemaestro/**" in want, "[D] instrument: that config's own list denies .vibemaestro/**")
    if repo_cfg:
        mine = json.load(open(repo_cfg, encoding="utf-8"))
        want = (mine.get("merge") or {}).get("deny_globs")
        got = C.effective(copy.deepcopy(mine))["merge"]["deny_globs"]
        say(want is None or got == want, "[D] plugin reader: this repo's merge.deny_globs is read as written")


def main(argv):
    fam, plugin, floor_dir, fx, repo_cfg = argv
    fpath = os.path.join(floor_dir, "reader.py")
    want = open(os.path.join(floor_dir, "floor.txt"), encoding="utf-8").read().split()[1]
    got = hashlib.sha256(open(fpath, "rb").read()).hexdigest()
    say(got == want, "[0] the floor snapshot is the file floor.txt names (sha256 %s…)" % got[:12])
    C = module(os.path.join(plugin, "scripts", "sdlc_config.py"), "plugin_sdlc_config")
    F = module(fpath, "floor_sdlc_config")
    globals()["fam_" + fam](C, F, fx, repo_cfg)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
