#!/bin/bash
# =============================================================================
# Replay of the fixture incident, run by tests/test-fixture-pin.sh (not a suite: it asserts nothing, it prints key=value facts)
# =============================================================================
# Environment: FX = directory holding the lib.sh and gates.sh to test, SCRATCH = this replay's scratch root, DECOY = a git repository
# OUTSIDE that root that stands for the real worktree. The current directory is the decoy, as the real worktree was in the incident.
# A `git` shim first in PATH logs every call that reaches git, so "refused" can be told from "ran and did nothing".
# =============================================================================
set -u
# shellcheck source=lib.sh
. "$FX/lib.sh"
# shellcheck source=gates.sh
. "$FX/gates.sh"
TMP=$(cd "$SCRATCH" && pwd -P)
REALGIT=$(command -v git)
clean_env "$TMP"
mkdir -p "$TMP/gitshim"
printf '#!/bin/sh\necho "$*" >> "%s/git-calls"\nexec "%s" "$@"\n' "$TMP" "$REALGIT" > "$TMP/gitshim/git"; chmod +x "$TMP/gitshim/git"
PATH="$TMP/gitshim:$PATH"; export PATH
CALLS="$TMP/git-calls"; : > "$CALLS"
calls() { wc -l < "$CALLS" | tr -d ' '; }
dgit() { "$REALGIT" -C "$DECOY" "$@"; }               # the decoy is inspected with the real git, never through git_
hs() { printf '%s|%s' "$(dgit rev-parse HEAD)" "$(dgit status --porcelain)"; }   # the decoy's HEAD and status
ld() { ls -A "$DECOY" | sort | tr '\n' ' '; }                                        # what the decoy's top directory holds
fact() { printf '%s=%s\n' "$1" "$2"; }
onoff() { [ "$1" = "$2" ] && echo 1 || echo 0; }

# [A] the collision: the same $RANDOM twice for the same name (a redirect, not $(...), because bash reseeds RANDOM in subshells)
RANDOM=7; mk_repo e1 > "$TMP/o1"; a=$(sed -n '$p' "$TMP/o1"); G -C "$a" checkout -qb feat >/dev/null 2>&1
RANDOM=7; mk_repo e1 > "$TMP/o2"; b=$(sed -n '$p' "$TMP/o2")
fact collision_one_line "$([ "$(wc -l < "$TMP/o1" | tr -d ' ')" = 1 ] && [ "$(wc -l < "$TMP/o2" | tr -d ' ')" = 1 ] && echo 1 || echo 0)"
fact collision_distinct "$([ "$a" != "$b" ] && echo 1 || echo 0)"
fact collision_both_repos "$([ "$("$REALGIT" -C "$a" rev-parse --absolute-git-dir 2>/dev/null)" = "$a/.git" ] && [ "$("$REALGIT" -C "$b" rev-parse --absolute-git-dir 2>/dev/null)" = "$b/.git" ] && echo 1 || echo 0)"
mk_origin o > "$TMP/o3" 2>/dev/null; fact origin_one_line "$([ "$(wc -l < "$TMP/o3" | tr -d ' ')" = 1 ] && echo 1 || echo 0)"

# [B] the incident: cm with the three-line "path" that the second mk_repo returned, from inside the decoy
polluted=$(printf 'On branch feat\nnothing to commit, working tree clean\n%s' "$b")
h0=$(hs); l0=$(ld)
cm "$polluted" a.txt "feat: a" >/dev/null 2>&1; rc=$?
fact cm_polluted_rc_nonzero "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
fact cm_polluted_decoy_unchanged "$(onoff "$(hs)" "$h0")"
fact cm_polluted_no_dir "$(onoff "$(ld)" "$l0")"
# the directory exists inside the decoy now (what cm's mkdir -p used to make): git_ itself must still refuse it
mkdir -p "$polluted"; h1=$(hs)
G -C "$polluted" commit --allow-empty -qm leak >/dev/null 2>&1; fact git_in_polluted_dir_rc "$?"
fact git_in_polluted_dir_unchanged "$(onoff "$(hs)" "$h1")"

# [C] calls aimed at the decoy or at a directory with no repository of its own
: > "$CALLS"
G -C "$DECOY" commit --allow-empty -qm c1 >/dev/null 2>&1; fact c_dash_c_decoy_rc "$?"
(cd "$DECOY" && G commit --allow-empty -qm c2 >/dev/null 2>&1); fact c_cwd_decoy_rc "$?"
mkdir -p "$TMP/plain"; G -C "$TMP/plain" status >/dev/null 2>&1; fact c_plain_dir_rc "$?"
G init -q "$DECOY/inner" >/dev/null 2>&1; fact c_init_outside_rc "$?"
fact c_refused_ran_git "$(calls)"

