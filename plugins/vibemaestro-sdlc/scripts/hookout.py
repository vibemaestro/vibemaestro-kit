"""Đầu ra và dedup dùng chung của hook plugin vibemaestro-sdlc — CHỈ thư viện chuẩn, không import module nào của plugin.

Tách riêng để `import_failed` chạy được cả khi `vsdlc.py` / `rules.py` không nạp nổi (file hỏng, lỗi cú pháp, ném lỗi lúc
import): hook vẫn fail-open (rc 0, công cụ không bị chặn) nhưng NÓI TO một lần mỗi phiên thay vì im lặng. Tương thích Python 3.8+.
"""
import hashlib
import json
import os
import re
import sys

PLUGIN_NAME = "vibemaestro-sdlc"


def session_dir(sid):
    return os.path.join(os.environ.get("TMPDIR", "/tmp"), "vsdlc-" + re.sub(r"[^A-Za-z0-9_-]", "", sid or "")[:64])


def marker_name(kind):
    """Tên file dấu cho `kind`: băm sha1 của NGUYÊN `kind` (đường dẫn repo dài làm tên > 255 byte → OSError → nhắc lặp),
    cộng một đoạn đầu đã làm sạch để người đọc thư mục dấu còn nhận ra là dấu gì. Băm cả `kind` nên hai `kind` khác nhau
    dù cùng đoạn đầu vẫn ra hai tên khác nhau."""
    head = re.sub(r"[^A-Za-z0-9_.-]", "_", kind)[:40]
    return "%s-%s" % (head, hashlib.sha1(kind.encode("utf-8", "replace")).hexdigest()[:20])


def once(kind, sid):
    """True nếu đây là lần đầu `kind` được nói trong phiên `sid` (và ghi dấu). Không có session_id hoặc không
    ghi được dấu thì cứ nói — thà lặp còn hơn im."""
    if not sid:
        return True
    try:
        d = session_dir(sid)
        os.makedirs(d, exist_ok=True)
        m = os.path.join(d, marker_name(kind))
        if os.path.exists(m):
            return False
        open(m, "w").close()
    except OSError:
        return True
    return True


def warn_text(problems):
    """Khối cảnh báo cho model: nêu việc cần làm, không chỉ nêu lỗi."""
    return ("⚠ WARNING plugin %s — this session is running WITHOUT the plugin's rules:\n%s\n"
            "Tell the user in your first reply. Do not invent a process to stand in for the missing part; "
            "tools still run normally. Reinstall the plugin if the error persists." % (PLUGIN_NAME, "\n".join("- " + p for p in problems)))


def short_warn(problems):
    return "%s: %s" % (PLUGIN_NAME, "; ".join(problems))


def config_warn_text(problems):
    """Warning for the model when `.vibemaestro/sdlc.json` is invalid: hooks carry on with defaults and never block."""
    return ("WARNING plugin %s: .vibemaestro/sdlc.json is invalid, so this session runs the hooks with DEFAULT settings "
            "(a tool call is never blocked by this). `kb.py`, the gates and the cores refuse to run until it is fixed:\n%s\n"
            "Tell the user in your first reply and name the keys; run `kb.py config check` for the full list."
            % (PLUGIN_NAME, "\n".join("- %s: %s" % (k, why) for k, why in problems[:12])
               + ("\n- ... and %d more" % (len(problems) - 12) if len(problems) > 12 else "")))


def config_note_text(notes):
    """Warning for the model when `.vibemaestro/sdlc.json` is valid but has keys this plugin ignores (written for a newer plugin,
    or deprecated): everything runs, with those keys at their defaults (rule config-compat)."""
    return ("WARNING plugin %s: .vibemaestro/sdlc.json has keys this plugin does not know, or knows as deprecated; everything runs. "
            "An unknown key is ignored (its setting keeps the plugin's default); a deprecated key is still read during its window, "
            "a removed one is ignored like an unknown key:\n%s\n"
            "Tell the user in your first reply; a newer plugin may read them (claude plugin update vibemaestro-sdlc@vibemaestro)."
            % (PLUGIN_NAME, "\n".join("- %s: %s" % (k, why) for k, why in notes[:12])
               + ("\n- ... and %d more" % (len(notes) - 12) if len(notes) > 12 else "")))


def config_short_note(notes):
    return "%s: .vibemaestro/sdlc.json: %s ignored or deprecated" % (PLUGIN_NAME, ", ".join(k for k, _w in notes[:5]))


def config_short_warn(problems):
    return "%s: .vibemaestro/sdlc.json is invalid (%s); hooks use defaults" % (
        PLUGIN_NAME, ", ".join(k for k, _w in problems[:5]))


def emit(event, ctx="", sysmsg="", extra=None):
    """In MỘT JSON hook. Cảnh báo đi hai đường (additionalContext cho model, systemMessage cho người)
    vì tài liệu không nói trường nào hiện ra ở đâu."""
    out = {}
    h = {"hookEventName": event}
    if ctx:
        h["additionalContext"] = ctx
    if extra:
        h.update(extra)
    if len(h) > 1:
        out["hookSpecificOutput"] = h
    if sysmsg:
        out["systemMessage"] = sysmsg
    if out:
        sys.stdout.write(json.dumps(out, ensure_ascii=False))


def import_failed(event, exc):
    """Gọi từ `except` quanh `import vsdlc` ở ba script hook: cảnh báo (một lần mỗi phiên) rồi trả về để script thoát rc 0.
    Không in stack trace — chỉ tên lỗi và một dòng ngắn của nó. Không bao giờ ném."""
    try:
        if isinstance(exc, KeyboardInterrupt):
            return
        try:
            sid = (json.loads(sys.stdin.read()) or {}).get("session_id")
        except Exception:
            sid = None
        why = " ".join(str(exc).split())[:160]
        msg = "could not load the plugin's hook code (%s%s) — the plugin's rules are NOT delivered in this session" % (
            type(exc).__name__, ": " + why if why else "")
        if once("import-failed", sid):
            emit(event, warn_text([msg]), short_warn([msg]))
    except BaseException:
        pass
