"""Lõi dùng chung của ba hook plugin vibemaestro-sdlc (SessionStart, PreToolUse path, PreToolUse lệnh).

Plugin TỰ ĐỦ: lõi quy trình, luật và cơ chế tra luật đều nằm trong thư mục plugin (`rules/`,
`scripts/rules.py`); không phụ thuộc repo nào khác lúc chạy. Module này làm bốn việc:

  1. đọc config của repo: `hooks: off` thì IM (repo giữ hook tra luật riêng đặt nó để khỏi nhắc hai lần);
  2. giao lõi quy trình + danh mục luật + lời nhắc luồng/`kb/` lúc mở phiên;
  3. nhắc luật theo file/lệnh khi sắp sửa file hoặc chạy lệnh (kể cả chặn `level: block`);
  4. nói to khi hỏng, nhưng KHÔNG BAO GIỜ chặn công cụ (ngoại lệ duy nhất: `block` có chủ đích của luật).

Chỉ dùng thư viện chuẩn, tương thích Python 3.8+. Mọi đường lỗi trả rc 0.
"""
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time

sys.dont_write_bytecode = True      # không đẻ __pycache__ vào thư mục plugin (có thể là bản cài trong cache)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rules as R  # noqa: E402
import rule_packs  # noqa: E402
import sdlc_config as C  # noqa: E402
from hookout import (PLUGIN_NAME, config_short_note, config_short_warn, config_note_text, config_warn_text, emit, marker_name, once,  # noqa: E402,F401
                     session_dir, short_warn, warn_text)

# ── hằng số ────────────────────────────────────────────────────────────────────
CORE_NAME = "workflow-core.instructions.md"   # lõi quy trình: giao nguyên văn lúc mở phiên
COORDINATED_NAME = "coordinated-work.instructions.md"   # delivered after the core only in a coordinated session
PLUGIN_SKILLS = ("init-kb", "intake", "brainstorm", "spec", "plan", "ship")  # chỉ được nhắc khi thư mục skill CÓ MẶT (A7)
FLOW_ORDER = ("intake", "brainstorm", "spec", "plan", "ship")  # chuỗi lời nhắc luồng ở repo app, theo thứ tự làm
# (skill trùng việc của một plugin quy trình bên thứ ba → skill thay thế của ta): câu "không dùng X" chỉ có khi skill thay thế vừa kiểm là có mặt (A7)
PROCESS_SWAP = (("brainstorming", "brainstorm"), ("writing-plans", "plan"),
                ("finishing-a-development-branch", "ship"))
SANDBOX_ENV = ("INTENT_SLUG", "SEAT")                  # cả hai cùng có = phiên trong sandbox (in_sandbox)

# Trần nội dung MỖI chuỗi hook in ra là 10.000 ký tự (tài liệu hooks: "capped at 10,000 characters …
# each string measured on its own"). Giữ dưới 9.000 để chừa biên; ký tự tiếng Việt có dấu đếm theo ký tự.
BUDGET = 9000
GIT_TIMEOUT = 3
UNKNOWN_TTL = 300      # seconds a "could not tell" of the behind-origin check is reused in a session (repo_upstream)


