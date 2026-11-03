#!/usr/bin/env python3
"""`brain`: the vibemaestro-brain CLI (B1.1: op, owner, claim, render, doctor; B1.3: matrix, cost; the ledger; export, import
and backup; extensions).

    brain op add --kind now|next|trap|session|queue|fact --text T [--expires ISO] [--link L]… [--anchor A]… [--closes A]…
                 [--focus P1 (next)]
    brain op add --kind focus --text T --owner-quote Q --where W --goal G1 [--anchor A]… [--link L]…
    brain op add --kind request --text T --owner-quote Q --where W [--due YYYY-MM-DD] [--anchor A]… [--closes A]…
    brain op close ID --reason R [--pointer P] [--bulk]          (a request: --pointer required)
    brain op supersede ID --text T --reason R [--drop-anchor A]… [--anchor A]… [--closes A]… [--focus P1] [--due DAY]
                       [--shorter] [--bulk]
    brain op touch ID | brain op hit T5 [--pointer P] [--session S4]
    brain op held RULE --pointer P [--session S4] | brain op broke RULE --pointer P --differed D [--session S4]
    brain op progress G1 --measure M --pointer P
    brain op close-linked
    brain owner add --kind decision|window --text T --owner-quote Q --where W [--anchor A]… [--link L]… [--expires ISO]
                    [--scope global|project (decision)]
    brain owner add --kind goal --text T --owner-quote Q --where W --done D --not-doing N --review YYYY-MM-DD
                    --scope global|project [--anchor A]… [--link L]…
    brain owner unpin ID | owner supersede ID [--text T] [--done D] [--not-doing N] [--review DAY] [--scope S]
    brain owner promote ID POINTER                         (a goal, decision or window moved out to a pointer)
    brain owner import FILE                                (a bundle's goals, decisions and windows: one dialog for all)
    brain owner batch FILE                                 (2 to 5 owner items from a JSON array of owner argv lists: one dialog)
    brain owner backup DIR [--every HOURS] | owner backup off
    brain owner VERB …                                     (a verb a plugin that extends the brain adds: brain doctor lists them)
    brain export --out FILE [--scope global|project]
    brain import FILE [--only LETTERS]
    brain backup [--if-due]
    brain claim [--take-over]
    brain render [--check]
    brain overflow
    brain show ID
    brain ledger [RULE] | brain ledger --record [--days N]
    brain ext NAME [ARG…]                                  (what a plugin that extends the brain prints; it writes nothing)
    brain doctor [--path | --bundle FILE]
    brain matrix [--json]
    brain cost TRANSCRIPT [--merge-log F] [--json]

rc 0 ok; 1 refused (sensitive, cap, budget, rule); 3 not the writer session; 4 a worker session; 5 the log does not match
head.json; 6 owner item without an approved dialog; 7 no Claude Code session; 2 (cost) the transcript or merge log cannot be read; 64 usage; 70 an internal error (named, never a traceback, so it cannot
read as a refusal).
The owner argv is strict, because B1.2's dialog line is built from the same tokens: each option spelled in full, its value
as the next token (no `--opt=value`; a value may start with `-`), and a single-value option at most once. `brain op` never touches a `G`, `D` or `W`
item (`held`, `broke` and `progress` are ledger data about one, never a change to it): those go through `brain owner`, which writes only with a fresh, matching, unused "asked" record of Claude Code's permission
dialog.
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
               "issue); at most 2, all must be done; for now, next, session, queue and request")
GOAL_OPTIONS = {"--done", "--not-doing", "--review", "--scope"}
OWNER_OPTIONS = {"add": ({"--kind", "--text", "--owner-quote", "--where", "--expires"} | GOAL_OPTIONS, {"--anchor", "--link"}),
                 "supersede": ({"--text"} | GOAL_OPTIONS, set()), "unpin": (set(), set()), "promote": (set(), set()),
                 "import": (set(), set()), "backup": ({"--every"}, set()),
                 "batch": (set(), set())}
EFFECT_OPTIONS = {"pin": ({"--text", "--owner-quote", "--where"}, {"--anchor", "--link"}), "archive": (set(), set())}


def owner_options(verb):
    """(single, multi) options of `brain owner VERB`: brain's own, or those of an extension's effect; None for no such verb."""
    if verb in OWNER_OPTIONS:
        return OWNER_OPTIONS[verb]
    _, spec = s.ext_verb(verb)
    return EFFECT_OPTIONS[spec["effect"]] if spec else None


def owner_grammar(args):
    """Refuse (64) an owner argv that argparse would read differently from its tokens."""
    opts = owner_options(args[0]) if args else None
    if opts is None:
        return
    single, multi = opts
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


def goal_options(p):
    p.add_argument("--done", help="a goal: what done means (≤ 200)")
    p.add_argument("--not-doing", help="a goal: what it does not do (≤ 200)")
    p.add_argument("--review", help="a goal: the day the owner reviews it, YYYY-MM-DD, not in the past")
    p.add_argument("--scope", help="a goal or a decision: global (valid in every project) or project (a decision's default)")


def ext_options(p, verb):
    """The options extensions add to `brain op VERB` (each one value), as `ext:--name` in the namespace."""
    if not s.extensions():
        return
    import brain_ext
    for o in brain_ext.option_names(verb):
        p.add_argument(o, dest="ext:" + o, help="(an extension's option)")


def ext_given(ns):
    """{option: value} of the extension options of the parsed command."""
    return {k[4:]: v for k, v in vars(ns).items() if k.startswith("ext:") and v is not None}


def parser():
    p = Parser(prog="brain", description="vibemaestro-brain: hot memory that survives compaction")
    sub = p.add_subparsers(dest="cmd", parser_class=Parser)
    sub.required = True

    op = sub.add_parser("op", help="one delta on a non-owner item").add_subparsers(dest="verb", parser_class=Parser)
    op.required = True
    a = op.add_parser("add")
    a.add_argument("--kind", required=True, help="now, next or trap; session (a running session: its next step and "
                   "pointers, ≤ 600), queue (what waits on the owner) or fact (a path in use, a fact); focus (the wave's "
                   "focus, pointing to a goal) or request (what the owner asked), each with the owner's words")
    a.add_argument("--text", required=True)
    a.add_argument("--expires")
    a.add_argument("--link", action="append", default=[])
    a.add_argument("--anchor", action="append", default=[])
    a.add_argument("--closes", action="append", default=[], help=CLOSES_HELP)
    a.add_argument("--owner-quote", help="the owner's words, verbatim (focus, request): stored whole, never rewritten")
    a.add_argument("--where", help="where the owner said them (focus, request)")
    a.add_argument("--goal", help="the live goal a focus points to, like G1")
    a.add_argument("--focus", help="the live focus a Next item is tied to, like P1: it orders Next")
    a.add_argument("--due", help="a request's due day, YYYY-MM-DD: named from 7 days before")
    ext_options(a, "add")
    c = op.add_parser("close")
    c.add_argument("id")
    c.add_argument("--reason", required=True)
    c.add_argument("--pointer")
    c.add_argument("--bulk", action="store_true")
    ext_options(c, "close")
    u = op.add_parser("supersede")
    u.add_argument("id")
    u.add_argument("--text", required=True)
    u.add_argument("--reason", required=True)
    u.add_argument("--drop-anchor", action="append", default=[])
    u.add_argument("--anchor", action="append", default=[])
    u.add_argument("--closes", action="append", default=[], help=CLOSES_HELP + "; without it the item's own are carried over")
    u.add_argument("--focus", help="a Next item's focus; without it the item's own is carried over")
    u.add_argument("--due", help="a request's due day; without it the item's own is carried over")
    u.add_argument("--shorter", action="store_true")
    u.add_argument("--bulk", action="store_true")
    ext_options(u, "supersede")
    op.add_parser("touch").add_argument("id")
    h = op.add_parser("hit", help="a trap met again: a held for it in the ledger, and its hits")
    h.add_argument("id")
    h.add_argument("--pointer")
    h.add_argument("--session", help="the session item whose result it is, like S4; without it, this session")
    ext_options(h, "hit")
    for v, what in (("held", "a rule held"), ("broke", "a rule did not hold: always recorded, in the turn it is seen")):
        e = op.add_parser(v, help=what)
        e.add_argument("rule", help="a decision D3, a trap or lesson T5, a fact F2, or a SOUL code like [S07]")
        e.add_argument("--pointer", required=True, help="the PR, SHA, file or message that shows it")
        if v == "broke":
            e.add_argument("--differed", required=True, help="what differed from the rule (≤ 150)")
        e.add_argument("--session", help="the session item whose result it is, like S4; without it, this session")
        ext_options(e, v)
    g = op.add_parser("progress", help="a goal's progress measure: ledger data, the goal itself unchanged")
    g.add_argument("id")
    g.add_argument("--measure", required=True, help="the measure, ≤ 80, like '2 of 4 rows merged'")
    g.add_argument("--pointer", required=True)
    ext_options(g, "progress")
    op.add_parser("close-linked", help="close every item whose closes anchors are all done (fresh lookups)")

    ow = sub.add_parser("owner", help="owner goals, decisions and windows, through the permission dialog")
    ov = ow.add_subparsers(dest="verb", parser_class=Parser)
    ov.required = True
    a = ov.add_parser("add")
    a.add_argument("--kind", required=True, choices=["goal", "decision", "window"])
    a.add_argument("--text", required=True)
    a.add_argument("--owner-quote", required=True)
    a.add_argument("--where", required=True)
    a.add_argument("--expires")
    a.add_argument("--link", action="append", default=[])
    a.add_argument("--anchor", action="append", default=[])
    goal_options(a)
    ov.add_parser("unpin").add_argument("id")
    u = ov.add_parser("supersede")
    u.add_argument("id")
    u.add_argument("--text", help="the new text; without it the text and the owner's words are carried unchanged")
    goal_options(u)
    pr = ov.add_parser("promote", help="a goal, decision or window moved out of hot memory to a pointer")
    pr.add_argument("id")
    pr.add_argument("pointer")
    ov.add_parser("import", help="a bundle's goals, decisions and windows, through one dialog that lists them all").add_argument(
        "bundle")
    ov.add_parser("batch", help="2 to 5 owner items (add, supersede, unpin) from a JSON file, through one dialog that lists "
                  "them all").add_argument("file")
    bk = ov.add_parser("backup", help="the private directory this project's brain is backed up to (or off)")
    bk.add_argument("place", help="an absolute directory: yours, mode 0700, outside every git work tree; or off")
    bk.add_argument("--every", help="hours between two backups, 1 to 720 (24)")
    for e in s.extensions():
        for verb, spec in sorted(e["owner"].items()):
            x = ov.add_parser(verb, help="%s (extension %s): %s" % (verb, e["name"], "pins a decision" if spec["effect"] == "pin"
                                                                       else "moves an item out to a pointer"))
            if spec["effect"] == "archive":
                x.add_argument("id")
                x.add_argument("pointer")
                continue
            for arg in spec["args"]:
                x.add_argument("ext_arg_" + arg, metavar=arg.upper())
            x.add_argument("--text", required=True)
            x.add_argument("--owner-quote", required=True)
            x.add_argument("--where", required=True)
            x.add_argument("--link", action="append", default=[])
            x.add_argument("--anchor", action="append", default=[])

    ex = sub.add_parser("export", help="one bundle of this project's brain, into a new file")
    ex.add_argument("--out", required=True)
    ex.add_argument("--scope", choices=["global", "project"], help="only the goals and decisions of this scope")
    im = sub.add_parser("import", help="a bundle's right brain as `brain op` adds, and its ledger (the owner's half: "
                        "`brain owner import`)")
    im.add_argument("bundle")
    im.add_argument("--only", help="the right brain's letters to import, like TF (all without it)")
    sub.add_parser("backup", help="one bundle into the place the owner named").add_argument("--if-due", action="store_true")

    sub.add_parser("claim").add_argument("--take-over", action="store_true")
    sub.add_parser("render").add_argument("--check", action="store_true")
    sub.add_parser("overflow", help="the overflow queue of each right-brain section, head first (not injected)")
    sub.add_parser("show", help="every stored field of one item, live, queued or retired; the owner's words whole").add_argument("id")
    lg = sub.add_parser("ledger", help="held and broke per rule, goals' progress; one rule's events; the record")
    lg.add_argument("rule", nargs="?")
    lg.add_argument("--record", action="store_true", help="the measurement record of the last --days days (logged; one of "
                    "30 days or more restarts the card's monthly due clock)")
    lg.add_argument("--days", type=int, default=30)
    x = sub.add_parser("ext", help="what a plugin that extends the brain prints (it writes nothing)")
    x.add_argument("name")
    x.add_argument("args", nargs=argparse.REMAINDER)
    dr = sub.add_parser("doctor")
    dr.add_argument("--path", action="store_true")
    dr.add_argument("--bundle", help="check a bundle on its own: its chain, its copies, its text")
    sub.add_parser("matrix", help="the Brain Matrix").add_argument("--json", action="store_true")
    c = sub.add_parser("cost", help="a transcript's usage at baseline A's weights")
    c.add_argument("transcript")
    c.add_argument("--merge-log")
    c.add_argument("--json", action="store_true")
    return p


WRITE_CMDS = ("op", "owner", "import", "claim")


def main(argv):
    if argv[:1] and argv[0] in WRITE_CMDS:          # before any option is read: a worker loads no extension, so an option
        s.check_worker()                            # only an extension knows would otherwise be a usage error (64)
    if argv[:1] == ["owner"]:
        owner_grammar(argv[1:])
        ns = parser().parse_args(argv[:1] + owner_argv(argv[1:]))
    else:
        ns = parser().parse_args(argv)
    note = s.session_note() if ns.cmd != "cost" else None
    if note:
        sys.stderr.write("brain: %s\n" % s.printable(note))
    if ns.cmd in ("op", "owner", "import"):
        try:
            return write_cmd(argv, ns)
        finally:                                    # an unknown key, a left cap off its default: said whatever the write did
            for w in s.config_notes() + ext_warnings():
                sys.stderr.write("brain: warning: %s\n" % s.printable(w))
    if ns.cmd == "claim":
        return s.claim(ns.take_over)
    if ns.cmd == "export":
        import brain_transfer
        return brain_transfer.export(ns.out, ns.scope)
    if ns.cmd == "backup":
        import brain_transfer
        return brain_transfer.backup(ns.if_due)
    if ns.cmd == "render":
        return render(ns.check)
    if ns.cmd == "overflow":
        return overflow()
    if ns.cmd == "show":
        return s.show(ns.id)
    if ns.cmd == "ledger":
        return ledger(ns)
    if ns.cmd == "ext":
        return ext_read(ns.name, ns.args)
    if ns.cmd == "matrix":
        import brain_matrix
        return brain_matrix.main(ns.json)
    if ns.cmd == "cost":
        return cost(ns.transcript, ns.merge_log, ns.json)
    return doctor(ns.path, ns.bundle)


def write_cmd(argv, ns):
    if ns.cmd == "import":
        import brain_transfer
        return brain_transfer.import_bundle(ns.bundle, ns.only)
    if ns.cmd == "op":
        if ns.verb == "add":
            return s.op_add(ns.kind, ns.text, ns.link, ns.anchor, ns.expires, ns.closes, ns.owner_quote, ns.where, ns.goal,
                            ns.focus, ns.due, ext_given(ns))
        if ns.verb == "close":
            return s.op_close(ns.id, ns.reason, ns.pointer, ns.bulk, ext_given(ns))
        if ns.verb == "supersede":
            return s.op_supersede(ns.id, ns.text, ns.reason, ns.drop_anchor, ns.anchor, ns.shorter, ns.bulk, ns.closes,
                                  ns.focus, ns.due, ext_given(ns))
        if ns.verb in ("held", "broke"):
            return s.op_evidence(ns.rule, ns.verb, ns.pointer, getattr(ns, "differed", None), ns.session, extopts=ext_given(ns))
        if ns.verb == "hit":
            return s.op_evidence(ns.id, "held", ns.pointer, None, ns.session, via="hit", extopts=ext_given(ns))
        if ns.verb == "progress":
            return s.op_progress(ns.id, ns.measure, ns.pointer, ext_given(ns))
        if ns.verb == "close-linked":
            import brain_stale
            return brain_stale.close_linked()
        return s.op_counter(ns.id, ns.verb)
    return s.owner(argv[1:], ns.verb, ns)


def ext_warnings():
    """What the extensions' checks left to say (a check that did not run); nothing without an extension loaded."""
    return list(sys.modules["brain_ext"].WARNINGS) if "brain_ext" in sys.modules else []


