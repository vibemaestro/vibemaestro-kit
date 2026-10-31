#!/usr/bin/env python3
"""Gate: the PR body, every PR comment and every commit message carry no sensitive value.

Rule behind it: `pr-no-leaks`. It flags secrets, public IPs, account IDs, e-mails, phone numbers and personal home-directory paths
(`/Users/<name>`, `/home/<name>`, `C:\\Users\\<name>`). Text that leaves the machine is public to everyone who can read the repo, and the history of
an edited body or comment stays on the server, so a value hidden later is still exposed.

    pr_sensitive.py --pr N [--repo OWNER/NAME]     one PR, read through `gh api` AT RUN TIME (not from an event payload: a payload is a
                                                   snapshot, so editing the body and re-running would scan the old text)
    pr_sensitive.py --payload p.json               one PR as JSON: {number, body, comments:[{where, body}], commits:[{sha, message}]}
    pr_sensitive.py --corpus prs.json              a list of such objects
    pr_sensitive.py --git-log RANGE                the commit messages of a git range
    ... | pr_sensitive.py --text                   one text from stdin
        [--allow FILE]       the allowlist from this file
        [--config-ref REF]   read .vibemaestro/sdlc.json AND the allowlist file at this git ref (CI: the base of the PR) instead of
                             the working tree. `--pr` reads both at the PR's base commit unless this is given
        [--max-body N]       warn (not red) above N characters of body (default 5000)
        [--cwd DIR]

Config (read through the loader): `sensitive.scan` (which of pr_body, pr_comments, commit_messages are scanned) and `sensitive.allowlist`
(a path; one sha256 of the EXACT value per line followed by `# reason`; never the value itself).

Output prints ONLY masked values (first 4 characters and the length): a log that everyone with read access can open must not
repeat the value it just caught. Do not add context around a match. The sha256 of a hit is printed only outside GitHub Actions, so
a person can add the line to the allowlist: a hash of a low-entropy value (an IPv4 is 2^32, a phone number 10^9) can be reversed
from a public log in minutes.

rc 0 clean, 1 a sensitive value, 2 could not conclude (`gh` failed, a ref does not read), 64 usage, 65 invalid config.
Standard library only.
"""
import argparse
import hashlib
import ipaddress
import json
import os
import re
import subprocess
import sys

try:
    import gate_common as gc
except ImportError as e:     # a partial vendored copy must not read as "red" (a traceback exits 1)
    sys.stderr.write("%s: could not conclude: %s\n" % ("pr_sensitive.py", e))
    sys.exit(2)

# Above this the PR body is WARNED about (not red): the rule `pr-no-leaks` keeps the body short.
MAX_BODY = 5000

# FAIL CLOSED. An exemption depends ONLY on the shape of the value itself, never on the words near it. Exempting by context
# ("version", "tag", "example", "fake"...) has no balance point: loosen it and `<command> -v <ip>` or `fake: <real id>` slips through,
# tighten it and it flags innocent text. A real false positive is exempted for exactly that value through the allowlist (by hash).

# --- IP ----------------------------------------------------------------------
# `is_global` already excludes private, loopback, link-local, shared (CGNAT), documentation and benchmark ranges and 240/4. Multicast
# is still "global" on Python 3.9, so it is excluded separately. The published CDN ranges and well-known public resolvers are not
# anyone's infrastructure.
# The published ranges are written with spaces instead of dots: the repo's own scan for public addresses must not see them.
_CDN = [ipaddress.ip_network(n.replace(" ", ".", 3)) for n in (
    "173 245 48 0/20", "103 21 244 0/22", "103 22 200 0/22", "103 31 4 0/22",
    "141 101 64 0/18", "108 162 192 0/18", "190 93 240 0/20", "188 114 96 0/20",
    "197 234 240 0/22", "198 41 128 0/17", "162 158 0 0/15", "104 16 0 0/13",
    "104 24 0 0/14", "172 64 0 0/13", "131 0 72 0/22")]