# ── tiện ích nhỏ ───────────────────────────────────────────────────────────────
def read_text(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return None


def git_out(cwd, *args):
    """stdout đã strip nếu rc 0, None ở mọi nhánh lỗi (git thiếu, treo, repo lạ)."""
    try:
        r = subprocess.run(("git", "-C", cwd) + args, capture_output=True, text=True, timeout=GIT_TIMEOUT)
    except Exception:
        return None
    return r.stdout.strip() if r.returncode == 0 else None


def read_payload(raw):
    try:
        d = json.loads(raw)
        return d if isinstance(d, dict) else {}
    except Exception:
        return {}


def plugin_root():
    """Thư mục plugin: biến `CLAUDE_PLUGIN_ROOT` (Claude Code đặt cho hook) hoặc vị trí của chính file này."""
    root = os.environ.get("CLAUDE_PLUGIN_ROOT", "").strip()
    return os.path.abspath(root) if root else os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def plugin_problems(root):
    """Lý do bộ luật của plugin không dùng được; rỗng = dùng được. Plugin hỏng khi cài (thiếu rules/, thiếu lõi)."""
    out = []
    if not os.path.isdir(os.path.join(root, R.RULES_DIR)):
        out.append("the plugin lacks the directory %s/: %s" % (R.RULES_DIR, os.path.join(root, R.RULES_DIR)))
    elif not os.path.isfile(os.path.join(root, R.RULES_DIR, CORE_NAME)):
        out.append("the plugin lacks the process core %s/%s" % (R.RULES_DIR, CORE_NAME))
    return out


# ── gốc repo của phiên và trạng thái hook ──────────────────────────────────────
def project_root(payload):
    """Gốc repo của PHIÊN: CLAUDE_PROJECT_DIR (Claude Code đặt), rồi cwd trong payload."""
    d = os.environ.get("CLAUDE_PROJECT_DIR") or payload.get("cwd") or os.getcwd()
    d = os.path.realpath(d)
    top = git_out(d, "rev-parse", "--show-toplevel") if os.path.isdir(d) else None
    return os.path.realpath(top) if top else d


def hook_state(troot, sid):
    """(config, silent, warning). The activation table of the config contract:

      silent  when `hooks` is `off`; otherwise active. The repo's own `.claude/settings.json` plays no part: a repo that runs
              its own rule hooks next to the plugin's sets `hooks` to `off` to keep the reminders single.
      warning (text, short) for an INVALID config, once per session, else None. An invalid config means the defaults here,
              so `hooks` is `auto` and a warning never meets `silent`. A valid config with notes (keys this plugin does not
              know, deprecated keys) gives the notes' warning instead, once per session too.
    Never raises on a bad file, never blocks: the callers go on with `config`."""
    cfg, probs, _present = C.load(troot, quiet=True)
    if probs:
        warn = (config_warn_text(probs), config_short_warn(probs)) if once("config-invalid:" + troot, sid) else None
    else:
        notes = C.LAST_NOTES                           # what this load found: no second parse on the hook's hot path
        warn = (config_note_text(notes), config_short_note(notes)) if notes and once("config-notes:" + troot, sid) else None
    return cfg, cfg["hooks"] == "off", warn


def with_warn(warn, ctx, sysmsg=""):
    """(context, system message) with the config warning (if any) in front: the one place that merges it, so no branch of a hook
    drops it (`hook_state` has already used up its once-per-session mark)."""
    if not warn:
        return ctx, sysmsg
    return warn[0] + ("\n\n" + ctx if ctx else ""), (warn[1] + "; " + sysmsg) if sysmsg else warn[1]


def say(event, ctx, warn, extra=None):
    """One JSON for the hook: the config warning (if any) goes in front of what the hook has to say."""
    ctx, sysmsg = with_warn(warn, ctx)
    emit(event, ctx, sysmsg, extra)


def say_broken(kind, bad, sid, warn):
    """PreToolUse on a plugin that cannot deliver its rules: the plugin warning (once per session, `kind`) and the config warning
    in one JSON."""
    ctx, sysmsg = with_warn(warn, *((warn_text(["rule cannot be read: " + p for p in bad]), short_warn(bad)) if once(kind, sid)
                                    else ("", "")))
    if ctx:
        emit("PreToolUse", ctx, sysmsg)


# ── cảnh báo, dedup, đầu ra: ở hookout.py (không phụ thuộc module nào khác để báo được cả khi import hỏng) ──


# ── the tree behind origin/<default> (the git side is in rules.py) ──
def repo_upstream(troot, cfg, sid):
    """`R.upstream` for the session's repo, or None when it is not behind or cannot tell. The answer is cached per session,
    keyed by the two commits and the rule directories, so a hook after the first one pays for one git process."""
    deadline = time.monotonic() + R.UPSTREAM_DEADLINE   # one deadline for every git process of the check
    probe = R.upstream_probe(troot, deadline)
    if not probe or probe[0] == probe[2]:
        return None
    dirs = R.repo_dirs(cfg["rules"])
    key = hashlib.sha1(json.dumps([troot, list(probe), list(dirs)]).encode("utf-8")).hexdigest()[:20]
    path = os.path.join(session_dir(sid), "upstream-" + key + ".json") if sid else None
    up = _cache_read(path) if path else None
    if isinstance(up, dict) and up.get("unknown") and time.time() - float(up.get("at") or 0) < UNKNOWN_TTL:
        return None                            # it could not tell a moment ago: do not pay the deadline on every hook
    if not isinstance(up, dict) or not isinstance(up.get("files"), dict):
        try:
            up = R.upstream(troot, probe, dirs, deadline)
        except Exception:
            up = None                          # an answer git gave that we cannot read: the tree's rules, unmarked
        if up is None:                         # could not tell (git error, deadline): remembered for UNKNOWN_TTL seconds
            if path:
                _cache_write(path, {"unknown": True, "at": time.time()})
            return None
        if path:
            _cache_write(path, up)
    return up if up.get("behind") else None


def _cache_read(path):
    """The cached answer, trusted only from a file of this user that nobody else can write (its text reaches the model)."""
    try:
        st = os.lstat(path)
        if not os.path.isfile(path) or os.path.islink(path) or st.st_mode & 0o022 or (hasattr(os, "getuid") and st.st_uid != os.getuid()):
            return None
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def _cache_write(path, up):
    tmp = "%s.%d.tmp" % (path, os.getpid())
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(up, f)
        os.replace(tmp, path)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def upstream_line(up, rel, troot, kind="ref", local=None):
    """A reminder line for a file of the overlay: `<ref>:<path>` (quoted for a shell when it needs it) and its mark for the
    ref's text, or the tree's path and its mark for the other kinds (`R.load_repo_dir`)."""
    if kind != "ref":
        return "%s %s" % (local, R.upstream_mark(up, rel, troot, kind))
    return "%s %s" % (R.shq("%s:%s" % (up["ref"], rel)), R.upstream_mark(up, rel, troot))


def fetch_age(troot):
    """How long ago this checkout last fetched, in words, from the time of `FETCH_HEAD`: git writes it in the git dir of the
    checkout that fetched (a linked worktree has its own), so the newer of that one and the common dir's."""
    times = []
    for d in dict.fromkeys(x for x in R.git_dirs(troot) if x):
        try:
            times.append(os.path.getmtime(os.path.join(d, "FETCH_HEAD")))
        except OSError:
            pass
    if not times:
        return "unknown (no FETCH_HEAD)"
    age = time.time() - max(times)
    for unit, sec in (("day", 86400), ("hour", 3600), ("minute", 60)):
        if age >= sec:
            k = int(age // sec)
            return "%d %s%s ago" % (k, unit, "" if k == 1 else "s")
    return "under a minute ago"


def _plural(n, word):
    return "%d %s%s" % (n, word, "" if n == 1 else "s")


def behind_warning(up, troot, notes, dirs=()):
    """(context, system message) of the SessionStart warning that the tree is behind its default ref. The counts are of what
    is delivered: live rules and decisions from the ref, the tree's own edits kept, and files the ref deleted that were live in
    the tree (a deleted file the tree changed too is kept, so it is counted as kept)."""
    over = {d[0]: d[1] for k, _n, d in notes if k == "upstream"}
    over.update({r: kind for _n, _t, r, kind in R.load_repo_dir(troot, R.DECISIONS_REL, ".md", up) if r})
    count = {k: list(over.values()).count(k) for k in ("ref", "both", "gone")}
    lacking = R.unread_names(up, dirs)        # delivered from the tree when it has them, but counted and named either way
    default = up["ref"].split("/", 1)[1]
    update = ("`git pull --ff-only`" if R.head_branch(troot) == "refs/heads/" + default else
              "bring the branch up to date with %s (`git merge %s`; a pull only follows the branch's own upstream)"
              % (up["ref"], R.shq(up["ref"])))
    ctx = ("WARNING: this tree (%s) is behind %s by %s. The plugin never fetches: it compares with %s as last fetched "
           "(last fetch: %s), so the remote may be further ahead. Repo rules (rules.dirs) and kb/decisions that %s changed are "
           "served from it, each line marked [from %s: ...] with the command that shows its text: %s now%s. To bring the tree "
           "up to date: `git -C %s fetch origin`, then %s."
           % (troot, up["ref"], _plural(up["behind"], "commit"), up["ref"], fetch_age(troot), up["ref"], up["ref"],
              _plural(count["ref"], "file"),
              "".join("; %s %s, delivered as the tree has them and marked" % (_plural(count[k], "file"), what)
                      for k, what in (("both", "the tree changed too"), ("gone", "%s does not have" % up["ref"])) if count[k])
              + (("; %s whose text this clone lacks (%s%s), so a rule only the ref has cannot be matched until a fetch"
                  % (_plural(len(lacking), "file"), ", ".join(lacking[:5]), ", ..." if len(lacking) > 5 else ""))
                 if lacking else ""),
              R.shq(troot), update))
    sysmsg = "%s: this tree is behind %s by %d commit(s) (as last fetched); repo rules and decisions it changed are served from it" % (
        PLUGIN_NAME, up["ref"], up["behind"])
    return ctx, sysmsg


# ── PreToolUse ─────────────────────────────────────────────────────────────────
def _rule_path(root, name, paths=None):
    return (paths or {}).get(name) or os.path.join(root, R.RULES_DIR, name)


def _stale(notes):
    """{rule name: (its path in the repo, kind)} of the repo rules of the overlay (`upstream` notes of `load_all`)."""
    return {n: d for k, n, d in notes if k == "upstream"}


def _rule_line(root, name, paths, up, stale, troot):
    """The path a reminder prints for a rule; a rule of the overlay prints its line with the mark instead."""
    if up and name in stale:
        return upstream_line(up, stale[name][0], troot, stale[name][1], _rule_path(root, name, paths))
    return _rule_path(root, name, paths)


PACK_LINES_MAX = 10      # rule-pack lines in one reminder, and their characters together; the rest are counted in one line
PACK_CHARS_MAX = 3000


def _marked(kind, sid):
    """`once(kind, sid)` already said in this session (nothing is marked here)."""
    return bool(sid) and os.path.exists(os.path.join(session_dir(sid), marker_name(kind)))


def _slow_key(mine, name):
    return "pack-slow:%s:%s" % (mine[name], name)


def _match(rules, mine, match, sid, what):
    """(names of the rules that `match`, warning line or ""). This plugin's and the repo's rules first, unbounded; the rule
    packs (`mine`, see R.pack_of) after, under one timer (`R.match_bounded`). A pack rule that runs over the timer is marked for
    the session and skipped from then on, so it costs one call one second once; in that call the pack rules after it are not
    matched. The warning names the rule, once."""
    hits = match([r for r in rules if r[0] not in mine])
    more, over = R.match_bounded(match, [r for r in rules if r[0] in mine and not _marked(_slow_key(mine, r[0]), sid)])
    if not over or not once(_slow_key(mine, over), sid):
        return hits + more, ""
    return hits + more, ("WARNING: rule packs: matching the rule %s of %s ran over %.0f s and was stopped; it is skipped for "
                         "the rest of this session, and the rule-pack rules after it were not matched for this %s."
                         % (over, _short(mine.get(over)), R.PACK_MATCH_SECONDS, what))


def _oneline(s):
    """A value from a file this plugin does not control, for a message: one line, a control character shown as `?`."""
    return "".join(c if c.isprintable() else "?" for c in "%s" % (s,))


def _short(s, n=80):
    """`_oneline`, cut."""
    s = _oneline(s)
    return s if len(s) <= n else s[:n] + "..."


def _cap_packs(items, mine, size):
    """(the items to remind, how many pack items were left out): every item of this plugin and the repo, and of the rule packs
    at most PACK_LINES_MAX whose lines (`size(item)` characters each) take at most PACK_CHARS_MAX together, so pack lines cannot
    push the rest of a reminder past the hook's size cap. An item is a rule name or a tuple that starts with one."""
    out, n, used, extra = [], 0, 0, 0
    for x in items:
        if (x[0] if isinstance(x, tuple) else x) in mine:
            k = size(x)
            if n >= PACK_LINES_MAX or used + k > PACK_CHARS_MAX:
                extra += 1
                continue
            n, used = n + 1, used + k
        out.append(x)
    return out, extra


def _more_line(extra):
    return ("- ... and %d more rule-pack rule(s) match; they are left out of this reminder (size cap)" % extra) if extra else ""


def _seen(name, up, stale, mine=None):
    """Dedup key of a rule reminder: a rule of the overlay is keyed by the ref's commit too, so a fetch or a pull in the middle
    of a session that changes where the text comes from is reminded again; a rule-pack rule by its plugin, so it never
    answers for a repo rule of the same name."""
    if mine and name in mine:
        return "rule-pack:%s:%s" % (mine[name], name)
    return "rule:" + name + ((":%s:%s" % (stale[name][1], up["tip"])) if up and name in stale else "")


def _project(troot):
    """The session's project directory, where Claude Code reads the project settings (CLAUDE_PROJECT_DIR), else the repo."""
    return os.environ.get("CLAUDE_PROJECT_DIR") or troot


def _size_note(troot, cfg, rel, sid, path):
    """The size warning of the ledger when `rel` is the ledger and it is near its cap, said once per session per size; else None.
    It measures the file being edited (`path`, which may sit in a worktree other than the session root) as it is before the edit.
    Fail-open like the rest of the hook: any trouble reading or judging it is silence."""
    try:
        import current_state
        profile = current_state.profile_from_config(cfg)
        if current_state.is_page(rel, profile):
            profile, name = current_state.page_profile(profile), rel        # a page is near its own cap, not the index's
        elif rel == profile["path"]:
            name = None
        else:
            return None
        with open(path, "rb") as f:
            raw = f.read()
        line = current_state.size_warning(raw, profile, name)
        return line if line and once("size:%s:%d" % (os.path.realpath(path), len(raw)), sid) else None
    except Exception:
        return None


def _is_page(cfg, rel):
    g = cfg["current_state"].get("pages")
    return bool(g) and C.glob_match(g, rel)


def _path_rules(rules, rel, led, dirs):
    """`R.rules_for_path` of `rel`, then of `led` (the index, when `rel` is a page; else None) for the names not matched yet."""
    got = R.rules_for_path(rules, rel, dirs)
    return got + [n for n in (R.rules_for_path(rules, led, dirs) if led else []) if n not in got]


def pages_for_path(troot, cfg, rel, dirs=()):
    """The absolute paths of the ledger pages (`current_state.pages`) whose `applyTo` matches `rel`, read from the tree, as
    `kb/decisions` are matched. No `pages`: none. Fail-open: trouble reading them is silence."""
    try:
        g = cfg["current_state"].get("pages")
        if not g:
            return []
        d = C.page_dir(g)
        directory = os.path.join(troot, *d.split("/"))
        return [os.path.join(directory, n) for n, t in R.load_dir(directory, ".md")
                if C.glob_match(g, d + "/" + n) and R.apply_to_matches(t, rel, dirs)]
    except Exception:
        return []


def pretool_path(raw):
    payload = read_payload(raw)
    if not payload:
        return 0                                   # payload hỏng KHÔNG chặn tool
    sid = payload.get("session_id")
    root, troot = plugin_root(), project_root(payload)
    cfg, silent, warn = hook_state(troot, sid)
    if silent:
        return 0                                   # `hooks: off`: im, TRƯỚC mọi việc khác
    bad = plugin_problems(root)
    if bad:
        say_broken("pre-plugin-path", bad, sid, warn)
        return 0
    ti = payload.get("tool_input") or {}
    rel = R.rel_to_root(ti.get("file_path") or ti.get("notebook_path"), troot)
    ctx = ""
    if rel:                                        # file ngoài repo đích (scratchpad…) không phải việc của ta
        up = repo_upstream(troot, cfg, sid)
        packs, _w = rule_packs.load(troot, _project(troot))   # the pack warnings are said once, at SessionStart
        rules, paths, notes = R.load_all(root, troot, cfg["rules"], keep=(CORE_NAME,), up=up, packs=packs)
        dirs, stale, mine = R.repo_dirs(cfg["rules"], cfg.get("public")), _stale(notes), R.pack_of(notes)
        # a page of the ledger gets the rules the index gets (its shape rule), on top of its own path's
        led = cfg["current_state"]["path"] if _is_page(cfg, rel) else None
        hits, slow = _match(rules, mine, lambda rs: _path_rules(rs, rel, led, dirs), sid, "edit")
        fresh, extra = _cap_packs([n for n in hits if not _marked(_seen(n, up, stale, mine), sid)], mine,
                                  lambda n: len(_rule_line(root, n, paths, up, stale, troot)) + 3)
        fresh = [n for n in fresh if once(_seen(n, up, stale, mine), sid)]
        decs = [(p, r, k) for p, r, k in R.decisions_for_path(troot, rel, dirs, up)
                if once("dec:" + troot + ":" + p + ((":%s:%s" % (k, up["tip"])) if k else ""), sid)]
        parts = []
        note = _size_note(troot, cfg, rel, sid, os.path.abspath(ti.get("file_path") or ti.get("notebook_path") or ""))
        if note:
            parts.append(note)
        if fresh:
            parts.append("Before editing `%s`, rules you must read (matched by `applyTo`):\n%s\n"
                         "Read the files above before you write. This is the plugin's instruction, not a suggestion."
                         % (rel, "\n".join(["- " + _rule_line(root, n, paths, up, stale, troot) for n in fresh]
                                           + ([_more_line(extra)] if extra else []))))
        if decs:
            decs = [upstream_line(up, r, troot, k, p) if k else p for p, r, k in decs]
            # Khác hẳn khối luật: quyết định KHÔNG phải mệnh lệnh — gộp chung một câu "bắt buộc theo" là biến
            # mọi lựa chọn cũ thành bất biến.
            parts.append("This area already has a settled decision (with the alternatives that were dropped):\n%s\n"
                         "Read it so you do not break a choice that had a reason without knowing. You may change it, but bring a new "
                         "measurement — do not reopen it with an argument that was already rejected there." % "\n".join("- " + d for d in decs))
        pages = [q for q in pages_for_path(troot, cfg, rel, dirs) if once("page:" + troot + ":" + q, sid)]
        if pages:
            parts.append("This area is described by a page of the ledger (%s and its pages):\n%s\n"
                         "Read it before you change the area; if your change makes a line of it untrue, correct that line in this PR "
                         "(the diff gate counts any ledger file as the ledger edited)."
                         % (cfg["current_state"]["path"], "\n".join("- " + q for q in pages)))
        if slow:
            parts.append(slow)
        ctx = "\n\n".join(parts)
    if ctx or warn:
        say("PreToolUse", ctx, warn)
    return 0


# ── the bare-launcher trap ─────────────────────────────────────────────────────────────────────────────
BATON_RULE = "batonrun.instructions.md"     # the warning belongs to this rule: off when the rule is disabled
LAUNCHER_NAMES = ("baton", "baton.py")      # <state-dir>/bin/baton, or python3 …/scripts/baton.py
LAUNCHER_SUBS = ("sign", "run", "go")       # the subcommands the allow rules name one by one
SHELL_OP_CHARS = "|&;<>()"
SHELLS = ("bash", "sh", "zsh", "dash", "ksh", "fish", "eval")   # a word of theirs that is not an option may be a command line
WRAPPERS = ("time", "env", "nohup", "nice", "timeout", "exec", "command", "sudo", "stdbuf", "xargs", "watch", "!")
KEYWORDS = ("do", "then", "else", "elif", "if", "while", "until", "{")   # they stand before a command word
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
PYTHON = re.compile(r"^python[0-9.]*$")
# the one-call baton: `<launcher> go - <args> <<'BATON_EOF'`, the script, then `BATON_EOF`
QUOTED_DELIM = re.compile(r"<<[ \t]*(?:'([A-Za-z_][A-Za-z0-9_]*)'|\"([A-Za-z_][A-Za-z0-9_]*)\")[ \t]*$")
BARE_DELIM = re.compile(r"<<[ \t]*[A-Za-z_][A-Za-z0-9_]*[ \t]*$")


def _shell_scan(cmd):
    """(words, operators) of a command line read like the shell does at its top level. A word is (its text after quote
    removal, the number of operators before it); an operator is a run of `|&;<>()` outside quotes, `newline` for an unquoted
    line end, `$(` or a backtick for a command substitution outside single quotes, `#` for a comment (a `#` that starts a
    word; the rest of the line is skipped). A backslash escapes one character and a backslash-newline joins the lines; `$'…'`
    honours its backslash escapes. A heredoc body is read as command lines, on purpose: whether a shell runs it (`bash
    <<EOF`, `cat <<EOF | bash`, `. /dev/stdin`) is not decidable here, so a launcher line in it warns too."""
    words, ops, cur, inword, i, n = [], [], [], False, 0, len(cmd)

    def end():
        if inword:
            words.append(("".join(cur), len(ops)))
        return [], False

    while i < n:
        c = cmd[i]
        if c == "\\":
            if cmd[i + 1:i + 2] != "\n":                  # a backslash-newline is removed: the word goes on
                cur.append(cmd[i + 1:i + 2])
                inword = True
            i += 2
        elif c == "$" and cmd.startswith("$'", i):       # ANSI-C quoting: `\'` does not end it
            j = i + 2
            while j < n and cmd[j] != "'":
                j += 2 if cmd[j] == "\\" else 1
            cur.append(cmd[i + 2:j])
            inword, i = True, j + 1
        elif c == "'":
            j = cmd.find("'", i + 1)
            j = n if j < 0 else j
            cur.append(cmd[i + 1:j])
            inword, i = True, j + 1
        elif c == '"':
            inword, i = True, i + 1
            while i < n and cmd[i] != '"':
                if cmd[i] == "\\" and i + 1 < n:
                    cur.append(cmd[i + 1])
                    i += 2
                    continue
                if cmd[i] == "`" or cmd.startswith("$(", i):
                    ops.append(cmd[i] if cmd[i] == "`" else "$(")
                cur.append(cmd[i])
                i += 1
            i += 1
        elif c in " \t\r":
            cur, inword = end()
            i += 1
        elif c == "#" and not inword:
            j = cmd.find("\n", i)
            ops.append("#")
            i = n if j < 0 else j
        elif c == "\n":
            cur, inword = end()
            ops.append("newline")
            i += 1
        elif c == "`" or cmd.startswith("$(", i):
            cur, inword = end()
            ops.append("`" if c == "`" else "$(")
            i += 1 if c == "`" else 2
        elif c in SHELL_OP_CHARS:
            cur, inword = end()
            j = i
            while j < n and cmd[j] in SHELL_OP_CHARS:
                j += 1
            ops.append(cmd[i:j])
            i = j
        else:
            cur.append(c)
            inword, i = True, i + 1
    end()
    return words, ops


def _segments(words):
    """{operator count: the words of that simple command}."""
    segs = {}
    for w, k in words:
        segs.setdefault(k, []).append(w)
    return segs


def _call_in(words):
    """The subcommand of a `<launcher> sign|run|go` pair anywhere in `words`, else None."""
    for a, b in zip(words, words[1:]):
        if os.path.basename(a) in LAUNCHER_NAMES and b in LAUNCHER_SUBS:
            return b
    return None


def _launcher_call(words):
    """(subcommand, prefix) of the first launcher call among `words`: in a simple command whose command word (after
    assignments and keywords such as `do` or `{`) is the launcher (`…/baton`, or a python running `baton.py`) followed by
    sign, run or go, or a wrapper (`time`, `env`, `sudo`, `xargs` …) with such a pair among its arguments. `prefix` names an
    assignment or a wrapper before it, "" when none stands there. (None, "") when there is no such call."""
    for seg in _segments(words).values():
        i, prefix = 0, ""
        while i < len(seg) and (ASSIGNMENT.match(seg[i]) or seg[i] in KEYWORDS):
            prefix = prefix or ("a variable assignment" if ASSIGNMENT.match(seg[i]) else "")
            i += 1
        if i >= len(seg):
            continue
        cmd = os.path.basename(seg[i])
        if cmd in WRAPPERS:                               # it runs a command among its arguments, after options of its own
            sub = _call_in(seg[i + 1:])
            if sub:
                return sub, prefix or "a `%s` prefix" % cmd
        elif PYTHON.match(cmd):
            rest = seg[i + 1:]
            for j, w in enumerate(rest[:-1]):
                if os.path.basename(w) == "baton.py":
                    if rest[j + 1] in LAUNCHER_SUBS:
                        return rest[j + 1], prefix
                    break
        elif cmd in LAUNCHER_NAMES and i + 1 < len(seg) and seg[i + 1] in LAUNCHER_SUBS:
            return seg[i + 1], prefix
    return None, ""


def _wrapped_call(words, depth=0):
    """The subcommand of a launcher call that a shell or eval runs from its arguments (`bash -lc '<launcher> go …'`, `env
    bash -c …`, `eval <launcher> go …`), nested up to three wrappers deep, else None. One shell word per simple command and
    each argument read once, so the scan stays linear."""
    if depth > 3:
        return None
    for seg in _segments(words).values():
        j = next((j for j, w in enumerate(seg) if os.path.basename(w) in SHELLS), None)
        if j is None:
            continue
        args = [a for a in seg[j + 1:] if not a.startswith("-")]
        for t in ([" ".join(args)] if os.path.basename(seg[j]) == "eval" else args):
            inner = _shell_scan(t.strip())[0]
            sub = _launcher_call(inner)[0] or _wrapped_call(inner, depth + 1)
            if sub:
                return sub
    return None


def _go_script_word(words):
    """The index of the script word of the first launcher `go` among `words` (after `--by coordinator-auto` and `--`), else None."""
    for i in range(1, len(words)):
        if words[i] == "go" and os.path.basename(words[i - 1]) in LAUNCHER_NAMES:
            j = i + 1
            j += 2 if words[j:j + 2] == ["--by", "coordinator-auto"] else 0
            j += 1 if words[j:j + 1] == ["--"] else 0
            return j if j < len(words) else None
    return None


def stdin_go(cmd):
    """The one-call baton: ("", its first line) when `cmd` is exactly `<launcher> go [--by coordinator-auto] - [args…]
    <<'DELIM'` (or "DELIM"), the script, a line `DELIM`, and nothing but blank lines after it; (why not, None) for any other
    heredoc on a `go -`; (None, None) when `cmd` is not a heredoc on a `go -`. With a quoted delimiter the shell expands nothing in
    the body and hands it to baton as stdin; the first line equal to DELIM ends it, and whatever follows is a command of its own."""
    if not isinstance(cmd, str) or "\n" not in cmd:
        return None, None
    first, rest = cmd.split("\n", 1)
    words, ops = _shell_scan(first.strip(" \t"))    # bash's blanks only: a leading \x1c stays in the command word
    texts = [w for w, _n in words]
    j = _go_script_word(texts)
    if j is None or texts[j] != "-" or not any(o.startswith("<<") for o in ops):
        return None, None
    if "\r" in cmd:                                # to bash a CR is a character: `<<'E'\r` makes the delimiter `E\r` (round 1)
        return "a carriage return, which bash keeps in the delimiter and the lines, so the heredoc may end elsewhere", None
    if "<<-" in first:                              # the scan reads `<<-E` as `<<` and a word `-E`
        return "`<<-`, a tab-stripped heredoc", None
    other = [o for o in ops if o != "<<"]
    if other or ops.count("<<") != 1:
        return "more than the heredoc on the first line (%s)" % ", ".join("`%s`" % o for o in other or ops), None
    if [n for _w, n in words[:-1]] != [0] * (len(words) - 1) or words[-1][1] != 1:
        return "text after the heredoc's delimiter on the first line", None
    sub, prefix = _launcher_call([(w, n) for w, n in words if n == 0])
    if sub != "go" or prefix:
        return prefix or "the launcher not first on the line", None
    m = QUOTED_DELIM.search(first)
    if not m:
        if BARE_DELIM.search(first):
            return ("an unquoted delimiter: the shell expands `$(…)`, backticks and variables in the body before baton reads a "
                    "byte"), None
        return "a delimiter other than one quoted word", None
    delim = m.group(1) or m.group(2)
    lines = rest.split("\n")
    if delim not in lines:
        return "no line `%s` closes the heredoc" % delim, None
    if any(x.strip(" \t") for x in lines[lines.index(delim) + 1:]):     # bash's blanks only, not Python's Unicode ones
        return ("text after the first line `%s`, where the shell ends the heredoc and runs the rest as commands (the script itself "
                "must hold no such line)" % delim), None
    return "", first


def launcher_trap(cmd):
    """The warning for a launcher call (`sign`, `run`, `go`) sent inside a compound command, behind a prefix or inside a
    shell wrapper, else "". Said on EVERY such command, never once per session: no permission rule matches it, so the
    classifier decides, and it denied a piped `run` of a guarded merge three times."""
    if not isinstance(cmd, str):
        return ""
    why, _first = stdin_go(cmd)
    if why == "":
        return ""
    if why:
        return ("BatonRun: this launcher `go -` heredoc is not a shape that runs (%s): an unquoted delimiter or a later line runs "
                "outside the baton, and Claude Code blocks a heredoc that holds a baton skeleton in any shape. Write the script to a "
                "fresh path and `go <path>` in the same response." % why)
    words, ops = _shell_scan(cmd.strip())
    sub, prefix = _launcher_call(words)
    found = [prefix] if prefix else []
    for op in ops:
        what = ("a newline" if op == "newline" else "a comment `#`" if op == "#"
                else "a command substitution `%s`" % op if op in ("$(", "`")
                else "a redirect `%s`" % op if ">" in op or "<" in op else "`%s`" % op)
        if what not in found:
            found.append(what)
    if sub is None:
        sub = _wrapped_call(words)
        found += ["a shell wrapper"] if sub else []
    if sub is None and "\n" in cmd:                    # a quote left open in a heredoc body (`don't`) hides no later line
        for line in cmd.split("\n"):
            sub = _launcher_call(_shell_scan(line.strip())[0])[0]
            if sub:
                found += [] if "a newline" in found else ["a newline"]
                break
    if sub is None or not found:
        return ""
    return ("BatonRun: this launcher `%s` command is not bare (%s, outside quotes). The allow rule for `<launcher> %s` will "
            "not match it, so the auto-mode classifier decides (it denied a piped `run` of a guarded merge). Send the launcher bare, one "
            "command per call, the directory set in an earlier call: `run` and `go` print one line when they hold, and the "
            "full output is under `runs/`." % (sub, ", ".join(found), sub))


def pretool_command(raw):
    payload = read_payload(raw)
    if not payload:
        return 0
    sid = payload.get("session_id")
    root, troot = plugin_root(), project_root(payload)
    cfg, silent, warn = hook_state(troot, sid)
    if silent:
        return 0
    cmd = ((payload.get("tool_input") or {}).get("command") or "")
    if not cmd:
        if warn:
            say("PreToolUse", "", warn)
        return 0
    bad = plugin_problems(root)
    if bad:
        say_broken("pre-plugin-cmd", bad, sid, warn)
        return 0
    # only repo rules are read from the default ref, and decisions never match a command: no rules.dirs, no git process
    up = repo_upstream(troot, cfg, sid) if R.repo_dirs(cfg["rules"]) else None
    packs, _w = rule_packs.load(troot, _project(troot))   # the pack warnings are said once, at SessionStart
    rules, paths, notes = R.load_all(root, troot, cfg["rules"], keep=(CORE_NAME,), up=up, packs=packs)
    stale, mine = _stale(notes), R.pack_of(notes)
    why, first = stdin_go(cmd)              # the one-call baton's body is stdin data, not commands: rules read its first line only
    rcmd = first if why == "" else cmd
    hits, slow = _match(rules, mine, lambda rs: R.rules_for_command(rs, rcmd), sid, "command")

    def size(h):
        return len(_rule_line(root, h[0], paths, up, stale, troot)) + len(_short(h[2], 200)) + 6

    def lines(hh, extra=0):
        # a pack rule's description is cut, and the callers cap the pack lines (_cap_packs): they must not push the rest past the size cap
        return "This command has its own rule — read it before you run it:\n" + "\n".join(
            ["- %s — %s" % (_rule_line(root, n, paths, up, stale, troot), (_short(d, 200) if n in mine else d) or "(no description)")
             for n, _lv, d in hh] + ([_more_line(extra)] if extra else []))
    # Lối thoát nằm TRONG chuỗi lệnh: hook chạy ở process khác nên không thấy biến môi trường của shell người dùng.
    blocking = [] if "RULES_GATE=off" in rcmd else [h for h in hits if h[1] == "block"]
    if blocking:
        # Chặn thì KHÔNG dedup: người dùng phải thấy lý do mỗi lần.
        reason = lines(*_cap_packs(blocking, mine, size)) + ("\n\nThis is a trap whose consequence cannot be undone, so it BLOCKS, not only reminds."
                                    "\nIf you still want to run it, put the prefix `RULES_GATE=off` RIGHT IN the command.")
        say("PreToolUse", slow, warn, extra={"permissionDecision": "deny", "permissionDecisionReason": reason})
        return 0
    fresh, extra = _cap_packs([h for h in hits if not _marked(_seen(h[0], up, stale, mine), sid)], mine, size)
    fresh = [h for h in fresh if once(_seen(h[0], up, stale, mine), sid)]
    trap = launcher_trap(cmd) if any(n == BATON_RULE for n, _t in rules) else ""     # every time: no once()
    ctx = "\n\n".join(x for x in (trap, lines(fresh, extra) if fresh else "", slow) if x)
    if ctx or warn:
        say("PreToolUse", ctx, warn)
    return 0


# ── SessionStart ───────────────────────────────────────────────────────────────
def strip_front(text):
    if text.startswith("---\n"):
        end = text.find("\n---", 4)
        if end >= 0:
            nl = text.find("\n", end + 4)
            return text[nl + 1:] if nl >= 0 else ""
    return text


def fit(body, limit):
    """(thân đã cắt, có cắt?) — cắt ở ranh giới đoạn nếu còn quá nửa."""
    if len(body) <= limit:
        return body, False
    cut = body[:limit]
    i = cut.rfind("\n\n")
    if i > limit // 2:
        cut = cut[:i]
    return cut.rstrip(), True


def coordinated_session(root, troot=""):
    """This session is a coordinated one (rule coordinated-work): a sandbox session, or an enabled plugin of this copy's own
    marketplace that depends on it ships the marker file (rule_packs.coordinated)."""
    return in_sandbox() or rule_packs.coordinated(root, _project(troot)) is not None


def session_core(root, coordinated=False):
    """(nội dung lõi quy trình giao cho phiên, cảnh báo ngắn). With `coordinated`, rule coordinated-work follows the core in the
    same string (the core no longer holds that paragraph, so both together stay about the size the core alone had)."""
    path = os.path.join(root, R.RULES_DIR, CORE_NAME)
    text = read_text(path)
    if text is None:
        return warn_text(["cannot read the process core %s" % path]), short_warn(["cannot read the process core"])
    body = strip_front(text).strip()
    if coordinated:
        cpath = os.path.join(root, R.RULES_DIR, COORDINATED_NAME)
        ctext = read_text(cpath)
        body += ("\n\n" + strip_front(ctext).strip() if ctext is not None
                 else "\n\nThis is a coordinated session, but the rule %s cannot be read: read it before you start" % cpath)
    head = "The general way of working (read from the plugin at session start; it ships with the installed plugin, do not copy it into the repo): %s\n\n" % path
    limit = BUDGET - len(head) - 900
    body, cut = fit(body, limit)
    ctx = head + body
    problems = []
    if cut:
        problems.append("the process core is longer than the hook cap; only its beginning was delivered. READ the rest at %s" % path)
        ctx += "\n\n[… cut at the hook's 10,000-character cap — read it all at %s]" % path
        ctx = warn_text(problems) + "\n\n" + ctx
    return ctx, (short_warn(problems) if problems else "")


def catalogue(root, troot=None, cfg=None, up=None, packs=()):
    """(dòng danh mục luật, ghi chú): tên + mô tả + applyTo/applyWhen của luật được GIAO (plugin + `rules.dirs`), không gồm
    lõi (đã giao nguyên văn). Ghi chú: luật plugin bị file cùng tên của repo thay hoặc bị `rules.disable` tắt. With `up`, the
    repo rules the default ref changed are listed as the ref has them (`from` in the row). A rule of a rule pack (`packs`, see
    rule_packs.load) names its plugin (`pack` in the row); those rows come last, so the size cap drops them first."""
    cfg = cfg or C.defaults()
    rules, _paths, notes = R.load_all(root, troot or "", cfg["rules"], keep=(CORE_NAME,), up=up, packs=packs)
    rows, dirs, stale, mine = [], R.repo_dirs(cfg["rules"], cfg.get("public")), _stale(notes), R.pack_of(notes)
    for name, text in rules:
        if name == CORE_NAME:
            continue
        f = {k: R.front(text, k) for k in ("applyTo", "applyWhen", "level", "description")}
        declared = f["applyTo"]
        f["applyTo"] = ",".join(R.apply_to_patterns(f["applyTo"], dirs))     # the tokens as what they stand for here
        if declared and not f["applyTo"] and not f["applyWhen"]:
            continue                           # it can never fire in this repo (`${public.tree}` where nothing is published)
        f["from"] = R.upstream_mark(up, stale[name][0], troot, stale[name][1]) if up and name in stale else ""
        f["pack"] = _short(mine[name]) if name in mine else ""
        if name in mine:                       # text of a file this plugin does not control: one line each
            f = {k: _oneline(v) for k, v in f.items()}
        rows.append((name, f))
    return rows, notes


def notes_reminder(notes):
    """English lines for the SessionStart context about the repo's own rule settings (empty when there is nothing to say)."""
    out = []
    for kind, name, detail in notes:
        if kind == "replaced":
            out.append("WARNING: the repo rule %s/%s replaces the plugin rule of the same name (%s); the plugin text is not delivered."
                       % (detail, name, R.canonical(name)))
        elif kind == "disabled":
            out.append("The repo turned off the plugin rule %s (rules.disable)." % name if not detail else
                       "The repo turned off the rule %s of the rule pack of %s (rules.disable)." % (name, _short(detail)))
        elif kind == "renamed":
            out.append("WARNING: rules.disable names %s, which was renamed to %s; the old name still works, use the new one." % (name, detail))
        elif kind == "old-name":
            out.append("WARNING: the repo rule %s/%s has the old name of the plugin rule %s and replaces it; rename the file."
                       % (detail[0], name, detail[1]))
        elif kind == "pack-replaced":
            out.append("The repo rule %s/%s replaces the rule of the same name in the rule pack of %s." % (detail[1], name, _short(detail[0])))
    return out


PACK_WARN_MAX = 5


def pack_warnings(notes, problems, limit=PACK_WARN_MAX):
    """(lines, count): the warning lines about rule packs, what rule_packs.load ignored (`problems`) and the names a pack may
    not take, one line each, at most `limit` (None: all), then one line with the count of the rest; and how many there are."""
    lines = ["WARNING: rule packs: %s" % _short(p, 300) for p in problems]
    for kind, name, detail in notes:
        if kind == "pack-sdlc-name":
            lines.append("WARNING: rule packs: %s ships %s, a name of a %s rule: the pack's file is not delivered; rename it in "
                         "the pack." % (_short(detail), name, PLUGIN_NAME))
        elif kind == "pack-shadowed":
            lines.append("WARNING: rule packs: %s and %s both ship %s: only the one of %s (the first plugin id in sort order) is "
                         "delivered." % (_short(detail[1]), _short(detail[0]), name, _short(detail[1])))
    count = len(lines)
    if limit is not None and count > limit:
        lines = lines[:limit] + ["WARNING: rule packs: and %d more problem(s) like these." % (count - limit)]
    return lines, count


def render_catalogue(rows, desc_len, short_from=False):
    lines = []
    for name, f in rows:
        trig = []
        if f["applyTo"]:
            trig.append("applyTo: " + f["applyTo"][:80])
        if f["applyWhen"]:
            trig.append("applyWhen: by command" + (" [BLOCK]" if f["level"] == "block" else ""))
        d = f["description"]
        if desc_len and d:
            d = d if len(d) <= desc_len else d[:desc_len].rstrip() + "…"
        else:
            d = ""
        lines.append("- %s%s%s%s%s" % (name, (" — " + d) if d else "", (" [" + "; ".join(trig) + "]") if trig else "",
                                       (" " + (f["from"].split(":", 1)[0] + ": the edit reminder has the command]" if short_from
                                               else f["from"])) if f.get("from") else "",
                                       (" [rule pack of %s]" % f["pack"]) if f.get("pack") else ""))
    return lines


def plugin_skills():
    """Skill của CHÍNH plugin mà thư mục có mặt lúc này (A7: chỉ nhắc cái vừa kiểm là có)."""
    root = plugin_root()
    return [s for s in PLUGIN_SKILLS if os.path.isfile(os.path.join(root, "skills", s, "SKILL.md"))]


SCAFFOLD_BRANCH = "chore/kb-init"           # the branch the skill init-kb creates and pushes; kb.py base and the kb/ reminder look for these names only
SCAFFOLD_BRANCH_OLD = "chore/kb-khoi-tao"   # its old name: a branch pushed before the rename is still found
SCAFFOLD_PROBE = "kb/intent"                # the directory `kb.py new intent` needs; a tree entry exists once it holds a tracked file


def upstream_has_kb(troot):
    """True when the upstream (`@{u}`, as last fetched) of the current branch has `kb/intent`. Merged there: a tree with no `kb/` is not
    "not merged yet" (`scaffold_ref`), and a branch with no upstream is not covered."""
    return git_out(troot, "cat-file", "-e", "@{u}:" + SCAFFOLD_PROBE) is not None


def upstream_kb_ref(troot):
    """The name of the upstream when this tree is plainly only behind it: no `kb/` on disk (not even a file or a link in the way, which a
    pull would be refused over), HEAD itself tracks nothing under `kb` (a `kb/` only deleted from disk is restored by a checkout, not a pull),
    HEAD is not already at or ahead of `@{u}` (a pull then does nothing), and `@{u}` has `kb/intent`; else "". `kb_reminder` and
    `flow_reminder` ask this one question, so the sentence and the chain cannot disagree.
    A name with odd characters is shown as `@{u}`, which git reads the same."""
    kb = os.path.join(troot, "kb")
    if os.path.lexists(kb) or not upstream_has_kb(troot):
        return ""
    if git_out(troot, "cat-file", "-e", "HEAD:kb") is not None:
        return ""
    if git_out(troot, "merge-base", "--is-ancestor", "@{u}", "HEAD") is not None:
        return ""
    name = git_out(troot, "rev-parse", "--abbrev-ref", "@{u}") or ""
    return name if re.fullmatch(r"[\w./+-]+", name) else "@{u}"


def scaffold_ref(troot):
    """The ref of the init-kb scaffold branch (current name then old name, each local first, then `origin/`) that carries `kb/intent`, else "". Asked only when this
    tree has no `kb/`: the scaffold is made and pushed but not merged here, so the reminder must not say to scaffold it again. Also "" when the
    upstream (`@{u}`) of the current branch already has `kb/intent`: merged there, this tree is only behind, so "not merged yet" would be false
    (a branch with no upstream is not covered)."""
    if os.path.isdir(os.path.join(troot, "kb")):
        return ""
    if upstream_has_kb(troot):
        return ""       # the upstream of this branch already has kb/: it is merged there and only this tree is behind, not "not merged yet"
    for ref in (SCAFFOLD_BRANCH, "origin/" + SCAFFOLD_BRANCH, SCAFFOLD_BRANCH_OLD, "origin/" + SCAFFOLD_BRANCH_OLD):
        if git_out(troot, "cat-file", "-e", "%s:%s" % (ref, SCAFFOLD_PROBE)) is not None:
            return ref
    return ""


def flow_reminder(troot):
    """Lời nhắc LUỒNG ở repo app (mọi môi trường): việc thay đổi đi theo chuỗi skill của plugin, quy trình của plugin
    thắng plugin quy trình bên thứ ba. Sinh ra từ skill vừa kiểm là có mặt (A7): chuỗi chỉ gồm skill có thư mục, câu "không dùng
    skill X của plugin quy trình bên thứ ba" chỉ có khi skill thay X của ta có mặt. Chỉ khi `intake` (đầu quy trình) có mặt mới nói "bắt đầu bằng":
    thiếu nó thì chuỗi còn lại được nêu là các skill có mặt, vào ở khâu việc đang đứng. Repo chưa có `kb/` mà `init-kb` có
    mặt thì `init-kb` đứng đầu chuỗi (khớp `kb_reminder` và điều kiện của `intake`). Không skill nào của chuỗi có mặt thì
    không nhắc gì. Hook đã im từ trước khi tới đây khi config đặt `hooks: off`, nên hàm này không tự kiểm.
    Phạm vi của A7 ở đây: chỉ skill CỦA PLUGIN (thư mục `skills/<tên>/`) được kiểm có mặt. Tên ba skill của plugin quy trình
    bên thứ ba trong câu "KHÔNG dùng skill `X`" (chỉ có khi skill thay X của ta có mặt) và trong câu "vẫn dùng" (câu này luôn có,
    ghi "khi có") được nhắc KHÔNG qua kiểm — plugin không biết plugin quy trình bên thứ ba có cài hay không."""
    mine = plugin_skills()
    chain = [s for s in FLOW_ORDER if s in mine]
    if not chain:
        return ""
    # chưa có kb/ thì intake/brainstorm/spec/plan không có chỗ ghi: init-kb đứng trước (chỉ khi skill đó vừa kiểm là có mặt)
    need_kb = ("init-kb" in mine and not os.path.isdir(os.path.join(troot, "kb")) and not scaffold_ref(troot)
               and not upstream_kb_ref(troot))
    has_intake = chain[0] == "intake"
    if need_kb:
        chain = ["init-kb"] + chain
    hint = {"init-kb": " (this repo has no `kb/` yet)", "brainstorm": " (when the request is still vague)", "plan": " (when the work must be split)"}

    def nm(s):
        return "`%s:%s`" % (PLUGIN_NAME, s)
    steps = nm(chain[0]) + hint.get(chain[0], "") + "".join(", then " + nm(s) + hint.get(s, "") for s in chain[1:])
    typed = ("even when the person only types \"redo\", \"make a plan\", \"design\", \"add a feature\", or asks for a UI change")
    ask = "a clarifying question to the person is part of that skill itself."
    if has_intake:
        step_line = ("- Every request for a change — %s — starts with %s. Call the first skill of the chain BEFORE you read code or ask anything outside it; %s"
                     % (typed, steps, ask))
    else:
        step_line = ("- A request for a change — %s — follows the skills present here, in the order of the work: %s. Pick the skill of the "
                     "step you are at and call it BEFORE you read code or ask anything outside it; %s" % (typed, steps, ask))
    lines = [
        "The work flow in an app repo — the plugin's process WINS over the third-party process plugin here, because this is the process the "
        "user set for this plugin in an app repo (a hook reminder, not CLAUDE.md). That third-party process plugin itself says the user's "
        "instructions rank above its skills; when the two disagree, follow this process.",
        step_line,
    ]
    swaps = ["`%s` (the plugin already has %s)" % (sp, nm(ours)) for sp, ours in PROCESS_SWAP if ours in mine]
    if swaps:
        lines.append("- In an app repo do NOT use these skills of the third-party process plugin: " + ", ".join(swaps) + ".")
    lines.append("- Write the output into `kb/intent`, `kb/specs`, `kb/plans` of this very repo, not into the default output directory of the third-party process plugin (under `docs/`).")
    lines.append("- Skills of the third-party process plugin that do not overlap (`test-driven-development`, `systematic-debugging`, "
                 "`verification-before-completion`) are still used as normal when present.")
    return "\n".join(lines)


# `kb_reminder` when this tree has no `kb/` but the scaffold branch carries it, by the repo's `language` (`vi` also for a config without the key)
SCAFFOLD_ON_BRANCH = {
    "en": "This tree has no `kb/` yet, but `kb/` is on the branch `%s`, which is not merged yet: merge that branch or switch to it. "
          "The scaffold is made, so do not scaffold it again.",
    "vi": "Cây này chưa có `kb/`, nhưng `kb/` đã nằm trên nhánh `%s`, chưa được gộp: hãy gộp nhánh đó hoặc chuyển sang nhánh đó. "
          "Khung đã dựng rồi, đừng dựng lại.",
}


# `kb_reminder` when this tree has no `kb/` but its upstream (`@{u}`) already has it: only the tree is behind, so pull; same keys as above
UPSTREAM_HAS_KB = {
    "en": "This tree has no `kb/` yet, but its upstream `%s` already has one: bring this tree up to date with `git pull --ff-only` "
          "(a pull follows this branch's upstream; if the branch has local commits and cannot fast-forward, run `git merge %s`) "
          "and do not scaffold `kb/` again, a second one would conflict with it.",
    "vi": "Cây này chưa có `kb/`, nhưng upstream của nó `%s` đã có: hãy cập nhật cây bằng `git pull --ff-only` "
          "(pull đi theo upstream của nhánh này; nhánh có commit riêng, không fast-forward được thì chạy `git merge %s`), "
          "đừng dựng `kb/` lại, bản thứ hai sẽ xung đột với bản đã có.",
}


def kb_reminder(troot, injected=False, rel="kb/current-state.md", lang="vi"):
    kb = os.path.join(troot, "kb")
    if not os.path.isdir(kb):
        up = upstream_kb_ref(troot)
        if up:
            return UPSTREAM_HAS_KB.get(lang, UPSTREAM_HAS_KB["vi"]) % (up, up)
        ref = scaffold_ref(troot)
        if ref:
            return SCAFFOLD_ON_BRANCH.get(lang, SCAFFOLD_ON_BRANCH["vi"]) % ref
        # Repo chưa có kb/: chỉ chỉ đường tới skill dựng khung khi skill đó CÓ MẶT (A7).
        if "init-kb" in plugin_skills():
            return ("This repo has no `kb/` yet: use the skill `%s:init-kb` to scaffold it — this repo's intent, plan and spec "
                    "need a place to be written." % PLUGIN_NAME)
        return ""
    # a pointer to the map and to the three read-only finders, not a list of files to read: kb/ is too large to read whole
    kbpy = '`python3 "%s/scripts/kb.py"`' % plugin_root()
    # injected (B1.7): the file the index command reads (`current_state.path`); otherwise today's sentence
    if injected and os.path.isfile(os.path.join(troot, *rel.split("/"))):
        first = ("`%s` is the map (what holds now, where to read more): its text is in this context, in a block of its own that "
                 "starts \"Current-state index of this repo\"; read the file only when that block is missing or says it was not "
                 "injected. " % rel)
    else:
        first = ("`kb/current-state.md` is the map (what holds now, where to read more): read it first. "
                 if os.path.isfile(os.path.join(kb, "current-state.md")) else "")
    return ("This repo has a `kb/`. %sDo not read `kb/` or a long spec whole; find what you need with %s: "
            "`find <words>` (one line per document, superseded/done hidden), `list --type intent --status live` (open intents), "
            "`outline <file>` (line range of each section, then Read that range with offset/limit)." % (first, kbpy))


# Skill directories the "Skills of the plugin" line leaves out on purpose (empty: every user-facing skill is named).
SKILLS_NOT_LISTED = ()


def all_skills():
    """Every skill of the plugin whose `skills/<name>/SKILL.md` is present (A7), the process chain first in its order, then the
    rest by name, less `SKILLS_NOT_LISTED`: the list follows the directory, so a new skill cannot be left out of it."""
    d = os.path.join(plugin_root(), "skills")
    try:
        names = sorted(n for n in os.listdir(d) if os.path.isfile(os.path.join(d, n, "SKILL.md")))
    except OSError:
        return []
    chain = plugin_skills()
    return chain + [n for n in names if n not in chain and n not in SKILLS_NOT_LISTED]


def skills_reminder():
    mine = all_skills()
    if not mine:
        return []
    return ["Skills of the plugin (just checked to be present): " + ", ".join("`%s:%s`" % (PLUGIN_NAME, s) for s in mine) + "."]


def in_sandbox():
    """Phiên này chạy trong sandbox? Nhận ra bằng HAI biến cùng có và khác rỗng: `INTENT_SLUG` và `SEAT`
    (do hạ tầng dựng phiên đặt cho container của phiên). Một biến không đủ: máy cá nhân có thể tình cờ có
    `SEAT` (hay `INTENT_SLUG`) trong shell — khi đó plugin vẫn phải làm việc như ngoài sandbox."""
    return all(os.environ.get(v, "").strip() for v in SANDBOX_ENV)


def sandbox_first_steps():
    """Lời nhắc HÀNH VI ĐẦU TIÊN của phiên sandbox, chỉ khi `in_sandbox()`: intake nguyên văn → tạo spec → xin người
    duyệt → rồi mới code. Mỗi bước chỉ được nhắc khi thứ nó gọi vừa kiểm là có mặt (A7): skill của plugin có thư mục,
    `session-ask` có trong PATH. Ngoài sandbox trả rỗng. Đây là lời NHẮC, không phải cổng: không gì chặn Edit khi
    chưa duyệt — duyệt là lời của người, máy không có dấu "đã duyệt"."""
    if not in_sandbox():
        return ""
    mine = plugin_skills()
    steps = []
    if "intake" in mine:
        steps.append("record the intent VERBATIM (the words you were given at the start of the session, not rephrased) as `kb/intent/…` + branch "
                     "`intent/…` — skill `%s:intake`" % PLUGIN_NAME)
    if "spec" not in mine:
        return ("Sandbox session: " + "; ".join(steps) + ".") if steps else ""
    steps.append("CREATE A SPEC from the intent in `kb/specs/<date>-<slug>.md` in the four-section shape — skill `%s:spec`" % PLUGIN_NAME)
    if shutil.which("session-ask"):
        steps.append("ask the person to approve the spec with `session-ask \"<question>\"`, then end the turn")
    else:
        steps.append("ask the person to approve the spec: ask in words, then stop the turn and wait for a reply")
    steps.append("edit code ONLY AFTER the person has approved")
    return ("Sandbox session — first behaviour, in this order: " + "; ".join("(%d) %s" % (i, t) for i, t in enumerate(steps, 1))
            + ". Without an approval, no code edit: approval is the person's words, the machine has no \"approved\" mark, and silence is not approval.")


def session_context(root, troot, cfg=None, sid=None, source=""):
    cfg = cfg or C.defaults()
    up = repo_upstream(troot, cfg, sid)
    packs, problems = rule_packs.load(troot, _project(troot))
    rows, notes = catalogue(root, troot, cfg, up, packs)
    # once per session and tip; again after a compaction, which drops the earlier context but keeps the session id
    warn_now = up and (once("behind:%s:%s" % (troot, up["tip"]), sid) or source == "compact")
    behind, sysmsg = behind_warning(up, troot, notes, R.repo_dirs(cfg["rules"])) if warn_now else ("", "")
    pw, npw = pack_warnings(notes, problems)
    if pw:
        line = "%s: rule packs: %d warning(s) in the session context" % (PLUGIN_NAME, npw)
        sysmsg = sysmsg + "; " + line if sysmsg else line
    # when even the pack warnings do not fit, they become one line, before any row of this plugin or the repo is shortened
    pw_one = ["WARNING: rule packs: %d problem(s), not listed here (hook size cap); `python3 %s/scripts/kb.py config check` "
              "lists them" % (npw, root)] if npw else []
    base_tail = [x for x in [kb_reminder(troot, index_injects(cfg, source), cfg["current_state"]["path"], cfg["language"]), sandbox_first_steps()] + skills_reminder() + notes_reminder(notes) if x]
    flow = flow_reminder(troot)
    head = ("The plugin's common rules are in %s/%s — a hook will remind you of the right rule when you edit a file (applyTo) or run a command "
            "(applyWhen); the catalogue below is only so you know they exist:" % (root, R.RULES_DIR))
    main = [r for r in rows if not r[1].get("pack")]
    extra = [r for r in rows if r[1].get("pack")]

    def compose(lines, more=0, warns=pw):
        # lời nhắc luồng ĐỨNG ĐẦU, trước danh mục: danh sách tên skill một mình đã không đủ để phiên chọn đúng skill
        tail = base_tail + warns
        return "\n".join(([behind, ""] if behind else []) + ([flow, ""] if flow else []) + [head] + lines
                         + (["- ... %d more rule(s) not listed here (hook size cap); each is still reminded on its own trigger"
                             % more] if more else []) + ([""] + tail if tail else []))
    for dl, short in ((160, False), (90, False), (0, False), (0, True)):
        # last resort: the marks of the catalogue rows lose their command (each edit or command reminder still has it)
        own_l, pack_l = render_catalogue(main, dl, short), render_catalogue(extra, dl, short)
        body = compose(own_l + pack_l)
        if len(body) <= BUDGET:
            break
        # the rule-pack rows go before this plugin's and the repo's rows are shortened (as many as fit, in order), and then the
        # pack warnings become one line
        for warns in (pw, pw_one):
            room, keep = BUDGET - len(compose(own_l, len(pack_l), warns)), 0
            while keep < len(pack_l) and room >= len(pack_l[keep]) + 1:
                room, keep = room - len(pack_l[keep]) - 1, keep + 1
            body = compose(own_l + pack_l[:keep], len(pack_l) - keep, warns)
            if len(body) <= BUDGET:
                break
        if len(body) <= BUDGET:
            break
    rows_out = render_catalogue(main, 0, True)
    while len(body) > BUDGET and rows_out:
        # still over: the last rows go, and one line says so (the warning, the flow and the tail stay)
        rows_out = rows_out[:-1]
        body = compose(rows_out, len(rows) - len(rows_out), pw_one)
    return body, sysmsg


# ── SessionStart: the current-state index (B1.7 of the brain ladder) ───────────────────────────────
# A third command prints the index as a string of its own, so it never eats the `context` block's BUDGET. Only `startup` and
# `compact` (the owner's decision B): `resume` and `clear` were measured and proposed to the owner, not injected.
INDEX_SOURCES = ("startup", "compact")
HOOK_CAP = 10000            # the cap of one hook string, in characters
LABELS_MAX = 1000           # the list of unchecked labels appended to the index
LABELS_AFTER = 4.0          # seconds from the hook's start after which no label scan starts (each scan has a 2 s timer of its own)
INDEX_MAX_READ = 1 << 20    # an index larger than this is over the cap without being read
COMPARE_MAX_READ = 1 << 24  # a larger index is read this far only to tell whether the tree changed it (index_overlay)


def index_injects(cfg, source):
    """The repo turned injection on (`current_state.inject`) and this SessionStart source injects."""
    return bool(cfg["current_state"].get("inject")) and source in INDEX_SOURCES


def _read_index(troot, rel, limit=INDEX_MAX_READ):
    """(text, too large, why not read) of the tree's index, CRLF read as LF. It is read only when it is a regular file whose
    directory is inside the tree: a symlink, a FIFO, a device or a directory would put another file into the context or hang
    the hook, so each is a reason (`why`), never read. At most `limit` bytes. (None, False, None) when there is no index."""
    import errno
    import stat
    path = os.path.join(troot, *rel.split("/"))
    try:
        st = os.lstat(path)
    except OSError as e:
        return (None, False, None) if e.errno in (errno.ENOENT, errno.ENOTDIR) else (None, False, "cannot be read (%s)" % e.strerror)
    if stat.S_ISLNK(st.st_mode):
        return None, False, "is a symlink"
    if not stat.S_ISREG(st.st_mode):
        return None, False, "is not a regular file"
    top, here = os.path.realpath(troot), os.path.realpath(os.path.dirname(path))
    if here != top and not here.startswith(top.rstrip(os.sep) + os.sep):
        return None, False, "sits under a symlink that leaves the tree"
    try:
        # no symlink and no blocking even if the file changed since the lstat; the read is bounded whatever the size says
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0))
        with os.fdopen(fd, "rb") as f:
            raw = f.read(limit + 1)
    except OSError as e:
        return None, False, "cannot be read (%s)" % (e.strerror or type(e).__name__)
    if len(raw) > limit:
        return None, True, None
    return R._nl(raw.decode("utf-8", "replace")), False, None


