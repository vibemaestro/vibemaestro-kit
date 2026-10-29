#!/usr/bin/env python3
"""`brain`: the vibemaestro-brain CLI (B1.1: op, owner, claim, render, doctor; B1.3: matrix, cost).

    brain op add --kind now|next|trap|session|queue|fact --text T [--expires ISO] [--link L]… [--anchor A]… [--closes A]…
    brain op close ID --reason R [--pointer P] [--bulk]
    brain op supersede ID --text T --reason R [--drop-anchor A]… [--anchor A]… [--closes A]… [--shorter] [--bulk]
    brain op touch ID | brain op hit ID
    brain op close-linked
    brain owner add --kind decision|window --text T --owner-quote Q --where W [--anchor A]… [--link L]… [--expires ISO]
    brain owner unpin ID | owner supersede ID --text T | owner promote ID POINTER
    brain claim [--take-over]
    brain render [--check]
    brain doctor [--path]
    brain matrix [--json]
    brain cost TRANSCRIPT [--merge-log F] [--json]

rc 0 ok; 1 refused (sensitive, cap, budget, rule); 3 not the writer session; 4 sandbox worker; 5 the log does not match
head.json; 6 owner item without an approved dialog; 7 no Claude Code session; 2 (cost) the transcript or merge log cannot be read; 64 usage; 70 an internal error (named, never a traceback, so it cannot
read as a refusal).
The owner argv is strict, because B1.2's dialog line is built from the same tokens: each option spelled in full, its value
as the next token (no `--opt=value`; a value may start with `-`), and a single-value option at most once. `brain op` never touches a `D` or `W` item: those go through
`brain owner`, which writes only with a fresh, matching, unused "asked" record of Claude Code's permission dialog.
"""
import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import brain_store as s  # noqa: E402


class Parser(argparse.ArgumentParser):
    def __init__(self, *a, **k):
        k.setdefault("allow_abbrev", False)
        argparse.ArgumentParser.__init__(self, *a, **k)

    def error(self, message):
        self.print_usage(sys.stderr)
        sys.stderr.write("brain: %s\n" % s.printable(message))
        sys.exit(64)


CLOSES_HELP = ("owner/name#N or an issue or PR URL whose close means this item is done (not one it waits on, not a tracking "
               "issue); at most 2, all must be done; for now, next, session and queue")
OWNER_OPTIONS = {"add": ({"--kind", "--text", "--owner-quote", "--where", "--expires"}, {"--anchor", "--link"}),
                 "supersede": ({"--text"}, set()), "unpin": (set(), set()), "promote": (set(), set())}


def owner_grammar(args):
    """Refuse (64) an owner argv that argparse would read differently from its tokens."""
    if not args or args[0] not in OWNER_OPTIONS:
        return
    single, multi = OWNER_OPTIONS[args[0]]
    seen, i = set(), 1
    while i < len(args):
        a = args[i]
        if a.startswith("-"):
            if a not in single | multi:
                raise s.Refused(64, "brain owner %s: option %s is not spelled in full, takes no `=`, or is unknown"
                                % (args[0], a))
            if a in single and a in seen:
                raise s.Refused(64, "brain owner %s: %s is given twice" % (args[0], a))
            seen.add(a)
            i += 2
        else:
            i += 1


def owner_argv(args):
    """The checked owner argv as argparse must read it: each option joined to the token after it, so a value that starts with
    `-` is a value (argparse would take `--text -x` for two options). The record still matches the tokens as typed."""
    out, i = [], 0
    while i < len(args):
        if i > 0 and args[i].startswith("-") and i + 1 < len(args):
            out.append("%s=%s" % (args[i], args[i + 1]))
            i += 2
        else:
            out.append(args[i])
            i += 1
    return out


def parser():
    p = Parser(prog="brain", description="vibemaestro-brain: hot memory that survives compaction")
    sub = p.add_subparsers(dest="cmd", parser_class=Parser)
    sub.required = True

    op = sub.add_parser("op", help="one delta on a non-owner item").add_subparsers(dest="verb", parser_class=Parser)
    op.required = True
    a = op.add_parser("add")
    a.add_argument("--kind", required=True, help="now, next or trap; session (a running session: its next step and "
                   "pointers, ≤ 450), queue (what waits on the owner) or fact (a path in use, a fact)")
    a.add_argument("--text", required=True)
    a.add_argument("--expires")
    a.add_argument("--link", action="append", default=[])
    a.add_argument("--anchor", action="append", default=[])
    a.add_argument("--closes", action="append", default=[], help=CLOSES_HELP)
    c = op.add_parser("close")
    c.add_argument("id")
    c.add_argument("--reason", required=True)
    c.add_argument("--pointer")
    c.add_argument("--bulk", action="store_true")
    u = op.add_parser("supersede")
    u.add_argument("id")
    u.add_argument("--text", required=True)
    u.add_argument("--reason", required=True)
    u.add_argument("--drop-anchor", action="append", default=[])
    u.add_argument("--anchor", action="append", default=[])
    u.add_argument("--closes", action="append", default=[], help=CLOSES_HELP + "; without it the item's own are carried over")
    u.add_argument("--shorter", action="store_true")
    u.add_argument("--bulk", action="store_true")
    for v in ("touch", "hit"):
        op.add_parser(v).add_argument("id")
    op.add_parser("close-linked", help="close every item whose closes anchors are all done (fresh lookups)")

    ow = sub.add_parser("owner", help="owner decisions and windows, through the permission dialog")
    ov = ow.add_subparsers(dest="verb", parser_class=Parser)
    ov.required = True
    a = ov.add_parser("add")
    a.add_argument("--kind", required=True, choices=["decision", "window"])
    a.add_argument("--text", required=True)
    a.add_argument("--owner-quote", required=True)
    a.add_argument("--where", required=True)
    a.add_argument("--expires")
    a.add_argument("--link", action="append", default=[])
    a.add_argument("--anchor", action="append", default=[])
    ov.add_parser("unpin").add_argument("id")
    u = ov.add_parser("supersede")
    u.add_argument("id")
    u.add_argument("--text", required=True)
    pr = ov.add_parser("promote")
    pr.add_argument("id")
    pr.add_argument("pointer")

    sub.add_parser("claim").add_argument("--take-over", action="store_true")
    sub.add_parser("render").add_argument("--check", action="store_true")
    sub.add_parser("doctor").add_argument("--path", action="store_true")
    sub.add_parser("matrix", help="the Brain Matrix").add_argument("--json", action="store_true")
    c = sub.add_parser("cost", help="a transcript's usage at baseline A's weights")
    c.add_argument("transcript")
    c.add_argument("--merge-log")
    c.add_argument("--json", action="store_true")
    return p


