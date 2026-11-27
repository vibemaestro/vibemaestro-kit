#!/usr/bin/env python3
# =============================================================================
# Why `sign --by owner` or `mode` is refused with "something can answer the dialog in place of a human" in a Claude Code host:
# a by-hand reading, run inside a session of that host (the Claude desktop app's Code tab, the VS Code extension), through the
# session's shell tool (Bash, Git Bash or PowerShell), so the processes above it are the host's.
# Run: python3 tests/manual/desktop-host-diagnose.py      (Windows: python or py works too)
#      python3 tests/manual/desktop-host-diagnose.py --self-test   (the Windows reader on fake records, on any system that has
#      vibemaestro-sdlc installed: it loads that baton.py too)
# What it does: loads the baton.py of the installed vibemaestro-sdlc (Claude Code's installed_plugins.json under
# CLAUDE_CONFIG_DIR, else ~/.claude) and calls its own functions: for each process above this one, the pid and the argv as
# baton reads it, the five conditions of the official-host rule for each process carrying --permission-prompt-tool, where a
# launcher's program lives (yes/no only), then baton's list of what can answer the dialog. On Windows baton has no process
# lineage (it refuses the owner's dialog there), so this script reads the processes itself, as vibemaestro-brain does: parent
# ids from a Toolhelp32 snapshot, each command line from NtQueryInformationProcess (class 60), with query-only access; what it
# computes from that reading is marked so. It writes nothing, starts only `ps` (macOS) and `git worktree list`, uses no
# network, and always exits 0.
# The output is safe to paste into a chat: an argument is shown only as a flag name, a program's base name or the value of
# --permission-prompt-tool; any other word as <n> (its length). No path, user name, host name, e-mail or token is printed.
# Needs: python3 (standard library only).
# =============================================================================
import ctypes
import getpass
import importlib.util
import io
import json
import ntpath
import os
import platform
import posixpath
import re
import socket
import struct
import subprocess
import sys
from contextlib import redirect_stdout

sys.dont_write_bytecode = True                         # importing baton.py leaves no __pycache__ in the plugin cache
FLAG = "--permission-" + "prompt-tool"                # split: this file's own text never reads as the flag
NAME = re.compile(r"[A-Za-z0-9._+-]{1,40}\Z")
FLAG_NAME = re.compile(r"--?[A-Za-z][A-Za-z0-9-]{0,40}\Z")
TOOL_VALUE = re.compile(r"[A-Za-z0-9_.:-]{1,64}\Z")
BY_ME = " (computed by this script, not by baton)"


def private_words():
    words = set()
    for get in (getpass.getuser, socket.gethostname, lambda: os.path.basename(os.path.expanduser("~"))):
        try:
            w = get()
        except Exception:
            continue
        if w:
            words.update({w.lower(), w.split(".")[0].lower()})
    return words


PRIVATE = private_words()


def base(word):
    """A program's base name when it is plainly one (not a user or host name, not token-shaped), else <n>."""
    b = re.split(r"[\\/]", word.rstrip("/\\"))[-1]
    shaped = len(b) >= 24 or (len(b) >= 16 and re.search(r"[0-9]", b) and re.search(r"[A-Za-z]", b) and "." not in b)
    if NAME.match(b) and b.lower() not in PRIVATE and b.split(".")[0].lower() not in PRIVATE and not shaped:
        return b
    return "<%d>" % len(word)


def shown(argv, programs):
    out, after = [], False
    for i, w in enumerate(argv):
        name, eq, val = w.partition("=")
        if after:
            out.append(w if TOOL_VALUE.match(w) else "<%d>" % len(w))
        elif w.startswith("-"):
            if not FLAG_NAME.match(name):
                out.append("<%d>" % len(w))
            elif name == FLAG and eq:
                out.append(name + "=" + (val if TOOL_VALUE.match(val) else "<%d>" % len(val)))
            else:
                out.append(name + ("=<%d>" % len(val) if eq else ""))
        elif i < 2 or (re.search(r"[\\/]", w) and (base(w) in programs or "/claude/versions/" in w.replace("\\", "/"))):
            out.append(base(w))
        else:
            out.append("<%d>" % len(w))
        after = w == FLAG
    return " ".join(out)


