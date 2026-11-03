"""planted_lint.py — [L3], [L4] and [L5] of tests/test-capped-breaks.sh: no planted breaks.

A planted break changes the code under test, or a copy of the repository's own files, so that a check must go red
(mutation-style). The kit has none: the evidence for a new test is that it is red on main before the change and green after.
A functional negative case (a checker given a bad input it must report) is not one: it builds its input and uses `capped`.
This lint tells the two apart by what the code does:

  a rewrite    changes text that is already in a file: Python that reads a file (`.read(`, `.read_text(`, `.readlines(`) or
               replaces text (`.replace(`, `re.sub(`) and writes a file (`.write(`, `.write_text(`, `.writelines(`,
               `.write_bytes(`); `sed -i` (any flag cluster with `i`, `--in-place`); `perl` with an `-i` flag; a `sed` or
               `awk` that reads a file (an operand, or `<`) into another (`sed … "$f" > "$copy"`); or a call of a function
               that does one of these (the file's own helpers, and those of tests/fixtures/*.sh: `mutate`). Writing new
               content (`printf > f`, `>> f`, `cp`, `sed` on a pipe) builds an input.
  a red-expected run   `capped` (fixtures/capped.sh caps every run that must go red), or a call of a function that runs it.
  a block      a function body (from `name() {` to the `}` at the same indent, or one line), or a run of top-level lines
               with no blank line between them. Heredoc bodies belong to the block that opens them.
  the marker   `not a break`: on a line, that line's rewrite (and the body of a here-document the line opens) builds a
               checker's input, and a red-expected run on it is a functional case; anywhere in a function, the whole helper
               builds or checks an input (a scratch map, a flow step, a copy's isolation): it is not scanned, and a call of it
               is neither a rewrite nor a break's run.

  [L3] a rewrite followed, in its block, by a red-expected run (ordinary commands in between do not end the pair; the next
       red-expected run does): a planted break. Events on one line keep their order. A capped command that is itself the
       rewrite (`capped sed -i …`, `capped python3` whose here-document writes the file) is a rewrite, not a run. A helper that
       rewrites and runs but never a rewrite before a run (it runs, then restores its copy) is a run for its callers.
  [L4] a call of a planted-break helper of the fixtures: expect_red (ports.sh), plant_break (plant.sh), and every fixture
       function a body of which rewrites and then runs capped (brain.sh `plant`), or that calls one of these (gates.sh
       `BRKG`), unless the file defines its own function of that name.
  [L5] a function whose name says it plants a break (plant, brk, break but not breaking/breakdown/breaks, mutant, mutate,
       sabotage, red_at, expect_red), without the marker.

Not seen (by design, a grep cannot): a rewrite written another way (an editor script, a Python file run from elsewhere), a
rewrite and its run in two separate blocks, a run that is not capped, a function reached through a variable. Review covers those.

Usage: python3 -I -B planted_lint.py <fixtures dir> <file>…   one line per problem, `<file>: [Ln] <why>: <line>`; rc 0 when it
read every file (with or without problems), non-zero and a traceback when it could not.
"""
import os
import re
import sys

FUNC = re.compile(r"^(\s*)(?:function\s+)?([A-Za-z_][\w-]*)\s*\(\)\s*\{(.*)$")
HEREDOC = re.compile(r"(-?)\s*\\?(['\"]?)([A-Za-z_][\w]*)\2")   # what follows `<<`: an optional `-`, then the tag, quoted or not
# sed -i, perl -pi, or sed reading a file operand into a redirect (`sed EXPR "$f" > "$copy"`); sed on a pipe builds new content
MUT_SHELL = re.compile(
    r"\bsed\b[^|;]*\s(?:-[A-Za-z]*i[A-Za-z.]*|--in-place)(?:\s|=|$)"                          # sed -i, -Ei, -i.bak, --in-place
    r"|\bperl\b[^|;]*\s-[A-Za-z]*i"                                                           # perl -pi, -i -pe, -p -i -e
    r"|\b(?:sed|awk)\s+(?:-\S+\s+)*(?:'[^']*'|\"[^\"]*\"|\S+)\s+(?:--\s+)?(?:<\s*)?(?:'[^']*'|\"[^\"]*\"|[^\s<>|;]+)\s*>\s*\S"
    r"|\b(?:sed|awk)\b[^|;]*<\s*\S+[^|;]*>\s*\S")                                              # sed/awk EXPR <file> > <copy>
