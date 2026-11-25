#!/usr/bin/env python3
"""The notebook nudge of the everyday mode: the Stop hook that asks the session, once per piece of work, to overwrite
`kb/current-state.md` when a turn changed files in the folder and the notebook's map did not change.

  notebook_nudge.py           the Stop hook (payload on stdin): print one `{"decision": "block", "reason": ...}` or nothing; always exit 0

It speaks only in everyday mode (scripts/everyday.py; a worker or coordinated session stays out: there the ship step owns
current-state), in a folder that has `kb/` (vsdlc.kb_missing, the one test), and with the kit on and a readable config. Never twice in a row:

  - a Stop that follows this hook's own block (`stop_hook_active`) passes;
  - a nudge records the map's mtime, and the next one waits until the map has changed since (a nudge that was ignored does not come
    back);
  - the stamp of every Stop is the start of the next turn, so a turn is nudged only for files changed in it.

"Files changed in the turn" is read from mtimes (a folder that is not a git repository, the everyday default, has no other record, and the
quiet save, which runs beside this hook, may commit before it looks). The scan stops at the first changed file and at a cap of files and of
time (checked at every file); a file dated after now is not this turn's; a scan that hit a cap says nothing. The first turn's start is the first timestamp of the session's transcript; with none, the hook
only stamps. The stamp lives in the session's own directory (hookout.session_dir). Never fails the turn: any error exits 0, nothing printed."""
import json
import os
import stat
import sys
import time
from datetime import datetime, timezone

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

STATE = "notebook-nudge.json"
MAP = ("kb", "current-state.md")
SCAN_ENTRIES = 5000                     # files and folders looked at before the scan gives up (checked at every file and folder)
SCAN_SECS = 0.5
TEXT = {
    "en": ("vibemaestro-sdlc: this turn changed files in the folder, but kb/current-state.md was not updated. Before you finish, "
           "overwrite kb/current-state.md with where the work stands now, in the person's language: the present state only, short, "
           "no diary. Add a file in kb/decisions/ only when a choice was made, and keep kb/preferences.md to what the person said. "
           "Do not repeat this note to the person."),
    "vi": ("vibemaestro-sdlc: lượt này đã đổi file trong thư mục nhưng kb/current-state.md chưa được cập nhật. Trước khi kết thúc, "
           "hãy ghi đè kb/current-state.md bằng nơi công việc đang đứng lúc này, bằng ngôn ngữ của người dùng: chỉ trạng thái hiện tại, "
           "ngắn, không viết nhật ký. Chỉ thêm một file trong kb/decisions/ khi có một lựa chọn được đưa ra, và giữ kb/preferences.md "
           "đúng những gì người dùng đã nói. Đừng nhắc lại ghi chú này với người dùng."),
}


