#!/usr/bin/env python3
"""The engine of the kit baton kit:coordinator-bootstrap: set up a coordinator machine for BatonRun in one owner-signed run.

    coordinator_bootstrap.py report                         the machine report: `CHECK <name>: <status> <detail>` lines, exit 0
    coordinator_bootstrap.py plan                           0 to 2 plan lines (`bootstrap launcher …`, `bootstrap settings …`);
                                                            exit 3 with a REFUSE line when there is nothing to do, or when the
                                                            merge cannot reach `permissions --check` rc 0
    coordinator_bootstrap.py do launcher|settings --expect-plan <file>
                                                            one write, only when its plan line is a line of the signed plan
    coordinator_bootstrap.py postcheck                      the launcher is current and `permissions --check` finds nothing
    coordinator_bootstrap.py undo --expect-plan <file>      put back what the run of that signed plan wrote, while it is still
                                                            what the run left (else LEAVE, exit 1)

What it reuses instead of a second copy: baton.py of this plugin, imported (the launcher text and its install, the printed block,
the settings sources and the findings of `permissions --check`, the mode), and the bytes of the kind settings-merge
(templates/baton-kinds/settings-merge.sh), run as baton runs a kind (its __NAME__ read as `coordinator-bootstrap`, so its
backup and run record are this run's) in the phase this gate is in. The kind adds rules and absent attribution keys and removes
nothing; its record names the signed plan, so its undo acts only on this run's merge, and only while the file has the merged
sha256. Its writes stay out of the kit baton's own write list (BATON_WRITES is the null device for it): the kit baton's plan line
carries the kind's merge line, rules named, so the signature binds every rule.

The rules come from baton.py's `snippet()` only: the whole permission block when `permissions --check` finds something besides
the launcher, else none (rules in force from any scope are not added again), plus attribution off, which the kind adds only
where a key is absent. A settings file that does not exist is created as `{}` first; undo removes it again only while it holds
exactly those bytes and the record names this plan. The launcher is installed by baton.py's own `--install-launcher`; the old
launcher's bytes are kept, and undo puts them back (or removes the launcher when there was none) while the launcher is the one
the run installed. The mode is read, never written.

The report never prints a path under the home directory, an account or a token: files are named by their variable. A plugin
that needs more of the machine adds its own lines: every installed plugin of the vibemaestro marketplace whose manifest declares
a dependency on vibemaestro-sdlc and that ships `scripts/bootstrap_report.py` (the newest version in the plugin cache that holds
the file, not a link) is run with `python3 -I -B`, no stdin and a 10 s limit, and only its `CHECK ` lines are kept (at most 20,
200 characters each, control characters dropped). This plugin names no other plugin: the dependent plugin owns its lines and
the steps they lead to. Its file is not code the signature binds, so in the run phase (BATON_PHASE=run) the report does not run it:
the owner saw those lines at rehearse.

The kit baton puts the sha256 of this file, the kind, baton.py and the launcher template into every plan line (`engine
sha256 …`), so the owner's signature binds the code that writes: a change after signing changes the run's plan, and baton refuses
the run. A `do` step hashes the same files again itself and accepts its line only with that exact sha256 in the signed plan,
and the kind's bytes it hashed are the bytes it runs, so a change between the kit baton's hash and the write is refused too.
The plan of the run phase and the undo hash them the same way: a kind that changed since the signature is never run there
(the plan refuses, the undo leaves a merge of this run to the owner). Code that loads before any hash (this file, baton.py)
is guarded by the deny rule on the plugin cache that this run installs, not by the hash.
Python 3.8+, standard library only.
"""
import hashlib
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
PLUGIN_ROOT = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
KIND = os.path.join(PLUGIN_ROOT, "templates", "baton-kinds", "settings-merge.sh")
# the files the kit baton hashes into every plan line (`engine sha256 …`), in its order
ENGINE_FILES = (os.path.join(PLUGIN_ROOT, "gates", "coordinator_bootstrap.py"), KIND,
                os.path.join(PLUGIN_ROOT, "scripts", "baton.py"), os.path.join(PLUGIN_ROOT, "scripts", "baton-launcher.py"))