NOT_A_BREAK = "not a break"   # a trailing comment on a rewrite that builds a checker's input: `sed -i … map  # input, not a break`
PY_EDIT = re.compile(r"\.replace\(|\bre\.subn?\(|(?<!stdin)\.read(?:_text|_bytes|lines)?\(")   # read (or replaced), then written
PY_WRITE = re.compile(r"(?<!stdout)(?<!stderr)\.write(?:_text|_bytes|lines)?\(")   # into a file, not to the terminal
# a word in command position: at the start, after `$(`, `(`, `;`, `&&`, `||`, `|`, `!`, `then`, `do`, or variable assignments
CMD = (r"(?:^|[;&|(!{]|\$\(|\$\{\w+:[+-]|\b(?:then|do|if|elif|while|until|else)\b)\s*(?:\w+=(?:\"[^\"]*\"|'[^']*'|\S*)\s+)*"
       # a wrapper in front of the command: timeout 5, env X=1, command, nice -n 5, time, exec, stdbuf -oL, xargs -0
       r"(?:(?:timeout(?:\s+-[sk]\s*\S+|\s+--(?:signal|kill-after)(?:=|\s+)\S+|\s+--?[\w-]+(?:=\S+)?)*\s+\S+"
       r"|env(?:\s+-[uCS]\s*\S+|\s+--(?:unset|chdir|split-string)(?:=|\s+)\S+|\s+-\S+|\s+\w+=\S*)*|command|nice(?:\s+-n\s*\S+)?|time|exec"
       r"|stdbuf(?:\s+-\S+)+|xargs(?:\s+-\S+)*)\s+)*")
BARE_CAPPED = re.compile(CMD + r"capped(?:\s|\})")   # `${GATE_BIN:+capped} bash …` too


def shell_scan(line, st=None):
    """(the (dash, tag) of the last here-document the line opens, the quote stack at its end). A `<<` inside a quoted string
    (`$'…<<EOF…'`, a label, `"$(f "<<EOF")"`) opens nothing: only one outside quotes, not `<<<`, counts. `$(…)` inside double
    quotes is code again, so the scan keeps a stack of contexts, and the stack a line ends with is where the next line starts
    (a quote opened on one line and closed on a later one)"""
    tag, i, n = None, 0, len(line)
    # None: code; "'", "$'", '"': inside that quote; "(": code inside $(…); "((": $((…)), "(p": a parenthesis inside it. In
    # arithmetic, quotes and $(…) are tracked as in code and `<<` is a shift; the `))` that matches the opening one ends it
    st = list(st) if st else [None]
    while i < n:
        c, q = line[i], st[-1]
        if q in ("((", "(p"):
            if q == "((" and line.startswith("))", i):
                st.pop(); i += 2; continue
            if c == "(" and not line.startswith("$(", i - 1 if i else 0):
                st.append("(p"); i += 1; continue
            if q == "(p" and c == ")":
                st.pop(); i += 1; continue
        if q in (None, "(", "((", "(p"):
            if q in (None, "(") and c == "#" and (i == 0 or line[i - 1] in " \t;"):
                break
            if c == "\\":
                i += 2; continue
            if q == "(" and c == ")":
                st.pop(); i += 1; continue
            if c == "$" and line[i + 1:i + 2] == "'":
                st.append("$'"); i += 2; continue
            if c == "$" and line[i + 1:i + 3] == "((":
                st.append("(("); i += 3; continue
            if c == "$" and line[i + 1:i + 2] == "(":
                st.append("("); i += 2; continue
            if c in "'\"":
                st.append(c); i += 1; continue
            if q in (None, "(") and line.startswith("<<", i) and not line.startswith("<<<", i) and (i == 0 or line[i - 1] != "<"):
                m = HEREDOC.match(line, i + 2)
                if m:
                    tag = (m.group(1), m.group(3)); i = m.end(); continue
        elif q == "'":
            if c == "'":
                st.pop()
        elif c == "\\":
            i += 2; continue
        elif q == '"' and c == "$" and line[i + 1:i + 3] == "((":
            st.append("(("); i += 3; continue
        elif q == '"' and c == "$" and line[i + 1:i + 2] == "(":
            st.append("("); i += 2; continue
        elif c == q[-1]:
            st.pop()
        i += 1
    return tag, st


