#!/usr/bin/env python3
"""The engine of the kit baton kit:soul-line: add or remove one SOUL line (`- [S14] text`) in a file, only as an owner step of
the project's brain names it.

    soul_line.py plan --file F --code S14 --action add|remove --text T       one plan line; exit 3 with a REFUSE line otherwise
    soul_line.py do --expect-plan <file> --file F --code … --text T          the write, only when the plan line it computes is a
                                                                             line of the signed plan
    soul_line.py postcheck --file F                                          the file holds the bytes the run wrote
    soul_line.py undo --expect-plan <file> --file F                          the bytes back, while the file holds what the run
                                                                             wrote (else LEAVE, exit 1)

The owner step. vibemaestro-brain writes it when the owner approves `brain owner promote … --soul-line "[S14] T"` (or an
extension's SOUL step) in Claude Code's permission dialog, which shows the line and the file: an owner op of the brain's log
carrying `soul_line` {code, action, text, file, sha}. This engine reads that log itself, at the place the brain keeps it for the
project the run stands in (never a path it is given), and plans only what one such op names: the same code, action and text
(its sha256), and the same file by its real path. Only the newest such op for a code counts: an older step for that code is
dead. A step is used once: the write creates a marker for it with O_EXCL before it touches the file, and a step with a marker
is never planned again (undo removes the marker when it puts the bytes back). The
step is as trustworthy as the brain's owner items: an owner op is written only through the dialog's record; a hand edit of
the log defeats this as it defeats every owner item.

The file. A regular file (not a link), at most 1 MiB, UTF-8. `add` needs no line naming the code and puts `- [S14] T` after
the last line that names any SOUL code, else at the end; `remove` needs exactly one line naming the code, whose text after
`[S14] ` is the step's, and deletes it. Every other byte stays; a line written takes the line ending of the file. Lines end
at a line feed only. Reads and writes go through a handle on the file's directory opened without following a link, and one
run at a time writes a file (a lock beside its record).
The plan line carries the file's sha256 before and after, the step and the sha256 of this file, so the signature binds them.
Python 3.8+, standard library only.
"""
import contextlib
import fcntl
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
NAME = "soul-line"
ENGINE_SUFFIX = ", engine sha256 "
OK, FAIL, REFUSE, USAGE = 0, 1, 3, 64
CODE = r"S(?:[0-9]{2}|[1-9][0-9]{2})"
ANY_CODE = re.compile(r"\[%s\]" % CODE)
FILE_MAX = 1024 * 1024
TEXT_MAX = 600
OWNER_OPS = ("owner-promote", "owner-add")


def sha(data):
    return hashlib.sha256(data).hexdigest()


def refuse(msg):
    sys.stderr.write("REFUSE %s\n" % msg)
    sys.stderr.flush()
    return REFUSE


def baton_state():
    x = os.environ.get("XDG_STATE_HOME", "")
    base = x if os.path.isabs(x) else os.path.join(os.path.expanduser("~"), ".local", "state")
    return os.path.join(base, "vibemaestro", "baton")


def records():
    return os.path.join(baton_state(), "records")


def brain_dir(cwd):
    """The brain's state directory of the project `cwd` stands in: brain_store.state_dir(cwd), the same rule (the git common
    directory, so every worktree shares one brain; its parent's name, or the directory's own, then the SHA-1 of the path)."""
    try:
        out = subprocess.run(["git", "rev-parse", "--git-common-dir"], cwd=cwd, capture_output=True, timeout=10)
        common = out.stdout.decode(sys.getfilesystemencoding(), "surrogateescape").rstrip("\n") if out.returncode == 0 else ""
    except (OSError, subprocess.SubprocessError):
        common = ""
    p = os.path.realpath(os.path.join(cwd, common)) if common else os.path.realpath(cwd)
    name = os.path.basename(os.path.dirname(p)) if os.path.basename(p) == ".git" else os.path.basename(p)
    name = re.sub(r"[^A-Za-z0-9._-]", "_", name)[:40] or "project"
    try:
        raw = p.encode("utf-8")
    except UnicodeEncodeError:
        raw = os.fsencode(p)
    x = os.environ.get("XDG_STATE_HOME", "")
    base = x if os.path.isabs(x) else os.path.join(os.path.expanduser("~"), ".local", "state")
    return os.path.join(base, "vibemaestro", "brain", "%s-%s" % (name, hashlib.sha1(raw).hexdigest()[:12]))