def _short_mark(up, kind):
    """`upstream_mark` without the path and the command, for a string that would pass the hook cap with them."""
    n = "%d commit%s" % (up["behind"], "" if up["behind"] == 1 else "s")
    return {"ref": "[from %s: this tree is behind it by %s]",
            "both": "[%s changed it too and this tree is behind it by %s: this is the tree's own edit]",
            "gone": "[%s does not have it and this tree is behind it by %s]",
            "unread": "[%s changed it and this tree is behind it by %s, but its text is not in this clone]"}[kind] % (up["ref"], n)


def index_overlay(troot, rel):
    """{text, mark, short, ref, big, why}: the index as the session should see it. The tree's text, unless the tree is behind its
    default ref and the ref changed the index since the fork point: then the ref's text (`ref` names the ref), or, when the
    tree changed it too, the ref deleted it or this clone lacks the ref's text, the tree's text; marked as
    `rules.load_repo_dir` marks a rule (`mark`, and `short` without the command). A tree that deleted the index gets the
    ref's text, as the rule overlay does. Could not tell (detached HEAD, no origin ref, a git error, the deadline): the tree's
    text, unmarked. `big`: over INDEX_MAX_READ; `why`: the tree's index exists but is not read (`_read_index`)."""
    local, big, why = _read_index(troot, rel)
    out = {"text": local, "mark": "", "short": "", "ref": None, "big": big, "why": why}
    deadline = time.monotonic() + R.UPSTREAM_DEADLINE
    try:
        probe = R.upstream_probe(troot, deadline)
        up = R.upstream(troot, probe, (), deadline, files=(rel,), decisions=False) if probe and probe[0] != probe[2] else None
    except Exception:
        up = None
    if not up or not up.get("behind"):
        return out
    files, base = up.get("files") or {}, up.get("base")
    if rel in (up.get("unread") or []):
        kind = "unread"
    elif rel not in files or (local is not None and R._nl(local) == R._nl(files[rel])):
        return out
    elif files[rel] is None:
        kind = "gone"
    elif isinstance(base, dict) and (why or local is not None and local != R._nl(base.get(rel)) or big and (
            _read_index(troot, rel, COMPARE_MAX_READ)[0] != R._nl(base.get(rel)))):
        kind = "both"
    else:
        kind = "ref"
        out.update(text=R._nl(files[rel]), ref=up["ref"], big=False, why=None)
    out.update(mark=R.upstream_mark(up, rel, troot, kind), short=_short_mark(up, kind))
    return out