def heredoc_tag(line):
    return shell_scan(line)[0]


def closes(lines, i, tag):
    """True when a line after lines[i] ends the here-document `tag` opens: an unclosed one was a misread, not a heredoc"""
    for ln in lines[i + 1:]:
        if (ln.strip() if tag[0] else ln) == tag[1]:
            return True
    return False


def blocks(path):
    """([(name or None, [(lineno, text)])], {line inside a here-document: the line that opened it}) of one file. A function runs
    from `name() {` to the `}` at its indent (or is one line); top-level code is cut at blank lines. Inside a here-document or a
    quoted string that spans lines, nothing starts, ends or cuts a block"""
    lines = open(path, encoding="utf-8", errors="replace").read().split("\n")
    out, here, top, cur = [], {}, [], None   # cur: (name, indent, body) of the function being read
    st, tag, opener = [None], None, None

    def flush_top():
        if top:
            out.append((None, list(top)))
            top.clear()

    for i, raw in enumerate(lines):
        n = i + 1
        if tag:
            (cur[2] if cur else top).append((n, raw)); here[n] = opener
            if (raw.strip() if tag[0] else raw) == tag[1]:
                tag = None
            continue
        if st == [None]:   # at a command boundary: a function may start or end, a blank line cuts
            if cur is None:
                m = FUNC.match(raw)
                if m and not raw.lstrip().startswith("#"):
                    flush_top()
                    t2, st2 = shell_scan(m.group(3))
                    if re.search(r"\}\s*(#.*)?$", m.group(3)) and st2 == [None] and not (t2 and closes(lines, i, t2)):
                        out.append((m.group(2), [(n, raw)]))   # a one-line function
                        continue
                    cur = (m.group(2), m.group(1), [(n, raw)])
                    t, st = shell_scan(raw)
                    if t and closes(lines, i, t):
                        tag, opener = t, n
                    continue
                if raw.strip() == "":
                    flush_top()
                    continue
            elif re.match(re.escape(cur[1]) + r"\}\s*(;|#.*)?\s*$", raw):
                cur[2].append((n, raw)); out.append((cur[0], cur[2])); cur = None
                continue
        (cur[2] if cur else top).append((n, raw))
        t, st = shell_scan(raw, st)
        if t and closes(lines, i, t):
            tag, opener = t, n
    if cur:
        out.append((cur[0], cur[2]))
    flush_top()
    return out, here


def code(body, here):
    """the lines of a block that are code: shell comments dropped, heredoc bodies kept (they hold the Python that mutates)"""
    return [(n, t) for n, t in body if n in here or not t.lstrip().startswith("#")]


def mutation_lines(lines, helper=True, here=None):
    """the line numbers of a block that rewrite a file: a shell rewrite, or the write of Python that read or replaced text. A
    helper (a function) with the marker anywhere rewrites nothing; in top-level code only a marked line is left out, and a
    marked line that opens a here-document leaves out its body"""
    if helper and any(NOT_A_BREAK in t for _, t in lines):
        return set()
    out = {n for n, t in lines if MUT_SHELL.search(bare(t))}
    if PY_EDIT.search("\n".join(t for _, t in lines)):
        out |= {n for n, t in lines if PY_WRITE.search(t)}
    text, here = dict(lines), here or {}
    return {n for n in out if NOT_A_BREAK not in text[n] and NOT_A_BREAK not in text.get(here.get(n), "")}


