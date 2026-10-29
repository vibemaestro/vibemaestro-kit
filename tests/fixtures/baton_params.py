#!/usr/bin/env python3
"""Fixtures of tests/test-baton-params.sh: baton files with Params, and the long tables of refused and allowed forms, run in one
process against a plugin copy (its scripts/baton.py, so a planted break in that copy shows).

  baton_params.py make <plugin> <out> <params> <targets> [<top> [<act> [<Expect lines>]]]   write a test baton
  baton_params.py table <plugin> grammar|values|reader|owner              one line per case: PASS|FAIL<TAB><label>

A case's label is its tag in the suite: a planted break must turn the intended label red."""
import json
import os
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True

ACT = '  write "put $P_DEST/x" touch -- "$P_DEST/x"'
UNDO = ('undo() {\n  if [ -f "$P_DEST/x" ]; then\n    write "remove $P_DEST/x" rm -f -- "$P_DEST/x"\n  fi\n  [ ! -f "$P_DEST/x" ]\n}\n')
DISPATCH = ('case "$PHASE" in\n  rehearse)\n    act\n    echo "VERDICT rehearse ok"\n    ;;\n  run)\n    act\n    echo "VERDICT run ok"\n'
            '    ;;\n  postcheck)\n    postcheck\n    echo "VERDICT postcheck ok"\n    ;;\n  undo)\n    undo\n    echo "VERDICT undo ok"\n'
            '    ;;\n  *)\n    exit 64\n    ;;\nesac\n')


def gate(plugin):
    t = open(os.path.join(plugin, "templates", "baton-script.sh"), encoding="utf-8").read()
    return t[t.index("write() {"):t.index("# ── arguments")]


def baton(plugin, params, targets, top="", act=None, block=None, expect="*", stops="none", header=""):
    """A baton text: the header, the template's gate, the values block (one P_<KEY>="$n" per key, unless `block` is given),
    `top` (top-level lines), act() holding `act`, a post-check and an undo, and the dispatch."""
    keys = [] if params == "none" else [d.split("=", 1)[0] for d in params.split(" ")]
    act = ACT if act is None else act
    if block is None:
        block = "".join('P_%s="$%s"\n' % (k.upper(), j + 1 if j < 9 else "{%d}" % (j + 1)) for j, k in enumerate(keys))
    head = ("#!/usr/bin/env bash\n# Purpose: a test baton\n# Targets: %s\n# Blast: one file\n# Undo: removes the file\n# Pre: none\n"
            "# Stops: %s\n# Params: %s\n%s" % (targets, stops, params, header)
            + "".join("# Expect: %s\n" % e for e in expect.split("\n")))
    return (head + "set -euo pipefail\nPHASE=${BATON_PHASE:-rehearse}\n\n" + gate(plugin) + block + top
            + ("\n" if top and not top.endswith("\n") else "") + "act() {\n" + act + "\n}\n"
            + 'postcheck() {\n  [ -f "$P_DEST/x" ]\n}\n' + UNDO + DISPATCH)


def load(plugin):
    sys.path.insert(0, os.path.join(plugin, "scripts"))
    import baton                                                    # noqa: E402  the copy's own baton.py
    return baton


def check_text(b, text):
    """(problems) of `check` on a scratch baton holding text."""
    d = tempfile.mkdtemp(prefix="bp-")
    p = os.path.join(d, "t.sh")
    with open(p, "w", encoding="utf-8") as f:
        f.write(text)
    try:
        return [x for _n, x in b.check_script(b.Script(p))]
    finally:
        os.unlink(p)
        os.rmdir(d)


P = P2 = "dest=path n=name"
T = "{dest}/** — the file"
BODY, UNDECIDED = "in the body of a here-document", "cannot decide"
SEG = "a segment of a value can start with -"