_WELL_KNOWN = {n.replace(" ", ".") for n in ("1 1 1 1", "1 0 0 1", "8 8 8 8", "8 8 4 4", "9 9 9 9")}
# A version number shaped like an IPv4 (four numeric parts) escapes only when a prefix is GLUED to it: `<name>/<version>` or `v<version>`
# (`v` is \w, so the lookbehind `(?<![\w.])` excludes it). `version <version>` (a space) stays red: that is context by words.
_IP_RX = re.compile(r"(?<![\w.])(?<![A-Za-z]/)(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})(?!\.?\d)")


def _ip_ok(s):
    try:
        ip = ipaddress.ip_address(s)
    except ValueError:
        return True                       # a quad with a part above 255 is not an IP
    if not ip.is_global or ip.is_multicast or s in _WELL_KNOWN:
        return True
    return any(ip in n for n in _CDN)


# --- e-mail ------------------------------------------------------------------
# `git@` only for known git hosts: `git@<company>` is a person's mailbox. A cluster-internal DSN is only `*.svc.cluster.local`
# (not routable); `.local`, `.internal` and the like are red: they are the owner's own host names, not a placeholder shape.
_EMAIL_OK = re.compile(
    r"(?i)^(noreply@anthropic\.com|noreply@github\.com"
    r"|git@(github\.com|gitlab\.com|bitbucket\.org)"
    r"|[^@]+@users\.noreply\.github\.com|[^@]+@([\w-]+\.)*example\.(com|org|net)"
    r"|[^@]+@([a-z0-9-]+\.)+svc\.cluster\.local)$")


# --- long base64 / hex strings -------------------------------------------------
def _b64_ok(s):
    if re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", s):
        return True                       # a git SHA, a sha256 digest
    digits = sum(c.isdigit() for c in s)
    if "/" in s and "+" not in s and digits < 0.08 * len(s):
        return True                       # a long file path or URL
    # A random secret nearly always has all three classes; a long identifier (camelCase, SCREAMING_CASE) has no digit.
    return not (digits and re.search(r"[a-z]", s) and re.search(r"[A-Z]", s))


# What a placeholder hides: a `<...>` group, a `${NAME...}` group (a name starts with a letter or `_`: `${9Zx2...}` and `${}` are
# not one), `xxx` or `***`. A run of one letter 5 times or more (`yyyyy` in `xxxxx.yyyyy.zzzzz`) is filler only in a value that has
# such a part: without one it is part of a real value (`pppppppp`, `zzzzz` + 9 random characters). A shorter run, or a
# run of digits or punctuation, is never filler (`hunter222`, `Pass00000word`).
_PH_PART = re.compile(r"<[^<>\s]*>|\$\{[A-Za-z_][^{}\s]*\}|x{3,}|\*{3,}")
_PH_RUN = re.compile(r"([a-z])\1{4,}")
_PH_LEFT = 10
# variable references at the START of a value (`$GITHUB_TOKEN`, `${A}$B`); a name with upper case, lower case AND a digit has the
# shape of a password that starts with `$` (`$uperS3cretPass2026`), not of a variable name
_PH_VARS = re.compile(r"(?:\$\{?[A-Za-z_]\w*\}?)+")
# what may follow them: lower-case attribute or method names and closing punctuation (`$TOKEN.`, `$X.trim()`), never random text
_PH_VAR_TAIL = re.compile(r"(?:\.[a-z_]+(?:\(\))?)*[.,;:!?)\]'\"]*")


def _var_name_ok(ref):
    n = ref.strip("${}")
    return not (re.search(r"\d", n) and re.search(r"[a-z]", n) and re.search(r"[A-Z]", n))


