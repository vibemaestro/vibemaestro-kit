"""Máy kiểm khuôn `kb/current-state.md`: chỉ TRẠNG THÁI HIỆN HÀNH, trong trần kích thước.

File này là thứ phiên đọc đầu tiên, nên mỗi dòng thừa là context bị nạp vô ích. Máy bắt hai loại lỗi:

  1. DẤU HIỆU LỊCH SỬ trên một dòng — thứ trả lời "đã thành thế này ra sao" thay vì "đang thế nào":
       ngày (`2026-10-11`, `2026/10/11`, `11/10`, `11/10/2026`, `tháng 10 năm 2026`, `ngày 11 tháng 10`), số PR/issue (`#<n>`, `PR <n>`, `/pull/<n>`), commit SHA đi kèm
       chữ `commit`, từ chỉ quá khứ/nhật ký (`trước đây`, `đã đo`, `đã gỡ`, `nhật ký`…), tiêu đề mục kiểu
       lịch sử (`## Lịch sử`, `## Changelog`), dòng "Đo ngày …" / "Cập nhật lần cuối …".
     Ngày trong nhóm `date` của một nhãn `current_state.labels` không là dấu hiệu lịch sử (mục "dated labels" bên dưới).
  2. VƯỢT TRẦN — `MAX_LINES` dòng, `MAX_BYTES` byte, `MAX_LINE` ký tự mỗi dòng. Vượt trần nghĩa là chi tiết đang nằm
     sai chỗ (đáng ra ở `kb/specs/` hoặc `kb/decisions/`); sửa bằng cách đẩy chi tiết đi, không nới trần.

Bộ dấu hiệu và trần được CHỌN BẰNG ĐO trên văn bản thật (lý do và số đo: `kb/decisions/` của repo plugin này); mỗi dấu
hiệu là một regex ở `HISTORY` bên dưới. Máy chỉ nhìn HÌNH THỨC của dòng: một dòng lịch sử viết không dấu nào trong
danh sách vẫn lọt (máy không hiểu nghĩa) — nó là lưới bắt ca thường gặp, không thay việc đọc lại. Giới hạn đã khai, KHÔNG bắt:
từ quá khứ mơ hồ ("đã thêm", "gần đây", "vừa migrate") và SHA trần không kèm chữ `commit` (đo ở tài liệu sạch thì "vừa …" nằm
trong câu hiện tại hợp lệ nên bắt sẽ nhầm); số dòng lọt đo ở `kb/decisions/…-nguong-current-state.md`.
Chỉ dùng thư viện chuẩn, Python 3.8+.
"""
import os
import posixpath
import re
import signal
import subprocess
import sys
import unicodedata

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import messages  # noqa: E402
import sdlc_config  # noqa: E402

sys.dont_write_bytecode = True

MAX_LINES = 120
MAX_BYTES = 12000
MAX_LINE = 200

_MONTH = r"(?:0[1-9]|1[0-2])"
_DAY = r"(?:0[1-9]|[12]\d|3[01])"
_M1 = r"(?:1[0-2]|0?[1-9])"            # tháng, có thể không zero-pad (chỉ dùng khi có chữ "tháng"/"ngày" dẫn)
_D1 = r"(?:3[01]|[12]\d|0?[1-9])"
_W = r"[\wÀ-ỹ]"

# `dd/mm` đứng cạnh một danh từ đếm ("11/11 suite xanh", "Test: 11/11", "3/4 replica") là PHÂN SỐ, không là ngày. Chỉ nhìn
# cạnh KỀ (khoảng trắng + từ), không nhìn cả dòng: "10/10: mục 2" hay "Đo 10/10 trên pod" vẫn là ngày thật (10 tháng 10).
_COUNT_AFTER = re.compile(
    r"^\s+(?:suite|test|bản sao|replica|pod|assert|kịch bản|xanh|pass|ok|đạt)(?!" + _W + r")", re.I)
_COUNT_BEFORE = re.compile(r"(?<![\wÀ-ỹ-])(?:suite|test|replica|pass|ok|xanh|đạt)[:\s]{1,2}$", re.I)
# `#N` MỘT chữ số đứng sau từ xếp hạng ("luật cứng #1", "ưu tiên #2", "priority #1") là số thứ tự, không là issue/PR.
# Số nhiều chữ số (`#<nn>`) không bị loại: PR thật hầu như luôn từ hai chữ số trở lên ở repo đã có lịch sử.
_RANK_BEFORE = re.compile(
    r"(?<!" + _W + r")(?:ưu tiên|priority|luật|quy tắc|rule|mức|bước|hạng|top|điều|nhóm|tiêu chí|phương án|lựa chọn|option|chặng|pha|"
    r"giai đoạn|cấp|tầng|vị trí|số)(?:\s+" + _W + r"+)?\s+$", re.I)


def _veto_ddmm(line, m):
    return bool(_COUNT_AFTER.match(line[m.end():]) or _COUNT_BEFORE.search(line[:m.start()]))


def _veto_pr(line, m):
    return bool(re.fullmatch(r"#\d", m.group(0)) and _RANK_BEFORE.search(line[:m.start()]))


