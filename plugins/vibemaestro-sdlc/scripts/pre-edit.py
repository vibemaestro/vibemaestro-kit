#!/usr/bin/env python3
"""PreToolUse Edit|Write|NotebookEdit của plugin vibemaestro-sdlc: luật trong plugin khớp `applyTo` cộng
`kb/decisions` của repo đang đứng. Im khi config đặt `hooks: off` (vsdlc.hook_state)."""
import os
import sys

sys.dont_write_bytecode = True      # không đẻ __pycache__ vào thư mục plugin (có thể là bản cài trong cache)
try:
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import vsdlc
except BaseException as _e:
    # import hỏng (rules.py/vsdlc.py nổ…): vẫn rc 0, công cụ không bị chặn — nhưng nói to một lần (hookout chỉ dùng thư viện chuẩn)
    try:
        import hookout
        hookout.import_failed("PreToolUse", _e)
    except BaseException:
        pass
    sys.exit(0)

if __name__ == "__main__":
    sys.exit(vsdlc.run(lambda: vsdlc.pretool_path(sys.stdin.read())))