def index_warning(msg):
    """The one line the index command prints instead of the index (the rules are delivered either way)."""
    return "WARNING plugin %s: %s." % (PLUGIN_NAME, msg)


def label_rows(troot, cfg, rel, text, stop=None):
    """([(file, line, label, age in days or None)], ran over) of the unchecked labels of the injected index and of each page.
    The scanning is B1.6's `current_state.labels` and the pages B1.5's `list_pages`, looked up by name: without them (or without
    `current_state.labels` set) there are no rows. No file is started after `stop` (time.monotonic), which counts as ran over."""
    import current_state as S
    fn, profile = getattr(S, "labels", None), S.profile_from_config(cfg)
    if fn is None or not profile.get("labels"):
        return [], False
    stop = stop or time.monotonic() + LABELS_AFTER
    files = [(rel, text)]
    pages = getattr(S, "list_pages", None)
    if pages is not None and profile.get("pages"):
        files += [(r, raw) for r, raw in pages(troot, profile)[0]]
    rows, over = [], False
    for name, t in files:
        if time.monotonic() > stop:
            return rows, True
        found, ran_over = fn(t, profile)
        over = over or ran_over
        rows += [(name, i, lab, age) for i, lab, _day, age in found]
    return rows, over


def render_labels(rows, room, max_age=None, over=False):
    """The list of unchecked labels appended to the injected index, at most `room` characters (as the hook cap counts them): a
    heading (which says when the scan ran over its timer), one line per label (no date first, then oldest first), whole lines
    only, then one line with the count of the rest; '' when there is nothing to list or no room for the heading and one line."""
    import current_state as S
    if not rows:
        return ""
    order = sorted(rows, key=lambda r: (r[3] is not None, -(r[3] or 0), r[0], r[1]))
    lines = []
    for f, i, lab, age in order:
        lab = _oneline(lab)
        lab = lab if len(lab) <= 80 else lab[:77] + "..."
        when = "no date" if age is None else "%d day%s%s" % (age, "" if age == 1 else "s",
                                                             " OLD" if max_age is not None and age > max_age else "")
        lines.append("- %s:%d %s %s" % (_oneline(f), i, when, lab))
    head = "Unchecked labels of the ledger (file:line, age%s)%s:" % (
        "; OLD is over %d days" % max_age if max_age is not None else "",
        "; the scan ran over its timer, so some are not listed" if over else "")
    more = "- ... and %d more, not listed (size cap)"
    reserve = S.inject_chars(more % len(lines)) + 1
    out, used = [head], S.inject_chars(head)
    for k, ln in enumerate(lines):
        n = S.inject_chars(ln) + 1
        if used + n + (reserve if k < len(lines) - 1 else 0) > room:
            if k == 0 or used + reserve > room:
                return ""
            out.append(more % (len(lines) - k))
            break
        out.append(ln)
        used += n
    return "\n".join(out)