def yes(v):
    return "yes" if v else "no"


def env_word(key, pattern):
    v = os.environ.get(key)
    return "unset" if v is None else v if re.fullmatch(pattern, v) else "<%d>" % len(v)


def bundle(path):
    """The macOS app bundle a program path is inside (`….app`), or None."""
    k = path.find(".app/Contents/")
    return path[:k + 4] if k >= 0 else None


def inside(top, path, mod):
    """`path` is in the directory tree of `top` (both compared as the platform compares them)."""
    if not top or not path:
        return False
    d = mod.normcase(mod.normpath(top))
    return mod.normcase(mod.normpath(path)).startswith(d.rstrip(mod.sep) + mod.sep)


def install_place(path, env):
    """per-user, system or other: where a Windows program is installed, from the profile and program-files folders."""
    for kind, keys in (("per-user", ("LOCALAPPDATA", "APPDATA", "USERPROFILE")),
                       ("system", ("ProgramFiles", "ProgramFiles(x86)", "ProgramW6432", "ProgramData", "SystemRoot"))):
        if any(env.get(k) and inside(env[k], path, ntpath) for k in keys):
            return kind
    return "other"


# --- Windows: the processes above this one, as vibemaestro-brain reads them (win_chain) ----------------------------------------

def us_text(b, address):
    """The text of the UNICODE_STRING at the start of `b`, the bytes NtQueryInformationProcess filled at `address` (its Buffer
    points into them); None when a length or the pointer does not fit in `b`. Nothing is read outside `b`."""
    head = struct.calcsize("HHP")
    if len(b) < head:
        return None
    n, most, ptr = struct.unpack_from("HHP", b, 0)
    at = ptr - address
    if n % 2 or n > most or not head <= at <= len(b) - n:
        return None
    try:
        return b[at:at + n].decode("utf-16-le")
    except UnicodeDecodeError:
        return None


