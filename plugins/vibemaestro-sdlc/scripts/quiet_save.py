#!/usr/bin/env python3
"""The quiet save of the everyday mode: the person's folder is saved locally after each turn, in a git history the kit itself
created there (owner decision: never into a git repository that was there before), never pushed anywhere.

  quiet_save.py save          the Stop hook (async): save the folder of the session (payload on stdin), always exit 0, print nothing
  quiet_save.py list [N] [--dir D]
                              the last N saves (default 20) in plain words: number, time, the files that changed, the id
  quiet_save.py copy <id or number> [--dir D]
                              write that save, as a copy, into a new folder ban-cu/<time of the save>/ inside the folder (ban-cu-2/
                              ... when ban-cu is the person's); nothing else changes (but one line added to .ignore), nor the
                              history, its index or HEAD
  quiet_save.py drop-copy <folder/copy> [--dir D]
                              remove one copy the kit made (on its list in the history's state), named as copy's answer gave it
                              (on the person's word only); anything else is refused

`save` runs only in everyday mode (scripts/everyday.py, a worker or coordinated session excluded) and only in a folder that is not
inside another repository: a plain folder (the first save creates the history and marks it), or one the kit created. It never
saves the root, the home folder or a parent of it, Desktop/Documents/Downloads or a OneDrive folder itself, a first save of more
than MAX_FILES files, a folder with a remote (the developer flow), a folder git cannot read, or during a merge, rebase, cherry-pick
or revert. Each attempt leaves its result in everyday.trace_path; a save that did not keep the work (failed, or skipped to keep
something safe) or never finished is said in one plain line at the next everyday session start (everyday.save_trouble)."""
import json
import os
import shutil
import stat
import subprocess
import sys
import time

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import everyday  # noqa: E402

MAX_FILES = 2000
LOCK_STALE = 600                        # seconds after which a lock left by a killed save (or a killed git) is taken over
GIT_TIMEOUT = 60                        # seconds for one git call; a call killed at it leaves git's index.lock, cleared below
TOP_ONLY = ("desktop", "documents", "downloads")
# the private ignore list, in the repository's info/exclude (never the person's .gitignore): secrets and bulky generated folders
# Names, not contents: an ordinary file can carry one of these names (a Keynote deck is *.key) and is then not saved either.
EXCLUDE = ("*.env", ".env.*", ".envrc", "*.key", "*.pem", "*.pfx", "*.p12", "*.ppk", "*.jks", "*.keystore", "*.ovpn", "*.kdbx",
           "id_rsa*", "id_dsa*", "id_ecdsa*", "id_ed25519*", "credentials", "credentials.*", ".credentials*", "secret.*", "secrets.*",
           "*.secret", "client_secret*.json", "*service-account*.json", "password.txt", "passwords.*", "token.json", "tokens.json",
           ".htpasswd", ".npmrc", ".pypirc", ".netrc", ".git-credentials", ".aws/", ".ssh/", ".docker/", ".kube/",
           ".claude/settings.local.json",
           "node_modules/", ".venv/", "venv/", "__pycache__/")
OLD = "ban-cu"                            # the folder of old copies (owner decision 5), or ban-cu-2, ... when the name is the person's
MARKER = "DAY-LA-BAN-CU.txt"              # at the top of the kit's folder only, written when the kit makes it: no copy holds it
COPIES = "quiet-save-copies"              # in the git directory: the folders and copies this kit made ("ban-cu", "ban-cu/<copy>")
KIT_BLOCK = "# folders of old copies the kit made (the kit rewrites the lines below)"   # last in info/exclude
MARKER_TEXT = ("ĐÂY LÀ BẢN CŨ: các thư mục ở đây là bản chép từ những lần kit tự lưu thư mục này. Đây không phải bài hiện tại; "
               "đừng sửa ở đây. Lấy tệp nào về thì chép nó ra thư mục làm việc.\n"
               "THESE ARE OLD COPIES: each folder here is a copy of one of the kit's saves of this folder. This is not the current "
               "work; do not edit here. To bring a file back, copy it out to the work folder.\n")
