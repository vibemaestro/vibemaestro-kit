#!/usr/bin/env python3
"""SessionStart của plugin vibemaestro-sdlc. Đối số: `core` (lõi quy trình, and rule coordinated-work in a coordinated session), `context`
(danh mục luật + lời nhắc luồng/kb/skill; the old names `loi` and `boi-canh` are still read) hoặc `index` (the repo's current-state index, when
`current_state.inject` is on). Separate hooks because the 10,000-character cap counts EACH string a hook prints. Logic ở vsdlc.py; import hỏng ở đây → rc 0 kèm cảnh báo (hookout.py)."""
import os
import sys

sys.dont_write_bytecode = True
try:
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import vsdlc
except BaseException as _e:
    # import hỏng (rules.py/vsdlc.py nổ…): vẫn rc 0, công cụ không bị chặn — nhưng nói to một lần (hookout chỉ dùng thư viện chuẩn)
    try:
        import hookout
        hookout.import_failed("SessionStart", _e)
    except BaseException:
        pass
    sys.exit(0)

def with_baton_warning(emit):
    """`emit` with baton's one-line permission warning (baton.session_warning) appended to both fields, when there is one.
    The check runs only when the hook speaks (not with `hooks: off`) and lives in baton.py; a failure of it costs the line,
    never the hook."""
    def emit_with_line(event, ctx="", sysmsg="", extra=None):
        try:
            import baton
            line = baton.session_warning()
        except BaseException:
            line = None
        if line:
            ctx, sysmsg = (ctx + "\n\n" + line if ctx else line), (sysmsg + "; " + line if sysmsg else line)
        emit(event, ctx, sysmsg, extra)
    return emit_with_line


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "context"
    if mode in vsdlc.CORE_MODES:                    # one of the two hooks, so the line comes once
        vsdlc.emit = with_baton_warning(vsdlc.emit)
    sys.exit(vsdlc.run(vsdlc.session_start, mode))