def _placeholder(s):
    """A placeholder recognised from the WHOLE value: variable references followed only by lower-case attribute names or closing
    punctuation (`$GITHUB_TOKEN`, `$A$B`, `$ACCESS_TOKEN.trim`), or a value with a `<...>`, `${...}` or `xxx`/`***` part and fewer
    than 10 letters and digits outside it and the 5-letter runs (`sk-ant-xxxxxxxx`, `ab***cdef`, `<password>`, `xxxxx.yyyyy.zzzzz`).
    Without such a part a value is never a placeholder, so it is never green where 1.0.0 (which exempted a value that merely
    contains `xxx`, `***`, `<` or `${`) is red: `pppppppp` and `aaaaa.bbbbb` are red. A part alone is not enough: a real token with `xxx`,
    `$DEF` or `zzzzz` inside keeps its other characters and is red. Not from words inside it (`secret`, `example`, `fake`,
    `changeme`): a real password `fake0123456789` or `PROD_SECRET_2026` is still a password."""
    m = _PH_VARS.match(s)
    if m and all(_var_name_ok(r) for r in re.findall(r"\$\{?[A-Za-z_]\w*\}?", m.group(0))):
        return bool(_PH_VAR_TAIL.fullmatch(s[m.end():]))
    low = s.lower()            # may be longer than s (the Turkish dotted capital I): never compare their lengths
    if not _PH_PART.search(low):
        return False           # no placeholder part: nothing marks the value as one
    left = _PH_RUN.sub("", _PH_PART.sub(" ", low))   # a space: removing a part must not join two letter groups into a run
    return sum(c.isalnum() for c in left) < _PH_LEFT


def _first_piece(ok, stops, n):
    """`ok` for the value, and also for the value up to the first of `stops` when that piece alone is n characters or more. The
    `stops` joined the value class in 1.1.0; 1.0.0 read only that piece as the value. A mark after them (`zzzzzAb3xK9pQ2#xxx`) does
    not exempt the text before them, which 1.0.0 flagged."""
    def check(s):
        i = next((k for k, c in enumerate(s) if c in stops), len(s))
        return ok(s) and (i == len(s) or i < n or ok(s[:i]))
    check.stops = stops
    return check


def _resume(m, grp, ok):
    """Where the scan of one pattern goes on after match m: for a keyword pattern (its check is a _first_piece), right after the
    first character of the value, else after the match. A value may swallow the keyword of the next assignment, glued behind a
    stop (`token=xxxxxx#token=<secret>`) or behind `.` `-` `_` `/` (`password=xxxxxx.secret=xxxxxxxxxxxx.token=<secret>`, where
    the other keyword pattern swallows `token`); 1.0.0, with one pattern and a shorter value, read that keyword. A value holds no
    `=`, so it swallows at most one keyword, and every search starts later than the one before."""
    return m.start(grp) + 1 if hasattr(ok, "stops") else m.end()


def _matches(rx, grp, ok, text):
    m = rx.search(text)
    while m:
        yield m
        m = rx.search(text, _resume(m, grp, ok))


def _url_pw_ok(s):
    # A value with a `/` is a path, not a password, when it has only one of upper case, lower case and digits
    # (`host:port/path/to/pkg@1.2.3`) or ends in `.git` (scp style, `github.com:Acme2/Tool.git@v1`). Without a `/` the value is
    # judged like any other.
    if "/" in s and (s.endswith(".git") or sum(bool(re.search(c, s)) for c in (r"\d", r"[a-z]", r"[A-Z]")) < 2):
        return True
    return _placeholder(s)


def _kv_ok(s):
    # A name in place of a value: `api_key: OPENAI_API_KEY_FROM_VAULT` (SCREAMING_CASE), `secret=my-resource-name` (a resource name
    # of at most 3 words; from 4 words it is a diceware-style passphrase). Only when there is NO digit: `PROD_ENV_2026_XQ` has the
    # shape of a variable name and is a password.
    return _placeholder(s) or bool(re.fullmatch(r"[a-z]+(-[a-z]+){1,2}", s)) or bool(re.fullmatch(r"[A-Z]+(_[A-Z]+)+", s))


