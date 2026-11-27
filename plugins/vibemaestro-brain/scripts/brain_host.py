"""The macOS desktop app's launcher, read as part of the app (vibemaestro-sdlc's baton applies the same rule).

On macOS the Claude desktop app starts its Claude Code through a program of its own bundle that keeps Claude Code's command line
after its own words, so two processes carry the prompt tool. brain_store.answerers folds that one launcher into the Claude Code it
starts (_app_launcher); everywhere else the rule of brain_store.official_host stands alone. Standard library only, Python 3.8+.
"""
import os
import subprocess
import sys

from brain_store import official_host, prompt_tool

LAUNCHER_FOLD = sys.platform == "darwin"   # the desktop app starts its Claude Code through a launcher of its bundle (_app_launcher)


def _program_path(pid):
    """The whole path of the program the running process `pid` runs, as the kernel holds it (Linux /proc/<pid>/exe, macOS
    proc_pidpath), or ''. Never argv[0], which whoever starts a process chooses (macOS `ps -o comm=` prints argv[0])."""
    try:
        return os.readlink("/proc/%d/exe" % pid)
    except OSError:
        pass
    if sys.platform != "darwin":
        return ""
    try:
        import ctypes
        buf = ctypes.create_string_buffer(4096)          # PROC_PIDPATHINFO_MAXSIZE
        n = ctypes.CDLL(None).proc_pidpath(ctypes.c_int(pid), buf, ctypes.c_uint32(4096))   # libSystem, as every process has
        return os.fsdecode(buf.raw[:n]) if n > 0 else ""
    except (ImportError, OSError, AttributeError, ValueError):
        return ""


def _app_bundle(path):
    """The macOS app bundle (`….app`) an absolute program path lies inside, or None."""
    k = path.find(".app/Contents/")
    return path[:k + 4] if os.path.isabs(path) and k > 0 else None


def _pids_above():
    """[(pid, argv)] of the processes above this one, nearest first, each argv read as _ancestors reads it."""
    out, pid = [], os.getppid()
    while pid > 1 and len(out) < 64:
        try:
            with open("/proc/%d/cmdline" % pid, "rb") as f:
                argv = [a.decode("utf-8", "replace") for a in f.read().split(b"\0") if a]
            with open("/proc/%d/stat" % pid) as f:
                ppid = int(f.read().rsplit(")", 1)[1].split()[1])
        except (OSError, ValueError, IndexError):
            try:
                r = subprocess.run(["ps", "-o", "ppid=,args=", "-p", str(pid)], capture_output=True, text=True, timeout=5)
                ppid_s, _, args = r.stdout.strip().partition(" ")
                ppid, argv = int(ppid_s), args.split()
            except (OSError, ValueError, subprocess.SubprocessError):
                break
        out.append((pid, argv))
        pid = ppid
    return out


def _app_launcher(anc):
    """The index in `anc` of the macOS desktop app's launcher, or None. The app starts its Claude Code through a program of its
    own bundle that keeps Claude Code's command line after its own words, so two processes carry the prompt tool; it is
    folded into its child (vibemaestro-sdlc's baton applies the same rule, app_launcher). Only on macOS, and only the
    outermost process carrying the prompt tool, whose direct child carries it too and is an official host, whose argv is
    at least one word of its own followed by exactly that child's argv, and whose program lies inside the `.app` bundle of
    its own parent's program. A launcher above a launcher is not folded: its child is not Claude Code."""
    if not LAUNCHER_FOLD:
        return None
    at = [i for i, a in enumerate(anc) if prompt_tool(a[0])]
    if len(at) < 2 or at[-2] != at[-1] - 1 or at[-1] + 1 >= len(anc):
        return None
    i = at[-1]
    argv, child = anc[i][0], anc[i - 1][0]
    if not (official_host(child) and len(argv) > len(child) and argv[-len(child):] == child):
        return None
    walk = _pids_above()                                 # the same walk with each pid: the programs are read by pid
    if len(walk) <= i + 1 or [walk[j][1] for j in (i - 1, i, i + 1)] != [anc[j][0] for j in (i - 1, i, i + 1)]:
        return None
    mine = _app_bundle(_program_path(walk[i][0]))
    return i if mine and mine == _app_bundle(_program_path(walk[i + 1][0])) else None
