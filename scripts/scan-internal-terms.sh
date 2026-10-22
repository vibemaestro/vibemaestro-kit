#!/bin/bash
# =============================================================================
# Internal-term scanner: looks for names that must not ship in the files or in the history of a git repository
# =============================================================================
# Usage:
#   bash scripts/scan-internal-terms.sh --terms FILE [--skip PATH ...] [--terms FILE2 [--skip PATH ...]]
#                                       [--tree [PATH ...]] [--exclude DIR/ ...] [--history [DIR|REV]] [--ci]
#   KIT_TERMS_FILE=FILE bash scripts/scan-internal-terms.sh --tree
#
#   --terms FILE    term file (repeatable; falls back to $KIT_TERMS_FILE). The list is never committed: it would
#                   contain the names it hunts. Lines of the file:
#                     <term>                    one term, matched as a plain string, case-insensitive
#                     w:<term>                  the same, but only as a whole word (`zqx` must not match `azqxb`)
#                     allow: <path> <string>    the exact <string> is permitted inside the one tracked file <path>
#                   Blank lines are skipped, leading and trailing blanks are trimmed, a trailing CR is dropped.
#   --skip PATH     applies to the preceding --terms: this term file is not scanned in PATH (a path or a directory,
#                   relative to the repository root). Content and file names are skipped; commit metadata is not.
#   --tree [PATH..] scan the contents and the names of the tracked files (all of them, or only under PATH ...).
#                   Binary files are skipped and counted; symlinks are not followed.
#   --exclude DIR/  tree scan only (refused with --history; repeatable): a hit in a tracked file under DIR/ is counted, not
#                   listed, and does not fail the run. One line "excluded under DIR/: N hits" is printed before the control
#                   line; hits outside DIR/ are listed and fail as usual. DIR/ is strict: it must end in "/" (a directory:
#                   a file named like it is not excluded), be relative to the repository root, and hold no ".", ".." or empty
#                   segment (so no leading "/" or "./"); anything else is exit 2. It is matched against the path git tracks,
#                   case-sensitively: KB/x and sub/kb/x are not under kb/, and a tracked link is never followed.
#                   Unlike --skip (per term file, silent) this one is counted and is checked by the control.
#   --ci            CI mode: the term file must come from --terms (KIT_TERMS_FILE is not read) and must hold a term. A missing,
#                   unreadable or empty term file is exit 2 with a message naming the KIT_TERMS secret: a CI scan with no
#                   terms never passes and never skips. A file with a NUL byte is read as text (grep -a), not skipped.
#   --history [X]   scan every commit reachable from all refs: messages, author and committer names and e-mails,
#                   diff text including deleted lines, annotated tag objects, and branch and tag names.
#                   X is a repository directory (default: the repository of the current directory) or a revision
#                   that replaces "all refs" for the commit walk. If X names an existing directory it is a directory.
#   -h, --help      this text
#   --tree and --history may be given together. The repository is the one of the current directory unless a path
#   or a directory says otherwise.
#
# Output: one line per hit, "<place> term=<file>:<index>", sorted and without duplicates. The place is a location
#   (file, commit, ref ordinal) and the term is a position in its term file (1-based, blank lines not counted):
#   the matched text is never printed, and a path that itself contains a term is withheld.
#   Ref hits are numbered by `git for-each-ref` order.
# "terms: N" (the number of terms of all the term files, a count only) is printed before the tree summary.
# Last line, always: "control: found 1/1; hits: N" (N counts the hits outside every --exclude). Before every scan the
#   script plants a canary term in a throw-away repository and must find it with the same code, with -i, with -w, and with
#   a negative case; with --exclude it also plants one under each excluded directory and must see it counted, not listed.
# Exit codes: 0 no hit, 1 at least one hit, 2 misuse or a broken instrument (no usable terms, unreadable file,
#   not a git repository, canary not found).
#
# Uses only git, grep, sort and mktemp (plus the shell builtins and mkdir/rm). Matching is `grep -F -i -I -l -n`
# (`-a` instead of `-I` in --ci) with `-w` for w: terms, the term read from a file with -f so that it is never in an argument
# list, under LC_ALL=C. No -P, no \b, no \|, no GNU-only long options: meant to behave the same
# on GNU and BSD grep (BSD: not checked in the session that wrote this).
# Known limits (the scanner does not look at these; it never says "clean" about them):
#   - binary files and UTF-16 text are skipped by grep -I and only counted (tree); the history scan reads diffs as text
#   - an annotated tag object that no ref points to (the inner tag of a nested tag), tags of blobs and trees
#   - a path that git must quote (tab, newline, quote, backslash) is attributed to the wrong file in hit lines
#   - short terms also match the labels and hashes of the scanned streams (false positives only)
#   - a shallow clone is refused (exit 2); a tracked file missing from the working tree is refused (exit 2)
# Scope: git content only. Pull request and issue text, release notes and CI logs are not in git.
# =============================================================================
export LC_ALL=C
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR

DIE_HINT=""   # one more line for a failure while the term files are read (set in --ci mode)
die() {
  echo "scan-internal-terms: $*" >&2
  [ -z "$DIE_HINT" ] || echo "scan-internal-terms: $DIE_HINT" >&2
  exit 2
}

usage() {  # the header comment, without the rulers
  local line
  while IFS= read -r line; do
    case $line in
      "#!"*|"# ==="*) continue ;;
      "#"*) printf '%s\n' "${line#\# }" ;;
      *) break ;;
    esac
  done < "$0"
}

# --- state -------------------------------------------------------------------
CTX=""            # directory with the term lists of the scan in progress: t.<k>.list, t.<k>.allow, t.<k>.skip
HITS=""           # file collecting the hit lines
XHITS=""          # file collecting the hits under an --exclude directory: "<index of the directory> <hit line>"
EXCL=()           # the --exclude directories, each ending in "/"
NK=0              # number of term files
BIN_TREE=0        # binary files skipped in the tree scan
SCANNED_TREE=0    # tracked files (and links) that were looked at in the tree scan
BIN_HIST=0        # binary diffs skipped in the history scan
WFLAG=""        # set by split_term (the term itself is kept in no variable: a variable named TERM is exported by every terminal and would hand it to each child process)
BINF=-I           # how a tree scan treats a file with a NUL byte: skipped (-I) and counted, or read as text (-a, in --ci mode)
HREPO=""          # repository of the history scan

rec() { printf '%s\n' "$*" >> "$HITS"; }

rec_in() {  # rec_in <tracked path> <hit line>: a hit under an --exclude directory is only counted
  local f=$1 i=0
  while [ "$i" -lt "${#EXCL[@]}" ]; do
    case $f in "${EXCL[$i]}"*) printf '%s %s\n' "$i" "$2" >> "$XHITS"; return 0 ;; esac
    i=$((i+1))
  done
  rec "$2"
}

# --- terms -------------------------------------------------------------------
trim() {  # trim <string>: print without leading and trailing blanks
  local s=$1
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  printf '%s' "$s"
}

# parse_terms <file> <dir> <k>: write t.<k>.list (n:<term> or w:<term>) and t.<k>.allow (path TAB string)
parse_terms() {
  local f=$1 d=$2 k=$3 line rest p s t n=0
  [ -f "$f" ] && [ -r "$f" ] || die "cannot read term file: $f"
  : > "$d/t.$k.list"; : > "$d/t.$k.allow"; : > "$d/t.$k.skip"
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    line=${line#$'\xef\xbb\xbf'}   # a UTF-8 byte order mark would silently disable the first term
    line=$(trim "$line")
    [ -n "$line" ] || continue
    case $line in
      allow:*)
        rest=$(trim "${line#allow:}")
        case $rest in
          *" "*) p=${rest%% *}; s=$(trim "${rest#* }") ;;
          *) die "bad allow line in $f (want: allow: <path> <exact string>)" ;;
        esac
        [ -n "$p" ] && [ -n "$s" ] || die "bad allow line in $f (want: allow: <path> <exact string>)"
        printf '%s\t%s\n' "$p" "$s" >> "$d/t.$k.allow"
        ;;
      w:*)
        t=$(trim "${line#w:}")
        [ -n "$t" ] || continue
        printf 'w:%s\n' "$t" >> "$d/t.$k.list"; n=$((n+1))
        ;;
      *)
        printf 'n:%s\n' "$line" >> "$d/t.$k.list"; n=$((n+1))
        ;;
    esac
  done < "$f"
  [ "$n" -gt 0 ] || die "term file has no terms: $f (a scanner with no terms is a broken instrument)"
}

split_term() {  # split_term <list line> [pattern file]: sets WFLAG, and writes the term to the pattern file (default $CTX/pat)
  printf '%s\n' "${1#?:}" > "${2:-$CTX/pat}"   # greps read the term with -f: it never lands in an argument list or an environment
  if [ "${1%%:*}" = w ]; then WFLAG=-w; else WFLAG=""; fi
}

