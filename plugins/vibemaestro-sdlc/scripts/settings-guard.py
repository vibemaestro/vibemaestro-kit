#!/usr/bin/env python3
"""PreToolUse Edit|Write|MultiEdit|NotebookEdit|Bash hook of vibemaestro-sdlc: a plain-tool write that widens the boundary of a
Claude Code settings file is denied, and the one way is named: `kind:settings-merge`, a baton the owner signs.

A settings file is a `settings*.json` in a directory named `.claude`, or in `$CLAUDE_CONFIG_DIR`. Edit, Write and MultiEdit are
judged on the exact after-state: inside `permissions` a widening stops (an allow rule or an additional directory gained, an ask
or deny rule lost, `defaultMode` moved up, `disableBypassPermissionsMode` dropped, any other key changed) and a narrowing passes;
a top-level key off HARMLESS stops on any change. NotebookEdit on a settings file always stops. Bash is judged on its text and
only finds: a write shape onto a settings name it can read stops, narrowing included; a name built at run time, a script
file, a patch is not seen (skills/batonrun/limits.md). It runs whatever the repo's `hooks` config says, like baton-guard.py: the
config is a file the session can write. It reads the payload, the one file an Edit or Write targets, and $CLAUDE_CONFIG_DIR,
and on a deny asks baton.py how this machine's launcher is spelled and reads the denied settings file's state; it prints rule strings, key names and paths, never another
value. Fail-open until the target is known to be a settings file; after
that an error denies.
"""
import fnmatch
import functools
import json
import os
import re
import shlex
import stat
import sys

sys.dont_write_bytecode = True

# top-level keys whose change passes: they change how a session talks or shows, not what it may do. Any other key stops,
# so a key Claude Code adds later is gated until it is added here.
HARMLESS = ("$schema", "model", "outputStyle", "attribution", "includeCoAuthoredBy", "cleanupPeriodDays", "language",
            "alwaysThinkingEnabled", "spinnerTipsEnabled", "theme")
# permission modes, narrowest first; absent is `default`, a value not here counts as the top
MODES = ("plan", "dontAsk", "default", "acceptEdits", "auto", "bypassPermissions")
GROWS = ("allow", "additionalDirectories")     # a gained entry widens
SHRINKS = ("ask", "deny")                      # a lost entry widens
MISSING = object()
BOM = "\ufeff"
MAX_READ = 1 << 20                              # a settings file read from a payload path: at most 1 MiB

# ── Bash: the text only. Nothing here proves a command safe; it finds the shapes the docs list ──────────────────────────
NAME = re.compile(r"settings[\w.*?\[\]-]*\.json", re.I)
WORD = re.compile(r"""[^\s|;&<>()'"`]*settings[\w.*?\[\]-]*\.json""", re.I)
TOKEN = re.compile(r"""[\s|;&<>()'"`\\]+""")
REDIR_OP = re.compile(r"&>>?|<<<|<<-?|<>|>&|<&|>>?\|?|<")
HEREDOC_DELIM = re.compile(r"""[ \t]*(?:'([^'\n]*)'|"([^"\n]*)"|([^\s;&|<>()'"]+))""")
WRITE_ANY = ("tee", "sponge", "truncate", "rm", "unlink", "shred", "mv", "ln", "patch", "sd")   # the name anywhere after it
WRITE_LAST = ("cp", "install", "rsync", "mv", "ln")   # the destination: a settings name, or a `.claude` directory
IN_PLACE = ("sed", "gsed", "perl", "ruby", "yq", "awk", "gawk")
IN_PLACE_FLAG = re.compile(r"^(?:-[A-Za-z]*i\S*|--in-place\S*)$")
EDITORS = ("ed", "ex", "vi", "vim", "nvim", "emacs")
GIT_WRITES = ("checkout", "restore", "rm", "mv", "stash")
# after one of these, every later word of the simple command may be a command (their options are not parsed)
RUNNERS = ("sudo", "doas", "env", "nohup", "time", "command", "exec", "xargs", "parallel", "timeout", "nice", "ionice",
           "stdbuf", "setsid", "flock", "chroot", "unbuffer", "nsenter", "busybox", "strace", "watch", "then", "do", "else",
           "!", "{", "if", "while", "until", "function")