def first_stamp(path):
    """The first `timestamp` (ISO, UTC) in the transcript at `path`, as epoch seconds; None when there is none within its first lines."""
    try:
        if not stat.S_ISREG(os.stat(path).st_mode):
            return None
        with open(path, encoding="utf-8", errors="replace") as f:
            for _ in range(50):
                line = f.readline()
                if not line:
                    return None
                try:
                    ts = json.loads(line).get("timestamp")
                except (ValueError, AttributeError):
                    continue
                if isinstance(ts, str):
                    try:
                        return datetime.strptime(ts[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc).timestamp()
                    except ValueError:
                        continue
    except OSError:
        pass
    return None


def changed_since(troot, since, now):
    """A file of the work (not the notebook, the history, the kit's folders or bulky ones) changed after `since` and not after `now` (a
    time in the future is a clock or a zip, never this turn's work): True or False, and False when the scan ran into its cap. The cap and
    the deadline are checked at every file and for the folders of every directory, so neither a huge folder nor a deep tree outruns them.
    shortcut: a file a background process keeps writing (a dev server's log, a sync client) counts as work, so a session that obeys
    the nudge is nudged again on the next turn; a rule per kind of file when a real folder shows it."""
    import quiet_save as Q
    skip_dirs = set(Q.NOT_COUNTED) | set(Q.NOT_CONTENT)
    deadline, seen = time.monotonic() + SCAN_SECS, 0
    for root, dirs, files in os.walk(troot):
        top = root == troot
        dirs[:] = [x for x in dirs if x not in skip_dirs and not (top and (x == MAP[0] or (Q.kit_name(x) and Q.marked(os.path.join(root, x)))))
                   and not os.path.lexists(os.path.join(root, x, ".git"))]
        seen += len(dirs)
        if seen > SCAN_ENTRIES or time.monotonic() > deadline:
            return False
        for n in files:
            seen += 1
            if seen > SCAN_ENTRIES or time.monotonic() > deadline:
                return False
            if n in Q.NOT_CONTENT:
                continue
            try:
                st = os.lstat(os.path.join(root, n))
            except OSError:
                continue
            # st_ctime is set by this machine's clock and no copy or unzip can date it back or ahead: a file dated into the window
            # by its mtime alone (a zip from another time zone) was not changed in it. On Windows ctime is the creation time: unused.
            if since < st.st_mtime <= now and (os.name != "posix" or st.st_ctime > since):
                return True
    return False


def map_mtime(troot):
    """(mtime_ns, size) of kb/current-state.md; (0, 0) when it is missing or unreadable; None when something other than a file is there
    (nothing to overwrite: the hook says nothing)."""
    try:
        st = os.stat(os.path.join(troot, *MAP))
    except OSError:
        return 0, 0
    return (st.st_mtime_ns, st.st_size) if stat.S_ISREG(st.st_mode) else None


def read_state(path):
    try:
        if not stat.S_ISREG(os.stat(path).st_mode):
            return {}
        with open(path, encoding="utf-8") as f:
            d = json.load(f)
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


def nudge(payload):
    """The block to print for this Stop, or None. Raises on anything unforeseen (the caller exits 0 silently)."""
    import hookout
    import sdlc_config as C
    import vsdlc
    sid = hookout.session_key(payload)
    if not sid:
        return None
    troot = vsdlc.project_root(payload)
    cfg, probs, _present = C.load(troot, quiet=True)
    if (probs or cfg["hooks"] == "off" or C.off_below(vsdlc.session_folder(payload), troot)
            or vsdlc.session_mode(vsdlc.plugin_root(), troot, cfg)[0] != "everyday" or vsdlc.kb_missing(troot)):
        return None
    path = os.path.join(hookout.session_dir(sid), STATE)
    state = read_state(path)
    now = time.time()
    since = state.get("at") if isinstance(state.get("at"), (int, float)) else None
    if since is None:
        tp = payload.get("transcript_path")
        since = first_stamp(tp) if isinstance(tp, str) else None
    got = map_mtime(troot)
    if got is None:
        return None
    ns, size = got
    block = None
    if (since is not None and not payload.get("stop_hook_active") and changed_since(troot, since, now)
            and not (size and since < ns / 1e9 <= now) and state.get("map") != ns):
        block = {"decision": "block", "reason": TEXT[cfg["language"] if cfg["language"] in TEXT else "vi"]}
    new = {"at": now, "map": ns if block else state.get("map")}
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path + ".tmp", "w", encoding="utf-8") as f:
            json.dump(new, f)
        os.replace(path + ".tmp", path)
    except OSError:
        if block:
            return None                 # a nudge that cannot be remembered is never made: it could come back every turn
    return block


def main():
    try:
        payload = json.loads(sys.stdin.buffer.read().decode("utf-8", "replace") or "{}")
        out = nudge(payload) if isinstance(payload, dict) else None
        if out:
            sys.stdout.write(json.dumps(out, ensure_ascii=False) + "\n")
    except BaseException:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
