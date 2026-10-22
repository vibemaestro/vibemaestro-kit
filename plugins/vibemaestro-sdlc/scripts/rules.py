"""Tra luật theo file (`applyTo`) và theo lệnh (`applyWhen`) từ bộ luật NẰM TRONG plugin.

Bộ luật là các file `rules/*.instructions.md` cạnh thư mục `scripts/`, mỗi file có frontmatter:

    applyTo:    glob (phân tách bằng dấu phẩy) khớp đường dẫn file sắp sửa
    applyWhen:  regex khớp dòng lệnh sắp chạy
    level:      `block` thì lệnh khớp bị chặn; mặc định chỉ nhắc
    status:     khác `active` (hay `live`, cùng nghĩa từ khi có vòng đời kb/) thì không giao
    description một dòng, hiện trong danh mục

Nguồn thêm của repo đích: các thư mục `rules.dirs` của `.vibemaestro/sdlc.json` (cùng khuôn, xem `load_all`).
Thêm nguồn thứ hai: `kb/decisions/*.md` của REPO ĐANG SỬA (cùng khuôn frontmatter, chỉ `applyTo`).
Luật là mệnh lệnh; quyết định chỉ nói "vì sao chỗ này như vậy" kèm phương án đã loại.

Module này không đọc gì ngoài thư mục plugin và repo đích, không gọi mạng, chỉ dùng thư viện chuẩn
(Python 3.8+). Hàm thuần: không ghi file (dedup theo phiên nằm ở vsdlc.py).
"""
import os
import posixpath
import re
import subprocess
import time

RULES_DIR = "rules"
RULE_SUFFIX = ".instructions.md"
DECISIONS_REL = "kb/decisions"
GIT_TIMEOUT = 3
# Rule files renamed to English (2.7.0): old file name -> new. A name in `rules.disable`, and a repo rule file that replaces a plugin rule
# by its name, still answer to the old one (`load_all` maps it and adds a note); the map has no removal date.
RENAMED_RULES = {
    "cach-lam-viec-chung.instructions.md": "workflow-core.instructions.md",
    "khuon-current-state.instructions.md": "current-state-shape.instructions.md",
    "pr-khong-lo-thong-tin.instructions.md": "pr-no-leaks.instructions.md",
    "quy-trinh-git.instructions.md": "git-process.instructions.md",
    "truoc-khi-chuyen-ready.instructions.md": "before-ready.instructions.md",
}
DIRS_TOKEN = "${rules.dirs}"     # in `applyTo`: each directory of the repo's `rules.dirs` (apply_to_patterns)
# in `applyTo`, a whole glob of its own: every path of a repo that publishes its tree (`public.private` set), except the root kb/
# and the globs of `public.private`; nothing in a repo that does not publish (the key unset)
PUBLIC_TOKEN = "${public.tree}"


# ── frontmatter ────────────────────────────────────────────────────────────────
def front(text, key):
    """Giá trị một trường frontmatter, "" nếu không khai. Chỉ nhìn khối `---` mở đầu; không kéo PyYAML vào hook.

    The value of `key: value`: surrounding whitespace off, then one opening and one closing double quote off. Linear in the
    line: the regular expression it replaces (`^key:\\s*"?(.*?)"?\\s*$`, same values) took 1.8 s on a 32 KB line, and a rule
    file of a dependent plugin is input this hook does not control."""
    lines = (text or "").split("\n")
    if not lines or lines[0].strip() != "---":
        return ""
    head = key + ":"
    for line in lines[1:]:
        if line.strip() == "---":
            return ""
        if line.startswith(head):
            v = line[len(head):].lstrip()
            v = (v[1:] if v.startswith('"') else v).rstrip()
            return v[:-1] if v.endswith('"') else v
    return ""


def _read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return None


def _read_exact(path):
    """The file without newline translation (what the session would read)."""
    try:
        with open(path, encoding="utf-8", errors="replace", newline="") as f:
            return f.read()
    except OSError:
        return None


def _nl(t):
    """Text with CRLF as LF, for comparing a tree file with a blob: a CRLF blob, or a CRLF checkout of an LF blob
    (`core.autocrlf`), is the same text, not an edit."""
    return None if t is None else t.replace("\r\n", "\n")