EXEC_FLAGS = ("-exec", "-execdir", "-ok", "-okdir")
SHELLS = ("bash", "sh", "zsh", "dash", "ksh", "fish")
SHELL_C = re.compile(r"^-[A-Za-z]*c[A-Za-z]*$")
LITERAL = re.compile(r"'([^'\n]*)'" + r'|"((?:[^"\\\n]|\\.)*)"')
CD_ARG = re.compile(r"""(?:^|[\s;&|(])(?:cd|pushd)\s+["']?([^\s;&|()"']+)""")
# a Bash command whose words may be relative to another directory: a cd anywhere, pushd, popd, a -C or --chdir, dd's of=, a
# string a shell or eval runs. Broad on purpose: kind_state then says nothing about the file rather than name the wrong one.
OTHER_DIR = re.compile(r"""(?<![\w-])(?:cd|pushd|popd|eval)(?![\w-])|(?<!\S)(?:-C|--chdir(?:=\S*)?|--directory(?:=\S*)?)(?!\S)"""
                       r"""|(?<![\w-])of=|(?<![\w-])(?:ba|z|da|k)?sh\s+(?:-\w+\s+)*-\w*c""")
ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
OUTPUT_FLAG = re.compile(r"^(?:-o|-O|--output(?:-document)?)(?:=(.*))?$")
INTERPRETER = re.compile(r"""(?:^|[\s/;&|("'`])(?:python[0-9.]*|perl|ruby|node|deno|bun|php|osascript|pwsh|g?awk)(?=[\s;]|$)""")
WRITE_MARK = re.compile(r"""print[^;}\n]*>\s*["']|open\([^)]*,\s*(?:mode\s*=\s*)?['"][^'"]*[wax+>]|\.open\(\s*(?:mode\s*=\s*)?['"][^'"]*[wax+]"""
                        r"""|\bfile\s*=\s*(?!sys\.std)\w|writeTextFile|cpSync|copyFile|O_(?:WRONLY|RDWR|TRUNC|CREAT)|(?<!stdout)(?<!stderr)\.write\(|write_text|write_bytes"""
                        r"""|json\.dump\((?![^\n]*sys\.std)|os\.(?:replace|rename|remove|unlink|truncate)|shutil\.|writeFile|appendFile"""
                        r"""|createWriteStream|fs\.(?:rename|copy|unlink|rm)|File\.(?:write|open\([^)]*['"][wa])|IO\.write|file_put_contents""")

LAUNCHER = "<launcher>"     # only when baton.py cannot say how the launcher is spelled
KNOWN = []          # holds the settings path once the target is known to be one: from then on an error denies


class Unchecked(Exception):
    pass


def config_dir():
    c = os.environ.get("CLAUDE_CONFIG_DIR", "")
    return os.path.realpath(os.path.expanduser(c)) if c else ""


def named_settings(q, cfg):
    """True when the path `q` has a settings name: case is ignored, as a case-insensitive disk (macOS) does."""
    d = os.path.dirname(q)
    return fnmatch.fnmatchcase(os.path.basename(q).lower(), "settings*.json") and (
        os.path.basename(d).lower() == ".claude" or bool(cfg and os.path.realpath(d) == cfg))


def same_file(real, cwd):
    """True when `real` is the file a settings file in the places a session's settings live (the cwd's and the project's
    .claude, the user's ~/.claude, $CLAUDE_CONFIG_DIR) resolves to: a hard link of one, or the target of a settings link."""
    try:
        st = os.stat(real)
    except OSError:
        return False
    cfg = config_dir()
    dirs = {os.path.join(cwd, ".claude"), os.path.expanduser("~/.claude")}
    if os.environ.get("CLAUDE_PROJECT_DIR"):
        dirs.add(os.path.join(os.environ["CLAUDE_PROJECT_DIR"], ".claude"))
    if cfg:
        dirs.add(cfg)
    for d in dirs:
        try:
            names = os.listdir(d)
        except OSError:
            continue
        for n in names:
            if fnmatch.fnmatchcase(n.lower(), "settings*.json"):
                try:
                    if os.path.samestat(st, os.stat(os.path.join(d, n))):
                        return True
                except OSError:
                    pass
    return False


def settings_path(path, cwd):
    """The resolved path when `path` names a Claude Code settings file (as written, the file a symbolic link resolves to, or
    a file a settings file is linked to), else ""."""
    if not path:
        return ""
    p = os.path.abspath(os.path.join(cwd, os.path.expanduser(path)))
    real, cfg = os.path.realpath(p), config_dir()
    if named_settings(p, cfg) or named_settings(real, cfg) or same_file(real, cwd):
        return real
    return ""