BULKY = ("node_modules", ".venv", "venv", "__pycache__")
NOT_COUNTED = BULKY + (".git",)          # folders the first-save count skips (never saved anyway)
NOT_CONTENT = (".vibemaestro", ".claude", ".DS_Store")   # a folder holding only these is empty: the first save waits
IDENT = {"GIT_AUTHOR_NAME": "quiet-save", "GIT_AUTHOR_EMAIL": "", "GIT_COMMITTER_NAME": "quiet-save", "GIT_COMMITTER_EMAIL": ""}


class Skip(Exception):
    """Not saved, on purpose: `trace` is True when the person must hear it (their work is not kept), False when it is by design."""
    def __init__(self, why, trace=True, state="skipped"):
        super().__init__(why)
        self.why, self.trace, self.state = why, trace, state


def git(d, *args, ident=False, raw=False, index=None):
    """(rc, stdout, stderr) of git in `d`; rc 127 when git cannot be started, 124 when it times out. `index`: a temporary index
    file instead of the history's own (the copy reads a save through it and leaves the real one alone)."""
    env = dict(os.environ, LC_ALL="C", **(IDENT if ident else {}))
    for k in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE"):
        env.pop(k, None)                # the save is about this folder, whatever the caller's environment points at
    if index:
        env["GIT_INDEX_FILE"] = index
    try:
        p = subprocess.run(["git", "-C", d, "-c", "core.autocrlf=false", "-c", "core.quotePath=false"] + list(args),
                           stdin=subprocess.DEVNULL, capture_output=True, text=True, encoding="utf-8", errors="surrogateescape",
                           env=env, timeout=GIT_TIMEOUT)
    except OSError:
        return 127, "", "git cannot be started"
    except subprocess.TimeoutExpired:
        return 124, "", "Git took more than %d seconds (a very large file, or one not downloaded yet?)" % GIT_TIMEOUT
    return p.returncode, (p.stdout if raw else p.stdout.strip()), p.stderr.strip()


def fs(p):
    """A path git printed (UTF-8) in the form the OS functions take: the same on Windows and a UTF-8 system, the bytes kept on others."""
    return os.fsdecode(p.encode("utf-8", "surrogateescape"))


def trace(troot, state, why=""):
    """Leave this attempt's result for the next session start (best effort: a state directory that cannot be written costs only the
    trace)."""
    path = everyday.trace_path(troot)
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = path + ".%d.tmp" % os.getpid()
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump({"state": state, "why": why, "at": time.time(), "folder": os.path.realpath(troot)}, f)
        os.replace(tmp, path)
    except OSError:
        pass


def place_check(d):
    """Raise Skip when the folder `d` (real path) is a place the save must never turn into a repository."""
    home = os.path.expanduser("~")
    if not home or home == "~" or not os.path.isdir(home):
        raise Skip("the home folder is not known, so the folder cannot be checked")
    home = os.path.realpath(home)
    if os.path.dirname(d) == d:
        raise Skip("the root of a drive is not saved; open a project folder instead")
    if home == d or home.startswith(d.rstrip(os.sep) + os.sep):
        raise Skip("the home folder (or a folder above it) is not saved; open a project folder instead")
    if d.startswith(home + os.sep):
        parts = os.path.relpath(d, home).lower().split(os.sep)
        if (len(parts) == 1 and (parts[0] in TOP_ONLY or parts[0].startswith("onedrive"))) or \
           (len(parts) == 2 and parts[0].startswith("onedrive") and parts[1] in ("desktop", "documents")):
            raise Skip("%s itself is not saved; make a folder for the project inside it" % os.path.relpath(d, home))
    for name, real in protected(home):     # the same folders when they are links to somewhere else (a moved Desktop)
        if d == real:
            raise Skip("%s itself is not saved; make a folder for the project inside it" % name)


def protected(home):
    """[(name, real path)] of Desktop/Documents/Downloads and the OneDrive folders (and their Desktop/Documents) in `home`."""
    out = []
    try:
        top = os.listdir(home)
    except OSError:
        return out
    for e in top:
        low, path = e.lower(), os.path.join(home, e)
        if low in TOP_ONLY or low.startswith("onedrive"):
            out.append((e, os.path.realpath(path)))
        if low.startswith("onedrive") and os.path.isdir(path):
            try:
                out += [(os.path.join(e, s), os.path.realpath(os.path.join(path, s))) for s in os.listdir(path)
                        if s.lower() in ("desktop", "documents")]
            except OSError:
                pass
    return out