def split_cmdline(c):
    """The argv a Windows program's C runtime makes of the command line `c` (vibemaestro-brain's split_cmdline)."""
    out, i, n = [], 0, len(c)
    word, q = [], False
    while i < n and (q or c[i] not in " \t"):
        if c[i] == '"':
            q = not q
        else:
            word.append(c[i])
        i += 1
    out.append("".join(word))
    while True:
        while i < n and c[i] in " \t":
            i += 1
        if i >= n:
            return out
        word, q = [], False
        while i < n and (q or c[i] not in " \t"):
            if c[i] == "\\":
                j = i
                while j < n and c[j] == "\\":
                    j += 1
                if j < n and c[j] == '"':
                    word.append("\\" * ((j - i) // 2))
                    if (j - i) % 2:
                        word.append('"')
                        j += 1
                else:
                    word.append("\\" * (j - i))
                i = j
            elif c[i] == '"':
                if q and c[i + 1:i + 2] == '"':
                    word.append('"')
                    i += 2
                else:
                    q = not q
                    i += 1
            else:
                word.append(c[i])
                i += 1
        out.append("".join(word))


class WinApi:
    """The four Windows reads this script makes, through ctypes: query-only access, no read of another process's memory."""

    def __init__(self):
        from ctypes import wintypes as w
        self.w, self.k, self.nt = w, ctypes.WinDLL("kernel32", use_last_error=True), ctypes.WinDLL("ntdll")

        class PE(ctypes.Structure):                     # PROCESSENTRY32W
            _fields_ = [("dwSize", w.DWORD), ("cntUsage", w.DWORD), ("th32ProcessID", w.DWORD),
                        ("th32DefaultHeapID", ctypes.c_size_t), ("th32ModuleID", w.DWORD), ("cntThreads", w.DWORD),
                        ("th32ParentProcessID", w.DWORD), ("pcPriClassBase", w.LONG), ("dwFlags", w.DWORD),
                        ("szExeFile", w.WCHAR * 260)]
        self.PE, ref, k = PE, ctypes.POINTER, self.k
        for f, res, args in ((k.CloseHandle, w.BOOL, [w.HANDLE]), (k.CreateToolhelp32Snapshot, w.HANDLE, [w.DWORD, w.DWORD]),
                             (k.Process32FirstW, w.BOOL, [w.HANDLE, ref(PE)]), (k.Process32NextW, w.BOOL, [w.HANDLE, ref(PE)]),
                             (k.OpenProcess, w.HANDLE, [w.DWORD, w.BOOL, w.DWORD]),
                             (k.GetProcessTimes, w.BOOL, [w.HANDLE] + [ref(w.FILETIME)] * 4),
                             (k.QueryFullProcessImageNameW, w.BOOL, [w.HANDLE, w.DWORD, w.LPWSTR, ref(w.DWORD)]),
                             (self.nt.NtQueryInformationProcess, w.LONG,
                              [w.HANDLE, ctypes.c_int, ctypes.c_void_p, w.ULONG, ref(w.ULONG)])):
            f.restype, f.argtypes = res, args

    def table(self):
        """{pid: parent pid} of the processes running now (a Toolhelp32 snapshot)."""
        snap = self.k.CreateToolhelp32Snapshot(0x2, 0)  # TH32CS_SNAPPROCESS
        if snap in (None, ctypes.c_void_p(-1).value):
            raise ctypes.WinError(ctypes.get_last_error())
        try:
            pe, out = self.PE(), {}
            pe.dwSize = ctypes.sizeof(pe)
            more = self.k.Process32FirstW(snap, ctypes.byref(pe))
            while more:
                out[pe.th32ProcessID] = pe.th32ParentProcessID
                more = self.k.Process32NextW(snap, ctypes.byref(pe))
            return out
        finally:
            self.k.CloseHandle(snap)

    def info(self, pid):
        """(creation time, command line, program path) of the running process `pid`; OSError when Windows will not say."""
        w, k = self.w, self.k
        h = k.OpenProcess(0x1000, False, pid)           # PROCESS_QUERY_LIMITED_INFORMATION
        if not h:
            raise ctypes.WinError(ctypes.get_last_error())
        try:
            ft = [w.FILETIME() for _ in range(4)]
            if not k.GetProcessTimes(h, *map(ctypes.byref, ft)):
                raise ctypes.WinError(ctypes.get_last_error())
            size = w.ULONG(0)
            self.nt.NtQueryInformationProcess(h, 60, None, 0, ctypes.byref(size))   # ProcessCommandLineInformation
            buf = ctypes.create_string_buffer(size.value or 1)
            st = self.nt.NtQueryInformationProcess(h, 60, buf, size.value, ctypes.byref(size))
            text = us_text(buf.raw[:size.value], ctypes.addressof(buf)) if st >= 0 and size.value <= len(buf) else None
            if text is None:
                raise OSError("NTSTATUS 0x%08x" % (st & 0xFFFFFFFF))
            img, n = ctypes.create_unicode_buffer(32768), w.DWORD(32768)
            image = img.value if k.QueryFullProcessImageNameW(h, 0, img, ctypes.byref(n)) else ""
            return ft[0].dwHighDateTime << 32 | ft[0].dwLowDateTime, text, image
        finally:
            k.CloseHandle(h)


def win_lineage(api, me):
    """[(pid, argv, program path)] of the processes above `me`, nearest first, and why the walk ended. A parent that no longer
    runs (not in the snapshot, or an id a younger process took: created after its child) ends it, as System does."""
    table = api.table()
    t = api.info(me)[0]
    out, pid = [], me
    for _ in range(64):
        ppid = table.get(pid)
        if ppid in (None, 0, 4):
            return out, "System or no parent"
        if ppid not in table:
            return out, "the parent of %d no longer runs" % pid
        try:
            created, line, image = api.info(ppid)
        except OSError as e:
            return out, "process %d cannot be read (%s)" % (ppid, type(e).__name__)
        if created > t:
            return out, "the parent id of %d now names a younger process" % pid
        out.append((ppid, split_cmdline(line), image))
        pid, t = ppid, created
    return out, "64 processes"


# --- the report ------------------------------------------------------------------------------------------------------------

def load():
    cfg = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")
    with open(os.path.join(cfg, "plugins", "installed_plugins.json"), encoding="utf-8") as f:
        plugins = json.load(f).get("plugins") or {}
    found = [(e.get("lastUpdated") or "", key, e) for key, entries in plugins.items() if key.startswith("vibemaestro-sdlc@")
             for e in entries if isinstance(e, dict) and isinstance(e.get("installPath"), str)]
    if not found:
        raise LookupError("no vibemaestro-sdlc in installed_plugins.json")
    _stamp, key, e = max(found, key=lambda t: t[0])
    spec = importlib.util.spec_from_file_location("baton", os.path.join(e["installPath"], "scripts", "baton.py"))
    b = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(b)
    mkt = key.split("@", 1)[1]                         # another marketplace's name may be an organisation's: not printed
    return b, "vibemaestro-sdlc@%s, version %s" % (mkt if mkt == "vibemaestro" else "<another marketplace>",
                                                  base(str(e.get("version") or "?")))


def comm_of(pid):
    """`ps -o comm=` of `pid`: the program's whole path on macOS, its name on Linux; '' when unread."""
    try:
        return subprocess.run(["ps", "-o", "comm=", "-p", str(pid)], capture_output=True, text=True, timeout=5).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def kernel_path(pid):
    """The program path the kernel holds for `pid` (macOS proc_pidpath, as baton's program_path reads it), never argv[0]; ''."""
    try:
        buf = ctypes.create_string_buffer(4096)
        n = ctypes.CDLL(None).proc_pidpath(ctypes.c_int(pid), buf, ctypes.c_uint32(4096))
        return os.fsdecode(buf.raw[:n]) if n > 0 else ""
    except (OSError, AttributeError, ValueError):
        return ""


def exe_of(pid):
    """The program path of `pid` on Linux (/proc/<pid>/exe); '' when unread."""
    try:
        return os.readlink("/proc/%d/exe" % pid)
    except OSError:
        return ""


def main(system=None, api=None, env=None):
    system = system or platform.system()
    env = os.environ if env is None else env
    win = system == "Windows"
    print("path: %s" % (
        "Windows: this script reads the processes itself (Toolhelp32 snapshot, NtQueryInformationProcess class 60, as "
        "vibemaestro-brain's win_chain); baton has no Windows lineage and refuses the owner's dialog on Windows today" if win
        else "macOS: baton's own lineage (`ps -o ppid=,args=`, split on blanks)" if system == "Darwin"
        else "%s: baton's own lineage (/proc, exact words)" % system))
    print("platform: %s %s %s | python %s" % (system, platform.release(), platform.machine(), platform.python_version()))
    print("CLAUDE_CODE_ENTRYPOINT: %s | CLAUDE_CODE_DESKTOP_APP_VERSION: %s | CLAUDE_PID set: %s"
          % (env_word("CLAUDE_CODE_ENTRYPOINT", r"[a-z0-9-]{1,40}"), env_word("CLAUDE_CODE_DESKTOP_APP_VERSION", r"[0-9.]{1,20}"),
             "yes" if os.environ.get("CLAUDE_PID") else "no"))
    b, which = load()
    print("plugin loaded: %s" % which)
    entry, by = os.environ.get("CLAUDE_CODE_ENTRYPOINT"), BY_ME if win else ""
    print("entry point official (in %s): %s" % (", ".join(b.OFFICIAL_HOSTS), yes(entry in b.OFFICIAL_HOSTS)))
    if win:
        lin, end = win_lineage(api or WinApi(), os.getpid())
        print("the walk above this process ended at: %s" % end)
        is_claude = lambda argv: any(ntpath.basename(a) in b.CLAUDE_PROGRAMS or "/claude/versions/" in a.replace("\\", "/")
                                     for a in (argv[:argv.index("--")] if "--" in argv else argv)[:2])   # noqa: E731
    else:
        lin = [(pid, argv, comm_of(pid)) for pid, argv, _s in b.lineage()[1:]]   # the processes above this one, as the guard reads them
        is_claude = b.is_claude
    official = lambda argv: (entry in b.OFFICIAL_HOSTS and is_claude(argv) and not b.headless(argv)   # noqa: E731
                             and b.flag_values(argv, FLAG) == ["stdio"])
    hint = os.environ.get("CLAUDE_PID", "")
    tools = {tuple(argv) for _p, argv, _i in lin if b.prompt_tool(argv)}
    up = next((lin[i + 1] for i in range(len(lin) - 1, -1, -1) if b.prompt_tool(lin[i][1]) and i + 1 < len(lin)), None)
    top = "" if up is None else up[2] if win or system == "Darwin" else exe_of(up[0])   # the parent of the outermost carrier
    for i, (pid, argv, prog) in enumerate(lin, 1):
        print("%d. pid %s%s | program %s (%d blank%s in its path) | %d words" % (
            i, pid, " (CLAUDE_PID)" if str(pid) == hint else "", base(prog) if prog else "?", prog.count(" "),
            "" if prog.count(" ") == 1 else "s", len(argv)))
        print("   argv: %s" % shown(argv, b.CLAUDE_PROGRAMS))
        if not b.prompt_tool(argv):
            continue
        vals = b.flag_values(argv, FLAG)
        print("   carries the flag; the five conditions%s:" % by)
        print("     1 entry point official: %s" % yes(entry in b.OFFICIAL_HOSTS))
        print("     2 argv is Claude Code's: %s" % yes(is_claude(argv)))
        print("     3 not a -p run: %s" % ("no" if b.headless(argv) else "yes"))
        print("     4 value exactly stdio: %s (values %s)" % (yes(vals == ["stdio"]),
                                                            [v if TOOL_VALUE.match(v) else "<%d>" % len(v) for v in vals]))
        print("     5 the only argv carrying it: %s (%d carry it)" % (yes(tools == {tuple(argv)}), len(tools)))
        print("     excused: %s" % yes(official(argv) and tools == {tuple(argv)}))
        child = lin[i - 2][1] if i >= 2 else []
        if b.prompt_tool(child):                       # a launcher? its child, the process just above in this list, carries it too
            print("   its child (%d.) carries the flag too: ends with its child's exact argv: %s (%d words of its own)"
                  % (i - 1, yes(len(argv) > len(child) and argv[-len(child):] == child), len(argv) - len(child)))
        if system == "Darwin":
            parent = lin[i][2] if i < len(lin) else ""
            print("   program inside an app bundle (.app/Contents/): %s; in the same app bundle as its parent: %s"
                  % (yes(bundle(prog)), yes(bundle(prog) and bundle(prog) == bundle(parent))))
            kp, kq = kernel_path(pid), kernel_path(lin[i][0]) if i < len(lin) else ""
            print("   by the kernel's path (proc_pidpath): inside an app bundle: %s; in the same app bundle as its parent: %s; "
                  "argv[0] is that path: %s" % (yes(bundle(kp)), yes(bundle(kp) and bundle(kp) == bundle(kq)), yes(kp and kp == prog)))
        else:
            mod, at = (ntpath, prog) if win else (posixpath, exe_of(pid))
            print("   program inside the app's install directory (the directory tree of the top app process's program): %s%s"
                  % (yes(inside(mod.dirname(top), at, mod)), "; install location: %s" % install_place(prog, env) if win else ""))
    if win:
        print("claude process index%s: %s" % (by, next((i for i, (p, a, _x) in enumerate(lin, 1) if str(p) == hint),
                                                        next((i for i, (_p, a, _x) in enumerate(lin, 1) if is_claude(a)), None))))
        print("answerers (baton's function on this script's reading): %s"
              % (b.answerers([(argv, None, None, None) for _p, argv, _x in lin]) or "none"))
    else:
        print("claude process index: %s | -p run above: %s" % (b.claude_index(b.lineage(), hint), b.print_run(b.ancestors())))
        print("answerers: %s" % (b.answerers(b.ancestors()) or "none"))


# --- --self-test: the Windows path on fake records shaped as Windows gives them ----------------------------------------------

class FakeWin:
    """table() and info() as WinApi returns them, from fixed records: (pid, parent pid, creation time, command line, image)."""

    def __init__(self, rows):
        self.rows = {r[0]: r for r in rows}

    def table(self):
        return {pid: r[1] for pid, r in self.rows.items()}

    def info(self, pid):
        if pid not in self.rows:
            raise OSError("access denied")
        return self.rows[pid][2:]


def self_test():
    app = r"D:\profile-x\AppData\Local\AnthropicClaude\app-1.0.0"
    cc = r"D:\profile-x\AppData\Roaming\Claude\claude-code\2.1.300\claude.exe"
    sdk = "--output-format stream-json --verbose --input-format stream-json --permission-prompt-tool=stdio --model=x"
    me = os.getpid()
    env = {"LOCALAPPDATA": r"D:\profile-x\AppData\Local", "APPDATA": r"D:\profile-x\AppData\Roaming",
           "ProgramFiles": r"C:\Program Files"}

    def run(rows):
        out = io.StringIO()
        with redirect_stdout(out):
            main("Windows", FakeWin(rows), env)
        return out.getvalue()

    shape = [(me, 9005, 50, "python3 diag.py", r"C:\Python\python.exe"),
             (9005, 9004, 40, r'"C:\Program Files\Git\usr\bin\bash.exe" -c "python3 diag.py"', r"C:\Program Files\Git\usr\bin\bash.exe"),
             (9004, 9003, 30, '"%s" %s' % (cc, sdk), cc),
             (9003, 9002, 20, r'"%s\resources\disclaimer.exe" --pgroup 12 "%s" %s' % (app, cc, sdk), app + r"\resources\disclaimer.exe"),
             (9002, 9001, 10, r'"%s\Claude.exe"' % app, app + r"\Claude.exe"),
             (9001, 4, 5, "explorer.exe", r"C:\Windows\explorer.exe")]
    os.environ["CLAUDE_CODE_ENTRYPOINT"] = "claude-desktop"
    t = run(shape)
    checks = [("path: Windows: this script reads the processes itself" in t.splitlines()[0], "the first line names the Windows path"),
              ("the walk above this process ended at: System or no parent" in t, "the walk ends at System"),
              ("2. pid 9004 | program claude.exe (0 blanks in its path) | 8 words" in t, "the Claude Code process, read and split"),
              ("argv: claude.exe --output-format <11> --verbose --input-format <11> --permission-prompt-tool=stdio --model=<1>" in t,
               "its argv redacted"),
              (t.count("carries the flag; the five conditions (computed by this script, not by baton):") == 2, "two carriers, marked"),
              ("its child (2.) carries the flag too: ends with its child's exact argv: yes (3 words of its own)" in t,
               "the launcher's tail is its child's exact argv"),
              ("(the directory tree of the top app process's program): yes; install location: per-user" in t,
               "the launcher is in the app's tree, per-user"),
              ("(the directory tree of the top app process's program): no; install location: per-user" in t,
               "Claude Code is not in the app's tree"),
              ("     2 argv is Claude Code's: yes" in t and "profile-x" not in t and "AppData" not in t, "no profile name, no path")]
    bad = dict(enumerate(shape))
    bad[3] = (9003, 9002, 20, r'"%s\resources\disclaimer.exe" --pgroup 12 "%s" %s --extra' % (app, cc, sdk), bad[3][4])
    t2 = run(list(bad.values()))
    checks.append(("ends with its child's exact argv: no (4 words of its own)" in t2, "a launcher tail one word off: no"))
    reused = list(shape[:3]) + [(9003, 9002, 99, "evil.exe", r"C:\x\evil.exe")]
    checks.append(("ended at: the parent id of 9004 now names a younger process" in run(reused), "a reused parent id ends the walk"))
    raw = "ab".encode("utf-16-le")
    buf = struct.pack("HHP", 4, 6, 1000 + struct.calcsize("HHP")) + raw
    checks.append((us_text(buf, 1000) == "ab" and us_text(buf, 999) is None, "UNICODE_STRING read inside the buffer only"))
    checks.append((split_cmdline(r'"C:\a b\c.exe" x "y z" a\\"b"') == [r"C:\a b\c.exe", "x", "y z", "a\\b"], "C runtime split"))
    fails = [why for ok, why in checks if not ok]
    for ok, why in checks:
        print("  %s %s" % ("ok  " if ok else "FAIL", why))
    print("self-test: %d ok, %d fail" % (len(checks) - len(fails), len(fails)))


if __name__ == "__main__":
    try:
        self_test() if sys.argv[1:] == ["--self-test"] else main()
    except Exception as e:                             # always exit 0; a message may hold a path, so only its kind is printed
        print("stopped: %s%s" % (type(e).__name__, " (errno %s)" % e.errno if getattr(e, "errno", None) else ""))
    sys.exit(0)