# ── Edit, Write, MultiEdit: the exact after-state ───────────────────────────────────────────────────────────────────────
def read_bounded(path):
    """The one reader of a file named by the payload: its text (newlines as text mode reads them), or None when it does not
    exist. Unchecked, so denied, for anything but a regular file of at most MAX_READ bytes: the type is taken from the open
    descriptor (opened non-blocking, so a FIFO or a device is never waited on or read), and at most MAX_READ + 1 bytes are read."""
    try:
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_NOCTTY", 0))
    except FileNotFoundError:
        return None
    except OSError as e:                            # a socket cannot be opened: name its type when stat can
        try:
            other = not stat.S_ISREG(os.stat(path).st_mode)
        except OSError:
            other = False
        raise Unchecked("it is not a regular file, so it is not read" if other else "cannot open it (%s)" % type(e).__name__)
    try:                                            # the type from the descriptor, before anything reads it; closed on every path
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise Unchecked("it is not a regular file, so it is not read")
        f = os.fdopen(fd, "rb")
    except BaseException:
        os.close(fd)
        raise
    with f:
        data = f.read(MAX_READ + 1)
    if len(data) > MAX_READ:
        raise Unchecked("it is over %d bytes, so it is not read whole" % MAX_READ)
    try:
        return data.decode("utf-8").replace("\r\n", "\n").replace("\r", "\n")
    except UnicodeDecodeError as e:
        raise Unchecked("cannot read it (%s)" % type(e).__name__)


def read_before(real):
    """The file's text, or None when it does not exist. Any other failure: Unchecked."""
    return read_bounded(real)


def after_text(tool, ti, before):
    """The file's text after the call. An edit that does not apply exactly is Unchecked: Claude Code's Edit matches more
    loosely (it normalises quotes), so the guard cannot know what it would write."""
    if tool == "Write":
        return str(ti.get("content") or "")
    edits = ti.get("edits") if tool == "MultiEdit" else [ti]
    if not isinstance(edits, list):
        raise Unchecked("the edits are not a list")
    text = before
    for ed in edits:
        if not isinstance(ed, dict):
            raise Unchecked("an edit is not an object")
        old, new = str(ed.get("old_string") or ""), str(ed.get("new_string") or "")
        if text is None:
            if old:
                raise Unchecked("the file does not exist and the edit names text in it")
            text = new
            continue
        if not old and not text:
            text = new
            continue
        if not old or old not in text:
            raise Unchecked("the edit does not match the file exactly, so its result cannot be computed")
        text = text.replace(old, new) if ed.get("replace_all") else text.replace(old, new, 1)
    return text


def no_constant(name):
    raise ValueError("%s is not JSON to JavaScript" % name)


def as_object(text):
    """The object JSON.parse would read (no NaN or Infinity, which Python alone accepts), else None."""
    try:
        d = json.loads(text, parse_constant=no_constant)
    except ValueError:
        return None
    return d if isinstance(d, dict) else None


def strset(v, before=False):
    """The rules of a list. After: None unless a list of strings. Before: the strings it holds, whatever else is there."""
    if v is MISSING:
        return set()
    if isinstance(v, list) and (before or all(isinstance(x, str) for x in v)):
        return set(x for x in v if isinstance(x, str))
    return set() if before else None


def rank(mode, before=False):
    """A mode's place in MODES; absent is `default`. An unknown value counts as the top after the change, as `default`
    before it (Claude Code does not honour it), so a move from it is judged from where the session really stood."""
    if mode is MISSING or (before and mode not in MODES):
        mode = "default"
    return MODES.index(mode) if mode in MODES else len(MODES)


def widenings(b, a):
    """What the change from b to a widens, one phrase each (rule strings and key names only)."""
    out = []
    for k in sorted(set(b) | set(a)):
        if k != "permissions" and k not in HARMLESS and b.get(k, MISSING) != a.get(k, MISSING):
            out.append("changes the key `%s`" % k)
    pb, pa = b.get("permissions", {}), a.get("permissions", MISSING)
    pb = pb if isinstance(pb, dict) else {}
    if pa is MISSING:
        pa = {}
    if not isinstance(pa, dict):
        return out + ["makes `permissions` something other than an object"]
    for k in sorted(set(pb) | set(pa)):
        vb, va = pb.get(k, MISSING), pa.get(k, MISSING)
        if vb == va:
            continue
        if k in GROWS or k in SHRINKS:
            sb, sa = strset(vb, before=True), strset(va)
            if sa is None:
                out.append("makes `permissions.%s` something other than a list of strings" % k)
                continue
            if k in GROWS and sa - sb:
                out.append("adds to `permissions.%s`: %s" % (k, ", ".join(sorted(sa - sb))))
            if k in SHRINKS and sb - sa:
                out.append("removes from `permissions.%s`: %s" % (k, ", ".join(sorted(sb - sa))))
        elif k == "defaultMode":
            if rank(va) > rank(vb, before=True):
                out.append("moves `permissions.defaultMode` up to %s" % ("(none)" if va is MISSING else json.dumps(va)))
        elif k == "disableBypassPermissionsMode":
            if vb == "disable" and va != "disable":
                out.append("drops `permissions.disableBypassPermissionsMode: disable`")
        else:
            out.append("changes the key `permissions.%s`" % k)
    return out