# (label, params, top, act, refused: None for allowed, else a phrase the problem holds)
READER = [
    ("allowed: the default baton", P, "", ACT, None),
    ("allowed: \"$P_N\" and \"${P_N}\" and \"x/$P_N\"", P, 'A="$P_N"\nB="${P_N}"\nC="x/$P_N"\n', ACT, None),
    ("allowed: $1 inside a function body", P, 'f() {\n  echo "$1"\n}\n', ACT, None),
    ("allowed: gh api -f with a value", P, "", ACT + '\n  write "put $P_DEST/y" gh api "repos/$P_N" -f "body=$P_N"', None),
    # the values block
    ("refused: no values block", P, "", ACT, "values block", ""),
    ("refused: the values block out of order", P, "", ACT, "values block", 'P_N="$2"\nP_DEST="$1"\n'),
    ("refused: an unquoted values line", P, "", ACT, "values block", 'P_DEST=$1\nP_N="$2"\n'),
    ("refused: a P_ name assigned again", P, 'P_DEST="/tmp"\n', ACT, "assigned outside the values block"),
    ("refused: a P_ name read before the values block", P, "", ACT, "before the values block",
     'echo "$P_N"\nP_DEST="$1"\nP_N="$2"\n'),
    # positional parameters
    ("refused: a top-level \"$1\"", P, 'X="$1"\n', ACT, "positional parameter"),
    ("refused: a top-level \"$@\"", P, 'main() {\n  :\n}\nmain "$@"\n', ACT, "positional parameter"),
    ("refused: a top-level $*", P, 'X="$*"\n', ACT, "positional parameter"),
    ("refused: a top-level ${1:-x}", P, 'X="${1:-x}"\n', ACT, "positional parameter"),
    ("refused: a top-level shift", P, "shift\n", ACT, "`shift`"),
    ("refused: a top-level set --", P, "set -- a b\n", ACT, "`set`"),
    ("refused: a top-level getopts", P, "while getopts ab o; do\n  :\ndone\n", ACT, "`getopts`"),
    # forms of a parameter
    ("refused: $P_N unquoted", P, "", "  echo $P_N\n" + ACT, "unquoted"),
    ("refused: ${P_N#x}", P, "", '  echo "${P_N#x}"\n' + ACT, "operator"),
    ("refused: ${P_N:-x}", P, "", '  echo "${P_N:-x}"\n' + ACT, "operator"),
    ("refused: ${#P_N}", P, "", '  echo "${#P_N}"\n' + ACT, "operator"),
    ("refused: ${!P_N}", P, "", '  echo "${!P_N}"\n' + ACT, "operator"),
    ("refused: a nameref to P_N", P, "", "  local -n r=P_N\n" + ACT, "named bare"),
    ("refused: read P_N", P, "", "  read -r P_N < /dev/null || true\n" + ACT, "named bare"),
    ("refused: printf -v P_N", P, "", "  printf -v P_N '%s' x\n" + ACT, "named bare"),
    ("refused: export P_N", P, "", "  export P_N\n" + ACT, "named bare"),
    ("refused: P_N in arithmetic", P, "", '  echo "$(( P_N + 1 ))"\n' + ACT, "named bare"),
    ("refused: P_N in eval", P, "", '  eval "echo $P_N"\n' + ACT, "`eval`"),
    ("refused: P_N single-quoted in eval", P, "", "  eval 'echo \"$P_N\"'\n" + ACT, "`eval`"),
    ("refused: P_N in trap", P, "", "  trap 'echo \"$P_N\"' EXIT\n" + ACT, "`trap`"),
    ("refused: P_N in bash -c", P, "", '  bash -c "echo $P_N"\n' + ACT, "`bash`"),
    ("refused: P_N as the command name", P, "", '  "$P_N" --version\n' + ACT, "command name"),
    ("refused: P_N as the value of gh -F", P, "", ACT + '\n  write "put $P_DEST/y" gh api "repos/x" -F "body=$P_N"', "gh -F"),
    ("refused: P_N as the value of gh --field", P, "", ACT + '\n  write "put $P_DEST/y" gh api "repos/x" --field "b=$P_N"', "gh --field"),
    ("refused: P_N attached to gh -F", P, "", ACT + '\n  write "put $P_DEST/y" gh api "repos/x" -Fbody="$P_N"', "gh -F"),
    ("refused: P_N as the value of curl -d", P, "", '  curl -sS -d "$P_N" https://example.invalid/x || true\n' + ACT, "curl -d"),
    ("refused: P_N as the value of curl --data-binary", P, "", '  curl -sS --data-binary "$P_N" https://example.invalid || true\n' + ACT,
     "curl --data-binary"),
    ("refused: P_N as the value of curl --form", P, "", '  curl -sS --form "f=$P_N" https://example.invalid || true\n' + ACT, "curl --form"),
    ("refused: P_N as the value of curl --json", P, "", '  curl -sS --json "$P_N" https://example.invalid || true\n' + ACT, "curl --json"),
    ("refused: P_N in an unquoted here-document", P2, "", '  cat <<EOF\n$P_N\nEOF\n' + ACT, BODY),
    ("refused: P_N in a quoted here-document", P2, "", "  cat <<'EOF'\n$P_N\nEOF\n" + ACT, BODY),
    ("refused: P_N in a <<-EOF here-document", P2, "", '  cat <<-EOF\n\t$P_N\n\tEOF\n' + ACT, BODY),
    ("refused: P_N in a <<\\EOF here-document", P2, "", '  cat <<\\EOF\n$P_N\nEOF\n' + ACT, BODY),
    ("refused: P_N in a <<\"EOF\" here-document", P2, "", '  cat <<"EOF"\n$P_N\nEOF\n' + ACT, BODY),
    ("refused: P_N in a <<1 here-document", P2, "", '  cat <<1\n$P_N\n1\n' + ACT, BODY),
    ("refused: P_N in a <<'1' here-document", P2, "", "  cat <<'1'\n$P_N\n1\n" + ACT, BODY),
    ("refused: P_N in a <<@@ here-document", P2, "", '  cat <<@@\n$P_N\n@@\n' + ACT, BODY),
    ("refused: P_N in a <<'E-F' here-document", P2, "", "  cat <<'E-F'\n$P_N\nE-F\n" + ACT, BODY),
    ("refused: P_N in a <<'E F' here-document", P2, "", "  cat <<'E F'\n$P_N\nE F\n" + ACT, BODY),
    ("refused: P_N in a <<$'EOF' here-document", P2, "", "  cat <<$'EOF'\n$P_N\nEOF\n" + ACT, BODY),
    ("refused: P_N in a <<E'O'F here-document", P2, "", "  cat <<E'O'F\n$P_N\nEOF\n" + ACT, BODY),
    ("refused: P_N in the second here-document of a line", P2, "", "  cat <<A - <<'B-1'\nx\nA\n$P_N\nB-1\n" + ACT, BODY),
    ("refused: P_N in a here-document after a # inside ${…}", P2, 'L="a # b"\nL=${L%% #*}\n', '  bash -s <<EOF\n$P_N\nEOF\n' + ACT,
     BODY),
    ("refused: P_N in a here-document after $${", P2, "", '  echo "$$" $${\n  bash -s <<EOF\n$P_N\nEOF\n' + ACT, BODY),
    ("refused: P_N in a here-document inside $( ) inside ${…}", P2, 'X=${Y:-$(bash -s <<EOF\n$P_N\nEOF\n)}\n', ACT, BODY),
    ("refused: P_N in a here-document inside $( ) inside $(( ))", P2, 'Z=$(( $(bash -s <<EOF\n$P_N\nEOF\n) + 1 ))\n', ACT, BODY),
    ("refused: P_N in a <<$(x y) here-document", P2, "", '  bash -s <<$(x y)\n$\n$P_N\n$(x y)\n' + ACT, BODY),
    ("refused: P_N in a <<$'E\\eF' here-document", P2, "", "  cat <<$'E\\eF'\n$P_N\nE\x1bF\n" + ACT, BODY),
    ("refused: P_N in a <<$'A\\x4' here-document", P2, "", "  cat <<$'A\\x4'\n$P_N\nA\x04\n" + ACT, BODY),
    ("refused: a here-document delimiter after a line continuation (<<\\)", P2, "", '  bash -s <<\\\nEOF\n\n$P_N\nEOF\n' + ACT,
     UNDECIDED),
    ("refused: a here-document delimiter split by a line continuation (<<E\\)", P2, "", '  bash -s <<E\\\nOF\n$P_N\nEOF\n' + ACT,
     UNDECIDED),
    ("refused: a here-document delimiter with a quote left open", P2, "", "  bash -s <<'E\nF'\n" + ACT, UNDECIDED),
    ("refused: a here-document that no line closes", P2, "", "  cat <<NEVER_CLOSED\n" + ACT, "no line closes"),
    ("refused: code after a << inside ${…} and $[…] is still read as code", P2, 'X=a\nZ=${X//<</y}\nV=$[1<<2]\necho $P_N\n', ACT,
     "unquoted"),
    ("refused: code after an assignment subscript a[1<<E]= is still read as code", P2, 'E() {\n  :\n}\na[1<<E ]=1\n',
     ACT + '\n  gh pr merge 1 --squash\n  E', "privileged command outside write()"),
    ("refused: a NUL byte that would hide a << from the checks", P, "", '  bash -s <\x00<EOF\n$P_N\nEOF\n' + ACT, "NUL byte"),
    ("refused: a NUL byte that would hide a parameter name from the checks", P, "", '  eval "$P_\x00N"\n' + ACT, "NUL byte"),
    ("refused: code after $[ a[0] << 1 ] is still read as code", P2, 'V=$[ a[0] << 1 ]\necho $P_N\n', ACT, "unquoted"),
    ("allowed: << as a shift in $(( )) and (( ))", P2, 'S=$((1 << 2))\n(( S <<= 1 ))\n', ACT, None),
    ("allowed: here-documents with quoted, backslashed and numeric delimiters, then code", P2, "",
     "  cat <<'E-F'\nhello\nE-F\n  cat <<\\EOF\nhi\nEOF\n  cat <<1\nx\n1\n  echo \"$P_N\"\n" + ACT, None),
    ("allowed: a <<\"E-F\" and a <<-EOF here-document, then code", P2, "",
     '  cat <<"E-F"\nhello\nE-F\n  cat <<-EOF\n\thi\n\tEOF\n  echo "$P_N"\n' + ACT, None),
    ("allowed: a <<$'E\\tF' here-document, then code", P2, "", "  cat <<$'E\\tF'\nhello\nE\tF\n  echo \"$P_N\"\n" + ACT, None),
    ("allowed: a <<$'E\\eF' here-document, then code", P2, "", "  cat <<$'E\\eF'\nhello\nE\x1bF\n  echo \"$P_N\"\n" + ACT, None),
    ("allowed: a <<$(x y) here-document, then code", P2, "", '  cat <<$(x y)\nhello\n$(x y)\n  echo "$P_N"\n' + ACT, None),
    ("allowed: a here-document inside $( ) inside ${…}, then code", P2, 'X=${Y:-$(cat <<EOF\nhi\nEOF\n)}\necho "$P_N"\n', ACT, None),
    ("allowed: a here-string of a word value, with code after it", P, "", '  cat <<< "$P_N"\n  cat <<< "x"\n' + ACT, None),
    # a segment derived from a value: dest=/tmp/w/--force/x gives --force through basename of its dirname
    ("refused: basename of the dirname of a value", P, "", '  ls "$(basename "$(dirname "$P_DEST")")"\n' + ACT, SEG),
    ("refused: x=$(basename value)", P, "", '  x=$(basename "$P_DEST")\n  ls "$x"\n' + ACT, SEG),
    ("refused: basename of a value in backticks", P, "", '  x=`basename "$P_DEST"`\n  ls "$x"\n' + ACT, SEG),
    ("refused: basename of a value into a pipe", P, "", '  basename "$P_DEST" | xargs ls\n' + ACT, SEG),
    ("refused: basename of a value after a -- that is basename's own", P, "", '  ls "$(basename -- "$P_DEST")"\n' + ACT, SEG),
    ("refused: a copy trimmed with ##*/", P, 'D="$P_DEST"\n', '  ls "${D##*/}"\n' + ACT, SEG),
    ("refused: a local copy trimmed with #*/", P, "", '  local d="${P_DEST}"\n  ls "${d#*/}"\n' + ACT, SEG),
    ("refused: a copy transformed with @E", P, 'D="$P_DEST"\n', '  ls "${D@E}"\n' + ACT, SEG),
    ("refused: an array copy cut with ##*/", P, 'A=( /x "$P_DEST" )\n', '  ls "${A[1]##*/}"\n' + ACT, SEG),
    ("refused: a for variable over a value cut with ##*/", P, "", '  for d in "$P_DEST"; do\n    ls "${d##*/}"\n  done\n' + ACT, SEG),
    ("allowed: a suffix trim of a copy keeps its first character (dirname's reason)", P, 'D="$P_DEST"\nQ="head=$P_N"\n',
     '  ls "${D%/*}" "${Q%%=*}"\n' + ACT, None),
    ("refused: a copy cut with #prefix", P, 'D="$P_DEST"\n', '  ls "${D#/tmp/w/}"\n' + ACT, SEG),
    ("refused: a copy cut as a substring", P, 'D="$P_DEST"\n', '  ls "${D:7}"\n' + ACT, SEG),
    ("refused: a copy with a replacement", P, 'D="$P_DEST"\n', '  ls "${D/\\/tmp\\/w\\//}"\n' + ACT, SEG),
    ("refused: a dirname result trimmed with ##*/", P, "", '  d=$(dirname "$P_DEST")\n  ls "${d##*/}"\n' + ACT, SEG),
    ("refused: basename of a copy", P, 'D="$P_DEST"\n', '  ls "$(basename "$D")"\n' + ACT, SEG),
    ("refused: basename of a copy of a copy", P, 'D="$P_DEST"\nE="$D"\n', '  ls "$(basename "$E")"\n' + ACT, SEG),
    # round 1 of the review: an assignment's own --, basename -a, printf -v, and command output that is not a segment
    ("refused: local -- x=$(basename …): local's own --", P, "", '  local -- x=$(basename "$(dirname "$P_DEST")")\n  ls "$x"\n' + ACT, SEG),
    ("refused: export -- x=\"$(basename …)\"", P, "", '  export -- x="$(basename "$P_DEST")"\n  ls "$x"\n' + ACT, SEG),
    ("refused: ./ before basename -a (two words)", P, "", '  ls ./"$(basename -a "$P_DEST" "$(dirname "$P_DEST")")"\n' + ACT, SEG),
    ("refused: basename --multiple after --", P, "", '  ls -- $(basename --multiple "$P_DEST" /y)\n' + ACT, SEG),
    ("refused: a printf -v copy cut with ##*/", P, "", '  printf -v d %s "$P_DEST"\n  ls "${d##*/}"\n' + ACT, SEG),
    ("refused: a value inside a longer string, cut with #", P, 'X="pre/$P_DEST"\n', '  ls "${X#pre//tmp/w/}"\n' + ACT, SEG),
    ("refused: a ./ basename result cut with #./", P, "", '  x="./$(basename "$P_DEST")"\n  ls "${x#./}"\n' + ACT, SEG),
    ("allowed: the output of a command that reads a value, cut", P, "",
     '  SHA=$(gh api "repos/$P_N/commits/main" --jq .sha)\n  REF=$(git -C "$P_DEST" symbolic-ref HEAD)\n'
     '  echo "${SHA:0:7}" "${REF#refs/heads/}"\n' + ACT, None),
    # round 2: basename's abbreviated and attached options, and a dirname behind a wrapper
    ("refused: ./ before basename --mul (an abbreviation of --multiple)", P, "", '  ls ./$(basename --mul "$P_DEST" "$(dirname "$P_DEST")")\n' + ACT, SEG),
    ("refused: ./ before basename --suf=.x", P, "", '  ls ./$(basename --suf=.x "$P_DEST" /y)\n' + ACT, SEG),
    ("refused: ./ before basename -s.x (attached)", P, "", '  ls ./$(basename -s.x "$P_DEST" /y)\n' + ACT, SEG),
    ("refused: basename with three operands", P, "", '  ls ./$(basename "$P_DEST" /y /z)\n' + ACT, SEG),
    ("allowed: ./ before basename -z, and an -a after basename's --", P, "",
     '  ls ./"$(basename -z "$P_DEST")" ./"$(basename -- "$P_DEST")"\n' + ACT, None),
    ("refused: a command -p dirname copy cut with ##*/", P, "", '  d=$(command -p dirname "$P_DEST")\n  ls "${d##*/}"\n' + ACT, SEG),
    ("refused: an LC_ALL=C dirname copy cut with #*/", P, "", '  d=$(LC_ALL=C dirname "$P_DEST")\n  ls "${d#*/}"\n' + ACT, SEG),
    ("refused: a dirname copy behind cd and a subshell", P, "", '  d=$(cd /; ( dirname "$P_DEST" ))\n  ls "${d##*/}"\n' + ACT, SEG),
    ("refused: a printf -v d[0] copy cut", P, "", '  printf -v "d[0]" %s "$P_DEST"\n  ls "${d[0]##*/}"\n' + ACT, SEG),
    ("allowed: printf -v of a constant, then a value after &&", P, "", '  printf -v d %s x && ls "$P_DEST"\n  echo "${d#x}"\n' + ACT, None),
    # round 3: a quoted | or & does not end a printf -v or for value; a redirection or a pipe is not a basename operand
    ("refused: printf -v with a quoted | in the format, cut", P, "", "  printf -v d '%s|' \"$P_DEST\"\n  ls \"${d#/tmp/w/}\"\n" + ACT, SEG),
    ("refused: printf -v with a quoted && in the format, cut", P, "", '  printf -v d "%s && %s" y "$P_DEST"\n  ls "${d#/tmp/w/}"\n' + ACT, SEG),
    ("refused: for over a quoted a|b and a value, cut", P, "",
     '  for v in "a|b" "$P_DEST"; do\n    ls "${v#/tmp/w/}"\n  done\n' + ACT, SEG),
    ("refused: for over a quoted a&&b and a value, cut", P, "",
     '  for v in "a&&b" "$P_DEST"; do\n    ls "${v#/tmp/w/}"\n  done\n' + ACT, SEG),
    ("allowed: ./ before basename with 2>&1, || true, | head and 2> /dev/null", P, "",
     '  ls ./"$(basename "$P_DEST" 2>&1)" ./"$(basename "$P_DEST" || true)" ./"$(basename "$P_DEST" | head -1)"'
     ' ./"$(basename "$P_DEST" 2> /dev/null)"\n' + ACT, None),
    ("allowed: ./ before basename of a value", P, "", '  ls ./"$(basename "$P_DEST")"\n' + ACT, None),
    ("allowed: x=\"./$(basename value)\"", P, "", '  x="./$(basename "$P_DEST")"\n  ls "$x"\n' + ACT, None),
    ("allowed: basename of a value after the command's --", P, "", '  ls -- "$(basename "$P_DEST")"\n' + ACT, None),
    ("allowed: dirname of a value (it keeps the value's first character)", P, "",
     '  d=$(dirname "$P_DEST")\n  ls "$d"\n' + ACT, None),
    ("allowed: a copy read whole, with a default, and its length", P, 'SHA="$P_DEST"\n',
     '  echo "$SHA" "${SHA}" "${SHA:-none}" "${SHA:+x}" "${#SHA}"\n' + ACT, None),
    ("allowed: basename of a name that is not a value", P, 'R=/x/y\n', '  ls "$(basename "$R")"\n' + ACT, None),
]