def too_many(d):
    """More than MAX_FILES files under `d` (the walk stops at MAX_FILES + 1)."""
    n = 0
    for root, dirs, files in os.walk(d):
        dirs[:] = [x for x in dirs if x not in NOT_COUNTED and not os.path.lexists(os.path.join(root, x, ".git"))]
        n += len(files)
        if n > MAX_FILES:
            return True
    return False


def repo_of(d):
    """The kit's repository at `d`: Skip when it is not one the save may write. A plain folder becomes one."""
    rc, top, err = git(d, "rev-parse", "--show-toplevel")
    if rc == 127:
        raise Skip("Git is not installed, so nothing can be saved", state="failed")
    if rc != 0:
        if everyday._under_git(d):        # a .git here or above that git will not read (ownership, permissions, a broken file)
            raise Skip("Git cannot read this folder (%s)" % (err.splitlines() or ["no message"])[0][:160], state="failed")
        place_check(d)
        try:
            empty = not any(e not in NOT_CONTENT for e in os.listdir(d))
        except OSError:
            empty = False
        if empty:
            raise Skip("the folder is empty", trace=False, state="unchanged")
        if too_many(d):
            raise Skip("it holds more than %d files; the first save waits for a smaller project folder" % MAX_FILES)
        if git(d, "init", "-q")[0] != 0 or git(d, "config", "--local", everyday.MARK, "true")[0] != 0:
            raise Skip("Git could not start a history in this folder", state="failed")
        return d
    if os.path.realpath(fs(top)) != d:
        raise Skip("this folder sits inside another Git repository (%s), which the save never writes" % top)
    if git(d, "config", "--local", "--get", everyday.MARK)[1] != "true":
        raise Skip("this folder has its own Git history, which the save never writes", trace=False)
    return d


def history_repo(d):
    """The kit's history at `d` for list, copy and drop-copy: Skip with plain words when there is none, or it is not the kit's."""
    rc, top, err = git(d, "rev-parse", "--show-toplevel")
    if rc == 127:
        raise Skip("Git is not installed", trace=False)
    if rc != 0:
        if everyday.kit_made(d):
            raise Skip("Git cannot read this folder (%s)" % (err.splitlines() or ["no message"])[0][:160], trace=False)
        raise Skip("this folder has no saves yet", trace=False)
    if os.path.realpath(fs(top)) != d:
        raise Skip("this folder sits inside another Git repository, which the save never writes", trace=False)
    if git(d, "config", "--local", "--get", everyday.MARK)[1] != "true":
        raise Skip("this folder has its own Git history, which the save never writes", trace=False)
    return d


def ready_check(d):
    """Raise Skip when the repository is in a state where a commit would be wrong."""
    rc, remotes, _e = git(d, "remote")
    if rc != 0:
        raise Skip("Git could not list this folder's remotes", state="failed")
    if remotes:
        raise Skip("the folder is connected to a remote: the developer flow keeps it now", trace=False)
    if git(d, "symbolic-ref", "-q", "HEAD")[0] != 0:
        raise Skip("the folder's history is not on a branch (detached), so nothing was saved")
    for name in ("MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply"):
        if os.path.exists(os.path.join(d, git(d, "rev-parse", "--git-path", name)[1])):
            raise Skip("a merge or a similar Git operation is half done in this folder, so nothing was saved")


def marked(path):
    """`path` carries the kit's plain-words marker: a real folder directly inside its parent (a link or a Windows junction, which
    islink does not see, resolves elsewhere) holding the marker as a real file."""
    m = os.path.join(path, MARKER)
    return os.path.isdir(path) and os.path.realpath(path) == os.path.join(os.path.realpath(os.path.dirname(path)), os.path.basename(path)) \
        and os.path.isfile(m) and not os.path.islink(m)