def names_code(op, code):
    """True when the op is an owner step about the SOUL code `code`: a promotion to it (its pointer's one code, its own or an
    extension's `soul`), a demotion of it (`owner-demote`, an item an extension marked `demoted_from`), or a SOUL line for it."""
    kind = op.get("op")
    if not isinstance(kind, str) or not kind.startswith("owner-"):
        return False
    sl = op.get("soul_line")
    if isinstance(sl, dict) and sl.get("code") == code:
        return True
    exts = [op.get("ext"), (op.get("item") or {}).get("ext") if isinstance(op.get("item"), dict) else None]
    vals = [v for e in exts if isinstance(e, dict) for v in e.values() if isinstance(v, dict)]
    if kind == "owner-promote":
        codes = re.findall(r"\[(%s)\]" % CODE, op.get("pointer") or "") if isinstance(op.get("pointer"), str) else []
        if op.get("soul") == code or any(v.get("soul") == code for v in vals) or codes == [code]:
            return True
    return (kind == "owner-demote" and op.get("soul") == code) or any(v.get("demoted_from") == code for v in vals)


def step_marker(step):
    return os.path.join(records(), "%s-step-%s.used" % (NAME, step))


def find_step(code, action, text, path):
    """(step id, None) when the newest owner op of the brain's log that carries a SOUL line for `code` names exactly this line
    and no run used it yet, else (None, why). An older step for the code is dead once a newer one exists: undoing the marker
    of a spent step can only bring back the owner's latest word on that code, never an earlier one."""
    log = os.path.join(brain_dir(os.getcwd()), "hot.jsonl")
    try:
        with open(log, "rb") as f:
            lines = f.read().split(b"\n")
    except OSError:
        return None, "no brain log for this project (%s): no owner step names a SOUL line here" % log
    want = {"code": code, "action": action, "sha": sha(text.encode("utf-8")), "file": path}
    for raw in reversed(lines):
        try:
            op = json.loads(raw)
        except ValueError:
            continue
        if not isinstance(op, dict) or not names_code(op, code):
            continue
        sl = op.get("soul_line")
        if not isinstance(sl, dict) or sl.get("code") != code or op.get("op") not in OWNER_OPS:
            return None, "the owner's newest step for [%s] carries no SOUL line (%s): no older one counts" % (code, op.get("op"))
        if (op.get("confirm") or {}).get("asked") is not True:
            return None, "the owner's newest step for [%s] has no dialog behind it" % code
        if {k: sl.get(k) for k in want} != want or sl.get("text") != text:
            return None, ("the owner's newest step for [%s] is %s %r in %s, not this line" % (
                code, sl.get("action"), sl.get("text"), sl.get("file")))
        step = sha(raw)[:32]
        if os.path.exists(step_marker(step)):
            return None, "the owner step for this line was used already"
        return step, None
    return None, "no owner step of this project's brain names %s [%s] %r in %s" % (action, code, text, path)


class Plan:
    def __init__(self):
        self.line = self.refusal = self.data = self.before = self.step = None


def check_text(text):
    if not text or len(text) > TEXT_MAX or text != text.strip() or any(ord(c) < 32 or ord(c) == 127 for c in text):
        return "the text is 1 to %d characters on one line, no control character, no space at either end" % TEXT_MAX
    if ANY_CODE.search(text):
        return "the text names a SOUL code itself: one line holds one code"
    return None


@contextlib.contextmanager
def parent(f):
    """A handle on the file's directory, opened without following a link and checked to be the directory the path names (its
    real path, its device and inode): every read and write after it goes through this handle, so a directory swapped in later
    is never reached."""
    d = os.path.dirname(f)
    fd = os.open(d, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        a, b = os.fstat(fd), os.stat(d)
        if os.path.realpath(d) != d or (a.st_dev, a.st_ino) != (b.st_dev, b.st_ino):
            raise OSError("the directory of %s moved or is reached through a link" % f)
        yield fd
    finally:
        os.close(fd)


def read_in(dfd, name):
    """(bytes, mode) of the regular file `name` in the directory handle, opened without following a link and without waiting
    (a FIFO); None when it is not a regular file or is over FILE_MAX."""
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dfd)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_size > FILE_MAX:
            return None
        out = b""
        while len(out) <= FILE_MAX:
            chunk = os.read(fd, FILE_MAX + 1 - len(out))
            if not chunk:
                break
            out += chunk
        return (out, stat.S_IMODE(st.st_mode)) if len(out) <= FILE_MAX else None
    finally:
        os.close(fd)


def write_in(dfd, name, data, mode):
    """`name` replaced in the directory handle by a new file of `data` with `mode`."""
    tmp = ".%s.baton-new.%s" % (name, os.urandom(6).hex())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=dfd)
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
            fh.flush()
            os.fsync(fh.fileno())
            os.fchmod(fh.fileno(), mode)
        os.replace(tmp, name, src_dir_fd=dfd, dst_dir_fd=dfd)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp, dir_fd=dfd)
        raise