def ext_read(name, args):
    """`brain ext NAME [ARG…]`: the lines the extension prints from the brain's state; it writes nothing."""
    if not s.extensions():
        raise s.Refused(1, "no plugin extends the brain here (brain doctor says why when one ships %s)" % s.EXT_MARKER)
    import brain_ext
    import brain_ledger as L
    d = s.state_dir()
    if not os.path.isdir(d):
        raise s.Refused(1, "no brain state for this project yet")
    st, ops, _ = L.snapshot(d)
    return brain_ext.read(name, args, d, st, ops)


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
        now = time.time()
        strings = s.render_strings(st, now)
        text = "\n".join(t for _, t in strings)
        s.write_render(d, text)
    if check:
        over = []
        room = s.STRING_MAX - s.ANNOTATE_ROOM
        for i, (half, t) in enumerate(strings, 1):
            n = s.units(t) + (s.FIRST_RESERVE if i == 1 else 0)
            if n > room:
                over.append(str(i))
            sys.stdout.write("string %d (%s brain): %s of %s units%s%s\n" % (
                i, half, "{:,}".format(s.units(t)), "{:,}".format(s.STRING_MAX),
                " with string 1's %s for the hook's lines" % "{:,}".format(s.FIRST_RESERVE) if i == 1 else "",
                " — OVER" if n > room else ""))
        if len(strings) > s.SLOTS:
            sys.stdout.write("strings past %d are not injected: %d\n" % (s.SLOTS, len(strings) - s.SLOTS))
        for half, letters in s.HALVES:
            for letter in letters:
                q = len(s.queue(st, letter))
                sys.stdout.write("  %s: %d of %d%s\n" % (dict(s.SECTIONS)[letter], len(s.live(st, letter)), s.cap(letter),
                                                       ", %d queued" % q if q else ""))
                if letter == "T":
                    sys.stdout.write("  %s: %d\n" % (s.DONE_TITLE, len(s.done_items(st, now))))
        if over or len(strings) > s.SLOTS:
            raise s.Refused(1, "the render is over its cap: string %s" % ", ".join(over) if over else
                            "the render needs more than %d strings" % s.SLOTS)
        return None
    sys.stdout.write(s.PRECEDENCE + "\n" + text)  # as SessionStart injects string 1; hot.md holds the render alone
    return None