def quote_spans(t):
    """[(kind, open, close)] of the quoted strings of a line, `$(…)` inside double quotes followed as code (its own quotes are
    spans of their own); an unclosed quote runs to the end of the line"""
    spans, st, i, n = [], [(None, -1)], 0, len(t)
    while i < n:
        c, q = t[i], st[-1][0]
        if q in (None, "("):
            if c == "\\":
                i += 2; continue
            if q == "(" and c == ")":
                st.pop(); i += 1; continue
            if c == "$" and t[i + 1:i + 2] == "(":
                st.append(("(", i)); i += 2; continue
            if c == "$" and t[i + 1:i + 2] == "'":
                st.append(("$'", i + 1)); i += 2; continue
            if c in "'\"":
                st.append((c, i)); i += 1; continue
        elif q == "'":
            if c == "'":
                spans.append(("'", st.pop()[1], i))
        elif q == "$'":
            if c == "\\":
                i += 2; continue
            if c == "'":
                spans.append(("'", st.pop()[1], i))
        else:   # inside double quotes
            if c == "\\":
                i += 2; continue
            if c == "$" and t[i + 1:i + 2] == "(":
                st.append(("(", i)); i += 2; continue
            if c == '"':
                spans.append(('"', st.pop()[1], i))
        i += 1
    for q, at in st[1:]:
        if q != "(":
            spans.append(("'" if q == "$'" else q, at, n))
    return spans


def bare(t):
    """the line with quoted text masked as `x…x` (same length, so positions hold, one word for a regex), unless a double-quoted
    string holds an expansion (`$`, a backquote): a label such as "… (red)" is no call, a path such as "$d/x.py" is kept, and
    so is the code of a `"$(…)"` (its own quoted labels masked in turn)"""
    out = list(t)
    for kind, a, b in quote_spans(t):
        body = t[a + 1:b]
        if kind == "'" or not ("$" in body or "`" in body):
            out[a + 1:b] = "x" * len(body)
    return "".join(out)


def has(rx, lines):
    return [(n, t) for n, t in lines if rx.search(bare(t))]


def call_rx(names):
    return re.compile(CMD + r"(" + "|".join(re.escape(n) for n in sorted(names)) + r")(\s|$|\)|;)") if names else None


def calls(lines, names):
    rx = call_rx(names)
    return bool(rx) and any(rx.search(bare(t)) for _, t in lines)


BREAK_HELPERS = ("expect_red", "plant_break")
BREAK_NAME = re.compile(r"(?i)plant|brk|break(?!ing|down|s(?:_|$))|mutant|mutate|sabotage|red_at|expect_red")


def marked(body):
    return any(NOT_A_BREAK in t for _, t in body)


def closure(funcs, seed, skip=()):
    """seed plus every function of funcs (name -> body, or name -> [bodies] when several files define it) that calls one of
    them, directly or through others"""
    out, grew = set(seed), True
    while grew:
        grew = False
        for n, b in funcs.items():
            bodies = b if b and isinstance(b[0], list) else [b]
            if n not in out and n not in skip and any(calls(x, out - {n}) for x in bodies):
                out.add(n); grew = True
    return out