def compute(a):
    """The change planned on the file as it is now, for the arguments `a` (file, code, action, text)."""
    p = Plan()
    if not re.fullmatch(CODE, a["code"] or "") or a["action"] not in ("add", "remove"):
        p.refusal = "--code is S and two digits (or three, no leading zero) and --action add or remove"
        return p
    why = check_text(a["text"])
    if why:
        p.refusal = why
        return p
    f = a["file"]
    if not f or not os.path.isabs(f):
        p.refusal = "--file is an absolute path"
        return p
    if os.path.realpath(f) != os.path.normpath(f) or f != os.path.normpath(f):
        p.refusal = "%s goes through a link or holds . or ..: name the file by its real path" % f
        return p
    try:
        with parent(f) as dfd:
            got = read_in(dfd, os.path.basename(f))
    except OSError as e:
        p.refusal = "%s cannot be read (%s)" % (f, e.__class__.__name__ if e.errno else e)
        return p
    if got is None:
        p.refusal = "%s is not a regular file of at most 1 MiB (a link, a directory, a FIFO or a device)" % f
        return p
    raw = got[0]
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        p.refusal = "%s is not UTF-8" % f
        return p
    p.step, why = find_step(a["code"], a["action"], a["text"], f)
    if why:
        p.refusal = why
        return p
    tag = "[%s]" % a["code"]
    lines = re.split(r"(?<=\n)", text)               # lines end at \n only: no other character may split one
    if lines and lines[-1] == "":
        lines.pop()
    hits = [i for i, ln in enumerate(lines) if tag in ln]
    if a["action"] == "add":
        if hits:
            p.refusal = "%s already has a line naming %s" % (f, tag)
            return p
        at = max([i for i, ln in enumerate(lines) if ANY_CODE.search(ln)], default=len(lines) - 1)
        eol = "\r\n" if lines and lines[at].endswith("\r\n") else "\n"
        if lines and not lines[at].endswith(("\n", "\r")):
            lines[at] += eol
        lines.insert(at + 1, "- %s %s%s" % (tag, a["text"], eol))
    else:
        if len(hits) != 1:
            p.refusal = "%s has %d lines naming %s: remove needs exactly one" % (f, len(hits), tag)
            return p
        m = re.fullmatch(r"[ \t]*[-*] %s (.*?)[ \t]*" % re.escape(tag), lines[hits[0]].rstrip("\r\n"))
        if not m or m.group(1) != a["text"]:
            p.refusal = "the %s line of %s is not the line the owner saw (- %s %s): nothing to remove" % (tag, f, tag, a["text"])
            return p
        del lines[hits[0]]
    p.data = "".join(lines).encode("utf-8")
    p.before = sha(raw)
    p.line = '%s %s %s in %s: "- %s %s"; sha256 %s -> %s; owner step %s' % (
        NAME, a["action"], tag, f, tag, a["text"], p.before, sha(p.data), p.step)
    return p


def engine_hash():
    with open(os.path.realpath(__file__), "rb") as fh:
        return sha(fh.read())


def write_atomic(path, data, mode):
    fd, tmp = tempfile.mkstemp(prefix=".%s.baton-new." % os.path.basename(path), dir=os.path.dirname(path))
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def record_path(path):
    return os.path.join(records(), "%s-%s.last" % (NAME, sha(path.encode("utf-8", "surrogateescape"))[:16]))


def plan_id(plan_file):
    try:
        with open(plan_file, "rb") as fh:
            return sha(fh.read())
    except (OSError, TypeError):
        return ""


def signed_lines(plan_file):
    try:
        with open(plan_file, encoding="utf-8", errors="surrogateescape") as fh:
            return fh.read().splitlines()
    except (OSError, TypeError):
        return None


def sha_now(path):
    try:
        with parent(path) as dfd:
            got = read_in(dfd, os.path.basename(path))
    except OSError:
        return None
    return sha(got[0]) if got else None


def cmd_plan(a):
    p = compute(a)
    if p.refusal:
        return refuse(p.refusal)
    print(p.line)
    return OK