def _pw_ok(s):
    # After `password`/`passwd` a lower-case hyphenated value is a passphrase whatever its length: a password is never a resource name.
    return _placeholder(s) or bool(re.fullmatch(r"[A-Z]+(_[A-Z]+)+", s))


def _id_shape_ok(s):
    """A hand-typed id recognised from itself: fewer than 6 distinct characters, or the whole string is a chunk of at most 16
    characters repeated (`0f1e2d3c` x4, `0123456789abcdef` x2). A real 32-hex id has about 15 distinct characters and no repeat.
    The words "example" or "fake" near an id do NOT exempt it."""
    h = s.replace("-", "").lower()
    if len(set(h)) < 6:
        return True
    return any(h == (h[:k] * (len(h) // k + 1))[:len(h)] for k in range(1, 17))


# the value after a secret keyword: `@ ! $ #` are password characters too (`P@ssw0rd!`); `{`, `*`, `<` and quotes end it
_KV_VALUE = r"[\"']?\s*[:=]\s*[\"']?([A-Za-z0-9+/_\-.@!$#]{12,})"

# (kind, regex, group of the value, "this shape is a placeholder / not sensitive" function). The function gets the VALUE only:
# there is no context parameter, on purpose.
PATTERNS = [
    ("github-token", r"\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github" r"_pat_[A-Za-z0-9_]{40,})", 0, lambda s: bool(re.fullmatch(r"\w+_[xX]+", s))),
    ("api-key-sk", r"\bsk-(?:ant-|proj-)?[A-Za-z0-9_\-]{20,}", 0, _placeholder),
    ("slack-token", r"\bxox[abpr]-[A-Za-z0-9-]{10,}", 0, _placeholder),
    ("aws-access-key", r"\bAKIA[0-9A-Z]{16}\b", 0, None),
    ("vault-token", r"\bhv[sbr]\.[A-Za-z0-9_\-]{20,}", 0, _placeholder),
    ("jwt", r"\beyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{5,}", 0, None),
    ("private-key", r"-----BEGIN [A-Z ]*PRIVATE KEY-----", 0, None),
    ("age-secret-key", r"AGE-SECRET-KEY-1[A-Z0-9]{20,}", 0, None),
    # `$TOKEN` is a placeholder; the value before a `$` is judged on its own too (see _first_piece)
    ("bearer-token", r"(?i)authorization:\s*bearer\s+([A-Za-z0-9._\-$]{16,})", 1, _first_piece(_placeholder, "$", 16)),
    # two entries of one kind: the keyword decides whether a lower-case hyphenated value can be a resource name (see _kv_ok, _pw_ok)
    ("secret-assignment", r"(?i)(?<![a-z0-9])(?:password|passwd)" + _KV_VALUE, 1, _first_piece(_pw_ok, "@!$#", 12)),
    ("secret-assignment",
     r"(?i)(?<![a-z0-9])(?:secret|token|api[_-]?key|client[_-]?secret|access[_-]?key)" + _KV_VALUE, 1,
     _first_piece(_kv_ok, "@!$#", 12)),
    # the password may hold `/` (see _url_pw_ok for the paths it is not); digits right after the `:` and then `/` are a port
    # (`https://host:8443/a@b`), not a password
    ("url-credential", r"\b[a-z][a-z0-9+.-]*://[^/\s:@]+:(?!\d{1,5}/)([^\s@]{6,})@", 1, _url_pw_ok),
    ("long-base64", r"(?<![A-Za-z0-9/+_\-])[A-Za-z0-9+/]{40,}={0,2}(?![A-Za-z0-9/+_\-])", 0, _b64_ok),
    ("account-id",
     r"(?i)\b(?:account|tenant|subscription|zone)(?:[ _-]?ids?)?\b[^\n]{0,60}?"
     r"\b([0-9a-f]{32}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\b", 1, _id_shape_ok),
    ("cloud-account-url", r"(?i)(?:dash\.cloudflare\.com|/accounts)/([0-9a-f]{32})\b", 1, _id_shape_ok),
    ("email", r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b", 0, lambda s: bool(_EMAIL_OK.match(s))),
    # international `+<country code><number>` in one piece, or a national mobile shape (a 0, then 3, 5, 7, 8 or 9, then 8 digits)
    ("phone", r"(?<![\d.])(?:\+\d{9,14}|0[35789]\d{8})(?![\d.])", 0, None),
    ("public-ipv4", _IP_RX.pattern, 1, _ip_ok),
]
_COMPILED = [(k, re.compile(rx), g, ok) for k, rx, g, ok in PATTERNS]
# A commit or object id (a whole word of 40 or 64 hex digits) is not a phone number, though its digits may hold one. A
# shorter hex word stays scanned: `0912345678abc` may be a number glued to letters, and a gate prefers a false red.
_HEX_ID_RX = re.compile(r"(?<!\w)(?:[0-9a-fA-F]{64}|[0-9a-fA-F]{40})(?!\w)")
_NOT_IN_HEX_ID = ("phone",)

# --- personal home-directory path ------------------------------------------------
# `/Users/<name>`, `/home/<name>`, `/mnt/<drive>/Users/<name>` (also `/cygdrive/<drive>` and git-bash `/<drive>`) and `<drive>:\Users\<name>`: the
# user segment names a person. The value is the root plus that segment, so every path under one home is one value (and one allowlist line per
# spelling). The user segment must be LITERAL: a `<name>`, `$USER`, `${USER}`, `%USERNAME%`, `[name]` or glob does not start with a word
# character; a literal glued to the START of a template (`user-<id>`, `u$N`, `u%N`, `user-{id}`) is a template too. A `$`, `%` or `*` after
# a whole name that does not start a placeholder (a shell prompt `...$ ls`, a glob) is not: the name is still there.
# The root must stand at a token boundary: not glued to a path before it (`https://host/home/<x>`, `src/Users/<x>`, `$HOME/Users/<x>`,
# `~/home/<x>`, `$(cmd)/home/<x>`). `>` and `-` do not glue (a redirection, a tag, the removed line of a diff). `C:/Users/<x>` is read by the
# Windows shape, not twice. `file://` before the root is the one URL form that is a machine path.
# `/Users` and `/home` are case-sensitive (`/users/<id>` is an API route); after a drive letter `Users` is not.
_HOME_NAME = r"(\w[^\s/\\\"'`|,;:<>(){}\[\]%$*?!]*)"
_HOME_BOUND = r"(?:(?<![\w.~/$%}\])])|(?<=file://))"
_HOME_RX = [re.compile(rx) for rx in (
    _HOME_BOUND + r"(?<!\b[A-Za-z]:)(/Users/)" + _HOME_NAME,
    _HOME_BOUND + r"(/home/)" + _HOME_NAME,
    _HOME_BOUND + r"(/(?:(?:mnt|cygdrive)/)?[A-Za-z]/Users/)" + _HOME_NAME,
    r"(?<!\w)([A-Za-z]:[\\/]+(?i:Users)[\\/]+)" + _HOME_NAME,
)]
# Accounts of a product or an image, and system profiles, not persons (compared lower-case). `agent` is the sandbox pod's own account.
# Words that name the slot (`user`, `you`, `your-name`...) are not a person either. Nothing else is exempt: not `alice`, `foo`, `test`.
_HOME_OK = frozenset((
    "runner", "runneradmin", "vsts", "circleci", "linuxbrew", "agent", "shared", "guest", "public", "default",
    "node", "vscode", "codespace", "ubuntu", "ec2-user", "jovyan", "jenkins", "postgres", "www-data", "nobody", "git",
    "app", "appuser", "travis", "gitpod", "vagrant", "pi", "admin", "dev",
    "user", "username", "name", "you", "me"))
_HOME_SLOT = re.compile(r"(?i)your[-_]?(?:user[-_]?)?name|your[-_]?user")
_PCT = re.compile(r"(?:%[0-9A-Fa-f]{2})+")


def _unquote(t):
    """`%XX` runs decoded as UTF-8 (a multi-byte name stays one name), what cannot be decoded left as written."""
    return _PCT.sub(lambda m: bytes.fromhex(m.group(0).replace("%", "")).decode("utf-8", "replace"), t)


def _template_follows(t, end, name):
    """The user segment ends where a placeholder starts: `user-<id>` (a `<` after a name that ends in `-` or `_`; after any other name it is
    a tag, `<x>/home/<seg></x>`), `${ID}`, `$ID`, `%ID`, `{id}`."""
    a, b = t[end:end + 1], t[end + 1:end + 2]
    word = b.isalnum() or b == "_"
    return (a == "<" and name[-1] in "-_") or (a == "$" and (b == "{" or word)) or (a in ("%", "{") and word)


def _home_values(text):
    """The home-directory paths of `text`, read as written and with `%XX` decoded once and twice (`%2Fhome%2Falice`, `%252Fhome%252Falice`,
    `C%3A%5CUsers%5Calice`)."""
    out, seen = [], set()
    once = _unquote(text)
    for t in (text, once, _unquote(once)):
        for rx in _HOME_RX:
            for m in rx.finditer(t):
                name = m.group(2).rstrip(".")
                if (not name or name.lower() in _HOME_OK or _HOME_SLOT.fullmatch(name) or _template_follows(t, m.end(2), name)):
                    continue
                v = m.group(1) + name
                if v not in seen:
                    seen.add(v)
                    out.append(v)
    return out


def mask(s):
    """First 4 characters and the length: enough for a person who has the source to find it again, not enough to use it."""
    return "%s...[%d]" % (s[:4], len(s))


def digest(v):
    return hashlib.sha256(v.encode("utf-8", "surrogateescape")).hexdigest()   # stdin with a byte that is not UTF-8 holds a surrogate


def parse_allow(text):
    """(set of sha256, number of ignored lines). A line is `<sha256 of the value>  # reason`; blank lines and `#` lines are skipped.
    Any other line is IGNORED and only counted: a raw value pasted into the file must not be echoed back."""
    out, ignored = set(), 0
    for line in (text or "").splitlines():
        tok = line.split("#", 1)[0].split()
        if not tok:
            continue
        if len(tok) == 1 and re.fullmatch(r"[0-9a-f]{64}", tok[0]):
            out.add(tok[0])
        else:
            ignored += 1
    return out, ignored


def scan_text(text, allow=frozenset()):
    """[(kind, value)]: the REAL value, for internal use only (print it through `mask`)."""
    out, seen = [], set()
    hex_ids = [m.span() for m in _HEX_ID_RX.finditer(text or "")]
    for kind, rx, grp, ok in _COMPILED:
        for m in _matches(rx, grp, ok, text or ""):
            v = m.group(grp)
            if (ok and ok(v)) or (kind, v) in seen or digest(v) in allow:
                continue
            if kind in _NOT_IN_HEX_ID and any(a <= m.start(grp) and m.end(grp) <= b for a, b in hex_ids):
                continue
            seen.add((kind, v))
            out.append((kind, v))
    for v in _home_values(text or ""):
        if ("home-path", v) not in seen and digest(v) not in allow:
            seen.add(("home-path", v))
            out.append(("home-path", v))
    return out


def _annot(level, msg):
    if os.environ.get("GITHUB_ACTIONS"):
        print("::%s title=pr-sensitive::%s" % (level, msg))


def check_sources(label, sources, max_body=None, allow=frozenset()):
    """sources: [(where, text)]. Prints each hit masked and returns the number of hits."""
    hits = 0
    gha = bool(os.environ.get("GITHUB_ACTIONS"))
    for where, text in sources:
        for kind, v in scan_text(text, allow):
            hits += 1
            line = "%s %s: %s %s" % (label, where, kind, mask(v))
            print("RED  " + line + ("" if gha else "  sha256=" + digest(v)))
            _annot("error", line)
        if max_body and where == "body" and len(text or "") > max_body:
            line = "%s body is %d characters (> %d): summary, acceptance commands and short results; long logs stay out of the PR" % (label, len(text), max_body)
            print("WARNING " + line)
            _annot("warning", line)
    return hits


def from_payload(p, scopes):
    """[(where, text)] of one PR object, keeping the scopes the config asks for."""
    src = []
    if "pr_body" in scopes:
        src.append(("body", p.get("body") or ""))
    if "pr_comments" in scopes:
        for c in p.get("comments") or []:
            src.append((c.get("where") or "comment", c.get("body") or ""))
    if "commit_messages" in scopes:
        for c in p.get("commits") or []:
            src.append(("commit %s" % (c.get("sha") or "")[:8], c.get("message") or ""))
    return src


# --- reading a PR through gh ---------------------------------------------------
def _gh(args):
    try:
        p = subprocess.run(["gh"] + args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise gc.Infra("gh could not run: %s" % e)
    if p.returncode != 0:
        raise gc.Infra("gh %s failed: %s" % (" ".join(args[:2]), p.stderr.decode("utf-8", "replace").strip()[:160]))
    return p.stdout.decode("utf-8", "replace")   # UTF-8 on purpose, not the locale: a PR is not ASCII


def _pages(path):
    # `--slurp`, not `--paginate --jq`: `--jq` prints one array per page
    pages = json.loads(_gh(["api", path, "--paginate", "--slurp"]) or "[]")
    return [x for page in pages for x in page]


def read_pr(num, repo):
    base = "repos/%s/" % (repo or "{owner}/{repo}")
    pr = json.loads(_gh(["api", base + "pulls/%s" % num]))
    ic = _pages(base + "issues/%s/comments" % num)
    rc = _pages(base + "pulls/%s/comments" % num)
    rv = _pages(base + "pulls/%s/reviews" % num)
    cm = _pages(base + "pulls/%s/commits" % num)
    comments = ([{"where": "comment %s" % c["id"], "body": c.get("body")} for c in ic]
                + [{"where": "review-comment %s" % c["id"], "body": c.get("body")} for c in rc]
                + [{"where": "review %s" % c["id"], "body": c.get("body")} for c in rv])
    commits = [{"sha": c["sha"], "message": (c.get("commit") or {}).get("message")} for c in cm]
    return {"number": pr.get("number", num), "body": pr.get("body") or "", "comments": comments, "commits": commits,
            "commits_truncated": len(commits) >= 250,       # the commits endpoint returns at most 250
            "base_sha": (pr.get("base") or {}).get("sha")}, base


def base_reader(cwd, base_sha, base_path, check_ref=False):
    """A reader of one repo file as it is at the PR's base commit: through git when the commit is here, through the API otherwise.
    `check_ref`: the ref was given by hand (`--config-ref`), so one that neither git nor the API knows is rc 2, not a 404 read as
    "no file" (the defaults and an empty allowlist in place of the repo's)."""
    if check_ref and base_sha and not gc.ref_ok(base_sha, cwd):
        try:
            _gh(["api", "%scommits/%s" % (base_path, base_sha), "--jq", ".sha"])
        except gc.Infra:
            raise gc.Infra("ref `%s` does not read (neither in this clone nor through the API)" % base_sha)

    def read(rel):
        if base_sha and gc.ref_ok(base_sha, cwd):
            return gc.read_at(cwd, base_sha, rel)
        if not base_sha:
            return None
        try:   # an error or a 404 (the base has no such file) reads as "absent": a broken read is stricter, never looser
            return _gh(["api", "%scontents/%s?ref=%s" % (base_path, rel, base_sha), "-H", "Accept: application/vnd.github.raw"])
        except gc.Infra:
            return None
    return read


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--pr")
    g.add_argument("--payload")
    g.add_argument("--corpus")
    g.add_argument("--git-log", metavar="RANGE")
    g.add_argument("--text", action="store_true")
    ap.add_argument("--repo")
    ap.add_argument("--allow", metavar="FILE")
    ap.add_argument("--config-ref")
    ap.add_argument("--max-body", type=int, default=MAX_BODY)
    ap.add_argument("--cwd", default=".")
    try:
        a = ap.parse_args(argv)
    except SystemExit as e:
        return gc.USAGE if e.code else 0

    pr_obj, reader = None, None
    if a.pr:
        pr_obj, base_path = read_pr(a.pr, a.repo)
        reader = base_reader(a.cwd, a.config_ref or pr_obj["base_sha"], base_path, check_ref=bool(a.config_ref))
        cfg = gc.load_config_text(reader(gc.sdlc_config.CONFIG_REL), " (read at the PR base)")
    else:
        cfg = gc.load_config(a.cwd, a.config_ref)
    scopes = cfg["sensitive"]["scan"]
    ignored = 0
    if a.allow:
        try:
            with open(a.allow, encoding="utf-8") as f:
                allow, ignored = parse_allow(f.read())
        except OSError as e:
            sys.stderr.write("pr-sensitive: cannot read --allow: %s\n" % e)
            return gc.USAGE
    else:
        rel = cfg["sensitive"]["allowlist"]
        if reader:
            text = reader(rel)
        elif a.config_ref:
            text = gc.read_at(a.cwd, a.config_ref, rel)
        else:
            text = gc.read_at(gc.sdlc_config.repo_root(a.cwd), None, rel)
        allow, ignored = parse_allow(text)
    if ignored:
        print("WARNING allowlist: %d line(s) are not `<sha256>  # reason` and were ignored (their text is not repeated)" % ignored)

    total = n_src = 0
    if pr_obj is not None:
        src = from_payload(pr_obj, scopes)
        n_src = len(src)
        total = check_sources("PR #%s" % pr_obj["number"], src, a.max_body, allow)
        if pr_obj["commits_truncated"] and "commit_messages" in scopes:
            line = "PR #%s: the API returns at most 250 commits - later commits are NOT scanned" % pr_obj["number"]
            print("WARNING " + line)
            _annot("warning", line)
    elif a.payload:
        with open(a.payload, encoding="utf-8") as f:
            p = json.load(f)
        src = from_payload(p, scopes)
        n_src = len(src)
        total = check_sources("PR #%s" % p.get("number", "?"), src, a.max_body, allow)
        if p.get("commits_truncated") and "commit_messages" in scopes:
            line = "PR #%s: the API returns at most 250 commits - later commits are NOT scanned" % p.get("number")
            print("WARNING " + line)
            _annot("warning", line)
    elif a.corpus:
        red = 0
        with open(a.corpus, encoding="utf-8") as f:
            corpus = json.load(f)
        for p in corpus:
            src = from_payload(p, scopes)
            n_src += len(src)
            h = check_sources("PR #%s" % p.get("number"), src, None, allow)
            total += h
            red += bool(h)
        print("corpus: %d sources, %d red PRs" % (n_src, red))
    elif a.git_log:
        if "commit_messages" not in scopes:
            print("git-log: commit_messages is not in sensitive.scan - nothing scanned")
            return gc.OK
        raw = gc.must(["log", "--format=%H%x00%B%x01", a.git_log], a.cwd)
        red = []
        for rec in raw.split("\x01"):
            sha, _, msg = rec.strip("\n").partition("\x00")
            if not sha:
                continue
            n_src += 1
            if check_sources("commit %s" % sha[:8], [("message", msg)], None, allow):
                red.append(sha[:8])
        total = len(red)
        print("git-log: %d commits, %d red: %s" % (n_src, len(red), " ".join(sorted(red))))
    else:
        n_src = 1
        total = check_sources("stdin", [("text", sys.stdin.read())], None, allow)

    print("pr-sensitive: %d sources, %d sensitive values" % (n_src, total))
    return gc.RED if total else gc.OK


if __name__ == "__main__":
    sys.exit(gc.run_gate("pr-sensitive", main))