def unread_names(up, dirs):
    """Paths of the rule directories and `kb/decisions` the ref changed whose text this clone lacks (a partial clone)."""
    return [r for r in (up or {}).get("unread") or []
            if any(_in_dir(r, d, RULE_SUFFIX) for d in dirs) or _in_dir(r, DECISIONS_REL, ".md")]


def live(t):
    return (front(t, "status") or "active") in ("active", "live")


def load_dir(directory, suffix=".md"):
    """[(tên file, nội dung)] theo tên, chỉ file `status: active` hoặc `live` (mặc định active)."""
    try:
        names = sorted(n for n in os.listdir(directory) if n.endswith(suffix))
    except OSError:
        return []
    out = []
    for n in names:
        t = _read(os.path.join(directory, n))
        if t is None or not live(t):
            continue
        out.append((n, t))
    return out


def load_repo_dir(troot, rel_dir, suffix=".md", up=None):
    """`load_dir` of the repo directory `rel_dir`, with the files of `up` (see `upstream`) taken into account.

    Returns [(file name, text, rel path or None, kind)] by name. kind:
      None     the tree's text, unmarked: the ref did not change it, or has the same text
      `ref`    the ref changed it (or only the ref has it): the ref's text, status included (a rule the ref made not live is gone)
      `both`   the tree changed it too since the fork point (committed or not): the tree's text, the edit being made here
      `gone`   the ref does not have it (deleted there, or added here when there is no fork point): the tree's text, so a
               rule never vanishes without a mark (a directory moved upstream while the tree's config names the old one)
      `unread` the ref changed it but its text is not in this clone (a partial clone): the tree's text
    Every kind but None is marked by the caller (`upstream_mark`)."""
    directory = os.path.join(troot, *rel_dir.split("/")) if rel_dir != "." else troot
    up = up or {}
    files, unread = up.get("files") or {}, up.get("unread") or []
    mine = {rel: posixpath.basename(rel) for rel in sorted(set(files) | set(unread)) if _in_dir(rel, rel_dir, suffix)}
    if not mine:
        return [(n, t, None, None) for n, t in load_dir(directory, suffix)]
    out = {n: (t, None, None) for n, t in load_dir(directory, suffix)}
    base = up.get("base")
    for rel, n in mine.items():
        local = _read_exact(os.path.join(directory, n))
        if rel in unread:
            kind, text = "unread", local       # a file only the ref has cannot be matched: the warning names it (unread_names)
        elif rel not in files:
            continue
        elif local is not None and _nl(local) == _nl(files[rel]):
            continue                           # the same text on both sides: nothing is stale
        elif files[rel] is None:
            kind, text = "gone", local         # before `both`: a `git show` of a file the ref lacks would fail
        elif isinstance(base, dict) and local is not None and _nl(local) != _nl(base.get(rel)):
            kind, text = "both", local
        else:
            kind, text = "ref", files[rel]
        out.pop(n, None)
        if text is not None and live(text):
            out[n] = (text, rel, kind)
    return [(n,) + out[n] for n in sorted(out)]


def _in_dir(rel, rel_dir, suffix):
    """`rel` is a file directly in `rel_dir` (as `load_dir` reads it: no sub-directory) and ends in `suffix`."""
    return rel.endswith(suffix) and posixpath.dirname(rel) == ("" if rel_dir == "." else rel_dir)


def load_rules(plugin_root):
    return load_dir(os.path.join(plugin_root, RULES_DIR), RULE_SUFFIX)


def rule_file_name(name):
    """`rules.disable` accepts a rule file name with or without the suffix."""
    return name if name.endswith(RULE_SUFFIX) else name + RULE_SUFFIX


def canonical(file_name):
    """The current file name of a rule file name: the new name for a renamed rule's old name, else the name itself."""
    return RENAMED_RULES.get(file_name, file_name)


