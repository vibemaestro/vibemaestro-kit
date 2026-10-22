#!/bin/bash
# =============================================================================
# The fixtures cannot run git outside their own scratch tree (tests/fixtures/lib.sh git_, gates.sh mk_repo and cm)
# =============================================================================
# Run: bash tests/test-fixture-pin.sh
#
# The incident: a repeated $RANDOM made mk_repo reuse a repository, `git commit -q` printed "On branch ... nothing to commit" on stdout,
# $(mk_repo) returned that text plus the path, cm made the relative directory inside the REAL worktree and git committed there.
# Here a DECOY repository outside the suite's scratch root stands for the real
# worktree and the incident is replayed against it by tests/fixtures/pin-replay.sh, twice:
#   - on the real fixtures: nothing may reach the decoy;
#   - on a copy of the fixtures with TODAY'S behaviour put back (the old git_ and the old mk_repo and cm, appended as overrides): the
#     same replay must reach the decoy. A replay that did not go red there would prove nothing (the instrument check).
# A `git` shim first in PATH records every call that gets through, so "git did not run" is observed, not inferred.
# Real git on throw-away repositories, no gh, no network, no sleep.
# =============================================================================
set -uo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=fixtures/lib.sh
. "$HERE/fixtures/lib.sh"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
DECOY_HOME=$(env -u TMPDIR mktemp -d); DECOY_HOME=$(cd "$DECOY_HOME" && pwd -P)   # outside the scratch root on purpose
trap 'rm -rf "$TMP" "$DECOY_HOME"' EXIT
clean_env "$TMP"

# facts <fixtures dir> — run the replay in a fresh decoy and print its key=value lines
facts() {
  local fx=$1 d="$DECOY_HOME/decoy-$2" s="$TMP/scr-$2"
  mkdir -p "$d" "$s"
  command git init -q -b main "$d"
  ( cd "$d" && echo seed > seed.txt && command git add seed.txt && command git -c user.email=d@d -c user.name=d -c commit.gpgsign=false commit -qm seed )
  ( cd "$d" && env DECOY="$d" SCRATCH="$s" FX="$fx" bash "$HERE/fixtures/pin-replay.sh" 2>"$s/stderr" ); [ "$(grep -c -F 'FIXTURE_SCRATCH is not set in pin-replay.sh' "$s/stderr")" -ge 1 ] && echo stderr_has_suite=1 || echo stderr_has_suite=0
  [ "$(grep -c -F 'clean_env was skipped' "$s/stderr")" -ge 1 ] && echo stderr_has_skip_text=1 || echo stderr_has_skip_text=0
}
val() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n 1; }