def cmd_do(plan_file, a):
    signed = signed_lines(plan_file)
    if signed is None:
        return refuse("no signed plan (BATON_PLAN): this step runs only inside the signed run")
    p = compute(a)
    if p.refusal or p.line + ENGINE_SUFFIX + engine_hash() not in signed:
        return refuse("the change now plans %r, which is not a line of the signed plan: nothing written" % (p.line or p.refusal))
    f = a["file"]
    os.makedirs(records(), mode=0o700, exist_ok=True)
    lk = os.open(record_path(f) + ".lock", os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    with os.fdopen(lk, "w") as lk:                  # one write at a time on this file: two runs never read the same bytes
        fcntl.flock(lk, fcntl.LOCK_EX)
        try:                                        # the step is spent before the file is touched: two runs cannot both use it
            os.close(os.open(step_marker(p.step), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600))
        except FileExistsError:
            return refuse("the owner step %s was used by another run: nothing written" % p.step)
        try:
            with parent(f) as dfd:
                got = read_in(dfd, os.path.basename(f))
        except OSError:
            got = None
        if got is None or sha(got[0]) != p.before:
            os.unlink(step_marker(p.step))           # nothing written: the step stands for a new run
            return refuse("%s changed or went away after the plan: nothing written" % f)
        with parent(f) as dfd:
            old, mode = got
            backup = os.path.join(records(), "%s-%s.bak" % (NAME, p.before))
            if sha_now(backup) != p.before:
                write_atomic(backup, old, 0o600)
            rec = {"path": f, "backup": backup, "before": p.before, "after": sha(p.data), "mode": mode,
                   "plan": plan_id(plan_file), "step": p.step}
            write_atomic(record_path(f), (json.dumps(rec) + "\n").encode(), 0o600)  # first: undo always sees the write
            write_in(dfd, os.path.basename(f), p.data, mode)
            got = read_in(dfd, os.path.basename(f))
        if got is None or sha(got[0]) != rec["after"]:
            print("%s does not hold the planned bytes after the write" % f, file=sys.stderr)
            return FAIL
    print("%s %s [%s] in %s: sha256 %s -> %s; backup %s" % (NAME, a["action"], a["code"], f, p.before, rec["after"], backup))
    return OK


def read_record(f):
    try:
        with open(record_path(f)) as fh:
            rec = json.load(fh)
    except (OSError, ValueError):
        return None
    return rec if isinstance(rec, dict) and rec.get("path") == f else None


def cmd_postcheck(a):
    rec = read_record(a["file"])
    now = sha_now(a["file"])
    ok = rec is not None and now == rec.get("after")
    print("%s holds %s" % (a["file"], "the bytes the run wrote" if ok else "other bytes (sha256 %s)" % now))
    return OK if ok else FAIL


def cmd_undo(plan_file, a):
    pid = plan_id(plan_file)
    if not pid:
        print("LEAVE no signed plan (BATON_PLAN): cannot tell which run's write to put back", file=sys.stderr)
        return FAIL
    f = a["file"]
    rec = read_record(f)
    if rec is None or rec.get("plan") != pid:
        print("no record of this run: nothing of it to put back")
        return OK
    now = sha_now(f)
    if now == rec.get("after"):
        with open(rec["backup"], "rb") as fh:
            old = fh.read()
        if sha(old) != rec.get("before"):
            print("LEAVE the backup %s is not the bytes the run saved: compare by hand" % rec["backup"], file=sys.stderr)
            return FAIL
        with parent(f) as dfd:
            write_in(dfd, os.path.basename(f), old, int(rec.get("mode", 0o600)))
        print("restored %s from %s (sha256 %s)" % (f, rec["backup"], rec["before"]))
    elif now == rec.get("before"):
        print("same %s as before the run: the write never landed" % f)
    else:
        print("LEAVE %s changed since the run (sha256 %s): compare it with %s by hand" % (f, now, rec["backup"]), file=sys.stderr)
        return FAIL
    if isinstance(rec.get("step"), str) and re.fullmatch(r"[0-9a-f]{32}", rec["step"]):
        try:                                        # nothing of the step landed: the owner's approval stands for a new run
            os.unlink(step_marker(rec["step"]))
        except FileNotFoundError:
            pass
    os.unlink(record_path(f))
    return OK


def parse(argv):
    """{file, code, action, text} of `--file F --code C --action A --text T` (each once, in any order); None otherwise."""
    keys = {"--file": "file", "--code": "code", "--action": "action", "--text": "text"}
    out = {}
    if len(argv) % 2:
        return None
    for k, v in zip(argv[::2], argv[1::2]):
        if k not in keys or keys[k] in out:
            return None
        out[keys[k]] = v
    return out


def main(argv):
    mode, rest, plan_file = (argv[0] if argv else ""), argv[1:], None
    if mode in ("do", "undo"):
        if rest[:1] != ["--expect-plan"] or len(rest) < 2:
            mode = ""
        else:
            plan_file, rest = rest[1], rest[2:]
    a = parse(rest)
    if mode in ("plan", "do") and a is not None and set(a) == {"file", "code", "action", "text"}:
        return cmd_plan(a) if mode == "plan" else cmd_do(plan_file, a)
    if mode in ("postcheck", "undo") and a is not None and "file" in a:
        return cmd_postcheck(a) if mode == "postcheck" else cmd_undo(plan_file, a)
    sys.stderr.write(__doc__.split("\n\n")[1] + "\n")
    return USAGE


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