def load_all(plugin_root, troot, rules_cfg=None, keep=(), up=None, packs=()):
    """The rules that are DELIVERED: the plugin's, then those of the repo's `rules.dirs`, then the rule packs.

    Returns (rules, paths, notes). `rules` is [(file name, text)] as `load_rules` gives it; `paths` maps a file name to the
    absolute path of the file that is delivered (repo or plugin), which is what a reminder must print; `notes` is
    [(kind, file name, detail)] with kind `replaced` (a repo file took the place of the plugin file of the same name; the name is the repo file's own, which may be an
    old name; detail is the repo directory), `disabled` (turned off by `rules.disable`), `renamed` (`rules.disable` names a rule by its old file name; detail: the
    new file name), `old-name` (a delivered repo rule file has the old name of a renamed plugin rule and is treated as that rule; detail: (its
    directory, the new file name)), `core-name` (a repo file named like a name in `keep`, not
    delivered; detail is its directory) or `shadowed` (the same name in a later `rules.dirs` directory, not delivered; detail is
    (its directory, the directory delivered, the file name delivered)). Names in `keep` (the process core) are never disabled or replaced. A repo
    directory that is missing or empty contributes nothing, quietly; one directory spelled twice (`r1`, `./r1`) is read once.
    With `up` (see `upstream`) the repo directories are read through `load_repo_dir`, and each delivered repo rule that comes from
    the default ref, or that the ref changed too, adds a note `upstream` (detail: (its path in the repo, `ref` or `both`), see
    `load_repo_dir`). Plugin rules are never read from the ref.

    `packs` is `rule_packs.load`'s list, which is sorted by plugin id: that order decides between two packs, never the
    registry's. A pack rule never takes a name of this plugin's `rules/` (the process core included, a disabled or retired rule
    too): note `pack-sdlc-name` (detail: the plugin id). A repo rule replaces a pack rule of its name, in every pack
    (`pack-replaced`, detail (plugin id, repo directory)); `rules.disable` turns it off in every pack (`disabled`, detail the
    plugin id); otherwise a name already taken by an earlier pack is not delivered (`pack-shadowed`, detail (plugin id, the
    plugin id delivered)). Each delivered pack rule adds a note `pack` (detail: the plugin id) and comes after every other rule."""
    rules_cfg = rules_cfg or {}
    disabled, notes = set(), []
    for n in rules_cfg.get("disable") or []:
        old = rule_file_name(n)
        if old in RENAMED_RULES and not any(k == "renamed" and a == old for k, a, _b in notes):
            notes.append(("renamed", old, RENAMED_RULES[old]))
        disabled.add(canonical(old))
    disabled -= set(keep)
    repo, fresh = {}, {}                # repo[canonical name] = (directory, text, the file's own name)
    for d in repo_dirs(rules_cfg):
        # in one directory a file with the current name goes first, so it beats a file with the old name of the same rule
        for fname, t, rel, kind in sorted(load_repo_dir(troot, d, RULE_SUFFIX, up), key=lambda x: x[0] != canonical(x[0])):
            n = canonical(fname)
            if n in keep:
                notes.append(("core-name", fname, d))
            elif n not in repo:
                repo[n] = (d, t, fname)
                if n != fname:                  # only a delivered file is told to be renamed
                    notes.append(("old-name", fname, (d, n)))
                if rel:
                    fresh[n] = (rel, kind)
            else:
                notes.append(("shadowed", fname, (d, repo[n][0], repo[n][2])))
    rules, paths = [], {}
    for n, t in load_rules(plugin_root):
        if n in disabled:
            notes.append(("disabled", n, ""))
        elif n in repo:
            notes.append(("replaced", repo[n][2], repo[n][0]))
        else:
            rules.append((n, t))
            paths[n] = os.path.join(plugin_root, RULES_DIR, n)
    for n in sorted(repo):
        fname = repo[n][2]
        rules.append((fname, repo[n][1]))
        paths[fname] = os.path.join(troot, *repo[n][0].split("/"), fname)
        if n in fresh:
            notes.append(("upstream", fname, fresh[n]))
    if packs:
        try:
            own = {n for n in os.listdir(os.path.join(plugin_root, RULES_DIR)) if n.endswith(RULE_SUFFIX)}
        except OSError:
            own = set()
        own |= set(keep) | set(RENAMED_RULES)       # a pack never takes a name of this plugin, and an old name is still one
        taken = {}
        for pid, rdir, prules in packs:
            for n, t in prules:
                if n in own:
                    notes.append(("pack-sdlc-name", n, pid))
                elif repo.get(n):               # a repo rule of this name replaces the pack's, in every pack
                    notes.append(("pack-replaced", n, (pid, repo[n][0])))
                elif n in disabled:
                    notes.append(("disabled", n, pid))
                elif n in taken:
                    notes.append(("pack-shadowed", n, (pid, taken[n])))
                else:
                    taken[n] = pid
                    rules.append((n, t))
                    paths[n] = os.path.join(rdir, n)
                    notes.append(("pack", n, pid))
    return rules, paths, notes