def check_file(tool, ti, cwd):
    real = settings_path(str(ti.get("file_path") or ti.get("notebook_path") or ""), cwd)
    if not real:
        return None
    KNOWN.append(real)
    if tool == "NotebookEdit":
        return real, ["edits it with NotebookEdit"]
    before = read_before(real)
    after = after_text(tool, ti, before)
    before = before or ""
    bb, ab = before.startswith(BOM), after.startswith(BOM)
    a = as_object(after[1:] if ab else after)
    if a is None or (ab and not bb):
        return real, ["leaves it not a JSON object as JavaScript reads it (Claude Code then drops the file, its deny rules "
                      "with it)"]
    b = as_object(before[1:] if bb else before or "{}") or {}
    found = widenings(b, a)
    if bb and not ab:                               # a BOM dropped: the file may have counted as empty before
        found += [x for x in widenings({}, a) if x not in found]
    return (real, found, added_rules(b, a)) if found else None


def added_rules(b, a):
    """The rules file for kind:settings-merge: the allow, ask and deny rules the change gains, or None when it gains no allow
    rule (then the kind has nothing to add that Edit could not)."""
    pb, pa = b.get("permissions", {}), a.get("permissions", {})
    if not isinstance(pa, dict):
        return None
    pb = pb if isinstance(pb, dict) else {}
    out = {}
    for k in ("allow", "ask", "deny"):
        sa = strset(pa.get(k, MISSING))
        gained = sorted(sa - strset(pb.get(k, MISSING), before=True)) if sa else []
        if gained:
            out[k] = gained
    return out if "allow" in out else None


# ── Bash ────────────────────────────────────────────────────────────────────────────────────────────────────────────────
def _close(cmd, i, opener):
    """The index just after the `)` or backtick that closes a substitution opened before `i` (naive: parentheses are
    counted, quotes are skipped), or None when none closes it (a heredoc body with an odd quote): the caller then reads on
    as words, so nothing after it is hidden."""
    depth, q = 1, ""
    while i < len(cmd):
        c = cmd[i]
        if q:
            if c == q:
                q = ""
            elif c == "\\" and q == '"':
                i += 1
        elif c in "'\"":
            q = c
        elif c == "\\":
            i += 1
        elif opener == "`" and c == "`":
            return i + 1
        elif opener == "(" and c == "(":
            depth += 1
        elif opener == "(" and c == ")":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return None