# (label, type, arg, value, refused: None for allowed, else a phrase)
VALUES = [("allowed: int 0", "int", None, "0", None), ("allowed: int 42", "int", None, "42", None),
          ("refused: int 042", "int", None, "042", "not a int"), ("refused: int of 19 digits", "int", None, "1" * 19, "not a int"),
          ("allowed: sha40", "sha40", None, "a" * 40, None), ("refused: sha40 upper case", "sha40", None, "A" * 40, "not a sha40"),
          ("refused: sha40 of 39", "sha40", None, "a" * 39, "not a sha40"), ("allowed: sha256", "sha256", None, "0" * 64, None),
          ("refused: sha256 of 63", "sha256", None, "0" * 63, "not a sha256"),
          ("allowed: name", "name", None, "pod-file_put1", None), ("refused: name with a dot", "name", None, "a.b", "not a name"),
          ("refused: name upper case", "name", None, "Ab", "not a name"), ("refused: name of 101", "name", None, "a" * 101, "not a name"),
          ("allowed: repo", "repo", None, "Org-1/repo.name_x", None), ("refused: repo of three parts", "repo", None, "o/r/x", "not a repo"),
          ("refused: repo name starting with a dot", "repo", None, "o/.r", "not a repo"),
          ("allowed: ref", "ref", None, "feature/x-1.2", None), ("refused: ref a..b", "ref", None, "a..b", "check-ref-format"),
          ("refused: ref a//b", "ref", None, "a//b", "check-ref-format"), ("refused: ref /a", "ref", None, "/a", "check-ref-format"),
          ("refused: ref .a", "ref", None, ".a", "check-ref-format"), ("refused: ref a/", "ref", None, "a/", "check-ref-format"),
          ("refused: ref a.", "ref", None, "a.", "check-ref-format"), ("refused: ref a.lock", "ref", None, "a.lock", "check-ref-format"),
          ("refused: ref a/.b", "ref", None, "a/.b", "check-ref-format"), ("refused: ref HEAD", "ref", None, "HEAD", "another ref"),
          ("refused: ref FETCH_HEAD", "ref", None, "FETCH_HEAD", "another ref"), ("refused: ref refs/heads/x", "ref", None, "refs/heads/x", "another ref"),
          ("refused: ref heads/x", "ref", None, "heads/x", "another ref"), ("refused: ref of 40 hex", "ref", None, "a" * 40, "another ref"),
          ("refused: ref with ~", "ref", None, "a~1", "[A-Za-z0-9._/-]"), ("refused: ref with :", "ref", None, "a:b", "[A-Za-z0-9._/-]"),
          ("refused: ref of 201", "ref", None, "a" * 201, "[A-Za-z0-9._/-]"),
          ("allowed: path", "path", None, "/srv/a/b.c@1+2", None), ("refused: path relative", "path", None, "a/b", "absolute"),
          ("refused: path with ..", "path", None, "/a/../b", ". or .."), ("refused: path with .", "path", None, "/a/./b", ". or .."),
          ("refused: path //a", "path", None, "//a", "//"), ("refused: path with a trailing /", "path", None, "/a/", "//"),
          ("refused: path /", "path", None, "/", "//"), ("refused: path segment -b", "path", None, "/a/-b", "starts with -"),
          ("refused: path segment +b", "path", None, "/a/+b", "starts with +"), ("refused: path segment @b", "path", None, "/a/@b", "starts with @"),
          ("refused: path of one segment -b", "path", None, "/-b", "starts with -"),
          ("allowed: path with a -b segment in the middle", "path", None, "/a/-b/c", None),
          ("allowed: path with a +b segment in the middle", "path", None, "/a/+b/c", None),
          ("allowed: path with a @b segment in the middle", "path", None, "/a/@b/c", None),
          ("allowed: path with a -b first segment", "path", None, "/-b/c", None),
          ("allowed: a scratchpad-shaped path", "path", None, "/tmp/claude-1000/-home-u-proj/0427b41-bdfa/scratchpad/body.txt", None),
          ("refused: a scratchpad-shaped path with a -x file name", "path", None, "/tmp/claude-1000/-home-u-proj/0427b41-bdfa/scratchpad/-x", "starts with -"),
          ("refused: a -b segment in the middle before a .. segment", "path", None, "/a/-b/../c", ". or .."),
          ("allowed: under: a base with a -b segment, a value below it", "under", "/tmp/claude-1000/-home-u-proj/s/scratchpad",
           "/tmp/claude-1000/-home-u-proj/s/scratchpad/x", None),
          ("refused: under: a base with a -b segment, a value outside it", "under", "/tmp/claude-1000/-home-u-proj/s/scratchpad",
           "/tmp/claude-1000/-home-u-proj/s/other/x", "neither"),
          ("allowed: url with a -b segment in the middle", "url", None, "https://h.example/a/-b/c", None),
          ("refused: url with a -b last segment", "url", None, "https://h.example/a/-b", "path"),
          ("refused: path with a space", "path", None, "/a b", "outside"), ("refused: path with *", "path", None, "/a*", "outside"),
          ("refused: path of 1025", "path", None, "/" + "a" * 1024, "longer"),
          ("allowed: under its base", "under", "/srv/base", "/srv/base/x", None), ("allowed: under: the base itself", "under", "/srv/base", "/srv/base", None),
          ("refused: under: a sibling with the base as prefix", "under", "/srv/base", "/srv/base2/x", "neither"),
          ("refused: under: outside", "under", "/srv/base", "/etc/x", "neither"),
          ("allowed: under:~", "under", "~", "/srv/u/x", None), ("refused: under:~ outside HOME", "under", "~", "/srv/v/x", "neither"),
          ("allowed: url", "url", None, "https://api.example.com:6443/a/b", None), ("allowed: url of an IPv4 host", "url", None, "https://192.0.2.1", None),
          ("refused: url http", "url", None, "http://example.com", "https://"), ("refused: url with userinfo", "url", None, "https://u@example.com", "https://"),
          ("refused: url with a query", "url", None, "https://example.com/a?b", "path"), ("refused: url with a fragment", "url", None, "https://example.com/#x", "path"),
          ("refused: url upper-case host", "url", None, "https://Example.com", "https://"), ("refused: url port 0", "url", None, "https://h.example:0", "https://"),
          ("refused: url port 65536", "url", None, "https://h.example:65536", "65535"), ("refused: url IPv4 256", "url", None, "https://192.0.2.256", "IPv4"),
          ("refused: url with ..", "url", None, "https://h.example/a/../b", "path"), ("refused: url with a trailing /", "url", None, "https://h.example/", "path"),
          ("refused: url of 2049", "url", None, "https://h.example/" + "a" * 2040, "2048"),
          ("allowed: enum", "enum", ("a", "b-c"), "b-c", None), ("refused: enum not listed", "enum", ("a", "b-c"), "c", "one of"),
          ("refused: a value with a newline", "path", None, "/a\nb", "control"), ("refused: a value with a CR", "path", None, "/a\rb", "control"),
          ("refused: a value with a tab", "path", None, "/a\tb", "control"), ("refused: a value with ESC", "path", None, "/a\x1bb", "control"),
          ("refused: a value with NUL", "path", None, "/a\x00b", "control"), ("refused: a value with DEL", "path", None, "/a\x7fb", "control"),
          ("refused: a value with a C1 control", "path", None, "/a\x85b", "control"),
          ("refused: a value with U+200B (Cf)", "path", None, "/a\u200bb", "format"),
          ("refused: a value with U+202E (Cf)", "path", None, "/a\u202eb", "format"),
          ("refused: a value with U+2028 (Zl)", "path", None, "/a\u2028b", "separator"),
          ("refused: a value with U+2029 (Zp)", "path", None, "/a\u2029b", "separator"),
          ("refused: a value that is not UTF-8", "path", None, "/a\udcffb", "UTF-8")]