def pack_of(notes):
    """{rule name: plugin id} of the delivered pack rules (`pack` notes of `load_all`)."""
    return {n: d for k, n, d in notes if k == "pack"}


# ── applyTo (glob → regex) ─────────────────────────────────────────────────────
def glob_to_regex(pat):
    """Glob kiểu `applyTo` → regex. Thứ tự thay thế quan trọng: `**/` trước `**`, `**` trước `*` —
    làm ngược thì `**/*.yaml` không khớp file nằm sâu, sai im lặng."""
    return re.compile("^" + _glob_fragment(pat) + "$")


def _glob_fragment(pat):
    out, i = [], 0
    while i < len(pat):
        if pat.startswith("**/", i):
            out.append(r"(?:[^/]+/)*")
            i += 3
        elif pat.startswith("**", i):
            out.append(r".*")
            i += 2
        elif pat[i] == "*":
            out.append(r"[^/]*")
            i += 1
        elif pat[i] == "?":
            out.append(r"[^/]")
            i += 1
        else:
            out.append(re.escape(pat[i]))
            i += 1
    return "".join(out)


class RepoDirs(tuple):
    """The repo's `rules.dirs` as a tuple, carrying `public`: None when the repo does not publish its tree, else the globs of
    `public.private`. It rides along the `dirs` every matcher already takes; a plain tuple has no `public`, so the token is off."""
    public = None


def repo_dirs(rules_cfg, public_cfg=None):
    """The repo's `rules.dirs`, each spelled once (`r1`, `./r1`, `r1/` are one directory), in their order; with `public_cfg` (the
    config's `public` object) the result also carries `public.private` for `${public.tree}`."""
    out = RepoDirs(dict.fromkeys(posixpath.normpath(x) for x in (rules_cfg or {}).get("dirs") or []))
    private = (public_cfg or {}).get("private")
    out.public = tuple(private) if isinstance(private, list) else None
    return out


def public_regex(dirs):
    """`${public.tree}` as one regex: any path but the root kb/ and the `public.private` globs; None when the repo does not publish."""
    private = getattr(dirs, "public", None)
    if private is None:
        return None
    return re.compile("^(?!kb/)" + "".join("(?!%s$)" % _glob_fragment(g) for g in private) + ".*$")


def apply_to_patterns(value, dirs=()):
    """The globs of an `applyTo` value. `${rules.dirs}` in a glob stands for each directory of the repo's `rules.dirs` (one glob
    per directory, none when the list is empty), so a rule can follow wherever a repo keeps its rules. `${public.tree}` reads
    `** except kb/** <private globs>` in a repo that publishes, and is left out in one that does not."""
    out = []
    for pat in (g.strip() for g in (value or "").split(",")):
        if not pat:
            continue
        if pat == PUBLIC_TOKEN:
            private = getattr(dirs, "public", None)
            if private is not None:
                out.append(" ".join(("** except kb/**",) + private))   # for the reader: the catalogue joins globs with ","
            continue
        if DIRS_TOKEN not in pat:
            out.append(pat)
            continue
        for d in dirs:
            # the repo root as a rules directory: `${rules.dirs}/**` is `**`, not `./**` (a relative path never starts with `./`)
            out.append(pat.replace(DIRS_TOKEN + "/", "").replace(DIRS_TOKEN, "") if d == "." else pat.replace(DIRS_TOKEN, d))
    return out


def apply_to_regexes(value, dirs=()):
    """The regexes of an `applyTo` value, as `apply_to_patterns` spells it, with each directory of `${rules.dirs}` taken
    literally (a directory named `r*` is not a glob)."""
    out = []
    for pat in (g.strip() for g in (value or "").split(",")):
        if not pat:
            continue
        if pat == PUBLIC_TOKEN:
            rx = public_regex(dirs)
            if rx is not None:
                out.append(rx)
            continue
        if DIRS_TOKEN not in pat:
            out.append(glob_to_regex(pat))
            continue
        for d in dirs:
            p = pat.replace(DIRS_TOKEN + "/", DIRS_TOKEN) if d == "." else pat
            lit = "" if d == "." else re.escape(d)
            out.append(re.compile("^" + lit.join(_glob_fragment(x) for x in p.split(DIRS_TOKEN)) + "$"))
    return out