def scan(cmd, run=False):
    """Read `cmd` as the shell splits it, enough to find writes: (segments, targets, nested). A segment is the words of one
    simple command (quotes removed; a quoted sentence stays one word), split at an unquoted `;`, `&`, `|`, `(`, `)` or
    newline. Targets are the words an unquoted output redirection writes to; an input redirection's word is dropped, and so
    is a dup (`2>&1`). Nested are the command strings run inside this one: `$(…)`, backticks, `<(…)`, `>(…)`, and the body of
    a heredoc whose line names a shell. The body of any other heredoc is data and skipped; a comment is an unquoted `#`
    that starts a word. What this cannot read stays as words and is judged as commands."""
    segs, targets, nested = [[]], [], []
    line, pending_hd = [], []
    cur, inword, redir = [], False, None
    i, n = 0, len(cmd)

    def end_word():
        nonlocal cur, inword, redir
        if inword:
            w = "".join(cur)
            if redir == "out":
                targets.append(w)
            elif redir is None:
                segs[-1].append(w)
                line.append(w)
            redir = None
        cur, inword = [], False

    def new_seg():
        end_word()
        if segs[-1]:
            segs.append([])

    while i < n:
        c = cmd[i]
        if c == "\\":
            if cmd[i + 1:i + 2] == "\n":
                i += 2
                continue
            cur.append(cmd[i + 1:i + 2])
            inword, i = True, i + 2
        elif c == "'":
            j = cmd.find("'", i + 1)
            j = n if j < 0 else j
            cur.append(cmd[i + 1:j])
            inword, i = True, j + 1
        elif c == "$" and cmd.startswith("$'", i):
            j = i + 2
            while j < n and cmd[j] != "'":
                if cmd[j] == "\\":
                    j += 1
                cur.append(cmd[j:j + 1])
                j += 1
            inword, i = True, j + 1
        elif c == '"':
            i += 1
            while i < n and cmd[i] != '"':
                if cmd[i] == "\\" and i + 1 < n:
                    cur.append(cmd[i + 1])
                    i += 2
                    continue
                if cmd[i] == "`" or cmd.startswith("$(", i):
                    k = i + (1 if cmd[i] == "`" else 2)
                    j = _close(cmd, k, "`" if cmd[i] == "`" else "(")
                    if j is not None:
                        nested.append(cmd[k:j - 1])
                        cur.append(cmd[i:j])
                        i = j
                        continue
                    nested.append(cmd[k:])          # unclosed: its text is read as commands too
                cur.append(cmd[i])
                i += 1
            inword, i = True, i + 1
        elif c == "`" or cmd.startswith("$(", i) or (c in "<>" and cmd[i + 1:i + 2] == "(" and not inword):
            k = i + (1 if c == "`" else 2)
            j = _close(cmd, k, "`" if c == "`" else "(")
            if j is None:                               # unclosed: read on as words, and its text as commands
                nested.append(cmd[k:])
                cur.append(cmd[i:k])
                inword, i = True, k
            else:
                nested.append(cmd[k:j - 1])
                cur.append(cmd[i:j])
                inword, i = True, j
        elif c == "#" and not inword:
            j = cmd.find("\n", i)
            i = n if j < 0 else j
        elif c in " \t\r":
            end_word()
            i += 1
        elif c == "\n":
            new_seg()
            i += 1
            for delim, strip_tabs, shell in pending_hd:
                body = []
                while i < n:
                    j = cmd.find("\n", i)
                    j = n if j < 0 else j
                    ln = cmd[i:j]
                    i = j + 1
                    if (ln.lstrip("\t") if strip_tabs else ln) == delim:
                        break
                    body.append(ln)
                if shell or run:
                    nested.append("\n".join(body))
            pending_hd, line[:] = [], []
        elif c in "<>&" and (c != "&" or cmd[i + 1:i + 2] == ">"):
            if inword and "".join(cur).isdigit():
                cur, inword = [], False                  # `2>`: the fd is not a word
            end_word()
            op = REDIR_OP.match(cmd, i).group(0)
            i += len(op)
            if op in (">&", "<&") and re.match(r"[0-9-]", cmd[i:i + 1]):
                while i < n and re.match(r"[0-9-]", cmd[i]):
                    i += 1                               # a dup: no file
            elif op.startswith("<<") and op != "<<<":
                m = HEREDOC_DELIM.match(cmd, i)
                if m:
                    i = m.end()
                    delim = m.group(1) if m.group(1) is not None else m.group(2) if m.group(2) is not None else m.group(3).replace("\\", "")
                    pending_hd.append((delim, op == "<<-", None))
                    # whether this line runs a shell is known at its end: mark it lazily below
            elif op in ("<", "<<<"):
                redir = "in"
            else:
                redir = "out"
        elif c in "|;&()":
            new_seg()
            i += 1
        else:
            cur.append(c)
            inword, i = True, i + 1
        if pending_hd and (i >= n or cmd[i:i + 1] == "\n"):
            end_word()
            shell = any(os.path.basename(w) in SHELLS + ("eval", "source", ".") for w in line + segs[-1])
            pending_hd = [(d, t, shell) for d, t, _ in pending_hd]
    end_word()
    return [sg for sg in segs if sg], targets, nested


def expand(w, cwd):
    """`w` with $HOME, ~, $PWD and $CLAUDE_CONFIG_DIR put in (the names a session writes literally); `.` is the cwd."""
    cfg = config_dir()
    for k, v in (("${HOME}", os.path.expanduser("~")), ("$HOME", os.path.expanduser("~")), ("${PWD}", cwd), ("$PWD", cwd),
                 ("${CLAUDE_CONFIG_DIR}", cfg or "\0cfg"), ("$CLAUDE_CONFIG_DIR", cfg or "\0cfg")):
        w = w.replace(k, v)
    return os.path.expanduser(w)


@functools.lru_cache(maxsize=4096)
def claude_dir(w, cwd):
    """True when the word `w` names a `.claude` directory or $CLAUDE_CONFIG_DIR (a copy into it lands on its settings)."""
    if not w or len(w) > 4096:
        return False
    x = expand(w, cwd).rstrip("/") or "/"
    if "\0cfg" in x:
        return x.endswith("\0cfg")
    cfg = config_dir()
    p = os.path.realpath(os.path.join(cwd, x))
    return os.path.basename(x).lower() == ".claude" or os.path.basename(p).lower() == ".claude" or bool(cfg and p == cfg)


def settings_glob(base):
    """True when the file name (or glob) `base` is or can match a settings file name."""
    b = base.lower()
    return fnmatch.fnmatchcase(b, "settings*.json") or any(fnmatch.fnmatchcase(x, b) for x in ("settings.json", "settings.local.json"))