def session_index(troot, cfg, stop=None):
    """(context, system message) of the index command: the lead line, the stale-tree mark (if any), the index, the label list;
    ('', '') when there is no index; one warning instead of the index when it cannot be read, is over INJECT_MAX_CHARS, or
    would not fit the hook cap even with the short mark."""
    import current_state as S
    rel = cfg["current_state"]["path"]
    o = index_overlay(troot, rel)
    text, mark, ref = o["text"], o["mark"], o["ref"]
    where = (" %s" % o["short"]) if o["short"] else ""
    if o["why"]:
        msg = ("the current-state index %s %s: it was NOT injected (only a regular file inside the tree is); check what it is "
               "before you read it%s" % (rel, o["why"], where))
        return index_warning(msg), "%s: current-state index not injected (%s)" % (PLUGIN_NAME, o["why"])
    if (text is None or not text.strip()) and not o["big"]:
        return "", ""
    n = S.inject_chars(text) if not o["big"] else None
    head = ("Current-state index of this repo, %s, injected by %s at session start and after each compaction: what holds now and "
            "where to read more. It is already in context, so do not Read it whole; open a page, spec or decision it points to "
            "when you need it." % (rel, PLUGIN_NAME))
    body = None
    if not o["big"] and n <= S.INJECT_MAX_CHARS:
        for m in ((mark, o["short"]) if mark else ("",)):
            body = head + ("\n" + m if m else "") + "\n\n" + text.rstrip("\n")
            if S.inject_chars(body) <= HOOK_CAP:
                break
            body = None
    if body is None:
        size = ("over %d bytes" % INDEX_MAX_READ if o["big"] else "%d characters" % n)
        msg = ("the current-state index %s%s is %s, over the %d a SessionStart hook can inject (current_state.inject): it was NOT "
               "injected, read it first%s; `kb.py check current-state` refuses an index that size while injection is on"
               % (rel, (" of %s" % ref) if ref else "", size, S.INJECT_MAX_CHARS, where))
        return index_warning(msg), "%s: current-state index not injected (%s > %d)" % (PLUGIN_NAME, size, S.INJECT_MAX_CHARS)
    rows, over = label_rows(troot, cfg, rel, text, stop)
    labels = cfg["current_state"].get("labels") or {}
    tail = render_labels(rows, min(LABELS_MAX, HOOK_CAP - S.inject_chars(body) - 2), labels.get("max_age_days"), over)
    sysmsg = "%s: current-state index injected from %s (this tree is behind it)" % (PLUGIN_NAME, ref) if ref else ""
    return body + ("\n\n" + tail if tail else ""), sysmsg


