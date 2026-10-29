#!/usr/bin/env python3
"""The engine of the kit baton kit:permissions-upgrade: in one owner-signed run, swap the old broad ask rules of the baton
permission block (baton.py OLD_ASKS, the block before the anchored rules) for the anchored ones (baton.py owner_asks) in the user settings.

    permissions_upgrade.py plan                         one plan line (`upgrade settings …`); exit 3 with a REFUSE line when there
                                                        is nothing to do or the swap cannot reach a clean `permissions --check`
    permissions_upgrade.py do --expect-plan <file>      the write, only when the plan line it computes is a line of the signed plan
    permissions_upgrade.py postcheck                    `permissions --check` finds no rule finding (the launcher's set aside)
    permissions_upgrade.py undo --expect-plan <file>    put the file back byte for byte, while it holds what the run wrote (else
                                                        LEAVE, exit 1)

The swap changes `permissions.ask` of the user settings only: every rule there that is one of the old patterns, written exactly
so, is removed; every anchored rule not there yet is added after the rest; no other rule or list changes (the file is
written back as JSON with two-space indent, so a key written twice keeps its last value). The plan line names each rule removed and added, the file's sha256 before and
after, and the sha256 of the code that writes (this file and baton.py), so the owner's signature binds the very bytes. An old
pattern in another settings scope (managed, the project's) is not this run's: the plan refuses and names it.

The write keeps the old bytes as a backup under the baton state directory and a record (the backup, both sha256 and the signed
plan's sha256) before it replaces the file through a new file next to it, with the file's mode. Undo acts only for the record of
this signed plan and only while the file has the after sha256: it puts the backup's bytes back with the same mode. A file that
changed since is left alone (LEAVE).
Python 3.8+, standard library only.
"""
import hashlib
import importlib.util
import json
import os
import shutil
import stat
import sys
import tempfile

sys.dont_write_bytecode = True
PLUGIN_ROOT = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
ENGINE_FILES = (os.path.realpath(__file__), os.path.join(PLUGIN_ROOT, "scripts", "baton.py"))
NAME = "permissions-upgrade"
LINE = "upgrade settings "
ENGINE_SUFFIX = ", engine sha256 "
OK, FAIL, REFUSE, USAGE = 0, 1, 3, 64


def load_baton():
    spec = importlib.util.spec_from_file_location("baton_for_upgrade", ENGINE_FILES[1])
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


def records():
    return os.path.join(B.state_dir(), "records")


def record_path(path):
    return os.path.join(records(), "%s-%s.last" % (NAME, sha(path.encode("utf-8", "surrogateescape"))[:16]))


def plan_id(plan_file):
    return sha_file(plan_file) if plan_file and os.path.isfile(plan_file) else ""


def signed_lines(plan_file):
    try:
        with open(plan_file, encoding="utf-8", errors="surrogateescape") as f:
            return f.read().splitlines()
    except (OSError, TypeError):
        return None


def engine_hash():
    h = hashlib.sha256()
    for path in ENGINE_FILES:
        h.update(sha_file(path).encode() + b"\n")
    return h.hexdigest()


def write_atomic(path, data, mode):
    fd, tmp = tempfile.mkstemp(prefix=".%s.baton-new." % os.path.basename(path), dir=os.path.dirname(path))
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def rule_findings(found):
    """The findings of `permissions --check` but the launcher's (an installed launcher is kit:coordinator-bootstrap's)."""
    return [f for f in found if not f[1].startswith("the launcher ")]


class Plan:
    def __init__(self):
        self.line, self.refusal, self.data, self.before = None, None, None, None


def compute():
    """The swap planned on the user settings as they are now."""
    p = Plan()
    other = B.registry_other()
    if other:
        p.refusal = "this session runs vibemaestro-sdlc %s, the installed one is %s: restart Claude Code; nothing written" % other[:2]
        return p
    user = user_settings()
    if os.path.islink(user):
        p.refusal = "%s is a symbolic link: the swap names the file itself" % user
        return p
    if not os.path.isfile(user):
        p.refusal = "nothing to do: there is no user settings file %s, so no old ask rule" % user
        return p
    with open(user, "rb") as f:
        raw = f.read()
    try:
        s = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as e:
        p.refusal = "%s is not JSON (%s): fix it by hand, then run again" % (user, e)
        return p
    perms = s.get("permissions") if isinstance(s, dict) else None
    ask = perms.get("ask") if isinstance(perms, dict) else None
    if not isinstance(ask, list) or not all(isinstance(r, str) for r in ask):
        p.refusal = "nothing to do: %s has no permissions.ask list of rules" % user
        return p
    old = [r for r in ask if r in B.OLD_ASKS]
    elsewhere = sorted(set("`%s` (%s)" % (text, where) for k, _t, _c, text, where in B.load_rules(
        [src for src in B.settings_sources() if src[0] != "user"])[0] if k == "ask" and text in B.OLD_ASKS))
    if elsewhere:
        p.refusal = ("an old ask rule sits in another settings scope, which this run does not change: %s; the owner removes it "
                     "there by hand" % "; ".join(elsewhere))
        return p
    if not old:
        p.refusal = "nothing to do: %s holds none of the old broad ask rules" % user
        return p
    kept = [r for r in ask if r not in B.OLD_ASKS]
    added = [r for r in B.owner_asks() if r not in kept]
    perms["ask"] = kept + added
    data = (json.dumps(s, indent=2) + "\n").encode("utf-8")
    work = tempfile.mkdtemp(prefix="upgrade-")
    try:
        copy = os.path.join(work, "settings.json")
        with open(copy, "wb") as f:
            f.write(data)
        after = rule_findings(B.perm_findings([(lab, copy if lab == "user" else path) for lab, path in B.settings_sources()]))
    finally:
        shutil.rmtree(work, ignore_errors=True)
    if after:
        p.refusal = ("the swap cannot reach a clean permissions --check (it changes the ask rules only); the owner fixes these "
                     "first, by hand or with kit:coordinator-bootstrap: %s" % "; ".join("%s %s" % f for f in after).replace(copy, user))
        return p
    p.data, p.before = data, sha(raw)
    p.line = "%s%s (sha256 %s): ask -%d %s +%d %s, to sha256 %s" % (LINE, user, p.before, len(old), json.dumps(old), len(added),
                                                                  json.dumps(added), sha(data))
    return p