# (regex, veto hoặc None), in the order of sdlc_config.HISTORY_IDS; the label a message names is `cs.sign.<id>` of messages.py.
# Mỗi regex chạy trên TỪNG DÒNG; một khớp bị `veto(dòng, khớp)` trả True thì bỏ qua.
HISTORY = (
    # ISO: là ngày, TRỪ khi là một phần tên file/đường dẫn (`kb/decisions/2026-01-05-ten.md` là con trỏ hợp lệ tới nơi
    # chứa chi tiết — đo khi viết current-state của chính repo này): không đứng sau `/` `-` `.` và không theo sau bởi `-chữ`.
    (re.compile(r"(?<![\w./-])\d{4}-" + _MONTH + r"-" + _DAY + r"(?![\w]|-[A-Za-z0-9])"), None),
    # YYYY/MM/DD zero-pad: ngày. Không đứng sau `/ . -` và không theo sau `/` (đường dẫn `data/2026/10/11/` là thư mục, không là ngày).
    (re.compile(r"(?<![\w./-])20\d{2}/" + _MONTH + r"/" + _DAY + r"(?![\w/])"), None),
    # dd/mm hoặc dd/mm/yyyy: bắt buộc zero-pad cả hai phần HOẶC có năm — để "3/4 replica", "8/28 field" (phân số) không bị nhận nhầm.
    # Hai số BẰNG NHAU (10/10, 11/11) vẫn là ngày hợp lệ (đo: 10/10 là ngày nhiều nhất ở current-state thật) nên KHÔNG loại theo
    # giá trị; chỉ loại khi đứng cạnh danh từ đếm (_veto_ddmm).
    (re.compile(r"(?<![\w/.\-])(?:" + _DAY + "/" + _MONTH + r"|(?:[12]?\d|3[01])/(?:1[0-2]|0?[1-9])/(?:20)?\d{2})(?![\w/])"), _veto_ddmm),
    # dạng viết bằng chữ: "tháng 10 năm 2026", "tháng 3/2027", "ngày 11 tháng 10", "ngày 5/9". Có chữ "tháng"/"ngày" dẫn nên
    # cho phép không zero-pad. Đo ở tài liệu sạch (kiến trúc, README, luật của plugin): 0 khớp.
    (re.compile(r"(?<!" + _W + r")tháng\s+" + _M1 + r"\s*(?:năm\s+|/\s*)20\d{2}(?![\d])", re.I), None),
    (re.compile(r"(?<!" + _W + r")ngày\s+" + _D1 + r"\s+tháng\s+" + _M1 + r"(?![\d])", re.I), None),
    (re.compile(r"(?<!" + _W + r")ngày\s+" + _D1 + r"/" + _M1 + r"(?![\w/])", re.I), None),
    # số PR/issue: #<n>, PR <n> / PR #<n>, /pull/<n>, /issues/<n>
    (re.compile(r"(?<![\w&/])#\d{1,6}\b|\bPR\s*#?\d+\b|/(?:pull|issues)/\d+"), _veto_pr),
    (re.compile(r"\bcommit\s+[0-9a-f]{7,40}\b", re.I), None),
    # từ chỉ quá khứ / nhật ký. Cố ý KHÔNG có "lịch sử", "history" (câu "lịch sử xem ở git log" là con trỏ, không phải lịch sử),
    # "ban đầu" ("bootstrap ban đầu"), "chuyển từ" ("đang chuyển từ A sang B" là trạng thái đang diễn ra), "cũ", "từng",
    # "thay vì" (đo: xuất hiện trong câu trạng thái hợp lệ — xem decision ngưỡng current-state). "hôm nay" chỉ tính khi đi
    # với động từ quá khứ/đo ("đo hôm nay", "hôm nay đã …"): đứng một mình ("trạng thái hôm nay", "ngày hôm nay") là hiện tại.
    (re.compile(
        r"(?<![\wÀ-ỹ])(?:trước đây|trước đó|ngày xưa|nhật ký|đã đo|đo ngày|hôm qua|đã từng|từng là|"
        r"(?:đo|sửa|thêm|gỡ|merge) hôm nay|hôm nay (?:đã|vừa|mới)|"
        r"đã gỡ|đã sửa|đã chuyển từ|đã đổi từ|đã thay|sau khi merge|changelog|previously|formerly|used to)(?![\wÀ-ỹ])", re.I), None),
    (re.compile(r"^\W*(?:cập nhật (?:lần cuối|ngày)|last updated|updated on)\b", re.I), None),
)
HEADING_HISTORY = re.compile(r"^#{1,6}\s.*(?<![\wÀ-ỹ])(?:lịch sử|nhật ký|changelog|history|log thay đổi)(?![\wÀ-ỹ])", re.I)


# ── profile ──────────────────────────────────────────────────────────────────────────────────────
# The knobs of the `current_state` object of `.vibemaestro/sdlc.json` (see sdlc_config.py for defaults and presets) plus
# `no_state_change`, the exemption tokens of `tokens`. `profile=None` everywhere means the `ledger` profile, which is what the
# constants above have always been, so a caller that passes nothing gets today's behaviour.
def _norm(s):
    """A name or value as the ledger side sees it: NFC, blanks collapsed (the cells of the ledger go through the same)."""
    return re.sub(r"\s+", " ", unicodedata.normalize("NFC", s)).strip()


def profile_from_config(cfg):
    p = dict(cfg["current_state"])
    p["language"] = cfg.get("language", "vi")         # the language of the problems' text (messages.py)
    p["no_state_change"] = list(cfg["tokens"]["no_state_change"])
    p["tables"] = [dict(e, columns=[_norm(c) for c in e["columns"]],
                        enums={_norm(k): [_norm(v) for v in vs] for k, vs in (e.get("enums") or {}).items()
                               if not k.startswith("_")},
                        decorations={_norm(k): [re.compile(r, re.I) for r in ([v] if isinstance(v, str) else v)]
                                     for k, v in (e.get("decorations") or {}).items() if not k.startswith("_")})
                   for e in p["tables"]]
    return p