class Words:
    """What one Bash text tells about settings names; cached per call."""

    def __init__(self, cmd, cwd):
        self.cwd = cwd
        cfg = config_dir()
        cds = set(CD_ARG.findall(cmd))
        self.bare = claude_dir(cwd, cwd) or any(claude_dir(x, cwd) for x in set(TOKEN.split(cmd)) | cds if x and (
            x in cds or ".claude" in x.lower() or "CLAUDE_CONFIG_DIR" in x or x in (".", "./", "..", "../", "$PWD", "${PWD}")
            or (cfg and (cfg in x or os.path.basename(cfg) in x))))
        self.cache = {}

    def claude(self, w):
        """True when `w` names a Claude Code settings file as far as the text shows: a settings name whose own directory
        is `.claude` or $CLAUDE_CONFIG_DIR (a `.claude/worktrees/…` path above it does not count), or a bare name where
        the cwd or a word of the text is such a directory (`cd .claude && …`)."""
        if w not in self.cache:
            if w.startswith("of="):
                w2 = w[3:]
            else:
                w2 = w
            ok = False
            if "settings" in w2.lower() or "*" in w2:
                base, d = os.path.basename(w2), os.path.dirname(w2)
                if settings_glob(base):
                    ok = (claude_dir(d, self.cwd) or bool(settings_path(expand(w2, self.cwd), self.cwd))) if d else self.bare
            self.cache[w] = ok
        return self.cache[w]


def git_sub(args):
    """git's subcommand: the first word after its global options (`-C <dir>`, `-c <k=v>` take a value)."""
    j = 0
    while j < len(args):
        if args[j] in ("-C", "-c", "--git-dir", "--work-tree", "--namespace"):
            j += 2
        elif args[j].startswith("-"):
            j += 1
        else:
            return args[j]
    return ""


def destination(n, args):
    """(destination, from a target-directory option) of a copy, move or link: `-t DIR`, `-rtDIR`, `--target-directory[=]DIR`
    (not rsync's `-t`, which keeps times), else the last word that is not an option."""
    if n != "rsync":
        for j, x in enumerate(args):
            if x.startswith("--target-directory"):
                v = x.partition("=")[2] or (args[j + 1] if j + 1 < len(args) else "")
                return v, True
            m = re.match(r"^-[A-Za-z]*t(.*)$", x)
            if m and not x.startswith("--"):
                return (m.group(1) or (args[j + 1] if j + 1 < len(args) else "")), True
    ops = [x for x in args if not x.startswith("-") or x == "-"]
    return (ops[-1] if ops else ""), False


def check_segment(words, w, xin, cwd):
    """(word, shape) of a write onto a settings name in one simple command, else None. `xin`: a settings name somewhere in
    the whole text, for what xargs is fed."""
    hits = [x for x in words if w.claude(x)]
    if "git" in words and "--cached" in words:
        return None                                 # `git rm --cached`: the index only, the file stays
    first = next((k for k, x in enumerate(words) if not ASSIGN.match(x)), len(words))
    runner = xargs = execd = False
    repl = "{}"
    for k in range(first, len(words)):
        x = words[k]
        nm = os.path.basename(x)
        if k == first or runner:
            args = words[k + 1:]
            if execd or xargs:
                cut = next((j for j, a in enumerate(args) if a in (";", "+")), len(args))
                args = args[:cut]
            later = [a for a in args if a in hits]
            fed = (execd and "{}" in args) or xargs  # its operands come from find or xargs
            fed_hit = (execd and hits) or (xargs and xin)
            if nm in WRITE_ANY and (later or (fed and fed_hit)):
                return (later or hits or [x])[0], nm
            if nm in WRITE_LAST and args:
                dest, tdir = destination(nm, args)
                if (execd and dest == "{}") or (xargs and (dest == repl or (not tdir and repl == "{}" and not any(
                        a.startswith("-I") or a.startswith("--replace") or a == "-i" for a in words[first:k])))):
                    if fed_hit:
                        return (hits or [dest])[0], nm + " of what " + ("find" if execd else "xargs") + " feeds it"
                elif w.claude(dest):
                    return dest, nm
                elif claude_dir(dest, cwd) and any(settings_glob(os.path.basename(a)) for a in args if a != dest):
                    return dest, nm + " into it"
            if nm == "dd" and any(a.startswith("of=") and w.claude(a) for a in args):
                return next(a for a in args if a.startswith("of=")), "dd of="
            if nm in IN_PLACE and any(IN_PLACE_FLAG.match(a) for a in args) and (hits or (xargs and xin)):
                return (hits or [x])[0], nm + " in place"
            if nm in EDITORS and later:
                return later[0], nm
            if nm == "git":
                sub = git_sub(args)
                if sub in GIT_WRITES and (later or (xargs and xin)) and not (
                        sub == "restore" and "--staged" in args and not ("--worktree" in args or "-W" in args)):
                    return (later or [x])[0], "git " + sub
            if nm == "find" and hits and "-delete" in args:
                return hits[0], "find -delete"
            if (k == first or runner) and nm in RUNNERS:
                runner = True
                if nm == "xargs":
                    xargs = True
                    for a in args:
                        if a.startswith("-I"):
                            repl = a[2:] or repl
        if x in EXEC_FLAGS:
            runner = execd = True
    for j, x in enumerate(words):
        o = OUTPUT_FLAG.match(x)
        if o and ((o.group(1) and w.claude(o.group(1))) or (not o.group(1) and j + 1 < len(words) and w.claude(words[j + 1]))):
            return o.group(1) or words[j + 1], "an output flag"
    return None