def events(t, muts_here, mut_rx, run_rx, fun_rx, opens_rewrite=False):
    """the line's rewrites and runs in the order they come: ["rewrite"|"run"|"functional"]. A capped command that is itself the
    rewrite (`capped sed -i …`, or `capped python3` whose here-document, opened by that same command, writes the file) is a
    rewrite, not a run. A call of a helper that runs and then restores is a run. Each event sits at the first character of its
    command word"""
    bt, ev = bare(t), []
    if muts_here:
        m = MUT_SHELL.search(bt) or PY_WRITE.search(t)
        ev.append((m.start() if m else 0, 1, "rewrite"))
    for rx, kind, order in ((run_rx, "run", 0), (mut_rx, "rewrite", 1)):
        for m in (rx.finditer(bt) if rx else ()):
            ev.append((m.start(1), order, kind))
    for m in BARE_CAPPED.finditer(bt):
        if MUT_SHELL.match(bt, m.end()) or (opens_rewrite and here_doc_opener(bt, m.end())):
            continue   # the capped command is the rewrite itself
        ev.append((bt.rindex("capped", 0, m.end()), 0, "run"))
    for m in (fun_rx.finditer(bt) if fun_rx else ()):
        ev.append((m.start(1), 0, "functional"))
    if NOT_A_BREAK in t:   # the marked line: its rewrite builds an input, its run is a functional case
        ev = [(p, o, "functional" if k == "run" else k) for p, o, k in ev if k != "rewrite"]
    # commands on a line run in order (`;`, `&&`, `||`, `|` at the top level; not the `&` of `2>&1` or `&>`), and inside one
    # command a command substitution runs before the command it is an argument of: `broken x "$(plant b1 …)"` rewrites, runs
    key, d, seg, i = [], 0, 0, 0
    while i < len(bt):
        if bt.startswith("$(", i):
            key += [(seg, -d), (seg, -d)]; d += 1; i += 2; continue
        if bt[i] == ")" and d:
            d -= 1
        elif d == 0 and bt[i] in ";&|" and not (bt[i] == "&" and (bt[i - 1:i] == ">" or bt[i + 1:i + 2] == ">")):
            seg += 1
        key.append((seg, -d)); i += 1
    at = lambda p: key[min(max(p, 0), len(key) - 1)] if key else (0, 0)
    return [k for _, _, k in sorted(ev, key=lambda e: (at(e[0]), e[0], e[1]))]


def here_doc_opener(bt, pos):
    """True when the command at pos opens a here-document (`python3 - "$f" <<'PY'`) before the command ends (`;`, `&&`, `||`,
    `|`): its body is that command's input. A `<<` of a later command is not"""
    d, i = 0, pos
    while i < len(bt):
        if bt.startswith("$(", i):
            d += 1; i += 2; continue
        if bt[i] == ")" and d:
            d -= 1
        elif d == 0 and bt[i] in ";&|" and not (bt[i] == "&" and (bt[i - 1:i] == ">" or bt[i + 1:i + 2] == ">")):
            return False
        elif bt.startswith("<<", i) and not bt.startswith("<<<", i):
            return True
        i += 1
    return False


def rewrite_openers(muts, here):
    """the lines that open a here-document whose body rewrites a file"""
    return {here[n] for n in muts if n in (here or {})}


def scan(name, b, muts, mut_rx, run_rx, fun_rx, here=None):
    """[(rewrite line, run line, run text)]: each rewrite whose next red-expected run in the block is that rewrite's run"""
    out, pending, openers = [], None, rewrite_openers(muts, here)
    for n, t in b:
        for k in events(t, n in muts, mut_rx, run_rx, fun_rx, n in openers):
            if k == "rewrite":
                pending = n
            elif k == "functional":
                pending = None
            elif k == "run":
                if pending is not None:
                    out.append((pending, n, t))
                pending = None
    return out


def runs(b, here, muts):
    """True when the body itself runs capped as a red-expected run (not a capped command that is its rewrite)"""
    openers = rewrite_openers(muts, here)
    return any("run" in events(t, n in muts, None, None, None, n in openers) for n, t in b)