def ledger_profile():
    return profile_from_config(sdlc_config.defaults())


# The index injected at SessionStart (`inject`) is one hook string, capped at 10,000 characters; 9,000 leaves room for its lead
# line, the stale-tree mark and the list of labels (B1.7 of the brain ladder).
INJECT_MAX_CHARS = 9000


def inject_chars(text):
    """The characters of `text` (bytes or str) as the hook cap counts them: UTF-16 code units of the text as written (no NFC), so
    a letter outside the BMP counts 2 and a decomposed letter counts each of its parts; never fewer than the code points. CRLF
    counts as LF: the hook injects it so, and a CRLF checkout of an LF blob must not judge differently from CI."""
    s = text.decode("utf-8", "replace") if isinstance(text, bytes) else text
    return len(s.replace("\r\n", "\n").encode("utf-16-le")) // 2


# one built-in history sign per id of sdlc_config.HISTORY_IDS, same order as HISTORY; the last id is the heading test
assert sdlc_config.HISTORY_IDS[-1] == "history_heading" and len(sdlc_config.HISTORY_IDS) == len(HISTORY) + 1
SIGNS = dict(zip(sdlc_config.HISTORY_IDS, HISTORY))


def _lines(raw):
    """Lines of the ledger as the checks see them: `\r` removed, NFC-normalised (the same letter composed or decomposed counts
    alike), a trailing newline adds no line."""
    lines = [unicodedata.normalize("NFC", ln.rstrip("\r")) for ln in raw.decode("utf-8").split("\n")]
    if lines and lines[-1] == "":
        lines = lines[:-1]
    return lines


# ── tables ───────────────────────────────────────────────────────────────────────────────────────
_SEP = re.compile(r"^:?-{3,}:?$")
_FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,})(.*)$")
_ATX = re.compile(r"^ {0,3}#{1,6}(?:[ \t]|$)")


def _cells(line):
    """Cells of a Markdown table row: outer pipes dropped, split at a `|` with no backslash before it, whitespace collapsed."""
    s = line.strip()
    s = s[1:] if s.startswith("|") else s
    s = s[:-1] if s.endswith("|") and not s.endswith("\\|") else s
    return [re.sub(r"\s+", " ", c).strip() for c in re.split(r"(?<!\\)\|", s)]


def _indent(line):
    s = line.expandtabs(4)
    return len(s) - len(s.lstrip(" "))


def _tables(lines):
    """[(section, [(line number, row)])]: a table is a line that starts with `|` (indented less than 4 columns) and every line
    right below it that still holds a `|`. `section` is the text of the last level-2 heading above it, without the `## `
    (None before the first one). Fenced blocks and lines indented 4 or more are not tables; a blank line, an ATX heading or a
    line with no `|` ends a table."""
    out, cur, sec, fence = [], None, None, None
    for n, line in enumerate(lines, 1):
        m = _FENCE.match(line)
        if fence:
            if m and m.group(1)[0] == fence[0] and len(m.group(1)) >= len(fence) and not m.group(2).strip():
                fence = None
            continue
        if m and not (m.group(1)[0] == "`" and "`" in m.group(2)):
            fence, cur = m.group(1), None
            continue
        if line.startswith("## "):
            sec, cur = line[3:].strip(), None
            continue
        if _ATX.match(line) or _indent(line) >= 4:
            cur = None
        elif cur is not None and "|" in line:
            cur[1].append((n, line))
        elif line.lstrip().startswith("|"):
            cur = (sec, [(n, line)])
            out.append(cur)
        else:
            cur = None
    return out


def _check_table(rows, names, width, enums, no_empty, decorations=None):
    """[(line, class, reason)] of one table against `names` (header text and order) or, when `names` is None, `width` cells.
    A table of an entry (`names`) needs a data row; an uncovered table checked by the `table` fallback does not."""
    n0, head = rows[0]
    got = _cells(head)
    k = len(names) if names else width
    if names and got != list(names):
        return [(n0, "table.header", "header is %s, the template wants %s" % (" | ".join(got), " | ".join(names)))]
    if not names and len(got) != k:
        return [(n0, "table.header", "header has %d cells, the template wants %d" % (len(got), k))]
    if len(rows) < 2:
        return [(n0, "table.separator", "no separator row right under the header (%d columns)" % k)]
    n, sep = rows[1]
    c = _cells(sep)
    if len(c) != k or not all(_SEP.match(x) for x in c):
        return [(n, "table.separator", "the row under the header must be a separator of %d columns (only - and :)" % k)]
    out = []
    if len(rows) == 2 and names:
        out.append((n0, "table.empty", "the table has no data row"))
    for n, line in rows[2:]:
        c = _cells(line)
        if len(c) != k:
            out.append((n, "table.row_width", "row has %d cells, the table wants %d%s" % (
                len(c), k, " (a `|` inside a cell, code spans included, is written `\\|`)" if len(c) > k else "")))
        elif no_empty and not all(c):
            out.append((n, "table.cell_empty", "row has an empty cell (cell %s)" % ", ".join(
                str(i + 1) for i, x in enumerate(c) if not x)))
        elif names:
            for col, allowed in (enums or {}).items():
                value = c[names.index(col)]
                for rx in (decorations or {}).get(col, ()):      # a decoration is taken off wherever it sits, in any case
                    value = rx.sub("", value)
                if value.strip() not in allowed:
                    out.append((n, "table.enum", "column %s holds `%s`, allowed: %s" % (col, c[names.index(col)], " / ".join(allowed))))
                    break
    return out