def apply_to_matches(text, rel, dirs=()):
    return any(rx.match(rel) for rx in apply_to_regexes(front(text, "applyTo"), dirs))


# ── đường dẫn file → đường dẫn tương đối trong repo đích ──────────────────────
def _git(d, *args):
    try:
        r = subprocess.run(("git", "-C", d) + args, capture_output=True, text=True, timeout=GIT_TIMEOUT)
    except Exception:
        return None
    return r.stdout.strip() if r.returncode == 0 else None


def _nearest_dir(path):
    d = os.path.dirname(path)
    while d and d != os.sep and not os.path.isdir(d):
        d = os.path.dirname(d)
    return d if os.path.isdir(d) else None


def rel_to_root(p, root):
    """Đường dẫn của `p` tính từ gốc checkout CHỨA nó (cây chính hoặc worktree của repo `root`).

    None nếu `p` không thuộc repo đó (file scratchpad, repo khác) — im là đúng.
    Quy về gốc checkout chứa file chứ không phải `root`: file sửa trong `.claude/worktrees/<x>/src/a.ts`
    phải khớp `applyTo: src/**`, nếu không mọi luật theo path im lặng đúng lúc làm việc trong worktree.
    """
    if not p or not root:
        return None
    ap = os.path.abspath(p)
    if ap.startswith(root + os.sep):
        d = os.path.dirname(ap)
        while d.startswith(root):
            if os.path.exists(os.path.join(d, ".git")):
                return os.path.relpath(ap, d).replace(os.sep, "/")
            if d == root:
                break
            d = os.path.dirname(d)
        return os.path.relpath(ap, root).replace(os.sep, "/")
    # Worktree NGOÀI cây repo: hỏi git xem nó có chung kho (`--git-common-dir`) với repo đích không.
    d = _nearest_dir(ap)
    if not d:
        return None
    mine = _git(root, "rev-parse", "--git-common-dir")
    theirs = _git(d, "rev-parse", "--git-common-dir")
    top = _git(d, "rev-parse", "--show-toplevel")
    if not (mine and theirs and top):
        return None
    if os.path.realpath(os.path.join(root, mine)) != os.path.realpath(os.path.join(d, theirs)):
        return None
    rel = os.path.relpath(os.path.realpath(ap), os.path.realpath(top))
    return None if rel.startswith("..") else rel.replace(os.sep, "/")


# ── the tree behind origin/<default> ─────────────────────────────────
# A clone's main tree is often behind `origin/<default>`, and its rules and decisions are then older than the ones the team
# has merged. Only refs already fetched are read: the hooks never touch the network (a fetch would cost a round trip on every
# tool call and can prompt for credentials), so "behind" means behind the remote as last fetched.
UPSTREAM_REMOTE = "origin"
UPSTREAM_BRANCHES = ("main", "master")       # tried in this order when `refs/remotes/origin/HEAD` is not set
UPSTREAM_DEADLINE = 2.0                      # seconds for the whole check, well below the hook timeout of 10 s
# no lazy fetch of a missing blob in a partial clone (git 2.44+; older git ignores it), no credential prompt, no index lock
_NO_NET = {"GIT_NO_LAZY_FETCH": "1", "GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0"}


def _git_raw(troot, args, deadline, data=None):
    """stdout (bytes) of `git -C troot <args>` when rc 0 within the deadline, else None. Never raises."""
    left = min(GIT_TIMEOUT, deadline - time.monotonic())
    if left <= 0:
        return None
    try:
        r = subprocess.run(("git", "--literal-pathspecs", "-C", troot) + tuple(args), input=data, capture_output=True,
                           timeout=left, env=dict(os.environ, **_NO_NET))
    except Exception:
        return None
    return r.stdout if r.returncode == 0 else None


def git_dirs(troot):
    """(git dir, common git dir) of the checkout at `troot`, read from the files (no process); (None, None) when it is none."""
    gd = os.path.join(troot, ".git")
    if not os.path.isdir(gd):
        t = _read(gd) or ""                    # a linked worktree or a submodule: `gitdir: <path>`
        if not t.startswith("gitdir:"):
            return None, None
        gd = os.path.normpath(os.path.join(troot, t[len("gitdir:"):].strip()))
    common = (_read(os.path.join(gd, "commondir")) or "").strip()
    return gd, os.path.normpath(os.path.join(gd, common)) if common else gd