def kit_name(n):
    """`n` is ban-cu or ban-cu-<number>, the names the kit gives its folders of old copies."""
    k = n[len(OLD) + 1:]
    return n == OLD or (n.startswith(OLD + "-") and k.isascii() and k.isdigit())


def made_by_kit(d):
    """The folders and copies this kit made, read from the history's own state (never from a file in the work folder)."""
    try:
        return set(x for x in open(os.path.join(d, git(d, "rev-parse", "--git-path", COPIES)[1]), encoding="utf-8").read().split("\n") if x)
    except FileNotFoundError:
        return set()


def set_made(d, add=(), drop=()):
    """Record `add` and forget `drop` in the kit's list, the file replaced whole."""
    path = os.path.join(d, git(d, "rev-parse", "--git-path", COPIES)[1])
    have = made_by_kit(d)
    want = (have | set(add)) - set(drop)
    if want != have:
        with open(path + ".new", "w", encoding="utf-8") as f:
            f.write("".join(x + "\n" for x in sorted(want)))
        os.replace(path + ".new", path)


def kit_folder(d, n, made):
    """`n` at the top of `d` is a folder of old copies the kit made: the kit's name, its marker, and on the kit's list."""
    return kit_name(n) and n in made and marked(os.path.join(d, n))


def kit_dirs(d):
    """The kit's folders of old copies at the top of `d`, each left out of the saves (by name, in info/exclude)."""
    made = made_by_kit(d)
    return sorted(n for n in os.listdir(d) if kit_folder(d, n, made))


def excludes(d):
    path = os.path.join(d, git(d, "rev-parse", "--git-path", "info/exclude")[1])
    try:
        lines = open(path, encoding="utf-8", errors="surrogateescape").read().split("\n")
    except FileNotFoundError:
        lines = [""]
    if lines[-1] == "":
        lines.pop()
    mine = lines
    if KIT_BLOCK in lines:                # the kit's block: the lines it wrote (its listed folders) go, every other line is kept
        i, listed = lines.index(KIT_BLOCK), made_by_kit(d)
        mine = lines[:i] + [x for x in lines[i + 1:] if x != KIT_BLOCK and not (x.startswith("/") and x.endswith("/") and x[1:-1] in listed)]
    kit = ["/%s/" % n for n in kit_dirs(d)]
    want = mine + [p for p in EXCLUDE if p not in mine] + ([KIT_BLOCK] + kit if kit else [])
    if want != lines:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        # replaced whole: a cut-off write never drops the secret names
        with open(path + ".new", "w", encoding="utf-8", errors="surrogateescape") as f:
            f.write("".join(x + "\n" for x in want))
        os.replace(path + ".new", path)


class Lock:
    """One save at a time per folder: a lock file in the git directory, taken over when older than LOCK_STALE."""
    def __init__(self, d):
        self.path = os.path.join(d, git(d, "rev-parse", "--git-path", "quiet-save.lock")[1])
        self.held = False

    def __enter__(self):
        for _ in range(2):
            try:
                os.close(os.open(self.path, os.O_CREAT | os.O_EXCL | os.O_WRONLY))
                self.held = True
                return self
            except FileExistsError:
                try:
                    if time.time() - os.path.getmtime(self.path) > LOCK_STALE:
                        os.unlink(self.path)
                        continue
                except OSError:
                    continue
                raise Skip("another save of this folder is running", trace=False, state="busy")
        raise Skip("another save of this folder is running", trace=False, state="busy")

    def __exit__(self, *exc):
        if self.held:
            try:
                os.unlink(self.path)
            except OSError:
                pass


def empty_inner(d):
    """The repositories inside the folder that hold no commit yet: `git add` cannot record them, so the save stops and says so.
    Read from `git status -z` (an untracked folder that is a repository is listed as `<path>/`) and the inner repository's own HEAD."""
    out = git(d, "status", "--porcelain=v2", "-z", "--untracked-files=all", "--ignored=no")[1]
    dirs = [e[2:].rstrip("/") for e in out.split("\0") if e.startswith("? ") and e.endswith("/")]
    return [x for x in dirs if os.path.lexists(os.path.join(d, fs(x), ".git"))
            and git(os.path.join(d, fs(x)), "rev-parse", "--verify", "--quiet", "HEAD")[0] != 0]


