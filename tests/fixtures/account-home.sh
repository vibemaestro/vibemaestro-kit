# shellcheck shell=bash
# =============================================================================
# A suite must not read the machine's own Claude Code directory: the ancestors a plugin copy sees from below the suite
# =============================================================================
# The owner's-dialog check of baton.py and the answerer check of the brain read `.claude` of every place the running session may take
# settings from: HOME, the account's home from the password database, CLAUDE_CONFIG_DIR, and the HOME of EVERY ancestor process,
# which they read from /proc/<pid>/environ, the environment the process was started with. A subshell shows the suite shell's
# initial environment, so a suite that only sets HOME after it starts still shows the launcher's real one. A suite keeps off the
# machine with three parts: the plugin copy it runs is isolated (its account home and its ancestor walk stop in the scratch tree),
# the suite starts itself again with HOME=/nonexistent (its first lines; the idiom of the brain-owner suite), and a [Y] case
# measures the result with
#   home_leaks <scripts dir> <module> <function>   the HOME of each ancestor that module's walk sees from below this suite, outside
#                                                  the scratch tree and not /nonexistent: [Y] wants none, and a control that starts
#                                                  a bash with another HOME above the call wants it named
# (defines functions only; sourced after lib.sh, which sets FIXTURE_SCRATCH)

home_leaks() {  # home_leaks <scripts dir> <module> <function>
  cat > "$TMP/home_leaks.py" <<'PY'
import importlib, os, sys
sys.path.insert(0, sys.argv[1])
anc = getattr(importlib.import_module(sys.argv[2]), sys.argv[3])()
scratch = os.environ["FIXTURE_SCRATCH"]
print(len(anc) > 0, [h for *_, h in anc if h and not h.startswith(scratch) and h != "/nonexistent"])
PY
  # the shape of a suite's own call, `( cd … && python3 baton.py … )`: a forked subshell above the python (bash does not fork one
  # for a lone command in $( ), which would hide exactly the process that carries the suite's initial environment), and a bash
  # between them, the case's own ancestor
  ( cd "$TMP" && bash -c 'python3 "$0" "$1" "$2" "$3"; exit $?' "$TMP/home_leaks.py" "$1" "$2" "$3" )
}