def main(argv):
    if argv[:1] == ["owner"]:
        owner_grammar(argv[1:])
        ns = parser().parse_args(argv[:1] + owner_argv(argv[1:]))
    else:
        ns = parser().parse_args(argv)
    note = s.session_note() if ns.cmd != "cost" else None
    if note:
        sys.stderr.write("brain: %s\n" % s.printable(note))
    if ns.cmd == "op":
        if ns.verb == "add":
            return s.op_add(ns.kind, ns.text, ns.link, ns.anchor, ns.expires, ns.closes)
        if ns.verb == "close":
            return s.op_close(ns.id, ns.reason, ns.pointer, ns.bulk)
        if ns.verb == "supersede":
            return s.op_supersede(ns.id, ns.text, ns.reason, ns.drop_anchor, ns.anchor, ns.shorter, ns.bulk, ns.closes)
        if ns.verb == "close-linked":
            import brain_stale
            return brain_stale.close_linked()
        return s.op_counter(ns.id, ns.verb)
    if ns.cmd == "owner":
        return s.owner(argv[1:], ns.verb, ns)
    if ns.cmd == "claim":
        return s.claim(ns.take_over)
    if ns.cmd == "render":
        return render(ns.check)
    if ns.cmd == "matrix":
        import brain_matrix
        return brain_matrix.main(ns.json)
    if ns.cmd == "cost":
        return cost(ns.transcript, ns.merge_log, ns.json)
    return doctor(ns.path)


def cost(path, merge_log, as_json):
    import json
    import brain_cost
    try:
        r = brain_cost.parse(path).report()
    except OSError as e:
        raise s.Refused(2, "cannot read %s (%s)" % (path, e.__class__.__name__))
    merged = None
    if merge_log:
        merged = brain_cost.merged_in_span(merge_log, r["first"], r["through"])
        if merged is None:
            raise s.Refused(2, "cannot read the merge log %s" % merge_log)
        r["merged"] = merged
        r["units_per_merged_pr"] = r["units"]["total"] / merged if merged else None
    if as_json:
        sys.stdout.write(json.dumps(r) + "\n")
    else:
        sys.stdout.write("".join(s.printable(l) + "\n" for l in brain_cost.text(os.path.basename(path), r, merged).split("\n")))
    return None


def render(check):
    d = s.state_dir()
    if not os.path.isdir(d):
        raise s.Refused(1, "no brain state for this project yet")
    with s.locked(d):
        head, st = s.load(d)
        if s.cache_state(d, head) is None:
            s.write_caches(d, st, head)
        parts = s.render_parts(st)
        text = s.join_parts(parts)
        s._write_file(os.path.join(d, "hot.md"), text)
    if check:
        over = []
        for p, letters in s.PARTS:
            cap = s.RENDER_CAP if p == "hot" else s.STRING_MAX
            if len(parts[p]) > cap:
                over.append(p)
            sys.stdout.write("%s render: %s of %s characters%s\n" % (
                {"hot": "hot memory", "sessions": "sessions", "plan": "plan"}[p], "{:,}".format(len(parts[p])),
                "{:,}".format(cap), " — OVER the cap" if len(parts[p]) > cap else ""))
            for letter in letters:
                sys.stdout.write("  %s: %d of %d\n" % (dict(s.SECTIONS)[letter], len(s.live(st, letter)), s.CAPS[letter]))
                if letter == "T":
                    sys.stdout.write("  %s: %d\n" % (s.DONE_TITLE, len(s.done_items(st, time.time()))))
        if over:
            raise s.Refused(1, "the render is over its cap: %s" % ", ".join(over))
        return None
    sys.stdout.write(text)
    return None


def doctor(path):
    if path:
        return s.state_dir()
    res = s.doctor()
    for level, text in res:
        sys.stdout.write("%-8s %s\n" % (level, s.printable(text)))
    if any(level == "problem" for level, _ in res):
        raise s.Refused(1, "brain doctor: %d problem(s)" % sum(level == "problem" for level, _ in res))
    return None


if __name__ == "__main__":
    try:
        msg = main(sys.argv[1:])
    except s.Refused as e:
        sys.stderr.write("brain: %s\n" % s.printable(e.msg))
        sys.exit(e.rc)
    except Exception as e:  # noqa: BLE001 — a traceback exits 1, which would read as a refusal
        sys.stderr.write("brain: internal error: %s: %s\n" % (e.__class__.__name__, s.printable(e)))
        sys.exit(70)
    if msg:
        sys.stdout.write("".join(s.printable(line) + "\n" for line in msg.split("\n")))   # its own lines only
    sys.exit(0)