def shell_strings(words):
    """The command strings a shell in this simple command runs: `bash -c [--] 'STR'` (any `-…c…` flag), `su|flock … -c
    'STR'`, `eval STR…`, and every operand of `watch` or `parallel`."""
    out = []
    for k, x in enumerate(words):
        nm = os.path.basename(x)
        if nm in SHELLS + ("su", "flock"):
            for j in range(k + 1, len(words) - 1):
                if SHELL_C.match(words[j]) or words[j] == "--command":
                    rest = [a for a in words[j + 1:] if a != "--"]
                    out.extend(rest[:1])
                    break
        if nm == "eval":
            out.append(" ".join(words[k + 1:]))
        if nm in ("watch", "parallel"):
            out.extend(a for a in words[k + 1:] if not a.startswith("-"))   # an option's value too: options are not parsed
    return out


def literals(text, depth=0):
    """The string literals in `text` that hold a settings name, and the literals inside them (two levels): in interpreter
    code they may be shell a shell-out runs (`os.system('… > settings.json')`), so each is read again as commands."""
    out = []
    for m in LITERAL.finditer(text):
        v = m.group(1) if m.group(1) is not None else m.group(2).replace('\\"', '"')
        if "settings" in v.lower():
            out.append(v)
            if depth < 2:
                out.extend(literals(v, depth + 1))
    return out


def check_bash(cmd, cwd, depth=0, run=False):
    """(word, shape) of the first write shape onto a Claude settings name, else None. `run`: a shell runs this text, so a
    heredoc body in it is commands."""
    cfg = config_dir()
    if depth > 6 or (not NAME.search(cmd) and not (cfg and cfg in cmd)):
        return None
    w = Words(cmd, cwd)
    named = [x for x in TOKEN.split(cmd) if "settings" in x.lower() and WORD.fullmatch(x)]
    xin = any(w.claude(x) for x in named)
    segs, targets, nested = scan(cmd, run)
    for t in targets:
        if w.claude(t):
            return t, "a redirection"
    for words in segs:
        hit = check_segment(words, w, xin, cwd)
        if hit:
            return hit
        for inner in shell_strings(words):
            hit = check_bash(inner, cwd, depth + 1, run=True)
            if hit:
                return hit
    for inner in nested:
        hit = check_bash(inner, cwd, depth + 1, run)
        if hit:
            return hit
    if xin and INTERPRETER.search(cmd):
        if WRITE_MARK.search(cmd):
            return next(x for x in named if w.claude(x)), "inline code that writes"
        for lit in literals(cmd):                   # a shell-out's string: `os.system('echo x > .claude/settings.json')`
            if lit != cmd:
                hit = check_bash(lit, cwd, depth + 1, run=True)
                if hit:
                    return hit
    return None


# ── the answer ──────────────────────────────────────────────────────────────────────────────────────────────────────────
BASH_NOTE = (" This guard reads a Bash command as text and found a write shape onto a Claude Code settings file, so it cannot "
             "tell a narrowing from a widening. If the command only reads, read another way (cat, jq, the Read tool). A "
             "narrowing or a harmless key goes through the Edit tool, which is checked exactly; the kind's rules file goes "
             "through the Write tool, outside `.claude/`.")


POD_NOTE = (" In a pod the owner never signs: after exit 8, hand the coordinator the call the output names; run no sign, run "
            "or go --queue line.")


def in_pod():
    return all(os.environ.get(v, "").strip() for v in ("INTENT_SLUG", "SEAT"))


def launcher():
    """The launcher as a session types it and the printed permission rules allow it (baton.py's `~/` spelling, else its quoted
    path); with none installed, the plugin's baton.py; LAUNCHER when baton.py cannot be read."""
    try:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import baton
        if os.path.isfile(baton.launcher_path()):
            return baton.tilde_launcher() or shlex.quote(baton.launcher_path())
        return "python3 " + shlex.quote(os.path.abspath(baton.__file__))
    except Exception:
        return LAUNCHER


NEW_FILE = "new"            # kind_state: the settings file is missing or empty, so `{}` goes first
NOT_OBJECT = "not-object"   # it holds something the kind cannot merge into