def inner_words(d, inner):
    """The plain words for inner repositories whose current branch holds no commit: none at all, or other branches only."""
    some = [x for x in inner if git(os.path.join(d, fs(x)), "rev-list", "-n", "1", "--all")[1]]
    if some:
        return "the folder %s is a Git repository whose current branch has nothing in it yet" % ", ".join(inner[:3])
    return "the folder %s has a Git history of its own with nothing in it yet" % ", ".join(inner[:3])


def gitlinks(d):
    """The paths the index records as inner repositories (mode 160000), read NUL-separated."""
    return [e.split("\t", 1)[1] for e in git(d, "ls-files", "-s", "-z")[1].split("\0") if e.startswith("160000 ") and "\t" in e]


def drop_dead_links(d):
    """An inner repository recorded earlier whose folder has no .git any more: unstage it, so `add` saves its files as plain files
    (otherwise the old entry stays and they are never saved)."""
    for path in gitlinks(d):
        if not os.path.lexists(os.path.join(d, fs(path), ".git")):
            git(d, "--literal-pathspecs", "rm", "--cached", "-q", "--", path)


def clear_index_lock(d, any_age=False, name="index.lock", stale=LOCK_STALE):
    """Remove git's lock `name` left by a git this save killed (`any_age`) or by one dead for `stale` seconds; the save's own lock
    is held, and a kit-made history has no other writer."""
    path = os.path.join(d, git(d, "rev-parse", "--git-path", name)[1])
    try:
        if any_age or time.time() - os.path.getmtime(path) > stale:
            os.unlink(path)
    except OSError:
        pass


def commit(d, message):
    """Commit everything the save keeps; False when there was nothing to save. Skip when the commit fails."""
    excludes(d)
    clear_index_lock(d)
    inner = empty_inner(d)
    if inner:
        raise Skip("%s, so the save stopped; move it out of this folder, or delete its hidden .git folder if that history is not "
                   "needed" % inner_words(d, inner))
    drop_dead_links(d)
    rc, _o, err = git(d, "add", "-A")
    if rc != 0:
        if rc == 124:
            clear_index_lock(d, any_age=True)
        raise Skip(err if rc == 124 else "Git could not read every file of this folder (%s)" % ((err.splitlines() or ["no message"])[0][:200]),
                   state="failed")
    if git(d, "diff", "--cached", "--quiet")[0] == 0:
        return False
    # no --no-verify: a commit hook the person has (a secret scanner) still runs, and when it refuses nothing is saved
    rc, _o, err = git(d, "-c", "commit.gpgsign=false", "commit", "-q", "-m", message, ident=True)
    if rc == 124:
        clear_index_lock(d, any_age=True)
    if rc != 0:
        raise Skip("the save was refused (%s)" % ((err.splitlines() or ["git failed"])[-1][:160]), state="failed")
    return True


def stamp():
    return time.strftime("%Y-%m-%d %H:%M:%S")


def save(payload):
    """The Stop hook: never raises, never prints."""
    try:
        import sdlc_config as C
        import vsdlc
        troot = vsdlc.project_root(payload)
        cfg, _probs, _present = C.load(troot, quiet=True)
        if cfg["hooks"] == "off" or vsdlc.session_mode(vsdlc.plugin_root(), troot, cfg)[0] != "everyday":
            return
    except Exception:
        return
    d = os.path.realpath(troot)
    try:
        repo_of(d)
        ready_check(d)
        with Lock(d):
            # Only the run holding the lock writes the marker, and a run that meets the lock returns without a word: the
            # "started" of a run killed while holding the lock stays, and the next session start says that save did not finish.
            trace(d, "started")
            outcome(d)
    except Skip as s:
        if s.state != "busy":
            trace(d, s.state if s.trace or s.state == "failed" else "quiet", s.why)
    except Exception as e:                    # an unforeseen failure is a lost save: say it at the next session start
        trace(d, "failed", "an internal error (%s)" % type(e).__name__)