echo "== the real fixtures =="
REAL=$(facts "$HERE/fixtures" real)
eq "$(val "$REAL" collision_one_line)" 1 "[A] two mk_repo calls with the same RANDOM: each prints exactly one line"
eq "$(val "$REAL" collision_distinct)" 1 "[A] ...and two different directories"
eq "$(val "$REAL" collision_both_repos)" 1 "[A] ...each its own repository"
eq "$(val "$REAL" origin_one_line)" 1 "[A] mk_origin prints exactly one line"
eq "$(val "$REAL" cm_polluted_rc_nonzero)" 1 "[B] cm with the path of the incident (three lines): non-zero exit"
eq "$(val "$REAL" cm_polluted_decoy_unchanged)" 1 "[B] ...the decoy's HEAD and status are untouched"
eq "$(val "$REAL" cm_polluted_no_dir)" 1 "[B] ...and no directory was made in it"
eq "$(val "$REAL" git_in_polluted_dir_rc)" 97 "[B] git_ -C on that directory once it exists inside the decoy: rc 97 (pin, not cm's own check)"
eq "$(val "$REAL" git_in_polluted_dir_unchanged)" 1 "[B] ...and the decoy is untouched"
eq "$(val "$REAL" c_dash_c_decoy_rc)" 97 "[C] git_ -C <decoy>: rc 97"
eq "$(val "$REAL" c_cwd_decoy_rc)" 97 "[C] git_ with no -C and the decoy as current directory: rc 97"
eq "$(val "$REAL" c_plain_dir_rc)" 97 "[C] git_ -C <directory in the scratch root with no repository of its own>: rc 97"
eq "$(val "$REAL" c_init_outside_rc)" 97 "[C] git_ init outside the scratch root: rc 97"
eq "$(val "$REAL" c_refused_ran_git)" 0 "[C] none of the refused calls reached git (shim log has no call)"
eq "$(val "$REAL" d_good_rc)" 0 "[D] control: cm on a good scratch repository exits 0"
eq "$(val "$REAL" d_good_committed)" 1 "[D] ...and commits (the shim saw the call: the instrument sees git)"
eq "$(val "$REAL" f_two_dash_c_rc)" 97 "[F] a second -C that moves to the decoy: rc 97"
eq "$(val "$REAL" f_git_dir_rc)" 97 "[F] --git-dir pointing at the decoy: rc 97"
eq "$(val "$REAL" f_work_tree_rc)" 97 "[F] --work-tree pointing at the decoy: rc 97"
eq "$(val "$REAL" f_init_dotdot_arg_rc)" 97 "[F] init ../x with -C on the scratch root: rc 97"
eq "$(val "$REAL" f_init_dotdot_missing_rc)" 97 "[F] init with a '..' in the part of the path that does not exist yet: rc 97"
eq "$(val "$REAL" f_init_abs_not_last_rc)" 97 "[F] init with the outside destination before an option: rc 97"
eq "$(val "$REAL" f_push_outside_rc)" 97 "[F] push to a repository outside the scratch root: rc 97"
eq "$(val "$REAL" f_refused_ran_git)" 0 "[F] none of these reached git (shim log has no call)"
eq "$(val "$REAL" f_decoy_unchanged)" 1 "[F] ...and the decoy is untouched"
eq "$(val "$REAL" f_nothing_made_outside)" 1 "[F] ...and no repository was created outside the scratch root"
eq "$(val "$REAL" f_env_git_dir_stays_in_r)" 1 "[F] GIT_DIR set in the environment: the commit lands in the repository named by -C, the decoy is untouched"
eq "$(val "$REAL" f_config_value_rc)" 0 "[F] control: git_ config gpg.program /bin/false (a value that is not a location) is allowed"
eq "$(val "$REAL" f_config_worktree_rc)" 97 "[F] git_ config core.worktree <decoy>: rc 97"
eq "$(val "$REAL" f_refusals_logged)" 1 "[F] every refusal is recorded in the scratch root (what summary() turns into a red suite)"
eq "$(val "$REAL" f_version_ok)" 0 "[F] git_ --version still works (no repository needed)"
eq "$(val "$REAL" f_dotdot_inside_rc)" 0 "[F] control: a '..' that stays inside the scratch root (a sibling worktree) is allowed"
eq "$(val "$REAL" g_symlink_dotdot_rc)" 97 "[G] -C <symlink into the decoy>/..: rc 97 (the '..' is applied to the link's target, as git does)"
eq "$(val "$REAL" g_symlink_rel_rc)" 97 "[G] a relative path through that symlink (worktree add link/wt): rc 97"
eq "$(val "$REAL" g_symlink_word_worktree_rc)" 97 "[G] a plain word that names a symlink out of the root (worktree add el): rc 97"
eq "$(val "$REAL" g_symlink_word_init_rc)" 97 "[G] ...and init el: rc 97"
eq "$(val "$REAL" g_symlink_word_nothing_made)" 1 "[G] ...and the outside directory stayed empty"
eq "$(val "$REAL" g_symlink_nothing_reached_decoy)" 1 "[G] ...and nothing reached the decoy"
eq "$(val "$REAL" e_unset_rc)" 97 "[E] FIXTURE_SCRATCH unset: rc 97, fail closed"
eq "$(val "$REAL" stderr_has_suite)" 1 "[E] ...the message names the suite"
eq "$(val "$REAL" stderr_has_skip_text)" 1 "[E] ...and says clean_env was skipped"

echo "== a refused call cannot hide in a green suite =="
# a stub suite that makes one refused call and then checks nothing else: summary() must still turn it red
STUB="$TMP/refusal-stub.sh"
# the stub must not leave counts in the directory run-all collects them in; the variable is named by assembly (a rule of the
# deleted suite-independence suite; harmless to keep)
RESULTS_VAR=SUITE_; RESULTS_VAR="${RESULTS_VAR}RESULTS_DIR"
{ printf '#!/bin/bash\n. "%s/fixtures/lib.sh"\nSTUB_TMP=$(mktemp -d); clean_env "$STUB_TMP"\n' "$HERE"
  printf 'ok "an assertion that passes"\ngit_ -C "%s" status >/dev/null 2>&1\nsummary\n' "$DECOY_HOME"; } > "$STUB"
SOUT=$(env -u NET_LOG -u "$RESULTS_VAR" bash "$STUB" 2>&1); SRC=$?
eq "$SRC" 1 "[R] a suite whose only wrong act is one refused git_ call: summary() exits 1"
has "$SOUT" "git_ refused 1 call(s) during this suite" "[R] ...and names the refusal"
{ printf '#!/bin/bash\n. "%s/fixtures/lib.sh"\nSTUB_TMP=$(mktemp -d); clean_env "$STUB_TMP"\nok "nothing refused"\nsummary\n' "$HERE"; } > "$STUB"
env -u NET_LOG -u "$RESULTS_VAR" bash "$STUB" >/dev/null 2>&1; eq "$?" 0 "[R] control: the same stub with no refused call exits 0"