def kind_state(path, cwd):
    """(state, absolute path): what the settings file holds now, as kind:settings-merge sees it. The kind merges only into a
    file holding a JSON object (json.load, so no byte-order mark). Unknown ("") for a word the shell would expand, no cwd (a
    Bash command that changes directory), what read_bounded refuses, or any failure: it never raises, since the deny that
    carries it must go out."""
    try:
        cwd = os.getcwd() if cwd is None else cwd
        if not cwd or re.search(r"[$*?\[`]", path):
            return "", path
        full = os.path.abspath(os.path.join(cwd, os.path.expanduser(path)))
        try:
            text = read_bounded(full)
        except Unchecked:
            return "", full
        if text is None:
            return NEW_FILE, full
        if not text.strip():
            return NEW_FILE, full
        return ("" if not text.startswith(BOM) and as_object(text) is not None else NOT_OBJECT), full
    except BaseException:                           # RecursionError on a deeply nested file, among others
        return "", path


def reason(tool, path, what, rules=None, cwd=None):
    first, full = kind_state(path, cwd)
    q = shlex.quote(path) if os.path.isabs(path) else path
    go = "`%s go kind:settings-merge %s <that path>`" % (launcher(), q)
    pre = ("Write {} to %s (Read it first if it exists; it widens nothing, so it passes; the kind merges only into a file "
           "holding a JSON object), then " % full if first == NEW_FILE else "")
    if first == NOT_OBJECT:
        how = ("The file holds no JSON object the kind can merge into (it reads plain JSON, no byte-order mark): that waits "
               "for the owner, as below; a Write of {} over it would drop what it holds. Once it holds one, the way is %s "
               "with a rules file" % go)
    elif rules:
        how = ("The one way, in one response: %sWrite %s to a fresh path outside `.claude/` (the kind reads a rules file only "
               "within 120 s of its writing), then run %s" % (pre, json.dumps(rules), go))
    else:
        how = ("The one way, in one response: %sWrite the rules you mean to add, as {\"allow\": [...], \"ask\": [...], "
               "\"deny\": [...]} with rule strings only, to a fresh path outside `.claude/`, then run %s" % (pre, go))
    return ("vibemaestro-sdlc settings guard: this %s call %s in %s. Widening what a session may do through a Claude Code "
            "settings file is a stop-list act (security-boundary): a session never makes it with a plain tool, on the owner's "
            "laptop as in a pod. %s; it adds the rules and stops for the owner to sign (exit 8). A change the kind does not "
            "make (defaultMode, an added directory, removing an ask or deny rule, another key) waits for the owner: tell them "
            "what and why. Never do it another way (another tool, command or file). A narrowing (removing an allow rule, adding "
            "an ask or deny rule) and the keys %s pass through Edit, which this guard checks exactly.%s%s"
            % (tool, "; ".join(what), path, how, ", ".join(HARMLESS), BASH_NOTE if tool == "Bash" else "",
               POD_NOTE if in_pod() else ""))


def deny(text):
    sys.stdout.write(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                                        "permissionDecisionReason": text}}) + "\n")


def main():
    inp = json.loads(sys.stdin.buffer.read().decode("utf-8", "replace") or "{}")
    if not isinstance(inp, dict) or not isinstance(inp.get("tool_input"), dict):
        return 0
    tool, ti = str(inp.get("tool_name") or ""), inp["tool_input"]
    cwd = str(inp.get("cwd") or "") or os.getcwd()
    if tool == "Bash":
        cmd = str(ti.get("command") or "")
        try:
            hit = check_bash(cmd, cwd)
        except Exception as e:                      # a text that names a settings file is denied when it cannot be read
            if not NAME.search(cmd):
                raise
            hit = (NAME.search(cmd).group(0), "could not be checked (%s)" % type(e).__name__)
        if hit:
            word = re.sub(r"^[A-Za-z_][\w-]*=", "", hit[0])     # dd's of=<file>: the file
            deny(reason(tool, word, ["writes %s (%s), and a Bash write cannot show what it changes" % hit],
                        cwd="" if OTHER_DIR.search(cmd) else cwd))   # the word may be relative to another directory
        return 0
    if tool in ("Edit", "Write", "MultiEdit", "NotebookEdit"):
        try:
            hit = check_file(tool, ti, cwd)
        except Unchecked as e:
            hit = (KNOWN[-1], ["could not be checked: %s" % e])
        if hit:
            deny(reason(tool, *hit, cwd=cwd))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:                              # fail-open on ordinary work; a known settings target is denied
        sys.stderr.write("settings-guard: %s: %s\n" % (type(e).__name__, e))
        if KNOWN:
            deny(reason("tool", KNOWN[-1], ["could not be checked (%s)" % type(e).__name__]))
        sys.exit(0)
