#!/usr/bin/env python3
"""UserPromptSubmit of the plugin vibemaestro-sdlc: a prompt that starts with `/init` in a repo that lacks `kb/` or the project's brain
gets the kit's setup added as context (`vsdlc.init_hint`). Every other prompt returns here, before the plugin's library is loaded.
Never fails the prompt and adds nothing on any error: exit 0."""
import json
import os
import re
import sys

sys.dont_write_bytecode = True

try:
    payload = json.loads(sys.stdin.read())
    prompt = payload.get("prompt")      # the same test as vsdlc.INIT_PROMPT, run before vsdlc is imported
    if isinstance(prompt, str) and re.match(r"\s*/init(?:\s|$)", prompt):
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import vsdlc
        vsdlc.init_hint(payload)
except BaseException:
    pass
sys.exit(0)