skipped() {  # skipped <k> <path>: is the path under a --skip of term file k?
  local k=$1 f=$2 p
  while IFS= read -r p; do
    p=${p%/}
    case $f in "$p"|"$p"/*) return 0 ;; esac
  done < "$CTX/t.$k.skip"
  return 1
}

path_has_term() {  # path_has_term <path>: does the path itself match a term of any term file?
  local p=$1 k=1 line
  while [ "$k" -le "$NK" ]; do
    while IFS= read -r line; do
      split_term "$line" "$CTX/pat.path"   # its own file: this runs inside the loops that hold $CTX/pat
      printf '%s\n' "$p" | grep -F -i -q $WFLAG -f "$CTX/pat.path" && return 0
    done < "$CTX/t.$k.list"
    k=$((k+1))
  done
  return 1
}

safe_path() {  # safe_path <path> [names-file]: the path, or a marker when the path would print a term
  local p=$1 names=$2 o
  if path_has_term "$p"; then
    if [ -n "$names" ]; then
      printf '%s\n' "${p//$'\n'/ }" > "$CTX/pat.name"   # a path that holds a term must not reach an argument list either; the names file holds a newline as a space
      o=$(grep -n -x -F -f "$CTX/pat.name" -- "$names")
      printf '(path withheld; file #%s)' "${o%%:*}"
    else
      printf '(path withheld)'
    fi
  else
    printf '%s' "$p"
  fi
}

# allow_strings <k> <path>: print the allowed strings of one file, one per line
allow_strings() {
  local p s
  while IFS=$'\t' read -r p s; do
    [ "$p" = "$2" ] && printf '%s\n' "$s"
  done < "$CTX/t.$1.allow"
}

# blank_allowed <k> <path> <in> <out>: copy <in> to <out> with every allowed string of <path> replaced by a blank
blank_allowed() {
  local k=$1 p=$2 in=$3 out=$4 line s
  local -a strs=()
  while IFS= read -r s; do strs[${#strs[@]}]=$s; done < <(allow_strings "$k" "$p")
  while IFS= read -r line || [ -n "$line" ]; do
    for s in "${strs[@]}"; do line=${line//"$s"/ }; done
    printf '%s\n' "$line"
  done < "$in" > "$out"
}

# distinct_allow_paths <k>: print each path that has an allow line, once
distinct_allow_paths() {
  local p s seen=$'\n'
  while IFS=$'\t' read -r p s; do
    case $seen in *$'\n'"$p"$'\n'*) continue ;; esac
    seen="$seen$p"$'\n'
    printf '%s\n' "$p"
  done < "$CTX/t.$1.allow"
}

# --- tree scan ---------------------------------------------------------------
# scan_tree <top> [pathspec ...]: contents and names of the tracked files
scan_tree() {
  local top; top=$(cd "$1" && pwd -P) || die "no such directory: $1"; shift
  local -a files=() kfiles=() chunk=()
  local f i k ti line p rc o
  while IFS= read -r -d '' f; do files[${#files[@]}]=$f; done < <(git -C "$top" ls-files -z -- "$@")
  [ "${#files[@]}" -gt 0 ] || die "no tracked files to scan: a scan of nothing proves nothing (check the path)"
  # one line per file, in the order of the array: a newline inside a path is written as a space, or the line numbers would drift
  { for f in "${files[@]}"; do printf '%s\n' "${f//$'\n'/ }"; done; } > "$CTX/names"

  for f in "${files[@]}"; do   # every tracked file must be readable; binary files are skipped by grep -I and counted here
    if [ -L "$top/$f" ]; then SCANNED_TREE=$((SCANNED_TREE+1)); continue
    elif [ -d "$top/$f" ]; then continue   # a submodule: its content is another repository
    elif [ ! -f "$top/$f" ]; then die "tracked file is missing from the working tree: $(safe_path "$f" "$CTX/names")"
    fi
    SCANNED_TREE=$((SCANNED_TREE+1))
    [ -s "$top/$f" ] || continue
    grep -I -q -e '' -- "$top/$f" 2>/dev/null; rc=$?   # stderr is dropped: grep would print the path, and a path may hold a term
    if [ "$rc" -eq 1 ]; then BIN_TREE=$((BIN_TREE+1)); elif [ "$rc" -gt 1 ]; then die "cannot read: $(safe_path "$f" "$CTX/names")"; fi
  done

  k=1
  while [ "$k" -le "$NK" ]; do
    # names of tracked files
    ti=0
    while IFS= read -r line; do
      ti=$((ti+1)); split_term "$line"
      grep -F -i -n $WFLAG -f "$CTX/pat" -- "$CTX/names" | while IFS= read -r p; do
        o=${p%%:*}
        skipped "$k" "${files[$((o-1))]}" && continue
        rec_in "${files[$((o-1))]}" "name #$o term=$k:$ti"
      done
    done < "$CTX/t.$k.list"

    # contents; files with an allow line are scanned further down, as a copy
    kfiles=()
    for f in "${files[@]}"; do
      [ ! -L "$top/$f" ] && [ -f "$top/$f" ] || continue
      skipped "$k" "$f" && continue
      if allow_strings_for_file "$k" "$f"; then continue; fi
      kfiles[${#kfiles[@]}]=$f
    done
    ti=0
    while IFS= read -r line; do
      ti=$((ti+1)); split_term "$line"
      i=0
      while [ "$i" -lt "${#kfiles[@]}" ]; do
        chunk=()
        for f in "${kfiles[@]:$i:200}"; do chunk[${#chunk[@]}]=$top/$f; done   # absolute: grep reads a file named "-" as stdin
        grep -F -i $BINF -l $WFLAG -f "$CTX/pat" -- "${chunk[@]}" 2>/dev/null < /dev/null > "$CTX/tree.hit"; rc=$?
        [ "$rc" -le 1 ] || die "grep failed on tracked files (status $rc)"   # a read error must not look like a clean scan
        while IFS= read -r p; do
          p=${p#"$top"/}
          rec_in "$p" "tree $(safe_path "$p" "$CTX/names") term=$k:$ti"
        done < "$CTX/tree.hit"
        i=$((i+200))
      done
    done < "$CTX/t.$k.list"

    # symbolic links: the tracked content is the link target text, read from the index
    for f in "${files[@]}"; do
      [ -L "$top/$f" ] || continue
      skipped "$k" "$f" && continue
      git -C "$top" cat-file blob ":$f" > "$CTX/link.copy" 2>/dev/null || die "cannot read the link target of a tracked link"
      ti=0
      while IFS= read -r line; do
        ti=$((ti+1)); split_term "$line"
        if grep -F -i -a -q $WFLAG -f "$CTX/pat" -- "$CTX/link.copy"; then
          rec_in "$f" "tree $(safe_path "$f" "$CTX/names") term=$k:$ti"
        fi
      done < "$CTX/t.$k.list"
    done

    # files with an allow line: scan a copy in which the allowed strings are blanked
    while IFS= read -r p; do
      grep -x -F -q -e "$p" -- "$CTX/names" || continue
      [ ! -L "$top/$p" ] && [ -f "$top/$p" ] || continue
      [ "$BINF" = -a ] || grep -I -q -e '' -- "$top/$p" 2>/dev/null || continue
      blank_allowed "$k" "$p" "$top/$p" "$CTX/allow.copy"
      ti=0
      while IFS= read -r line; do
        ti=$((ti+1)); split_term "$line"
        if grep -F -i $BINF -q $WFLAG -f "$CTX/pat" -- "$CTX/allow.copy"; then
          rec_in "$p" "tree $(safe_path "$p" "$CTX/names") term=$k:$ti"
        fi
      done < "$CTX/t.$k.list"
    done < <(distinct_allow_paths "$k")
    k=$((k+1))
  done
}

allow_strings_for_file() {  # allow_strings_for_file <k> <path>: does term file k have an allow line for this path?
  local p s
  while IFS=$'\t' read -r p s; do
    [ "$p" = "$2" ] && return 0
  done < "$CTX/t.$1.allow"
  return 1
}

# --- history scan ------------------------------------------------------------
hgit() { git --no-replace-objects -C "$HREPO" -c core.quotepath=off -c log.showSignature=false "$@"; }

# walk_hits <mode> <hits> <index> <k:i>: turn "N:text" lines of grep -n (<hits>) into places, using the header
# lines of the stream (<index>, also from grep -n). Both files are ascending, so one pass is enough.
walk_hits() {
  local mode=$1 hf=$2 xf=$3 tref=$4
  local -a xn=() xt=()
  local m=0 q=0 l hl h cur="" curline=0 curpath="" t p fld off r lastkey="" lastpath="" lastsafe=""
  while IFS= read -r l; do xn[$m]=${l%%:*}; xt[$m]=${l#*:}; m=$((m+1)); done < "$xf"
  while IFS= read -r hl; do
    h=${hl%%:*}
    while [ "$q" -lt "$m" ] && [ "${xn[$q]}" -le "$h" ]; do
      t=${xt[$q]}
      case $t in
        "commit "*) cur=${t#commit }; curline=${xn[$q]}; curpath="" ;;
        "tagobj "*) cur=${t#tagobj }; curline=${xn[$q]}; curpath="" ;;
        "diff --git a/"*) p=${t#diff --git a/}; curpath=${p% b/*} ;;
        "diff --cc "*) curpath=${t#diff --cc } ;;
      esac
      q=$((q+1))
    done
    case $mode in
      meta)
        off=$((h-curline))
        case $off in 0) fld=header ;; 1) fld=author ;; 2) fld=committer ;; *) fld=message ;; esac
        r="history commit ${cur:0:12} $fld"
        ;;
      tag) r="history tag-annotation ${cur:0:12}" ;;
      diff)
        if [ "$curpath" != "$lastpath" ] || [ -z "$lastsafe" ]; then
          lastpath=$curpath; lastsafe=$(safe_path "$curpath"); [ -n "$lastsafe" ] || lastsafe="(unknown)"
        fi
        r="history diff ${cur:0:12} $lastsafe"
        ;;
    esac
    if [ "$r" != "$lastkey" ]; then lastkey=$r; rec "$r term=$tref"; fi
  done < "$hf"
}

# scan_stream_k <mode> <stream> <index> <k>: every term of term file k over one stream
scan_stream_k() {
  local mode=$1 s=$2 x=$3 k=$4 ti=0 line rc
  while IFS= read -r line; do
    ti=$((ti+1)); split_term "$line"
    grep -F -i -a -n $WFLAG -f "$CTX/pat" -- "$s" > "$CTX/hit.tmp"; rc=$?
    [ "$rc" -le 1 ] || die "grep failed on a history stream (status $rc)"
    if [ -s "$CTX/hit.tmp" ]; then walk_hits "$mode" "$CTX/hit.tmp" "$x" "$k:$ti"; fi
  done < "$CTX/t.$k.list"
}

# scan_history <repo> [rev]
scan_history() {
  HREPO=$1
  local rev=$2 k ti line p o kind obj type nbin sh
  sh=$(hgit rev-parse --git-path shallow) || die "git rev-parse failed in $HREPO"
  case $sh in /*) ;; *) sh=$HREPO/$sh ;; esac
  [ ! -e "$sh" ] || die "$HREPO is a shallow clone: its history is incomplete (fetch the full history first)"
  local -a revargs=() excl=() difflags=()
  if [ -n "$rev" ]; then revargs=("$rev"); else revargs=(--all); fi
  difflags=(--format='commit %H' -p --text --cc -U0 --no-renames --no-ext-diff --no-textconv --no-color --src-prefix=a/ --dst-prefix=b/)

  # commit metadata: message, author and committer, name and e-mail
  hgit log "${revargs[@]}" --format='commit %H%nauthor %an <%ae>%ncommitter %cn <%ce>%n%B' -- > "$CTX/h.meta" ||
    die "git log failed in $HREPO"
  grep -a -n -E '^commit [0-9a-f]{40,64}$' -- "$CTX/h.meta" > "$CTX/h.meta.idx"
  k=1
  while [ "$k" -le "$NK" ]; do scan_stream_k meta "$CTX/h.meta" "$CTX/h.meta.idx" "$k"; k=$((k+1)); done

  # branch and tag names (and every other ref), numbered in for-each-ref order
  hgit for-each-ref --format='%(refname)' > "$CTX/h.refs" || die "git for-each-ref failed in $HREPO"
  k=1
  while [ "$k" -le "$NK" ]; do
    ti=0
    while IFS= read -r line; do
      ti=$((ti+1)); split_term "$line"
      grep -F -i -a -n $WFLAG -f "$CTX/pat" -- "$CTX/h.refs" | while IFS= read -r p; do
        o=${p%%:*}
        case ${p#*:} in
          refs/heads/*) kind=branch ;; refs/tags/*) kind=tag ;; refs/remotes/*) kind=remote-branch ;; *) kind=ref ;;
        esac
        rec "history $kind #$o term=$k:$ti"
      done
    done < "$CTX/t.$k.list"
    k=$((k+1))
  done

  # annotated tag objects: tagger and message
  : > "$CTX/h.tags"
  while read -r type obj; do
    [ "$type" = tag ] || continue
    { printf 'tagobj %s\n' "$obj"; hgit cat-file tag "$obj"; } >> "$CTX/h.tags"
  done < <(hgit for-each-ref --format='%(objecttype) %(objectname)' refs/tags)
  grep -a -n -E '^tagobj [0-9a-f]{40,64}$' -- "$CTX/h.tags" > "$CTX/h.tags.idx"
  k=1
  while [ "$k" -le "$NK" ]; do scan_stream_k tag "$CTX/h.tags" "$CTX/h.tags.idx" "$k"; k=$((k+1)); done

  # diff text (added and deleted lines) of every commit, per term file because of --skip and allow lines
  k=1
  while [ "$k" -le "$NK" ]; do
    excl=()
    while IFS= read -r p; do excl[${#excl[@]}]=":(exclude,literal)${p%/}"; done < "$CTX/t.$k.skip"
    while IFS= read -r p; do excl[${#excl[@]}]=":(exclude,literal)$p"; done < <(distinct_allow_paths "$k")
    if [ "${#excl[@]}" -gt 0 ]; then
      hgit log "${revargs[@]}" "${difflags[@]}" --full-history -- . "${excl[@]}" > "$CTX/h.diff" ||
        die "git log failed in $HREPO"
    else
      hgit log "${revargs[@]}" "${difflags[@]}" -- > "$CTX/h.diff" || die "git log failed in $HREPO"
    fi
    if [ "$k" -eq 1 ]; then
      nbin=$(grep -a -c -E '^Binary files ' -- "$CTX/h.diff"); BIN_HIST=$((BIN_HIST+nbin))
    fi
    grep -a -n -E '^(commit [0-9a-f]{40,64}|diff --git a/.*|diff --cc .*)$' -- "$CTX/h.diff" > "$CTX/h.diff.idx"
    scan_stream_k diff "$CTX/h.diff" "$CTX/h.diff.idx" "$k"

    # the files with an allow line: their own diff stream, allowed strings blanked
    while IFS= read -r p; do
      hgit log "${revargs[@]}" "${difflags[@]}" --full-history -- ":(literal)$p" > "$CTX/h.allow.raw" ||
        die "git log failed in $HREPO"
      blank_allowed "$k" "$p" "$CTX/h.allow.raw" "$CTX/h.allow"
      grep -a -n -E '^(commit [0-9a-f]{40,64}|diff --git a/.*|diff --cc .*)$' -- "$CTX/h.allow" > "$CTX/h.allow.idx"
      scan_stream_k diff "$CTX/h.allow" "$CTX/h.allow.idx" "$k"
    done < <(distinct_allow_paths "$k")
    k=$((k+1))
  done
}

# --- positive control --------------------------------------------------------
# Plants a canary in a throw-away repository and scans it with the same code and the same modes as the real run.
# The canary is found as a plain term and as a whole word (control.txt, upper case: proves -i), and the whole-word
# term must NOT match inside another word (embedded.txt: proves -w).
run_control() {  # run_control <do-tree> <do-history>; returns 0 when the instrument works
  local dotree=$1 dohist=$2 cd cr h ok=0 canary=zqxcanaryterm
  local save_ctx=$CTX save_hits=$HITS save_xhits=$XHITS save_nk=$NK save_bt=$BIN_TREE save_bh=$BIN_HIST save_sc=$SCANNED_TREE
  local x i
  cd=$(mktemp -d "${TMPDIR:-/tmp}/scan-control.XXXXXX") || die "mktemp failed"
  cr=$cd/repo; mkdir "$cd/ctx" "$cr"
  CTX=$cd/ctx; HITS=$cd/hits; XHITS=$cd/xhits; NK=1; : > "$HITS"; : > "$XHITS"
  printf '%s\nw:%s\n' "$canary" "$canary" > "$cd/terms"
  parse_terms "$cd/terms" "$CTX" 1
  git init -q --template= "$cr" 2>/dev/null || die "git init failed"
  printf 'x ZQXCanaryTerm y\n' > "$cr/control.txt"
  printf 'a%sb\n' "$canary" > "$cr/embedded.txt"
  git -C "$cr" add -- control.txt embedded.txt
  i=0
  while [ "$i" -lt "${#EXCL[@]}" ]; do   # one canary under each excluded directory
    x=${EXCL[$i]}
    mkdir -p "$cr/$x"; printf 'x %s y\n' "$canary" > "$cr/${x}inside.txt"
    git -C "$cr" add -- "${x}inside.txt"
    i=$((i+1))
  done
  git -C "$cr" -c user.name=control -c user.email=control@localhost -c commit.gpgsign=false \
    -c core.hooksPath=/dev/null commit -q -m "control $canary" || die "control commit failed"
  h=$(git -C "$cr" rev-parse HEAD); h=${h:0:12}
  ok=1
  if [ "$dotree" = 1 ]; then
    scan_tree "$cr"
    grep -x -F -q -e "tree control.txt term=1:1" -- "$HITS" || ok=0
    grep -x -F -q -e "tree control.txt term=1:2" -- "$HITS" || ok=0
    grep -x -F -q -e "tree embedded.txt term=1:1" -- "$HITS" || ok=0
    grep -x -F -q -e "tree embedded.txt term=1:2" -- "$HITS" && ok=0
    # an excluded directory: its canary is counted (both terms) and never listed; the rest of the control above proves
    # that the exclusion did not swallow what lies outside it
    i=0
    while [ "$i" -lt "${#EXCL[@]}" ]; do
      [ "$(grep -c -x -F -e "$i tree ${EXCL[$i]}inside.txt term=1:1" -- "$XHITS")" -eq 1 ] || ok=0
      [ "$(grep -c -x -F -e "$i tree ${EXCL[$i]}inside.txt term=1:2" -- "$XHITS")" -eq 1 ] || ok=0
      grep -q -F -e "inside.txt" -- "$HITS" && ok=0
      i=$((i+1))
    done
  fi
  if [ "$dohist" = 1 ]; then
    scan_history "$cr" ""
    grep -x -F -q -e "history diff $h control.txt term=1:1" -- "$HITS" || ok=0
    grep -x -F -q -e "history diff $h control.txt term=1:2" -- "$HITS" || ok=0
    grep -x -F -q -e "history diff $h embedded.txt term=1:1" -- "$HITS" || ok=0
    grep -x -F -q -e "history diff $h embedded.txt term=1:2" -- "$HITS" && ok=0
    grep -x -F -q -e "history commit $h message term=1:2" -- "$HITS" || ok=0
  fi
  rm -rf "$cd"
  CTX=$save_ctx; HITS=$save_hits; XHITS=$save_xhits; NK=$save_nk; BIN_TREE=$save_bt; BIN_HIST=$save_bh; SCANNED_TREE=$save_sc
  [ "$ok" = 1 ]
}

# --- arguments ---------------------------------------------------------------
TERM_FILES=(); SKIPS=()   # SKIPS[k-1]: newline-separated skip paths of term file k
DO_TREE=0; DO_HIST=0; CI=0
TREE_PATHS=(); HIST_ARG=""

while [ $# -gt 0 ]; do
  case $1 in
    -h|--help) usage; exit 0 ;;
    --terms)
      [ $# -ge 2 ] || die "--terms needs a file"
      TERM_FILES[${#TERM_FILES[@]}]=$2; SKIPS[${#SKIPS[@]}]=""; shift 2 ;;
    --skip)
      [ $# -ge 2 ] || die "--skip needs a path"
      [ "${#TERM_FILES[@]}" -gt 0 ] || die "--skip must follow a --terms"
      SKIPS[$((${#TERM_FILES[@]}-1))]="${SKIPS[$((${#TERM_FILES[@]}-1))]}$2"$'\n'; shift 2 ;;
    --tree)
      DO_TREE=1; shift
      while [ $# -gt 0 ]; do
        case $1 in -*) break ;; esac
        TREE_PATHS[${#TREE_PATHS[@]}]=$1; shift
      done ;;
    --exclude)
      [ $# -ge 2 ] || die "--exclude needs a directory"
      case $2 in */) ;; *) die "--exclude wants a directory that ends in '/' (relative to the repository root), got: $2" ;; esac
      case "/$2" in
        */./*|*/../*|*//*) die "--exclude wants a plain relative directory (no '.', '..', empty segment or leading '/'), got: $2" ;;
      esac
      EXCL[${#EXCL[@]}]=$2; shift 2 ;;
    --ci) CI=1; shift ;;
    --history)
      DO_HIST=1; shift
      if [ $# -gt 0 ]; then case $1 in -*) ;; *) HIST_ARG=$1; shift ;; esac; fi ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done
[ "$DO_TREE" = 1 ] || [ "$DO_HIST" = 1 ] || die "nothing to scan: give --tree and/or --history (see --help)"
[ "${#EXCL[@]}" -eq 0 ] || [ "$DO_HIST" = 0 ] || die "--exclude applies to the tree scan only: a history scan cannot tell which path a commit hit belongs to"
[ "${#EXCL[@]}" -eq 0 ] || [ "$DO_TREE" = 1 ] || die "--exclude needs --tree"
if [ "$CI" = 1 ]; then
  BINF=-a   # a NUL byte must not hide a text file from the gate
  DIE_HINT="CI mode: a scan with no usable terms must not pass (is the KIT_TERMS secret set and not empty?)"
  [ "${#TERM_FILES[@]}" -gt 0 ] || die "CI mode wants --terms FILE (KIT_TERMS_FILE is not read)"
fi
if [ "${#TERM_FILES[@]}" -eq 0 ]; then
  [ -n "${KIT_TERMS_FILE:-}" ] || die "no term file: give --terms FILE or set KIT_TERMS_FILE"
  TERM_FILES[0]=$KIT_TERMS_FILE; SKIPS[0]=""
fi

W=$(mktemp -d "${TMPDIR:-/tmp}/scan-terms.XXXXXX") || die "mktemp failed"
trap 'rm -rf "$W"' EXIT
mkdir "$W/ctx"
CTX=$W/ctx; HITS=$W/hits; XHITS=$W/xhits; : > "$HITS"; : > "$XHITS"
k=0
for f in "${TERM_FILES[@]}"; do
  k=$((k+1)); parse_terms "$f" "$CTX" "$k"
  while IFS= read -r p; do [ -n "$p" ] && printf '%s\n' "$p" >> "$CTX/t.$k.skip"; done <<< "${SKIPS[$((k-1))]}"
done
NK=$k
DIE_HINT=""

# repositories to scan
repo_top() {  # repo_top <dir> [bare]: physical top level of the repository holding <dir> (a bare one too, with "bare")
  local d t
  d=$(cd "$1" 2>/dev/null && pwd -P) || die "no such directory: $1"
  if ! t=$(git -C "$d" rev-parse --show-toplevel 2>/dev/null); then
    if [ "${2:-}" = bare ] && [ "$(git -C "$d" rev-parse --is-bare-repository 2>/dev/null)" = true ]; then
      t=$(git -C "$d" rev-parse --absolute-git-dir) || die "not a git repository: $1"
    else
      die "not a git repository: $1"
    fi
  fi
  printf '%s' "$t"
}
TREE_TOP=""; TREE_SPECS=()
if [ "$DO_TREE" = 1 ]; then
  if [ "${#TREE_PATHS[@]}" -eq 0 ]; then TREE_PATHS[0]=.; fi
  for p in "${TREE_PATHS[@]}"; do
    if [ -d "$p" ]; then d=$p; b=""
    elif [ -e "$p" ]; then
      case $p in */*) d=${p%/*}; [ -n "$d" ] || d=/ ;; *) d=. ;; esac
      b=${p##*/}
    else die "no such path: $p"; fi
    top=$(repo_top "$d") || exit 2   # die inside $( ) leaves only the subshell, so the status is passed on here
    abs=$(cd "$d" && pwd -P); [ -z "$b" ] || abs=${abs%/}/$b
    if [ -z "$TREE_TOP" ]; then TREE_TOP=$top; elif [ "$TREE_TOP" != "$top" ]; then die "paths are in different repositories"; fi
    case $abs in
      "$top") rel=. ;;
      "$top"/*) rel=${abs#"$top"/} ;;
      *) die "path is outside its repository: $p" ;;
    esac
    TREE_SPECS[${#TREE_SPECS[@]}]=$rel
  done
fi
HIST_TOP=""; HIST_REV=""
if [ "$DO_HIST" = 1 ]; then
  if [ -n "$HIST_ARG" ] && [ -d "$HIST_ARG" ]; then { HIST_TOP=$(repo_top "$HIST_ARG" bare) || exit 2; }
  else
    HIST_TOP=$TREE_TOP; HIST_REV=$HIST_ARG
    [ -n "$HIST_TOP" ] || { HIST_TOP=$(repo_top . bare) || exit 2; }
  fi
fi

# the instrument is checked before the scan
if ! run_control "$DO_TREE" "$DO_HIST"; then
  echo "scan-internal-terms: the planted canary was not found: grep or git does not behave as this script expects" >&2
  echo "control: found 0/1; hits: unknown"
  exit 2
fi

[ "$DO_TREE" = 1 ] && scan_tree "$TREE_TOP" "${TREE_SPECS[@]}"
[ "$DO_HIST" = 1 ] && scan_history "$HIST_TOP" "$HIST_REV"

sort -u "$HITS" > "$W/hits.sorted"
n=$(grep -c '' -- "$W/hits.sorted")
if [ "$n" -gt 0 ]; then
  while IFS= read -r line; do printf '%s\n' "$line"; done < "$W/hits.sorted"
fi
NT=0; k=1
while [ "$k" -le "$NK" ]; do NT=$((NT + $(grep -c '' -- "$CTX/t.$k.list"))); k=$((k+1)); done
echo "terms: $NT"
if [ "$DO_TREE" = 1 ]; then
  if [ "$BINF" = -a ]; then echo "scanned files: $SCANNED_TREE; binary files read as text: $BIN_TREE"
  else echo "scanned files: $SCANNED_TREE; skipped binary files: $BIN_TREE"; fi
fi
[ "$DO_HIST" = 1 ] && echo "skipped binary diffs: $BIN_HIST"
sort -u "$XHITS" > "$W/xhits.sorted"
i=0
while [ "$i" -lt "${#EXCL[@]}" ]; do
  echo "excluded under ${EXCL[$i]}: $(grep -c -e "^$i " -- "$W/xhits.sorted") hits"
  i=$((i+1))
done
echo "control: found 1/1; hits: $n"
[ "$n" -eq 0 ]