def _head_ref(troot, deadline):
    """`refs/heads/<branch>` that HEAD of the checkout at `troot` points to; None when detached, unborn or not a checkout.
    Read from the file (no process) when it says so plainly; git is asked only for other ref backends."""
    gd = git_dirs(troot)[0]
    if not gd:
        return None
    t = (_read(os.path.join(gd, "HEAD")) or "").strip()
    if not t.startswith("ref: refs/heads/"):
        return None                            # detached (a commit id), or not a git dir
    ref = t[5:]
    if ref == "refs/heads/.invalid":           # the reftable backend keeps HEAD in the table
        out = _git_raw(troot, ("symbolic-ref", "-q", "HEAD"), deadline)
        ref = out.decode("utf-8", "replace").strip() if out else ""
        return ref if ref.startswith("refs/heads/") else None
    return ref


def head_branch(troot):
    """`refs/heads/<branch>` of HEAD at `troot`, or None (detached, not a checkout)."""
    return _head_ref(troot, time.monotonic() + UPSTREAM_DEADLINE)


def live_in_tree(troot, rel):
    """The working tree has the file `rel` and its status is live."""
    t = _read(os.path.join(troot, *rel.split("/")))
    return t is not None and live(t)


def upstream_probe(troot, deadline=None):
    """(head commit, default ref name, its commit) for the checkout at `troot`, or None: HEAD detached or unborn, no
    `origin/HEAD`, `origin/main` or `origin/master`, a git error. One git process."""
    deadline = deadline or time.monotonic() + UPSTREAM_DEADLINE
    head = _head_ref(troot, deadline)
    if not head:
        return None
    base = "refs/remotes/%s/" % UPSTREAM_REMOTE
    want = [head, base + "HEAD"] + [base + b for b in UPSTREAM_BRANCHES]
    out = _git_raw(troot, ["for-each-ref", "--format=%(refname)%00%(objectname)%00%(symref)"] + want, deadline)
    if out is None:
        return None
    refs = {}
    for line in out.decode("utf-8", "replace").splitlines():
        parts = line.split("\0")
        if len(parts) == 3:
            refs[parts[0]] = (parts[1], parts[2])      # for-each-ref also matches `<pattern>/...`: exact names only below
    if head not in refs:
        return None
    if base + "HEAD" in refs and refs[base + "HEAD"][1].startswith("refs/remotes/"):
        name, tip = refs[base + "HEAD"][1][len("refs/remotes/"):], refs[base + "HEAD"][0]
    else:
        hit = [b for b in UPSTREAM_BRANCHES if base + b in refs]
        if not hit:
            return None
        name, tip = "%s/%s" % (UPSTREAM_REMOTE, hit[0]), refs[base + hit[0]][0]
    return refs[head][0], name, tip