def ledger(ns):
    """`brain ledger`: one line per rule; RULE: its events; --record: the record body (logged)."""
    import brain_ledger as L
    if ns.record and ns.rule:
        raise s.Refused(64, "brain ledger --record [--days N] takes no RULE")
    if not 1 <= ns.days <= 365:
        raise s.Refused(64, "--days is from 1 to 365")
    d = s.state_dir()
    if not os.path.isdir(d):
        raise s.Refused(1, "no brain state for this project yet")
    st, ops, led = L.snapshot(d)
    now = time.time()
    if ns.record:
        text = L.record(d, st, ops, led, now, ns.days, os.path.basename(s.config_root()) or "project")
    elif ns.rule:
        text = L.events_text(st, led, L.rule_key(st, ns.rule), now)
    else:
        text = L.table(st, ops, led, now)
    sys.stdout.write("".join(s.printable(l) + "\n" for l in text.split("\n")))
    if ns.record:                                   # logged once printed: a failed write does not lose the record
        sys.stdout.flush()
        L.recorded(d, ns.days, now)
    return None


def overflow():
    """Each right-brain section's overflow queue, head first, one render line per item; nothing when every queue is empty."""
    d = s.state_dir()
    if not os.path.isdir(d):
        raise s.Refused(1, "no brain state for this project yet")
    with s.locked(d):
        _, st = s.load(d)
    now, any_ = time.time(), False
    for letter in dict(s.HALVES)["right"]:
        q = s.queue(st, letter)
        if q:
            any_ = True
            sys.stdout.write("%s: %d queued (%d live of %d)\n" % (dict(s.SECTIONS)[letter], len(q), len(s.live(st, letter)),
                                                                  s.cap(letter)))
            sys.stdout.write("".join(s.printable(s.item_line(it, now, st)) + "\n" for it in q))
    if not any_:
        sys.stdout.write("the overflow queue is empty\n")
    return None


def doctor(path, bundle=None):
    if path and bundle:
        raise s.Refused(64, "brain doctor --path or --bundle FILE, not both")
    if path:
        return s.state_dir()
    if bundle:
        import brain_transfer
    res = brain_transfer.bundle_doctor(bundle) if bundle else s.doctor()
    for level, text in res:
        sys.stdout.write("%-8s %s\n" % (level, s.printable(text)))
    if any(level == "problem" for level, _ in res):
        raise s.Refused(1, "brain doctor%s: %d problem(s)" % (" --bundle" if bundle else "",
                                                            sum(level == "problem" for level, _ in res)))
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