def outcome(d):
    """Commit and record the result; under the lock, so nothing here is overwritten by a run that met it."""
    try:
        saved = commit(d, "quiet save %s" % stamp())
        inner = gitlinks(d)
        if inner:
            trace(d, "partial", "the inside of %s, which has a Git history of its own" % ", ".join(inner[:3]))
        else:
            trace(d, "saved" if saved else "unchanged")
    except Skip as s:
        trace(d, s.state if s.trace or s.state == "failed" else "quiet", s.why)
    except Exception as e:
        trace(d, "failed", "an internal error (%s)" % type(e).__name__)


WORDS = {"A": "added", "M": "changed", "D": "removed", "T": "changed"}


def entries(d, n):
    """[(number, commit id, time, subject, [(status, path)])], newest first; every read NUL-separated."""
    rc, out, _e = git(d, "log", "-z", "-n", str(n), "--date=format:%Y-%m-%d %H:%M:%S", "--format=%H%x1f%ad%x1f%s", raw=True)
    if rc != 0:
        return []
    res = []
    for i, rec in enumerate(r for r in out.split("\0") if r.strip()):
        cid, when, subject = (rec.strip("\n").split("\x1f") + ["", ""])[:3]
        f = git(d, "diff-tree", "-z", "-r", "--root", "--no-commit-id", "--no-renames", "--name-status", cid, raw=True)[1].split("\0")
        res.append((i + 1, cid, when, subject, [(f[k], f[k + 1]) for k in range(0, len(f) - 1, 2) if f[k]]))
    return res


def show(d, n):
    items = entries(d, n)
    if not items:
        return "No saves yet in this folder."
    lines = []
    for num, cid, when, subject, files in items:
        what = ", ".join("%s (%s)" % (p, WORDS.get(s[:1], "changed")) for s, p in files[:6]) + (" and %d more" % (len(files) - 6)
                                                                                                if len(files) > 6 else "")
        note = (" - went back to an earlier save" if subject.startswith("went back")
                else " - before going back" if "before going back" in subject else "")
        lines.append("%d. %s  %s%s  [%s]" % (num, when, what or "no file change", note, cid[:8]))
    return "\n".join(lines)


def not_connected(d):
    """Skip when the folder is connected to a remote: the developer flow keeps it, and the kit writes nothing there."""
    rc, remotes, _e = git(d, "remote")
    if rc != 0 or remotes:
        raise Skip("the folder is connected to a remote: the developer flow keeps it now", trace=False)


def which_save(d, which):
    """(commit id, time) of a save named by its id or its number in the list; Skip when it is not one of this folder's saves."""
    if which.isascii() and which.isdigit() and len(which) <= 4:
        items = entries(d, int(which))
        if len(items) < int(which) or int(which) < 1:
            raise Skip("there is no save number %s; see the list" % which, trace=False)
        return items[int(which) - 1][1], items[int(which) - 1][2]
    rc, cid, _e = git(d, "rev-parse", "--verify", "--quiet", "--end-of-options", which + "^{commit}")
    if not which or rc != 0 or git(d, "merge-base", "--is-ancestor", cid, "HEAD")[0] != 0:
        raise Skip("%s is not one of this folder's saves" % (which or "an empty id"), trace=False)
    return cid, git(d, "log", "-1", "--date=format:%Y-%m-%d %H:%M:%S", "--format=%ad", cid)[1]


def old_root(d, undo):
    """(name, path) of the kit's folder of old copies: the first of ban-cu, ban-cu-2, ... that is absent or one the kit made (its
    marker and the kit's list), so a file, a link or a folder of the person's is passed over and never written into. Made when
    missing: the .ignore line first, then the folder with its marker, then its line in the kit's list; `undo` collects what this
    run did, for a failed copy to take back."""
    made = made_by_kit(d)
    for k in range(1, 100):
        name = OLD if k == 1 else "%s-%d" % (OLD, k)
        root = os.path.join(d, name)
        if not os.path.lexists(root) or kit_folder(d, name, made):
            break
    else:
        raise Skip("%s to %s-99 are all names of yours" % (OLD, OLD), trace=False)
    ign = os.path.join(d, ".ignore")
    if os.path.islink(ign) or (os.path.lexists(ign) and not os.path.isfile(ign)):
        raise Skip(".ignore here is not a plain file, so the old copies could not be kept out of Claude's search", trace=False)
    try:
        with open(ign, "rb") as f:        # bytes: the line written is the line compared, whatever the platform's line ending
            have = f.read()
    except FileNotFoundError:
        have = None
    line = ("/%s/" % name).encode("ascii")
    if have is None or line not in [x.rstrip(b"\r") for x in have.split(b"\n")]:
        add = (b"\n" if have and not have.endswith(b"\n") else b"") + line + b"\n"
        undo["ignore"] = (ign, add, have is None)
        with open(ign, "ab") as f:
            f.write(add)
    if not os.path.lexists(root):
        if name not in made:              # only what this run adds is taken back if the copy fails
            undo["made"].append(name)
            set_made(d, add=[name])       # before the folder: a listed folder that is absent or unmarked is never taken for the kit's
        os.mkdir(root)
        undo["dirs"].append(root)
        with open(os.path.join(root, MARKER), "w", encoding="utf-8") as f:
            f.write(MARKER_TEXT)
    return name, root