def cmd_plan():
    p = compute()
    if p.refusal:
        return refuse(p.refusal)
    print(p.line)
    return OK


def cmd_do(plan_file):
    signed = signed_lines(plan_file)
    if signed is None:
        return refuse("no signed plan (BATON_PLAN): this step runs only inside the signed run")
    p = compute()
    if p.refusal or p.line + ENGINE_SUFFIX + engine_hash() not in signed:
        return refuse("the swap now plans %r, which is not a line of the signed plan: nothing written" % (p.line or p.refusal))
    user = user_settings()
    mode = stat.S_IMODE(os.stat(user).st_mode)
    with open(user, "rb") as f:
        old = f.read()
    if sha(old) != p.before:
        return refuse("%s changed after the plan: nothing written" % user)
    os.makedirs(records(), mode=0o700, exist_ok=True)
    backup = os.path.join(records(), "%s-%s.json" % (NAME, p.before))
    if not (os.path.isfile(backup) and not os.path.islink(backup) and sha_file(backup) == p.before):
        write_atomic(backup, old, 0o600)
    rec = {"path": user, "backup": backup, "before": p.before, "after": sha(p.data), "mode": mode, "plan": plan_id(plan_file)}
    write_atomic(record_path(user), (json.dumps(rec) + "\n").encode(), 0o600)      # first: no kill leaves a swap undo cannot see
    write_atomic(user, p.data, mode)
    if sha_file(user) != rec["after"]:
        print("%s does not hold the planned bytes after the write" % user, file=sys.stderr)
        return FAIL
    print("swapped the ask rules of %s: sha256 %s -> %s; backup %s" % (user, p.before, rec["after"], backup))
    return OK


def cmd_postcheck():
    found = rule_findings(B.perm_findings(B.settings_sources()))
    print("permissions --check: %s" % ("no rule finding" if not found else "%d rule finding(s)" % len(found)))
    for k, t in found[:10]:
        print("  %s %s" % (k, t))
    return OK if not found else FAIL


def cmd_undo(plan_file):
    pid = plan_id(plan_file)
    if not pid:
        print("LEAVE no signed plan (BATON_PLAN): cannot tell which run's write to put back", file=sys.stderr)
        return FAIL
    user = user_settings()
    try:
        with open(record_path(user)) as f:
            rec = json.load(f)
    except (OSError, ValueError):
        rec = None
    if not isinstance(rec, dict) or rec.get("plan") != pid or rec.get("path") != user:
        print("no record of this run: nothing of it to put back")
        return OK
    now = sha_file(user) if os.path.isfile(user) and not os.path.islink(user) else None
    if now == rec.get("after"):
        with open(rec["backup"], "rb") as f:
            old = f.read()
        if sha(old) != rec.get("before"):
            print("LEAVE the backup %s is not the bytes the run saved: compare by hand" % rec["backup"], file=sys.stderr)
            return FAIL
        write_atomic(user, old, int(rec.get("mode", 0o600)))
        print("restored %s from %s (sha256 %s)" % (user, rec["backup"], rec["before"]))
    elif now == rec.get("before"):
        print("same %s as before the run: the swap never landed" % user)
    else:
        print("LEAVE %s changed since the run (sha256 %s): compare it with %s by hand" % (user, now, rec["backup"]),
              file=sys.stderr)
        return FAIL
    os.unlink(record_path(user))
    return OK


def main(argv):
    if argv == ["plan"]:
        return cmd_plan()
    if argv == ["postcheck"]:
        return cmd_postcheck()
    if len(argv) == 3 and argv[0] == "do" and argv[1] == "--expect-plan":
        return cmd_do(argv[2])
    if len(argv) == 3 and argv[0] == "undo" and argv[1] == "--expect-plan":
        return cmd_undo(argv[2])
    sys.stderr.write(__doc__.split("\n\n")[1] + "\n")
    return USAGE


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