# [D] control: a good scratch repository still works, and the shim sees git
: > "$CALLS"
r=$(mk_repo d1); cm "$r" a.txt x >/dev/null 2>&1; fact d_good_rc "$?"
fact d_good_committed "$([ "$("$REALGIT" -C "$r" rev-list --count HEAD)" = 2 ] && [ "$(calls)" -gt 0 ] && echo 1 || echo 0)"

# [F] other ways to reach the decoy or to create a repository outside the scratch root (each found by the review of the first version)
: > "$CALLS"; h2=$(hs)
G -C "$TMP" -C "$DECOY" commit --allow-empty -qm twoC >/dev/null 2>&1; fact f_two_dash_c_rc "$?"
G -C "$r" --git-dir="$DECOY/.git" commit --allow-empty -qm gd >/dev/null 2>&1; fact f_git_dir_rc "$?"
G -C "$r" --work-tree="$DECOY" status >/dev/null 2>&1; fact f_work_tree_rc "$?"
G -C "$TMP" init -q ../init-rel-escape >/dev/null 2>&1; fact f_init_dotdot_arg_rc "$?"
G init -q "$TMP/nonexist/../../init-dotdot" >/dev/null 2>&1; fact f_init_dotdot_missing_rc "$?"
G init "$DECOY/inner2" -q >/dev/null 2>&1; fact f_init_abs_not_last_rc "$?"
G -C "$r" push -q "$DECOY" HEAD:refs/heads/pushed >/dev/null 2>&1; fact f_push_outside_rc "$?"
fact f_refused_ran_git "$(calls)"
fact f_decoy_unchanged "$(onoff "$(hs)" "$h2")"
fact f_nothing_made_outside "$([ ! -e "$TMP/../init-rel-escape" ] && [ ! -e "$DECOY/inner2" ] && echo 1 || echo 0)"
# GIT_DIR in the environment sends plain git to another repository whatever -C says; git_ must take it out of git's environment
n0=$("$REALGIT" -C "$r" rev-list --count HEAD)
(export GIT_DIR="$DECOY/.git"; G -C "$r" commit --allow-empty -qm viaenv >/dev/null 2>&1)
fact f_env_git_dir_stays_in_r "$([ "$("$REALGIT" -C "$r" rev-list --count HEAD)" = "$((n0+1))" ] && [ "$(hs)" = "$h2" ] && echo 1 || echo 0)"
G -C "$r" config gpg.program /bin/false >/dev/null 2>&1; fact f_config_value_rc "$?"
G -C "$r" config core.worktree "$DECOY" >/dev/null 2>&1; fact f_config_worktree_rc "$?"
fact f_refusals_logged "$([ "$(wc -l < "$TMP/.pin-refusals" | tr -d ' ')" -ge 9 ] && echo 1 || echo 0)"
fact f_version_ok "$(G --version >/dev/null 2>&1; echo $?)"
# a `..` that stays inside the scratch root is legitimate (ports.sh adds a worktree at "$origin/../wt"): it must NOT be refused
G -C "$r" worktree add -q -b sib "$r/../sibling-wt" >/dev/null 2>&1; fact f_dotdot_inside_rc "$?"

# [G] a symlink inside the scratch root that points into the decoy: `..` after it, and a relative path through it, must be judged where they land
mkdir -p "$DECOY/sub"; ln -s "$DECOY/sub" "$r/link"; h3=$(hs); l3=$(ls -A "$DECOY/sub" | tr '\n' ' ')
G -C "$r/link/.." commit --allow-empty -qm viadd >/dev/null 2>&1; fact g_symlink_dotdot_rc "$?"
G -C "$r" worktree add -q -b w1 link/wt >/dev/null 2>&1; fact g_symlink_rel_rc "$?"
mkdir -p "$DECOY/empty-out"; ln -s "$DECOY/empty-out" "$r/el"
G -C "$r" worktree add -q -b w7 el >/dev/null 2>&1; fact g_symlink_word_worktree_rc "$?"
G -C "$r" init -q el >/dev/null 2>&1; fact g_symlink_word_init_rc "$?"
fact g_symlink_word_nothing_made "$([ -z "$(ls -A "$DECOY/empty-out")" ] && echo 1 || echo 0)"
fact g_symlink_nothing_reached_decoy "$([ "$(hs)" = "$h3" ] && [ "$(ls -A "$DECOY/sub" | tr '\n' ' ')" = "$l3" ] && echo 1 || echo 0)"

# [E] clean_env skipped: no scratch root, git_ must refuse and say why
(unset FIXTURE_SCRATCH; G -C "$r" status >/dev/null); fact e_unset_rc "$?"