def link_like(p):
    """`p` is a link or a Windows junction: never followed, its target's mode never changed."""
    return os.path.islink(p) or getattr(os.path, "isjunction", lambda _p: False)(p)


def remove_tree(path):
    """Remove the folder `path` whole. Windows refuses to delete a read-only file or folder, and a folder without write permission
    keeps its entries: a failed delete is tried once more after the path and its folder are made writable (never through a link,
    never a folder above `path`). Anything else rmtree refuses (a link, a folder it cannot read) is raised as it came. Raises
    OSError for what still cannot go."""
    top = os.path.abspath(path)
    def again(func, p, exc):
        if func not in (os.unlink, os.rmdir, os.remove):
            raise exc if isinstance(exc, BaseException) else exc[1]
        for q in (os.path.dirname(p), p):
            if (q == top or q.startswith(top + os.sep)) and not link_like(q):
                os.chmod(q, stat.S_IMODE(os.lstat(q).st_mode) | stat.S_IWRITE | (stat.S_IEXEC if os.path.isdir(q) else 0))
        func(p)
    shutil.rmtree(top, **({"onexc": again} if sys.version_info >= (3, 12) else {"onerror": again}))


def take_back(d, undo):
    """A failed copy takes back what it did: the folders it created (never another), its lines in the kit's list, and the
    .ignore line it added (the file removed when this run created it)."""
    for path in reversed(undo["dirs"]):
        try:
            remove_tree(path)
        except OSError:
            pass
    try:
        set_made(d, drop=undo["made"])
    except OSError:
        pass
    if undo["ignore"]:
        ign, add, created = undo["ignore"]
        try:
            with open(ign, "rb") as f:
                data = f.read()
            if data.endswith(add):
                if created and data == add:
                    os.unlink(ign)
                else:
                    os.truncate(ign, len(data) - len(add))
        except OSError:
            pass


def copy_out(d, which):
    """Write save `which` into a new folder of the kit's folder of old copies; the work tree outside it, the index, HEAD and the
    history are left as they are (the save is read through a temporary index). The copy holds only the save's files."""
    history_repo(d)
    not_connected(d)
    cid, when = which_save(d, which)
    with Lock(d):
        undo = {"dirs": [], "made": [], "ignore": None}
        try:
            folder, root = old_root(d, undo)
            base = when.replace(":", "").replace(" ", "-")
            name, k = base, 2
            while os.path.lexists(os.path.join(root, name)):
                name, k = "%s-%d" % (base, k), k + 1
            dest = os.path.join(root, name)
            os.mkdir(dest)
            undo["dirs"].append(dest)
            index = os.path.join(d, git(d, "rev-parse", "--git-path", "quiet-save-copy.index")[1])
            clear_index_lock(d, name="quiet-save-copy.index.lock", stale=GIT_TIMEOUT)   # left by a copy killed in read-tree
            try:
                ok = git(d, "read-tree", cid, index=index)[0] == 0 and \
                    git(d, "checkout-index", "-a", "-f", "--prefix=" + dest + os.sep, index=index)[0] == 0
            finally:
                try:
                    os.unlink(index)
                except OSError:
                    pass
            if not ok:
                raise Skip("Git could not write the copy, so no copy was made", trace=False)
            set_made(d, add=[folder + "/" + name])   # after the copy is complete: only a whole copy is on the list
        except BaseException as e:
            take_back(d, undo)
            if isinstance(e, (OSError, ValueError)):
                raise Skip("the copy could not be written (%s), so no copy was made" % (getattr(e, "strerror", None) or type(e).__name__),
                           trace=False)
            raise
    why = "" if folder == OLD else " (%s/ is used because %s/ is yours)" % (
        folder, OLD if folder == OLD + "-2" else "%s/ to %s-%d" % (OLD, OLD, int(folder[len(OLD) + 1:]) - 1))
    return ("The save of %s is copied into %s/%s%s. Nothing in the work folder was changed; take the files you need from the copy."
            % (when, folder, name, why))