echo "== today's behaviour put back (the replay must go red) =="
OLD="$TMP/fx-old"; mkdir -p "$OLD"; cp "$HERE"/fixtures/*.sh "$OLD/"
cat >> "$OLD/lib.sh" <<'OLDGIT'

# today's git_: no pin
git_() { command git -c user.email=t@t -c user.name=t -c commit.gpgsign=false "$@"; }
OLDGIT
cat >> "$OLD/gates.sh" <<'OLDGATES'

# today's mk_repo and cm: a $RANDOM name, git output on stdout, no check of the repository argument
mk_repo() {
  local d="$TMP/r-$1-$RANDOM"
  mkdir -p "$d"; G init -q -b main "$d"
  echo seed > "$d/seed.txt"; G -C "$d" add seed.txt; G -C "$d" commit -qm seed
  echo "$d"
}
cm() {
  mkdir -p "$(dirname "$1/$2")"; echo "$3 $RANDOM" >> "$1/$2"
  G -C "$1" add "$2"; G -C "$1" commit -qm "$3"
}
OLDGATES
BRK=$(facts "$OLD" old)
eq "$(val "$BRK" collision_one_line)" 0 "[A] today: the second mk_repo prints more than one line"
eq "$(val "$BRK" cm_polluted_decoy_unchanged)" 0 "[B] today: cm with the path of the incident commits into the decoy"
eq "$(val "$BRK" git_in_polluted_dir_unchanged)" 0 "[B] today: git_ -C on the directory inside the decoy commits there"
eq "$(val "$BRK" c_dash_c_decoy_rc)" 0 "[C] today: git_ -C <decoy> runs"
eq "$(val "$BRK" c_cwd_decoy_rc)" 0 "[C] today: git_ with the decoy as current directory runs"
ne "$(val "$BRK" c_refused_ran_git)" 0 "[C] today: refused calls reach git (the shim saw them)"
eq "$(val "$BRK" f_two_dash_c_rc)" 0 "[F] today: a second -C to the decoy runs"
eq "$(val "$BRK" f_git_dir_rc)" 0 "[F] today: --git-dir at the decoy runs"
eq "$(val "$BRK" f_init_abs_not_last_rc)" 0 "[F] today: an init outside the scratch root runs"
eq "$(val "$BRK" f_decoy_unchanged)" 0 "[F] today: the decoy is changed by these calls"
eq "$(val "$BRK" f_env_git_dir_stays_in_r)" 0 "[F] today: GIT_DIR in the environment sends the commit to the decoy"
eq "$(val "$BRK" g_symlink_dotdot_rc)" 0 "[G] today: -C <symlink>/.. reaches the decoy"
eq "$(val "$BRK" g_symlink_nothing_reached_decoy)" 0 "[G] today: the decoy is changed through the symlink"
eq "$(val "$BRK" d_good_rc)" 0 "[D] today: the control still works (the replay does not just break everything)"
eq "$(val "$BRK" stderr_has_skip_text)" 0 "[E] today: no message about clean_env"

echo "== no directory name built from \$RANDOM =="
# A name that can repeat is how the incident started; numbers inside file CONTENT (echo "$3 $RANDOM") are fine and are not matched.
# Comment lines are skipped; this suite and the replay are left out because they hold today's old code on purpose, to prove the check goes red.
offenders() { grep -n 'RANDOM' "$@" 2>/dev/null | grep -v -E '^[^:]+:[0-9]+:[[:space:]]*#' | grep -E 'TMP/|mk_repo|mk_feat|mk_origin|mkdir' || true; }
OFF=$(cd "$HERE" && offenders $(ls test-*.sh fixtures/*.sh | grep -v -E '^(test-fixture-pin|fixtures/pin-replay)[.]sh$'))
empty "$OFF" "[S] no fixture or suite names a directory with \$RANDOM"
printf 'd="$TMP/r-x-$RANDOM"; mkdir -p "$d"\n' > "$TMP/plant-random.sh"
nonempty "$(offenders "$TMP/plant-random.sh")" "[S] planted offender: flagged"
printf 'echo "$3 $RANDOM" >> "$1/$2"\n' > "$TMP/plant-content.sh"
empty "$(offenders "$TMP/plant-content.sh")" "[S] planted content use: not flagged"

echo; summary