def session_index_start(payload):
    """The index command. Silent (as before B1.7) for another source, injection off, `hooks: off` or an invalid config (the
    other two commands report that; this one does not use up their once-per-session mark); every failure is one warning, rc 0."""
    stop = time.monotonic() + LABELS_AFTER
    if (payload.get("source") or "") not in INDEX_SOURCES:
        return 0
    troot = project_root(payload)
    cfg, probs, _present = C.load(troot, quiet=True)
    if probs or cfg["hooks"] == "off" or not cfg["current_state"].get("inject"):
        return 0
    try:
        ctx, sysmsg = session_index(troot, cfg, stop)
    except Exception as e:
        msg = "the current-state index could not be injected (%s): read %s first" % (type(e).__name__, cfg["current_state"]["path"])
        ctx, sysmsg = index_warning(msg), short_warn([msg])
    if ctx:
        emit("SessionStart", ctx, sysmsg)
    return 0


CORE_MODES = ("core", "loi")        # `loi`: the hook argument's old name, still read (a session started before an update)


def session_start(mode):
    raw = sys.stdin.read()
    payload = read_payload(raw)
    if mode == "index":
        return session_index_start(payload)
    root, troot = plugin_root(), project_root(payload)
    cfg, silent, warn = hook_state(troot, payload.get("session_id"))
    if silent:
        return 0                                   # `hooks: off`
    bad = plugin_problems(root)
    if bad:
        ctx, sysmsg = warn_text(bad), short_warn(bad)
    elif mode in CORE_MODES:
        ctx, sysmsg = session_core(root, coordinated_session(root, troot))
    else:
        ctx, sysmsg = session_context(root, troot, cfg, payload.get("session_id"), payload.get("source") or "")
    ctx, sysmsg = with_warn(warn, ctx, sysmsg)    # lời cảnh báo config hỏng đứng trước, cùng một JSON
    emit("SessionStart", ctx, sysmsg)
    return 0


# ── vỏ fail-open ───────────────────────────────────────────────────────────────
def run(fn, *args):
    """Mọi ngoại lệ → cảnh báo (nếu in được) và rc 0: hook KHÔNG làm công cụ lỗi cứng."""
    try:
        return fn(*args) or 0
    except BaseException as e:                     # kể cả SystemExit từ thư viện
        if isinstance(e, KeyboardInterrupt):
            return 0
        try:
            msg = "internal error in the hook (%s) — the plugin's rules may NOT be delivered in this session" % type(e).__name__
            emit("SessionStart" if fn is session_start else "PreToolUse", warn_text([msg]), short_warn([msg]))
        except BaseException:
            pass
        return 0