for c in "-+:@=~%":
    VALUES.append(("refused: a value starting with %s" % c, "name", None, c + "x", "starts with %s" % c))
    VALUES.append(("refused: a path starting with %s" % c, "path", None, c + "/x", "starts with %s" % c))
VALUES.append(("refused: an empty value", "name", None, "", "empty"))

# (label, params, refused phrase or None)
GRAMMAR = [("allowed: every type", "a=int b=sha40 c=sha256 d=name e=repo f=ref g=path h=url i=file j=input l=under:~/x", None),
           ("refused: a text type (free text goes through an input file)", "a=text", "the type is one of"),
           ("allowed: under: an absolute directory and enum", "a=under:/srv/x b=enum:x|y-z", None),
           ("refused: an unknown type", "a=string", "the type is one of"), ("refused: a key in upper case", "A=int", "<key>=<type>"),
           ("refused: a key of 33", "a" * 33 + "=int", "<key>=<type>"), ("refused: no =", "a", "<key>=<type>"),
           ("refused: two spaces", "a=int  b=int", "single spaces"), ("refused: a key twice", "a=int a=name", "given twice"),
           ("refused: 13 keys", " ".join("k%d=int" % i for i in range(13)), "at most 12"),
           ("refused: a key naming a token", "gh_token=name", "names a secret"), ("refused: a key naming a secret", "my_secret=name", "names a secret"),
           ("refused: a key naming a password", "passwd=name", "names a secret"), ("refused: a key naming a credential", "credentials=name", "names a secret"),
           ("refused: a key naming an apikey", "apikey=name", "names a secret"), ("refused: a key naming an api_key", "x_api_key=name", "names a secret"),
           ("refused: under: a relative directory", "a=under:srv", "the type is one of"), ("refused: under: with ..", "a=under:/srv/../x", "the type is one of"),
           ("refused: an enum word with a dot", "a=enum:x|y.z", "the type is one of"), ("refused: an empty enum", "a=enum:", "the type is one of"),
           ("refused: an empty Params", "", "empty"), ("refused: a Params line over 400 characters", " ".join("k%d=under:/%s" % (i, "a" * 30) for i in range(12)), "over 400")]