def _table_problems(lines, p):
    out = []
    tabs = _tables(lines)
    covered = set()
    for entry in p["tables"]:
        rx = re.compile(entry["heading"])
        mine = [t for t in tabs if t[0] is not None and rx.search(t[0])]
        covered.update(id(t) for t in mine)
        if len(mine) != 1:
            out.append((0, "table.count", "wants exactly one table under a heading matching /%s/, found %d" % (entry["heading"], len(mine))))
            continue
        out.extend(_check_table(mine[0][1], entry["columns"], None, entry.get("enums"), p["no_empty_cells"], entry.get("decorations")))
    table = p["table"]
    if table:
        for t in tabs:
            if id(t) not in covered:
                out.extend(_check_table(t[1], None, table["columns"], None, p["no_empty_cells"]))
        if table["required"] and not tabs:
            out.append((0, "table.required", "the ledger must hold at least one table"))
    elif p["table_own_width"]:
        # width only: the header sets the width, nothing else is asked of the cells (`no_empty_cells` belongs to the tables
        # an entry covers and to the `table` fallback)
        for t in tabs:
            if id(t) not in covered:
                out.extend(_check_table(t[1], None, len(_cells(t[1][0][1])), None, False))
    return out


# ── problems ─────────────────────────────────────────────────────────────────────────────────────
def problems_classified(text, profile=None):
    """[(line or 0, class, reason)]: `problems` with a stable class per rule, the unit parity with another gate is judged in.
    `text` is bytes (counted as read) or str."""
    p = profile or ledger_profile()
    lang = p.get("language", "vi")
    raw = text if isinstance(text, bytes) else text.encode("utf-8", "replace")
    try:
        lines = _lines(raw)
    except UnicodeDecodeError as e:
        return [(0, "encoding", "not valid UTF-8: broken byte at offset %d" % e.start)]
    lim = p["limits"]
    out = []
    if lim["lines"] is not None and len(lines) > lim["lines"]:
        out.append((0, "size.lines", _Over(messages.text("cs.over_lines", lang, len(lines), lim["lines"]), "lines", len(lines), lim["lines"])))
    if len(raw) > lim["bytes"]:
        out.append((0, "size.bytes", _Over(messages.text("cs.over_bytes", lang, len(raw), lim["bytes"]), "bytes", len(raw), lim["bytes"])))
    if p.get("inject") and inject_chars(raw) > INJECT_MAX_CHARS:
        out.append((0, "size.inject_chars", "%d characters > %d with current_state.inject on: the SessionStart hook cannot inject it "
                    "whole; move detail to a page, a spec or a decision" % (inject_chars(raw), INJECT_MAX_CHARS)))
    forbid = [(i, SIGNS[i]) for i in sdlc_config.HISTORY_IDS[:-1] if i in p["forbid"]]
    pats = [(q["id"], re.compile(q["regex"])) for q in p["forbid_patterns"]]
    # the date group of a label is a clock, not history; a regex that ran over its timer exempts nothing
    found, over = _scan_labels(lines, _label_rx(p)) if p.get("labels") and forbid else ([], False)
    dated = {}
    for i, _lab, d, span in found:
        if d is not None and _ISO_SHAPE.fullmatch(d):  # only `YYYY-MM-DD`: a wider group would hide more than a date
            dated.setdefault(i, []).append(span)
    slow = " (current_state.labels regex ran over %d s: no label date exempted)" % LABEL_SECONDS if over else ""
    for i, ln in enumerate(lines, 1):
        if len(ln) > lim["line_chars"]:
            out.append((i, "size.line_chars", messages.text("cs.long_line", lang, len(ln), lim["line_chars"])))
        spans = dated.get(i, ())
        for sid, (rx, veto) in forbid:
            m = next((x for x in rx.finditer(ln) if not (veto and veto(ln, x))
                      and not any(s <= x.start() and x.end() <= e for s, e in spans)), None)
            if m:
                out.append((i, "history." + sid, messages.text("cs.history_sign", lang, messages.text("cs.sign." + sid, lang), m.group(0), slow)))
        for pid, rx in pats:
            m = rx.search(ln)
            if m:
                out.append((i, "pattern." + pid, messages.text("cs.forbidden", lang, pid, m.group(0))))
        if "history_heading" in p["forbid"] and HEADING_HISTORY.search(ln):
            out.append((i, "history.history_heading", messages.text("cs.history_heading", lang)))
    return out + _table_problems(lines, p)


def problems(text, profile=None):
    """[(số dòng hoặc 0, lý do)] — rỗng = đạt khuôn."""
    return [(n, why) for n, _cls, why in problems_classified(text, profile)]