KIND_DATA = None  # the kind's bytes a `do` step hashed: the bytes it runs
NAME = "coordinator-bootstrap"
SDLC, MARKETPLACE = "vibemaestro-sdlc", "vibemaestro"
REPORT_HOOK = os.path.join("scripts", "bootstrap_report.py")
ENGINE_SUFFIX = ", engine sha256 "
HOOK_TIMEOUT, GH_TIMEOUT, KIND_TIMEOUT = 10, 10, 60
HOOK_LINES, HOOK_WIDTH = 20, 200
# a version directory as Claude Code names it (measured): X.Y.Z, X.Y.Z-<12 hex> (a
# tag-resolved dependency), <12 hex> (a git marketplace whose plugin carries no version), <12 hex>-<8 hex> (a git-subdir plugin
# source) or unknown (a directory marketplace)
INSTALL_DIR = re.compile(r"^(?:(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-[0-9a-f]{12})?|[0-9a-f]{12}(?:-[0-9a-f]{8})?|unknown)\Z")
MERGE_LINE = re.compile(r"^(?:PLAN|DO) merge (.*) \(rules sha256 ([0-9a-f]{64})\)$")
EMPTY = b"{}\n"
OK, FAIL, REFUSE, USAGE = 0, 1, 3, 64


def load_baton():
    spec = importlib.util.spec_from_file_location("baton_for_bootstrap", os.path.join(PLUGIN_ROOT, "scripts", "baton.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


B = load_baton()


def sha(data):
    return hashlib.sha256(data).hexdigest()


def sha_file(path):
    with open(path, "rb") as f:
        return sha(f.read())


def refuse(msg):
    sys.stderr.write("REFUSE %s\n" % msg)
    sys.stderr.flush()
    return REFUSE


def user_settings():
    return os.path.join(B.claude_config_dir(), "settings.json")


def named(text):
    """Text for the report and its refusals: the Claude Code directory by its variable, never the home directory spelled out."""
    cfg = os.environ.get("CLAUDE_CONFIG_DIR", "")
    return text.replace(B.claude_config_dir(), "$CLAUDE_CONFIG_DIR" if os.path.isabs(cfg) else "~/.claude")


def records():
    return os.path.join(B.state_dir(), "records")


def path_key(path):
    return sha(path.encode("utf-8", "surrogateescape"))[:16]


def plan_id(plan_file):
    return sha_file(plan_file) if plan_file and os.path.isfile(plan_file) else ""


def write_atomic(path, data, mode):
    d = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(prefix=".%s.baton-new." % os.path.basename(path), dir=d)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def read_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


# ── installed plugins: the registry and the cache, as the launcher reads them ──
def installed(name):
    """[(version, real install path)] of a vibemaestro plugin whose installPath is <cache>/<name>/<version directory>, the entry the
    registry updated last first (its `lastUpdated`; numbers are not compared: a SHA has no order, the public numbering restarted).
    The version is the registry's `version`, else the directory's name."""
    plugins = os.path.join(os.path.realpath(B.claude_config_dir()), "plugins")
    base = os.path.join(plugins, "cache", MARKETPLACE, name)
    data = read_json(os.path.join(plugins, "installed_plugins.json"))
    entries = (data.get("plugins") or {}).get("%s@%s" % (name, MARKETPLACE)) if isinstance(data, dict) else None
    out = []
    for i, e in enumerate(entries if isinstance(entries, list) else []):
        p = e.get("installPath") if isinstance(e, dict) else None
        if not isinstance(p, str) or not os.path.isabs(p):
            continue
        real = os.path.realpath(p)
        parent, dirname = os.path.split(real)
        if parent == base and INSTALL_DIR.match(dirname):
            v = e.get("version") if isinstance(e.get("version"), str) and INSTALL_DIR.match(e.get("version")) else dirname
            stamp = e.get("lastUpdated") if isinstance(e.get("lastUpdated"), str) else ""
            out.append((stamp, -i, v, real))
    return [(v, real) for _s, _i, v, real in sorted(out, reverse=True)]


def show(v):
    return v


def running_version():
    """The running plugin's version: its manifest `version` (the public kit), else the name of its cache directory (the version
    Claude Code computed: a SHA, X.Y.Z-<12 hex>, <12 hex>-<8 hex> or unknown), else unknown (a checkout)."""
    m = read_json(os.path.join(PLUGIN_ROOT, ".claude-plugin", "plugin.json"))
    if isinstance(m, dict) and isinstance(m.get("version"), str):
        return m["version"]
    d = os.path.basename(os.path.realpath(PLUGIN_ROOT))
    return d if INSTALL_DIR.match(d) else "unknown"


def names_sdlc(d):
    """A `dependencies` item naming vibemaestro-sdlc: the bare name (the private kit), `<name>@<marketplace>`, or an object's name."""
    n = d if isinstance(d, str) else d.get("name") if isinstance(d, dict) else None
    return isinstance(n, str) and (n == SDLC or n.startswith(SDLC + "@"))


def dependents():
    """[(plugin name, version, report hook or None)] of the installed vibemaestro plugins that declare a dependency on
    vibemaestro-sdlc, by name; the hook is the newest version's that holds one."""
    data = read_json(os.path.join(os.path.realpath(B.claude_config_dir()), "plugins", "installed_plugins.json"))
    ids = sorted((data.get("plugins") or {}) if isinstance(data, dict) and isinstance(data.get("plugins"), dict) else [])
    out = []
    for pid in ids:
        name, _sep, mkt = pid.partition("@")
        if mkt != MARKETPLACE or name == SDLC or not re.match(r"^[a-z0-9][a-z0-9-]*$", name):
            continue
        found = None
        for v, real in installed(name):
            m = read_json(os.path.join(real, ".claude-plugin", "plugin.json"))
            deps = m.get("dependencies") if isinstance(m, dict) else None
            if not isinstance(deps, list) or not any(names_sdlc(d) for d in deps):
                continue
            hook = os.path.join(real, REPORT_HOOK)
            ok = os.path.isfile(hook) and not os.path.islink(hook) and os.path.realpath(hook) == hook
            if found is None:
                found = (name, show(v), hook if ok else None)
            if ok:
                found = (name, show(v), hook)
                break
        if found:
            out.append(found)
    return out


def run_hook(name, hook):
    try:
        r = subprocess.run([sys.executable, "-I", "-B", hook], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, timeout=HOOK_TIMEOUT)
    except subprocess.TimeoutExpired:
        check("%s-report" % name, "info", "(timed out after %d s)" % HOOK_TIMEOUT)
        return
    except OSError:
        check("%s-report" % name, "info", "(the hook could not run)")
        return
    lines = [ln for ln in r.stdout.decode("utf-8", "replace").splitlines() if ln.startswith("CHECK ")]
    for ln in lines[:HOOK_LINES]:
        print("".join(c for c in ln if c.isprintable())[:HOOK_WIDTH])
    if not lines:
        check("%s-report" % name, "info", "(the hook printed no CHECK line, rc %d)" % r.returncode)


# ── the report ──
def check(name, status, detail=""):
    print(("CHECK %s: %s %s" % (name, status, detail)).rstrip())


def is_launcher_finding(f):
    return f[1].startswith("the launcher ")


def is_old_ask(f):
    """An old broad ask rule (baton.py OLD_ASKS): kit:permissions-upgrade removes it; this run only adds, so it sets it aside."""
    return f[1].startswith(B.OLD_ASK_FINDING)


def cmd_report(hooks=True):
    sdlc = installed(SDLC)
    check("vibemaestro-sdlc", running_version(), "(running; latest installed %s)" % (show(sdlc[0][0]) if sdlc else "none"))
    deps = dependents()
    for name, v, hook in deps:
        check(name, v, "(installed, no bootstrap report)" if not hook else "(installed; its report follows)" if hooks
              else "(installed; its report runs at rehearse, not in the signed run)")
    if not deps:
        check("dependent plugins", "none", "(no installed plugin adds report lines)")
    if B.launcher_current():
        check("launcher", "current")
    else:
        check("launcher", "stale" if os.path.exists(B.launcher_path()) else "missing", "(this run installs it)")
    sources = B.settings_sources()
    found = B.perm_findings(sources)
    if not found:
        check("rules", "in force", "(permissions --check rc 0)")
    else:
        kinds = {}
        for k, _t in found:
            kinds[k] = kinds.get(k, 0) + 1
        check("rules", "not in force", "(permissions --check rc 7: %s)" % ", ".join("%d %s" % (n, k) for k, n in sorted(kinds.items())))
    check("mode", B.read_mode(), "(read only: auto is the owner's word)")
    warns = B.attribution_warnings(sources)
    check("attribution", "off" if not warns else "on", "" if not warns else "(this run adds the keys that are absent, flips none)")
    gh = shutil.which("gh")
    if not gh:
        check("gh", "MISSING", "(gh is not on PATH)")
    else:
        try:
            rc = subprocess.run([gh, "auth", "status"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL, timeout=GH_TIMEOUT).returncode
        except (OSError, subprocess.SubprocessError):
            rc = None
        check("gh", "logged in" if rc == 0 else "MISSING", "" if rc == 0 else "(gh auth status rc %s: the owner logs in)" % rc)
    for name, _v, hook in deps:
        if hook and hooks:
            run_hook(name, hook)
    return OK


# ── the kind, run as baton runs it ──
def kind(phase, settings, rules, state=None, signed=True):
    """(rc, output lines) of the kind settings-merge in one phase, on a fresh copy of its bytes with __NAME__ filled in."""
    if KIND_DATA is None:
        with open(KIND, "rb") as f:
            data = f.read()
    else:
        data = KIND_DATA
    data = data.replace(b"__NAME__", NAME.encode("ascii"))
    d = tempfile.mkdtemp(prefix="bootstrap-kind-")
    try:
        script = os.path.join(d, "settings-merge.sh")
        with open(script, "wb") as f:
            f.write(data)
        env = {k: v for k, v in os.environ.items() if k not in B.SHELL_HOOKS and not k.startswith("BASH_FUNC_")}
        env.update(BATON_PHASE=phase, BATON_WRITES=os.devnull)
        if state:
            env["XDG_STATE_HOME"] = state
        if not signed:
            env.pop("BATON_PLAN", None)
        r = subprocess.run([shutil.which("bash") or "bash", script, settings, rules], stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env, timeout=KIND_TIMEOUT)
        return r.returncode, r.stdout.decode("utf-8", "replace").splitlines()
    finally:
        shutil.rmtree(d, ignore_errors=True)


def forward(lines):
    for ln in lines:
        print("  settings-merge: " + ln.replace("VERDICT", "verdict"))


def merge_of(lines, settings):
    """(counts, rules sha256) of the kind's merge line for `settings`, or None."""
    for ln in lines:
        m = MERGE_LINE.match(ln.strip())
        if m:
            counts, _sep, where = m.group(1).rpartition(" into ")
            if where == settings:
                return counts, m.group(2)
    return None


# ── the plan ──
class Plan:
    def __init__(self):
        self.lines, self.refusal, self.rules = [], None, None


def compute(work):
    """The plan of this machine now; the rules file is written into `work`."""
    p = Plan()
    other = B.registry_other()
    if other:       # a session that is not the installed sdlc sees another version's rules and launcher: cmd_permissions would refuse at the act
        p.refusal = "this session runs vibemaestro-sdlc %s, the installed one is %s: restart Claude Code; nothing written" % other[:2]
        return p
    sources = B.settings_sources()
    user = user_settings()
    launcher_ok = B.launcher_current()
    found = B.perm_findings(sources)
    unreadable = [t for k, t in found if k == "UNREADABLE"]
    if unreadable:
        p.refusal = "a settings file cannot be read (%s): fix it by hand, then run again" % named(unreadable[0])
        return p
    if os.path.islink(user):
        p.refusal = "%s is a symbolic link: the merge names the file itself" % named(user)
        return p
    rest = [f for f in found if not (is_launcher_finding(f) or is_old_ask(f))]
    old = [f for f in found if is_old_ask(f)]
    snip = B.snippet()
    rules = dict(snip["permissions"]) if rest else {}
    rules["attribution"] = snip["attribution"]
    p.rules = os.path.join(work, "rules.json")
    with open(p.rules, "w", encoding="utf-8") as f:
        f.write(json.dumps(rules, indent=2) + "\n")
    # the merge, simulated: the kind's own run phase on a copy, with a state directory of its own
    sim = os.path.join(work, "sim")
    os.makedirs(sim)
    copy = os.path.join(sim, "settings.json")
    absent = not os.path.exists(user)
    if absent:
        with open(copy, "wb") as f:
            f.write(EMPTY)
    else:
        shutil.copyfile(user, copy)
    rc, out = kind("run", copy, p.rules, state=os.path.join(sim, "state"), signed=False)
    if rc != 0:
        p.refusal = "the merge refuses %s: %s" % (named(user), "; ".join(ln for ln in out if "REFUSE" in ln) or "rc %d" % rc)
        return p
    merge = merge_of(out, copy)
    after = [f for f in B.perm_findings([(lab, copy if lab == "user" else path) for lab, path in sources])
             if not (is_launcher_finding(f) or is_old_ask(f))]
    if after:
        p.refusal = ("adding rules cannot reach permissions --check rc 0 (the run removes no rule); the owner removes or "
                     "changes these by hand first: %s" % named("; ".join("%s %s" % f for f in after).replace(copy, user)))
        return p
    if not launcher_ok:
        state = "stale" if os.path.exists(B.launcher_path()) else "missing"
        p.lines.append("bootstrap launcher %s: install (%s) sha256 %s, the launcher of vibemaestro-sdlc %s"
                       % (B.launcher_path(), state, sha(B.launcher_text().encode("utf-8")), running_version()))
    if merge:
        before = "absent: created as {} first" if absent else "sha256 %s" % sha_file(user)
        p.lines.append("bootstrap settings %s (%s): merge %s (rules sha256 %s)" % (user, before, merge[0], merge[1]))
    if not p.lines and old:
        p.refusal = ("nothing to do here: the launcher is current and only the old broad ask rules are left, which "
                     "kit:permissions-upgrade swaps")
    elif not p.lines:
        p.refusal = ("nothing to do: the launcher is current, the rules are in force (permissions --check rc 0) and no "
                     "attribution key is absent")
    return p


def with_plan(fn):
    work = tempfile.mkdtemp(prefix="bootstrap-")
    try:
        return fn(compute(work))
    finally:
        shutil.rmtree(work, ignore_errors=True)


def cmd_plan():
    if os.environ.get("BATON_PHASE") == "run":
        if not bind_kind(signed_lines(os.environ.get("BATON_PLAN"))):
            return refuse("the engine changed since the signature: the run's plan is not computed with it")
    else:
        bind_kind(None)

    def show_plan(p):
        if p.refusal:
            return refuse(p.refusal)
        for ln in p.lines:
            print(ln)
        return OK
    return with_plan(show_plan)


def engine_hash():
    """(the kit baton's `engine sha256`, the kind's bytes read for it): each file read once."""
    h, kind_bytes = hashlib.sha256(), None
    for path in ENGINE_FILES:
        with open(path, "rb") as f:
            data = f.read()
        if path == KIND:
            kind_bytes = data
        h.update(sha(data).encode() + b"\n")
    return h.hexdigest(), kind_bytes


def signed_engine(signed):
    """The one `engine sha256` the signed plan's lines carry, or None."""
    shas = {ln.rsplit(ENGINE_SUFFIX, 1)[1] for ln in signed if ln.startswith("bootstrap ") and ENGINE_SUFFIX in ln}
    return shas.pop() if len(shas) == 1 else None


def bind_kind(signed):
    """Hash the engine and keep the kind's bytes it read; True when the signed plan carries exactly that sha256."""
    global KIND_DATA
    code, KIND_DATA = engine_hash()
    return signed is not None and signed_engine(signed) == code


def signed_lines(plan_file):
    try:
        with open(plan_file, encoding="utf-8", errors="surrogateescape") as f:
            return f.read().splitlines()
    except (OSError, TypeError):
        return None


# ── the writes ──
def launcher_record():
    return os.path.join(records(), "%s-launcher.last" % NAME)


def created_record(path):
    return os.path.join(records(), "%s-created-%s.last" % (NAME, path_key(path)))


def do_launcher(line, pid):
    L = B.launcher_path()
    os.makedirs(records(), mode=0o700, exist_ok=True)
    backup = None
    if os.path.exists(L):
        with open(L, "rb") as f:
            old = f.read()
        backup = os.path.join(records(), "%s-launcher-%s.bak" % (NAME, sha(old)))
        if not (os.path.isfile(backup) and not os.path.islink(backup) and sha_file(backup) == sha(old)):
            write_atomic(backup, old, 0o600)
    after = sha(B.launcher_text().encode("utf-8"))
    write_atomic(launcher_record(), (json.dumps({"backup": backup, "backup_sha256": sha(old) if backup else None,
                                                 "after": after, "plan": pid}) + "\n").encode(), 0o600)
    rc = B.cmd_permissions(["--install-launcher"])
    if rc != B.OK or sha_file(L) != after:
        print("the launcher was not installed as planned (rc %s)" % rc, file=sys.stderr)
        return FAIL
    return OK


def do_settings(p, pid):
    user = user_settings()
    if not os.path.exists(user):
        # the record first, so no kill leaves a created file undo cannot see; a file that appears meanwhile is not ours
        os.makedirs(records(), mode=0o700, exist_ok=True)
        rec = created_record(user)
        write_atomic(rec, (json.dumps({"path": user, "plan": pid}) + "\n").encode(), 0o600)
        try:
            fd = os.open(user, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError:
            os.unlink(rec)
            print("%s appeared after the plan: nothing merged" % user, file=sys.stderr)
            return FAIL
        with os.fdopen(fd, "wb") as f:
            f.write(EMPTY)
        print("created %s as {}" % user)
    rc, out = kind("rehearse", user, p.rules)
    line = [ln for ln in p.lines if ln.startswith("bootstrap settings ")][0]
    want = re.search(r" \((?:sha256 ([0-9a-f]{64})|absent: created as \{\} first)\): merge (.*) \(rules sha256 ([0-9a-f]{64})\)$", line)
    before = want.group(1) or sha(EMPTY)
    backed = any(ln.strip().startswith("PLAN backup %s sha256 %s to " % (user, before)) for ln in out)
    if rc != 0 or not backed or merge_of(out, user) != (want.group(2), want.group(3)):
        forward(out)
        print("the merge's own rehearse is not the signed merge: nothing merged", file=sys.stderr)
        return FAIL
    rc, out = kind("run", user, p.rules)
    forward(out)
    if rc != 0 or not any(ln.strip() == "VERDICT run ok" for ln in out):
        print("the merge failed (rc %d)" % rc, file=sys.stderr)
        return FAIL
    return OK


def cmd_do(what, plan_file):
    global KIND_DATA
    signed = signed_lines(plan_file)
    if signed is None:
        return refuse("no signed plan (BATON_PLAN): this step runs only inside the signed run")
    prefix = "bootstrap %s " % what
    code, KIND_DATA = engine_hash()

    def step(p):
        mine = [ln for ln in p.lines if ln.startswith(prefix)]
        if p.refusal or len(mine) != 1 or mine[0] + ENGINE_SUFFIX + code not in signed:
            return refuse("the %s step now plans %r, which is not a line of the signed plan: nothing written"
                          % (what, mine[0] if mine else p.refusal))
        return do_launcher(mine[0], plan_id(plan_file)) if what == "launcher" else do_settings(p, plan_id(plan_file))
    return with_plan(step)


def cmd_postcheck():
    found = B.perm_findings(B.settings_sources())
    old = [f for f in found if is_old_ask(f)]
    found = [f for f in found if not is_old_ask(f)]
    current = B.launcher_current()
    print("launcher %s; permissions --check: %s" % ("current" if current else "NOT current",
                                                    "rc 0" if not found and not old else "%d finding(s)" % (len(found) + len(old))))
    for k, t in found[:10]:
        print("  %s %s" % (k, t))
    if old:
        print("  %d of them old broad ask rule(s), set aside here: kit:permissions-upgrade swaps them" % len(old))
    return OK if current and not found else FAIL


# ── undo: newest write first; a target that moved since the run is left alone ──
def merged_by(path, pid):
    """True when the kind's run record for `path` names the run of this signed plan."""
    try:
        with open(os.path.join(records(), "%s-%s.last" % (NAME, path_key(path)))) as f:
            fields = f.read().split()
    except OSError:
        return False
    return len(fields) == 3 and fields[2] == pid


def undo_settings(pid, kind_ok):
    user = user_settings()
    left = False
    if os.path.exists(user) and not kind_ok:
        if merged_by(user, pid):
            print("LEAVE the engine changed since the signature: the merge's undo is not run with it; the backup of %s "
                  "is in %s" % (user, records()), file=sys.stderr)
            return FAIL
        print("the engine changed since the signature, and this run merged nothing into %s" % user)
    elif os.path.exists(user):
        work = tempfile.mkdtemp(prefix="bootstrap-undo-")
        try:
            rules = os.path.join(work, "rules.json")
            with open(rules, "w") as f:
                f.write("{}\n")
            rc, out = kind("undo", user, rules)
        finally:
            shutil.rmtree(work, ignore_errors=True)
        forward(out)
        if rc != 0 or not any(ln.strip() == "VERDICT undo ok" for ln in out):
            print("LEAVE the merge's undo did not complete (rc %d)" % rc, file=sys.stderr)
            return FAIL
    rec = created_record(user)
    data = read_json(rec) if os.path.exists(rec) else None
    mine_created = isinstance(data, dict) and data.get("plan") == pid and data.get("path") == user
    if not os.path.exists(user) and not mine_created and merged_by(user, pid):
        print("LEAVE %s is gone since this run merged it: its backup is in %s" % (user, records()), file=sys.stderr)
        return FAIL
    if isinstance(data, dict) and data.get("plan") == pid and data.get("path") == user:
        if not os.path.exists(user):
            pass
        elif open(user, "rb").read() == EMPTY:
            os.unlink(user)
            print("removed %s, which this run created as {}" % user)
        else:
            print("LEAVE %s was created by this run but holds other bytes now: left as it is" % user, file=sys.stderr)
            left = True
        if not left:
            os.unlink(rec)
    return FAIL if left else OK


def undo_launcher(pid):
    rec = launcher_record()
    data = read_json(rec) if os.path.exists(rec) else None
    if not isinstance(data, dict) or data.get("plan") != pid:
        print("no launcher record of this run: nothing to put back")
        return OK
    L, backup, after, bsha = B.launcher_path(), data.get("backup"), data.get("after"), data.get("backup_sha256")
    now = sha_file(L) if os.path.exists(L) else None
    if now == after:
        if backup:
            with open(backup, "rb") as f:
                old = f.read()
            if sha(old) != bsha:
                print("LEAVE the launcher backup %s is not the bytes the run saved: compare by hand" % backup, file=sys.stderr)
                return FAIL
            write_atomic(L, old, 0o700)
            print("restored the launcher %s from %s" % (L, backup))
        else:
            os.unlink(L)
            print("removed the launcher %s, which this run installed" % L)
    elif now == bsha:
        print("same launcher as before the run: the install never landed")
    else:
        print("LEAVE the launcher %s changed since the run: compare it with %s by hand" % (L, backup or "(none before)"),
              file=sys.stderr)
        return FAIL
    os.unlink(rec)
    return OK


def cmd_undo(plan_file):
    signed = signed_lines(plan_file)
    if signed is None:
        print("LEAVE no signed plan (BATON_PLAN): cannot tell which run's writes to put back", file=sys.stderr)
        return FAIL
    pid, rc = plan_id(plan_file), OK
    kind_ok = bind_kind(signed)
    if any(ln.startswith("bootstrap settings ") for ln in signed):
        rc = undo_settings(pid, kind_ok) or rc
    if any(ln.startswith("bootstrap launcher ") for ln in signed):
        rc = undo_launcher(pid) or rc
    return rc


def main(argv):
    if argv == ["report"]:
        return cmd_report(hooks=os.environ.get("BATON_PHASE") != "run")
    if argv == ["plan"]:
        return cmd_plan()
    if argv == ["postcheck"]:
        return cmd_postcheck()
    if len(argv) == 4 and argv[0] == "do" and argv[1] in ("launcher", "settings") and argv[2] == "--expect-plan":
        return cmd_do(argv[1], argv[3])
    if len(argv) == 3 and argv[0] == "undo" and argv[1] == "--expect-plan":
        return cmd_undo(argv[2])
    sys.stderr.write(__doc__.split("\n\n")[1] + "\n")
    return USAGE


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