def upstream(troot, probe, dirs, deadline=None, files=(), decisions=True):
    """What the tree lacks of the default ref, for the rule directories `dirs` and `kb/decisions` (not with `decisions` false),
    and the exact paths `files` (the current-state index, for its SessionStart injection).

    `probe` is `upstream_probe`'s answer. Returns None when it cannot tell (a git error, the deadline), else a dict:
    `behind` (commits of the ref that HEAD lacks; 0 = not behind, and nothing else is filled), `ref`, `head`, `tip`, `files`
    {path in the repo: text at the ref, or None when the ref deleted it} for the files the ref changed since the fork point
    (`HEAD...ref`), `unread` [paths the ref changed whose text this clone does not have], and `base` {path: text at the fork
    point, or None when it did not exist there} for the files (None when there is no fork point, a shallow clone). A file only the tree changed is not in `files`, so a local edit the ref did
    not touch stays; `load_repo_dir` uses `base` to keep one that both changed."""
    deadline = deadline or time.monotonic() + UPSTREAM_DEADLINE
    head, ref, tip = probe
    out = {"ref": ref, "head": head, "tip": tip, "behind": 0, "files": {}}
    if head == tip:
        return out
    n = _git_raw(troot, ("rev-list", "--count", "%s..%s" % (head, tip)), deadline)
    if n is None:
        return None
    out["behind"] = int(n.strip() or 0)
    if not out["behind"]:
        return out
    specs = [d for d in dirs] + ([DECISIONS_REL] if decisions else []) + list(files)
    if not specs:
        return out                             # an empty pathspec would be the whole tree
    fork = _git_raw(troot, ("merge-base", head, tip), deadline)
    fork = fork.decode("ascii", "replace").strip() if fork else None
    names = _git_raw(troot, ["diff", "--name-status", "-z", "--no-renames", "%s..%s" % (fork, tip), "--"] + specs,
                     deadline) if fork else None
    if names is None:
        # no fork point (a shallow clone): every difference counts as the ref's, which serves the ref marked rather than
        # the tree unmarked
        names = _git_raw(troot, ["diff", "--name-status", "-z", "--no-renames", head, tip, "--"] + specs, deadline)
        if names is None:
            return None
    f = names.decode("utf-8", "replace").split("\0")
    changed = {}
    for st, rel in zip(f[0::2], f[1::2]):
        if "\n" not in rel and (any(_in_dir(rel, d, RULE_SUFFIX) for d in dirs) or rel in files
                                 or (decisions and _in_dir(rel, DECISIONS_REL, ".md"))):
            changed[rel] = st[:1]
    want = [(tip, rel) for rel in sorted(changed) if changed[rel] != "D"] + [(fork, rel) for rel in sorted(changed) if fork]
    texts = _cat_files(troot, want, deadline) if want else {}
    if texts is None:
        if time.monotonic() >= deadline:
            return None
        # git refused a blob it does not have (a partial clone; lazy fetching is off): the names are known, the texts are not
        out["files"] = {rel: None for rel in sorted(changed) if changed[rel] == "D"}
        out["unread"] = [rel for rel in sorted(changed) if changed[rel] != "D"]
        out["base"] = None
        return out
    # a deleted file is None; a file the ref has but cat-file could not read (an odd name) is `unread`: the tree's copy, marked
    out["files"] = {rel: texts.get((tip, rel)) for rel in sorted(changed) if changed[rel] == "D" or (tip, rel) in texts}
    out["unread"] = [rel for rel in sorted(changed) if changed[rel] != "D" and (tip, rel) not in texts]
    out["base"] = {rel: texts.get((fork, rel)) for rel in out["files"]} if fork else None
    return out


_CAT_HEADER = re.compile(rb"^[0-9a-f]{40,64} ([a-z]+) ([0-9]+)$")


def _cat_files(troot, objs, deadline):
    """{(commit, rel): text} of the blobs `<commit>:<rel>`, one `git cat-file --batch` process; None on a git error or an
    answer that cannot be parsed. A name git does not find (`... missing`, `... ambiguous`) is left out."""
    data = "".join("%s:%s\n" % (c, r) for c, r in objs).encode("utf-8")
    raw = _git_raw(troot, ("cat-file", "--batch"), deadline, data=data)
    if raw is None:
        return None
    out, i = {}, 0
    for key in objs:
        nl = raw.find(b"\n", i)
        if nl < 0:
            return None
        m = _CAT_HEADER.match(raw[i:nl])
        i = nl + 1
        if not m:
            continue                           # `<name> missing`: the name is echoed, any bytes in it, and nothing follows
        size = int(m.group(2))
        if m.group(1) == b"blob":
            out[key] = raw[i:i + size].decode("utf-8", "replace")
        i += size + 1                          # not a blob (a directory named like a rule): skipped
    return out


def upstream_mark(up, rel, troot, kind="ref"):
    """The visible mark of a file of the overlay (kinds of `load_repo_dir`): where its text comes from, and the command that
    shows the ref's side."""
    n = "%d commit%s" % (up["behind"], "" if up["behind"] == 1 else "s")
    show = "git -C %s show %s" % (shq(troot), shq("%s:%s" % (up["ref"], rel)))
    if kind == "both":
        return "[%s changed it too and this tree is behind it by %s: this is the tree's own edit; the ref's text: %s]" % (
            up["ref"], n, show)
    if kind == "gone":
        return ("[%s does not have it and this tree is behind it by %s: deleted there, or added here; check: git -C %s log "
                "--oneline -1 %s -- %s]" % (up["ref"], n, shq(troot), shq(up["ref"]), shq(rel)))
    if kind == "unread":
        return ("[%s changed it and this tree is behind it by %s, but its text is not in this clone: git -C %s fetch origin, "
                "then %s]" % (up["ref"], n, shq(troot), show))
    return "[from %s: this tree is behind it by %s; read it with: %s]" % (up["ref"], n, show)


