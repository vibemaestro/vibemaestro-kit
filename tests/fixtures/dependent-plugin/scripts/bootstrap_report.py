#!/usr/bin/env python3
"""bootstrap_report: the lines a dependent plugin adds to the coordinator bootstrap's machine report (test fixture).

The sdlc kit run `kit:coordinator-bootstrap` runs `scripts/bootstrap_report.py` of every installed plugin that declares a
dependency on vibemaestro-sdlc and keeps only the lines that start with `CHECK `. This one prints one line that depends on the
environment, one fixed line, and a line without the prefix that the report must drop. Exit 0 always.
"""
import os

print("CHECK fixture-env: %s" % ("ok" if os.environ.get("FIXTURE_REPORT") else "MISSING"))
print("fixture noise: not a CHECK line")
print("CHECK fixture-next: info")