def analyse(path, shared_mutators, shared_runners, shared_helpers):
    bl, here = blocks(path)
    bl = [(name, code(body, here)) for name, body in bl]
    funcs = {name: body for name, body in bl if name}
    functional = {n for n, b in funcs.items() if marked(b)}   # the marker: it builds or checks an input
    own = set(funcs)   # a function the file defines shadows a fixture's of that name (public-tree's own `plant`)
    mutators = ((set(shared_mutators) - own) | {n for n, b in funcs.items() if mutation_lines(b, here=here)}) - functional
    runners = ((set(shared_runners) - own) | {n for n, b in funcs.items() if runs(b, here, mutation_lines(b, here=here))}) - functional
    grew = True
    while grew:   # one helper calling another: a function that calls a rewriter rewrites, one that calls a runner runs capped
        grew = False
        for n, b in funcs.items():
            if n in functional:
                continue
            if n not in mutators and calls(b, mutators - {n}):
                mutators.add(n); grew = True
            if n not in runners and calls(b, runners - {n}):
                runners.add(n); grew = True
    def rxs(own_name, reported):
        own_ = {own_name} if own_name else set()
        return (call_rx(mutators - runners - own_), call_rx(runners - reported - own_),
                call_rx(functional - own_))
    # a helper that rewrites and runs capped, in that order, is reported where it is defined, not at every call; one that runs
    # first and rewrites after (a restore) leaves its copy as it found it, so a call of it is a run, not a rewrite
    reported = {name for name, b in bl if name in mutators & runners
                and scan(name, b, mutation_lines(b, here=here), *rxs(name, set()), here=here)}
    helper_rx = call_rx((set(shared_helpers) - own) | set(BREAK_HELPERS))
    problems = []
    for name, b in bl:
        if not b:
            continue
        muts = mutation_lines(b, helper=bool(name), here=here)
        for pending, n, t in ([] if name in functional else scan(name, b, muts, *rxs(name, reported), here=here)):
            problems.append("[L3] a planted break: a rewrite (line %d) run to go red: %d: %s" % (pending, n, t.strip()[:120]))
        for n, t in b:
            bt = bare(t)
            if helper_rx and helper_rx.search(bt):
                problems.append("[L4] calls a planted-break helper: %d: %s" % (n, t.strip()[:120]))
        if name and name not in BREAK_HELPERS and BREAK_NAME.search(name) and not marked(b):
            problems.append("[L5] a helper named for a planted break: %d: %s" % (b[0][0], b[0][1].strip()[:120]))
    return problems


def main():
    fixtures, files = sys.argv[1], sys.argv[2:]
    funcs, heres = {}, {}   # name -> [(body, here) of each unmarked definition]: two fixtures may define one name, each counts
    for f in sorted(os.listdir(fixtures)):
        if f.endswith(".sh"):
            bl, here = blocks(os.path.join(fixtures, f))
            for name, body in bl:
                if name and not marked(code(body, here)):
                    funcs.setdefault(name, []).append(code(body, here)); heres.setdefault(name, []).append(here)
    shared = closure(funcs, {n for n, bs in funcs.items() if any(mutation_lines(b, here=h) for b, h in zip(bs, heres[n]))})
    runners = closure(funcs, {n for n, bs in funcs.items()
                              if any(runs(b, h, mutation_lines(b, here=h)) for b, h in zip(bs, heres[n]))})
    # a break helper: a body of it rewrites and then runs capped (brain.sh plant), or it calls one (gates.sh BRKG calls
    # expect_red). `mutate` alone builds inputs too, and a helper that runs and then restores leaves its copy as it found it:
    # neither is one
    breaks = {n for n, bs in funcs.items() if n in shared and n in runners
              and any(scan(n, b, mutation_lines(b, here=h), call_rx(shared - runners - {n}), call_rx(runners - {n}), None, here=h)
                      for b, h in zip(bs, heres[n]))}
    helpers = closure(funcs, set(BREAK_HELPERS) | breaks)
    runners -= helpers; shared -= helpers | runners   # helpers' calls are [L4]; a run-then-restore helper is a run
    for f in files:
        for p in analyse(f, shared, runners, helpers):
            print("%s: %s" % (os.path.basename(f), p))


if __name__ == "__main__":
    main()