def drop_copy(d, path):
    """Remove one copy named `<kit folder>/<copy>` as copy's answer gave it: a folder directly in one of the kit's folders, not a
    link, and on the kit's list of the copies it made; anything else is refused and nothing removed."""
    history_repo(d)
    not_connected(d)
    with Lock(d):
        made = made_by_kit(d)
        parts = path.replace(os.sep, "/").split("/")
        folder, name = parts if len(parts) == 2 else ("", "")
        root, target = os.path.join(d, folder), os.path.join(d, folder, name)
        entry = folder + "/" + name
        if kit_name(folder) and name not in ("", ".", "..") and entry in made and not os.path.lexists(target):
            set_made(d, drop=[entry])
            return "The old copy %s is already gone (removed by hand); the kit no longer lists it." % entry
        if not kit_folder(d, folder, made) or name in ("", ".", "..") or entry not in made or os.path.islink(target) \
                or not os.path.isdir(target) or os.path.dirname(os.path.realpath(target)) != os.path.realpath(root):
            raise Skip("%s is not one of the kit's old copies" % (path or "an empty name"), trace=False)
        try:
            remove_tree(target)
        except OSError as e:          # still listed: asking again removes the rest once the cause is gone
            raise Skip("The old copy %s could not be removed whole (%s); what is left of it stays on the kit's list, so asking again "
                       "removes the rest" % (entry, e.strerror or type(e).__name__), trace=False, state="partial")
        set_made(d, drop=[entry])
    return "The old copy %s is removed." % entry


def main(argv):
    cmd = argv[1] if len(argv) > 1 else ""
    if cmd == "save" and len(argv) == 2:
        try:
            payload = json.loads(sys.stdin.buffer.read().decode("utf-8", "surrogateescape") or "{}")
        except ValueError:
            payload = {}
        save(payload if isinstance(payload, dict) else {})
        return 0
    usage = "usage: quiet_save.py save | list [N] [--dir D] | copy <id or number> [--dir D] | drop-copy <folder/copy> [--dir D]"
    sys.stdout.reconfigure(encoding="utf-8", errors="surrogateescape")   # names as git wrote them, whatever the console's code page
    rest, d = argv[2:], os.getcwd()
    if "--dir" in rest:
        i = rest.index("--dir")
        if i + 1 >= len(rest):
            print(usage, file=sys.stderr)
            return 64
        d, rest = rest[i + 1], rest[:i] + rest[i + 2:]
    d = os.path.realpath(d)
    rc, top, _e = git(d, "rev-parse", "--show-toplevel")
    if rc == 0 and top:
        d = os.path.realpath(fs(top))        # a sub-folder of the kit's folder: its history is the folder's
    try:
        if cmd == "list" and len(rest) <= 1 and (not rest or (rest[0].isascii() and rest[0].isdigit() and int(rest[0]) > 0)):
            history_repo(d)
            print(show(d, int(rest[0]) if rest else 20))
            return 0
        if cmd == "copy" and len(rest) == 1:
            print(copy_out(d, rest[0]))
            return 0
        if cmd == "drop-copy" and len(rest) == 1:
            print(drop_copy(d, rest[0]))
            return 0
    except Skip as s:
        print(("%s." if s.state == "partial" else "Nothing changed: %s.") % s.why)   # partial: something may have changed
        return 1
    print(usage, file=sys.stderr)
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv))