def size_warning(text, profile=None, name=None):
    """One `WARNING ...` line, or None. The soft side of the size caps: a ledger at or under its hard caps whose bytes (or lines, when
    the profile has a line cap) have reached `limits.warn_ratio` of the cap. Over a cap it is None: `problems` already fails there.
    When both caps are near, the larger share names the line, so a caller never prints two. The one function behind the shape check,
    the diff gate and the edit hook; it never decides a return code. `name` is the file the line is about (default: the profile's ledger)."""
    p = profile or ledger_profile()
    lim = p["limits"]
    ratio = lim.get("warn_ratio")
    raw = text if isinstance(text, bytes) else text.encode("utf-8", "replace")
    try:
        lines = _lines(raw)
    except UnicodeDecodeError:
        return None
    dims = [("bytes", len(raw), lim["bytes"])]
    if lim["lines"] is not None:
        dims.append(("lines", len(lines), lim["lines"]))
    if ratio is None or any(n > cap for _name, n, cap in dims):
        return None
    near = [(n / cap, what, n, cap) for what, n, cap in dims if n / cap >= ratio]
    if not near:
        return None
    _share, what, n, cap = max(near)
    return ("WARNING %s: %d/%d %s (%g%% of the cap, warning from %g%%): overwrite lines, do not append"
            % (name or p["path"], n, cap, what, n * 1000 // cap / 10, round(ratio * 100, 6)))


# ── dated labels ─────────────────────────────────────────────────────────────────────────────────
# With `labels` set, each match of its regex on a ledger line is a label ("*chưa kiểm từ 2026-10-12*"): the `date` group is the
# day it was first left unchecked. The date is a clock, not history: a history sign wholly inside the group is not a sign. A label
# with no date, one older than `max_age_days` or one dated after tomorrow is a `WARNING`; nothing here decides a return code.
LABEL_SECONDS = 2


def _label_rx(p):
    lab = p.get("labels")
    return re.compile(unicodedata.normalize("NFC", lab["regex"])) if lab else None


def _scan_labels(lines, rx):
    """([(line, label, date text or None, (start, end) of the date group or None)], ran over). The regex runs under a timer of
    `LABEL_SECONDS` (`sdlc_config.time_boxed`). A match with no letter outside its date group (a lookaround or a blank around a
    bare date, an empty match) carries no marker word and is not a label."""
    key = (rx.pattern, tuple(lines))
    if key in _SCANNED:                    # the shape check and the warnings read the same file: one scan, one timer
        return _SCANNED[key]
    _SCANNED.clear()
    _SCANNED[key] = got = _scan_labels_once(lines, rx)
    return got


_SCANNED = {}


def _scan_labels_once(lines, rx):
    out = []

    def run():
        for i, ln in enumerate(lines, 1):
            for m in rx.finditer(ln):
                d = m.group("date")
                s, e = m.span("date") if d is not None else (m.end(), m.end())
                if any(c.isalpha() for c in ln[m.start():s] + ln[e:m.end()]):
                    out.append((i, m.group(0), d, (s, e) if d is not None else None))
    return (out, False) if sdlc_config.time_boxed(run, LABEL_SECONDS) else ([], True)   # ran over: no label, no exempted date


_ISO_SHAPE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}")


def _day(s):
    """The calendar day of `s` written exactly `YYYY-MM-DD` (ASCII digits), or None."""
    import datetime
    if s is None or not _ISO_SHAPE.fullmatch(s):
        return None
    try:
        return datetime.date(int(s[:4]), int(s[5:7]), int(s[8:]))
    except ValueError:
        return None


def labels(text, profile=None, today=None):
    """([(line, label, day or None, age in days or None)], ran over) of the ledger `text` (bytes or str) under the profile's
    `labels`; ([], False) when it has none or the text is not UTF-8. `today` defaults to the local date."""
    import datetime
    p = profile or ledger_profile()
    rx = _label_rx(p)
    if rx is None:
        return [], False
    raw = text if isinstance(text, bytes) else text.encode("utf-8", "replace")
    try:
        lines = _lines(raw)
    except UnicodeDecodeError:
        return [], False
    found, over = _scan_labels(lines, rx)
    today = today or datetime.date.today()
    out = []
    for i, lab, d, _span in found:
        day = _day(d)
        out.append((i, lab, day, (today - day).days if day else None))
    return out, over


def label_warnings(text, profile=None, name=None, today=None):
    """The `WARNING` lines of the labels of `text`: no date, older than `max_age_days`, dated after tomorrow, or the regex ran
    over its timer. `name` is the file the lines are about (default: the profile's ledger)."""
    p = profile or ledger_profile()
    if not p.get("labels"):
        return []
    name = name or p["path"]
    n = p["labels"]["max_age_days"]
    found, over = labels(text, p, today)
    if over:
        return ["WARNING %s: current_state.labels regex ran over %d s: labels not checked" % (name, LABEL_SECONDS)]
    out = []
    for i, lab, day, age in found:
        lab = lab if len(lab) <= 80 else lab[:77] + "..."
        if day is None:
            out.append("WARNING %s:%d: label %r has no valid date, a real YYYY-MM-DD (current_state.labels): write the day it was first left "
                       "unchecked" % (name, i, lab))
        elif age > n:
            out.append("WARNING %s:%d: label %r is %d days old (over %d): check it again, then remove the label or correct the line"
                       % (name, i, lab, age, n))
        elif age < -1:
            out.append("WARNING %s:%d: label %r is dated after tomorrow: write the day it was first left unchecked" % (name, i, lab))
    return out


def file_warnings(text, profile=None, name=None, today=None):
    """Every `WARNING` line of one ledger file: `size_warning`, then `label_warnings`."""
    w = size_warning(text, profile, name)
    return ([w] if w else []) + label_warnings(text, profile, name, today)


# ── pages ────────────────────────────────────────────────────────────────────────────────────────
# With `pages` set the ledger is the index (`path`) plus every file of one flat directory that the glob matches. The index is
# the only way in: a page it does not point to is an orphan. A pointer is a path written from the repo root
# (`kb/state/x.md`) or a Markdown link target relative to the file that holds it; one that lands in the pages directory must
# name a page, else it is dead.
def is_page(rel, p):
    """`rel` (as git prints it) is a page path of the profile `p` (whether or not the file exists)."""
    return bool(p.get("pages")) and sdlc_config.glob_match(p["pages"], rel)


def page_profile(p):
    """The profile a page is judged by: the page cap, the index's history signs and patterns, no table check (tables belong to the index),
    no inject cap (only the index is injected at SessionStart)."""
    return dict(p, limits=p["page_limits"], tables=[], table=None, table_own_width=False, inject=False)


def list_pages(root, p):
    """([(rel, bytes)], [(rel, 0, class, reason)]) of the pages on disk under `root`: every name of the pages directory that
    the glob matches, by name. One that is not a regular file (a directory, a symlink) is a problem, not a page, and so is a
    pages directory reached through a symlink (it would read pages from outside the tree)."""
    if not p.get("pages"):
        return [], []
    d = sdlc_config.page_dir(p["pages"])
    base = root or os.getcwd()
    directory = os.path.join(base, *d.split("/"))
    if os.path.isdir(directory) and os.path.realpath(directory) != os.path.join(os.path.realpath(base), *d.split("/")):
        return [], [(d, 0, "pages.not_file", "the pages directory is (or sits under) a symlink: pages are read from the tree only")]
    try:
        names = sorted(os.listdir(directory))
    except OSError:
        return [], []
    got, probs = [], []
    for n in names:
        rel = d + "/" + n
        if not is_page(rel, p):
            continue
        full = os.path.join(root or os.getcwd(), *rel.split("/"))
        if os.path.islink(full) or not os.path.isfile(full):
            probs.append((rel, 0, "pages.not_file", "matches current_state.pages but is not a regular file (a directory or a symlink)"))
            continue
        try:
            with open(full, "rb") as f:
                got.append((rel, f.read()))
        except OSError:
            probs.append((rel, 0, "pages.not_file", "matches current_state.pages but cannot be read"))
    return got, probs


_LINK = re.compile(r"\]\(\s*(?:<([^<>\n]+)>|([^)\s<>]+))")
_BARE_STOP = "\\s`'\"()<>\\[\\]{}|*,;!?"


def pointers(rel, text, d):
    """[(line, target)] of the pointers into the directory `d` in the ledger file `rel`: repo-root paths that start with `d/`, and
    Markdown link targets that resolve there from the file's own directory (from the repo root when they start with `/`, as on
    GitHub; `<…>` may hold spaces). `#anchor` and `?query` are dropped; a mention of
    the directory itself (`kb/state/`, `kb/state/*.md`) names no page and is not a pointer."""
    from urllib.parse import unquote
    bare = re.compile(r"(?<![\w./-])" + re.escape(d) + r"/[^" + _BARE_STOP + r"]*")
    here = posixpath.dirname(rel)
    out = []
    for n, ln in enumerate(text.split("\n"), 1):
        cands = [m.group(0) for m in bare.finditer(ln)]
        for m in _LINK.finditer(ln):
            t = unquote(m.group(1) or m.group(2)).strip()
            if "://" in t or t.startswith(("mailto:", "#", "//")):
                continue
            cands.append(t.lstrip("/") if t.startswith("/") else posixpath.join(here, t))
        for c in cands:
            c = re.split(r"[#?]", c, 1)[0].rstrip(".:")
            c = posixpath.normpath(c) if c else c
            if c.startswith(d + "/"):
                out.append((n, c))
    return out


def ledger_problems(root, p, index):
    """[(rel, line or 0, class, reason)] of the whole ledger: the index (`index`: its bytes, None when it cannot be read) and,
    when the profile has pages, every page under the page cap, every page that is not a regular file, every orphan page and
    every dead pointer of any ledger file. Without `pages` it is the index's problems alone, as before pages existed."""
    led = p["path"]
    out = [(led, n, c, w) for n, c, w in problems_classified(index, p)] if index is not None else []
    if not p.get("pages"):
        return out
    pages, bad = list_pages(root, p)
    out.extend(bad)
    pp = page_profile(p)
    for rel, raw in pages:
        out.extend((rel, n, c, w) for n, c, w in problems_classified(raw, pp))
    d = sdlc_config.page_dir(p["pages"])
    names = {unicodedata.normalize("NFC", rel): rel for rel, _raw in pages}   # the text is read as NFC; a name on disk may be NFD
    from_index = set()
    for rel, raw in ([(led, index)] if index is not None else []) + pages:
        text = unicodedata.normalize("NFC", raw.decode("utf-8", "replace"))
        for n, target in pointers(rel, text, d):
            if rel == led:
                from_index.add(target)
            if target not in names:
                out.append((rel, n, "pages.dead_pointer", "points to %s, which is not a page (missing, not a regular file, or not "
                            "matched by current_state.pages %s)" % (target, p["pages"])))
    for rel in sorted(names[k] for k in set(names) - from_index):
        out.append((rel, 0, "pages.orphan", "orphan page: %s does not point to it, and the index is the only way in" % led))
    return out


def render_ledger(probs, root=None, lang="vi"):
    """`render` of each ledger file that has a problem, in the order the files first appear, in `lang`."""
    files = []
    for rel, *_rest in probs:
        if rel not in files:
            files.append(rel)
    out = [render(rel, [(n, c, w) for r, n, c, w in probs if r == rel], root, lang) for rel in files]
    if any(c.startswith("pages.") for _r, _n, c, _w in probs):
        out.append("Pages: the index points to every page by its path; a pointer into the pages directory names a page that exists.")
    return "\n".join(out)


def ledger_warnings(root, p, index, name=None):
    """The `WARNING` lines of the index (`name`: the file it is about, default the profile's index) and of each page: its size
    under the page cap, then its labels (`file_warnings`)."""
    out = file_warnings(index, p, name) if index is not None else []
    if p.get("pages"):
        pp = page_profile(p)
        out.extend(w for rel, raw in list_pages(root, p)[0] for w in file_warnings(raw, pp, rel))
    return [w for w in out if w]


# ── the diff gate ────────────────────────────────────────────────────────────────────────────────
def _read_ledger(root, rel):
    """bytes of the ledger on disk, or None when it cannot be opened."""
    try:
        with open(os.path.join(root or os.getcwd(), *rel.split("/")), "rb") as f:
            return f.read()
    except OSError:
        return None


def exemption(body, profile=None):
    """The reason of the exemption line of `body`, or None. The line is a `no_state_change` token and then a reason of at least
    `exempt.min_reason_chars` characters (stripped). A token with nothing after it takes the next line that has text as its
    reason, as 1.0.0 did (a reason on the line below the token is an exemption). Only the first token is looked at."""
    p = profile or ledger_profile()
    toks = p["no_state_change"]
    if not toks or not body:
        return None
    need = p["exempt"]["min_reason_chars"]
    # `\s*` after the token crosses the line break, as in 1.0.0: the reason may sit on the next line (so may a heading)
    rx = re.compile(r"^\s*(?:%s)\s*(%s)$" % ("|".join(re.escape(x) for x in toks), ".+" if need else ".*"), re.M)
    m = rx.search(body)
    if not m:
        return None
    reason = m.group(1).strip()
    return reason if len(reason) >= need else None


def decide(paths, body, profile=None, ledger=None, root=None):
    """(rc, message), rc 0 = pass. Pure apart from reading the ledger: the same contract as `decide(paths, body)` of a repo gate
    script, which is how `open_pr.py` calls it.

    Applies only when the profile watches something and a changed path starts with a watched prefix and no `watch_exclude`
    prefix, or is a ledger file (the index or, with `pages`, a page). Then the whole ledger (the `ledger` argument for the
    index, else the file under `root`; pages under `root`) must pass `ledger_problems`; a diff that carries any ledger file
    passes after that, a watched change without one passes only with an exemption line, and an exemption never excuses the
    shape check.
    """
    p = profile or ledger_profile()
    if not p["watch"]:
        return 0, "the profile watches no path: the diff gate does not apply"
    led = p["path"]
    excl = p.get("watch_exclude") or ()
    hits = sorted(x for x in paths if any(x.startswith(w) for w in p["watch"]) and not any(x.startswith(e) for e in excl))
    touched = led in paths
    mine = sorted(x for x in paths if x == led or is_page(x, p))
    if not hits and not mine:
        return 0, "no watched path and no ledger change: the diff gate does not apply"
    if ledger is None:
        ledger = _read_ledger(root, led)
    if isinstance(ledger, str):
        ledger = ledger.encode("utf-8")
    if ledger is None and touched:
        return 1, "%s is in the diff but cannot be read (deleted?): restore it, or fix its content instead of deleting it" % led
    probs = ledger_problems(root, p, ledger)
    if probs:
        return 1, render_ledger(probs, root, p.get("language", "vi"))
    warns = ledger_warnings(root, p, ledger)
    tail = "".join("\n" + w for w in warns)
    if mine and not p.get("pages"):
        return 0, "%s is in the diff and passes the template%s" % (led, tail)
    if mine:
        return 0, "%s %s in the diff and the ledger passes the template%s" % (
            ", ".join(mine[:4]) + (" …" if len(mine) > 4 else ""), "is" if len(mine) == 1 else "are", tail)
    why = exemption(body, p)
    if why is not None:
        return 0, "exempted: %s%s" % (why[:80], tail)
    miss = ("no file of the ledger (%s or a page %s) is" % (led, p["pages"])) if p.get("pages") else "%s is not" % led
    return 1, ("%d changed path(s) under %s but %s in the diff.\n  %s\n"
               "Update the ledger, or put a line in the PR body that starts with one of: %s"
               % (len(hits), ", ".join(p["watch"]), miss,
                  "\n  ".join(hits[:8]) + ("\n  …" if len(hits) > 8 else ""), " | ".join(p["no_state_change"])))


def load_external(root, rel):
    """`decide(paths, body)` of the repo script at `rel` under `root`, or None when there is no such file. Running it is the same
    trust as running that repo's tests (`kb.py config check` lists it for review)."""
    path = os.path.join(root, *rel.split("/"))
    if not os.path.isfile(path):
        return None
    import importlib.util
    spec = importlib.util.spec_from_file_location("repo_current_state_gate", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.decide


def run_gate(profile, paths, body, root, script_root=None):
    """(rc, message) of the diff gate in the mode of `profile["gate"]`: `builtin`, `off`, or `external:<path>` (a missing script
    is a block, not a pass: a gate that was asked for and cannot run must not wave a PR through). The ledger is read under `root`,
    the external script under `script_root` (default `root`; CI points it at the base ref's copy)."""
    gate = profile["gate"]
    if gate == "off":
        return 0, "current_state.gate is off"
    if gate.startswith("external:"):
        try:
            ext = load_external(script_root or root, gate[len("external:"):])
            if ext is None:
                return 1, "current_state.gate is %s but that file does not exist" % gate
            return ext(paths, body)
        except Exception as e:                                    # a gate that cannot run must not wave a PR through
            return 1, "current_state.gate %s failed to run: %s: %s" % (gate, type(e).__name__, " ".join(str(e).split())[:200])
    return decide(paths, body, profile, root=root)


class _Over(str):
    """The reason of a `size.lines` / `size.bytes` problem, carrying its unit and numbers: `render` reads them, never the text."""
    def __new__(cls, text, unit, got, cap):
        s = str.__new__(cls, text)
        s.unit, s.got, s.cap = unit, got, cap
        return s

    def __getnewargs__(self):                       # copy, deepcopy and pickle rebuild it with its numbers
        return (str(self), self.unit, self.got, self.cap)


# A reason handed in as plain text (a caller that builds its own) is read by its `N > M` numbers and the unit of either language
_OVER_TEXT = re.compile(r"^(?:vượt trần (byte|dòng)|over the (byte|line) cap): (\d+) > (\d+)")
BASE_REF = "origin/main"
ADDED_MAX = 20
ADDED_CHARS = 100
GIT_TIMEOUT = 10
_CONTROL = re.compile(r"[\x00-\x1f\x7f]")


def _git_out(root, *args):
    """stdout of `git -C root args` as text, or None for anything but a clean run (no git, not a repo, no such ref, a timeout).
    A run past GIT_TIMEOUT seconds is killed with its whole process group: a child git forked would otherwise hold the pipe open."""
    try:
        p = subprocess.Popen(("git", "-C", root) + args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL,
                             env=dict(os.environ, GIT_TERMINAL_PROMPT="0"), start_new_session=True)
    except (OSError, ValueError, subprocess.SubprocessError):      # ValueError: a NUL or a lone surrogate in an argument
        return None
    try:
        out, _ = p.communicate(timeout=GIT_TIMEOUT)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except (OSError, AttributeError):
            p.kill()
        p.communicate()
        return None
    return out.decode("utf-8", "replace") if p.returncode == 0 else None


def added_lines(path, root=None):
    """([(line number, text)], base ref) of the lines `path` has on disk that the merge-base of HEAD and `origin/main` does not, or None
    when that cannot be told: no git, not a repository, no `origin/main`, no merge-base (a shallow clone), a path outside the
    repository, a timeout. Never raises: the message that asks for this is already a failure, and must still arrive."""
    top = (root or _git_out(os.getcwd(), "rev-parse", "--show-toplevel") or "").strip()
    if not top:
        return None
    mb = (_git_out(top, "merge-base", "HEAD", BASE_REF) or "").strip()
    if not mb:
        return None
    full = path if os.path.isabs(path) else os.path.join(top, *path.split("/"))
    out = _git_out(top, "-c", "core.quotePath=false", "diff", "-U0", "--no-color", "--no-ext-diff", "--no-renames", mb, "--", full)
    if not out:
        return None
    got, n = [], 0
    for ln in out.split("\n"):
        m = re.match(r"@@ -\S+ \+(\d+)(?:,\d+)? @@", ln)
        if m:
            n = int(m.group(1))
        elif n and ln.startswith("+"):
            got.append((n, ln[1:]))
            n += 1
    return (got, BASE_REF) if got else None


def render(path, probs, root=None, lang="vi"):
    """The report of `probs` for `path`, in `lang`: [(line or 0, class, reason)] as `problems_classified` gives them, or
    [(line or 0, reason)] as `problems` does."""
    M = lambda key, *args: messages.text(key, lang, *args)  # noqa: E731
    lines = [M("cs.render_head", path, len(probs))]
    whys = [p[-1] for p in probs]
    for (n, *_c), why in zip(probs[:50], whys):
        lines.append("- %s%s" % (M("cs.line", n) if n else "", why))
    if len(probs) > 50:
        lines.append(M("cs.more_problems", len(probs) - 50))
    for why in whys:
        if isinstance(why, _Over):
            bytes_, got, cap = why.unit == "bytes", why.got, why.cap
        else:
            m = _OVER_TEXT.match(why)
            if not m:
                continue
            bytes_, got, cap = "byte" in (m.group(1) or m.group(2)), int(m.group(3)), int(m.group(4))
        lines.append(M("cs.over_by", got - cap, M("cs.unit_bytes" if bytes_ else "cs.unit_lines"), got, cap))
    add = added_lines(path, root)
    if add:
        got, base = add
        lines.append(M("cs.added_head", len(got), path, base))
        for n, text in got[:ADDED_MAX]:
            text = _CONTROL.sub("?", text)                          # a CR or ESC in the file must not repaint the log
            lines.append(M("cs.added_line", n, text if len(text) <= ADDED_CHARS else text[:ADDED_CHARS] + "…"))
        if len(got) > ADDED_MAX:
            lines.append(M("cs.added_more", len(got) - ADDED_MAX))
    lines.append(M("cs.fix"))
    return "\n".join(lines)