def table(plugin, which):
    b = load(plugin)
    out = []
    if which == "reader":
        for case in READER:
            label, params, top, act, want = case[:5]
            text = baton(plugin, params, T, top, act, block=case[5] if len(case) > 5 else None)
            probs = check_text(b, text)
            good = not probs if want is None else any(want in p for p in probs)
            out.append((good, label, "; ".join(probs)[:300]))
    elif which == "values":
        for label, typ, arg, value, want in VALUES:
            p = b.value_problem(typ, arg, value, "/srv/u")
            out.append((p is None if want is None else bool(p and want in p), label, p or "ok"))
        # check lets dirname of a value pass because its result keeps the value's first character: every type refuses a leading -
        for typ in b.PARAM_TYPES:
            p = b.value_problem(typ, "/srv" if typ == "path" else None, "-x/--force/y", "/srv/u")
            out.append((bool(p and "starts with -" in p), "refused: a %s value starting with -" % typ, p or "ok"))
    elif which == "grammar":
        for label, params, want in GRAMMAR:
            text = baton(plugin, params, "/x — the file", act='  write "put /x" true', block="")
            probs = [p for p in check_text(b, text) if "Params" in p]
            good = not probs if want is None else any(want in p for p in probs)
            out.append((good, label, "; ".join(probs)[:300]))
    elif which == "owner":
        exe = os.path.join(plugin, "scripts", "baton.py")
        cmd = "python3 %s sign --by owner --seal 0123456789abcdef.0123456789abcdef " % exe
        for label, words, want in (("accepted: project:<name>", "project:pod-file-put src=/srv/a", True),
                                   ("accepted: user:<name>", "user:pod-file-put src=/srv/a", True),
                                   ("accepted: kit:<name> as before", "kit:merge-pr --repo o/r", True),
                                   ("refused: Project:<name>", "Project:x a=1", False), ("refused: lib:<name>", "lib:x a=1", False),
                                   ("refused: a project name with a dot", "project:a.b a=1", False),
                                   ("refused: a quoted value", "project:x 'title=fix the bug'", False),
                                   ("refused: a value that is not ASCII", "project:x title=tiêu", False)):
            got = b.owner_shape(cmd + words) is not None
            out.append((got == want, label, "accepted" if got else "refused"))
    for good, label, why in out:
        print("%s\t%s\t%s" % ("PASS" if good else "FAIL", label, why.replace("\n", " ").replace("\t", " ")))


def main(argv):
    if argv[0] == "make":
        plugin, out, params, targets = argv[1:5]
        kw = {}
        if len(argv) > 5:
            kw["top"] = argv[5]
        if len(argv) > 6:
            kw["act"] = argv[6]
        if len(argv) > 7:
            kw["expect"] = argv[7]
        with open(out, "w", encoding="utf-8") as f:
            f.write(baton(plugin, params, targets, **kw))
        return 0
    if argv[0] == "table":
        table(argv[1], argv[2])
        return 0
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