def shq(p):
    """`p` quoted for a POSIX shell when it needs it: a path or a ref name in a command the reader is told to run."""
    return p if re.match(r"^[\w@%+=:,./-]+$", p) else "'" + p.replace("'", "'\\''") + "'"


# ── khớp ───────────────────────────────────────────────────────────────────────
def rules_for_path(rules, rel, dirs=()):
    """Tên các luật có `applyTo` khớp `rel` (`dirs`: the repo's `rules.dirs`, for `${rules.dirs}`)."""
    return [n for n, t in rules if apply_to_matches(t, rel, dirs)]


def decisions_for_path(troot, rel, dirs=(), up=None):
    """Các quyết định `kb/decisions/*.md` của repo đích khớp `rel`.

    Quyết định không khai `applyTo` thì không bao giờ được bơm — phần lớn quyết định nói về một lựa chọn
    chung, bơm hết thì thành tiếng ồn. `status` khác `active`/`live` cũng không bơm.
    Returns [(absolute path, path in the repo or None, kind)] with kind as `load_repo_dir` gives it: with `up` (see `upstream`)
    a decision the default ref changed is read from the ref (`ref`; the absolute path may not exist then)."""
    d = os.path.join(troot, *DECISIONS_REL.split("/"))
    return [(os.path.join(d, n), r, kind)
            for n, t, r, kind in load_repo_dir(troot, DECISIONS_REL, ".md", up) if apply_to_matches(t, rel, dirs)]


PACK_MATCH_SECONDS = 1.0     # one timer for all the rule-pack matching of one hook call


class _Overrun(BaseException):
    """The timer of `bounded`. Not an Exception: a matcher's `except Exception` must not swallow it."""


def bounded(fn, seconds):
    """True when `fn()` returned within `seconds`, False when the timer stopped it first (whatever `fn` built so far stays
    built). For work on files and rules this hook does not control (rule packs), which could otherwise hold the hook past its
    timeout and so silence every other rule. The timer is SIGALRM (Unix, main thread; it interrupts a regular expression on
    CPython 3.11, *chưa kiểm* before); where it cannot be set, `fn` runs unbounded. Not re-entrant: a `bounded` inside `fn`
    cancels the outer timer (the hooks run the pack load and the pack matching one after the other)."""
    import signal
    import threading
    use = hasattr(signal, "setitimer") and threading.current_thread() is threading.main_thread()
    done = False

    def on_alarm(*_a):
        raise _Overrun()
    old = signal.signal(signal.SIGALRM, on_alarm) if use else None
    try:
        try:
            if use:
                signal.setitimer(signal.ITIMER_REAL, seconds)
            fn()
            done = True
        finally:
            if use:
                signal.setitimer(signal.ITIMER_REAL, 0)
    except _Overrun:
        pass
    finally:
        if use and old is not None:              # None: a handler not set from Python, which cannot be put back
            signal.signal(signal.SIGALRM, old)
    return done


def match_bounded(match, rules, seconds=PACK_MATCH_SECONDS):
    """(results, None) of `match([rule])` for each rule in order, or (the results so far, name of the rule that was running)
    when the timer of `seconds` ran out first (`bounded`): the rules after it are not matched. A rule whose match raises is
    skipped: a pack `applyWhen` can backtrack for minutes or overflow the regular expression engine."""
    out, now = [], [None]

    def run():
        for r in rules:
            now[0] = r[0]
            try:
                out.extend(match([r]))
            except Exception:
                continue
    if not rules or bounded(run, seconds):
        return out, None
    return out, now[0]


def rules_for_command(rules, command):
    """[(tên, level, mô tả)] của luật có `applyWhen` khớp lệnh. Regex hỏng (hay quá lớn) → bỏ qua luật đó, không nổ.
    Luật không khai `applyWhen` không bao giờ khớp lệnh."""
    hit = []
    for n, t in rules:
        aw = front(t, "applyWhen")
        if not aw:
            continue
        try:
            if re.search(aw, command or ""):
                hit.append((n, front(t, "level") or "remind", front(t, "description")))
        except Exception:                      # re.error, and OverflowError or RecursionError of a pattern too big to compile
            continue
    return hit
