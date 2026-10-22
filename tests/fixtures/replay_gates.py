#!/usr/bin/env python3
"""Replay many versions of a ledger through an OLD gate and through the builtin current-state profile, and compare.

    replay_gates.py --scripts <plugin scripts dir> --profile-root <dir> --adapter <py file> --versions <dir>

`--profile-root` holds `.vibemaestro/sdlc.json`: the profile under test (presets applied by the real loader). `--versions` holds one
ledger per file, sorted by name (oldest first). `--adapter` is a Python file of the OLD gate's owner, loaded with importlib; it
exposes

    violations(raw: bytes) -> (items, capped)
        items   [(line or 0, class)] the old gate reports for that ledger; `class` uses the class names of
                `current_state.problems_classified` (size.bytes, size.line_chars, table.header, pattern.<id>, ...)
        capped  set of classes whose list the old gate cut short (a gate that prints at most N lines per kind)
    decide(paths, body, raw: bytes) -> rc          (optional) the old diff gate, with the ledger given as bytes

Parity is judged on the rc and on the SET of (line, class) problems, never on message text. Per version it reports: rc equal, sets
exactly equal, or equal "modulo caps" (the old set is contained in the new one and every class that differs was capped by the old
gate). With a `decide` in the adapter it also replays five synthetic diffs per version (a watched path alone, with the ledger,
with a valid exemption, with a too-short one, an unwatched path) and compares the rc.

The old gate's name, its paths and its messages live in the adapter, which belongs with the old gate, not in this repository.
Standard library only.
"""
import argparse
import collections
import importlib.util
import os
import sys


def load_adapter(path):
    spec = importlib.util.spec_from_file_location("replay_old_gate", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--scripts", required=True)
    ap.add_argument("--profile-root", required=True)
    ap.add_argument("--adapter", required=True)
    ap.add_argument("--versions", required=True)
    a = ap.parse_args()
    sys.path.insert(0, a.scripts)
    sys.dont_write_bytecode = True
    import current_state as S
    import sdlc_config as C

    cfg, probs, _present = C.load(a.profile_root)
    if probs:
        print("replay: the profile is invalid: %s" % probs)
        return 2
    profile = S.profile_from_config(cfg)
    old = load_adapter(a.adapter)
    names = sorted(os.listdir(a.versions))
    if not names:
        print("replay: no ledger version in %s" % a.versions)
        return 2
    n = len(names)
    rc_equal = exact = modulo = old_pass = new_pass = 0
    only_old, only_new = collections.Counter(), collections.Counter()
    first = {}
    rc_diff_versions = []
    d_total = d_equal = 0
    d_diff = collections.Counter()
    watched = (profile["watch"] or ["watched/"])[0]
    ledger_path = profile["path"]
    tok = (profile["no_state_change"] or ["NO STATE CHANGE:"])[0]
    need = profile["exempt"]["min_reason_chars"]
    scenarios = [
        ("watched path alone", [watched + "x"], ""),
        ("watched path and the ledger", [watched + "x", ledger_path], ""),
        ("watched path with a valid exemption", [watched + "x"], "%s %s" % (tok, "a reason that is long enough to pass")),
        ("watched path with a short exemption", [watched + "x"], "%s %s" % (tok, "x" * max(need - 1, 0)) if need else "%s" % tok),
        ("unwatched path", ["unwatched/x.md"], ""),
    ]
    for i, name in enumerate(names, 1):
        with open(os.path.join(a.versions, name), "rb") as f:
            raw = f.read()
        items, capped = old.violations(raw)
        o = set(items)
        w = set((ln, cls) for ln, cls, _why in S.problems_classified(raw, profile))
        o_rc, w_rc = (1 if o else 0), (1 if w else 0)
        old_pass += 1 - o_rc
        new_pass += 1 - w_rc
        if o_rc == w_rc:
            rc_equal += 1
        else:
            rc_diff_versions.append(i)
        if o == w:
            exact += 1
            modulo += 1
        else:
            differing = {c for _l, c in (o ^ w)}
            ok_mod = o <= w and all(c in capped for c in differing)
            modulo += 1 if ok_mod else 0
            for ln, c in sorted(o - w):
                only_old[c] += 1
                first.setdefault(("old", c), (i, ln))
            for ln, c in sorted(w - o):
                only_new[c] += 1
                first.setdefault(("new", c), (i, ln))
        if hasattr(old, "decide"):
            for label, paths, body in scenarios:
                d_total += 1
                orc = old.decide(paths, body, raw)
                nrc, _msg = S.decide(paths, body, profile, ledger=raw)
                if orc == nrc:
                    d_equal += 1
                else:
                    d_diff[label] += 1
    print("versions replayed: %d" % n)
    print("versions the old gate passes: %d, the new profile passes: %d (a replay with no passing version proves nothing about the pass side)" % (old_pass, new_pass))
    print("rc equal: %d/%d%s" % (rc_equal, n, "" if not rc_diff_versions else "  (versions %s)" % ",".join(map(str, rc_diff_versions[:20]))))
    print("(line, class) sets exactly equal: %d/%d" % (exact, n))
    print("(line, class) sets equal modulo the old gate's caps: %d/%d" % (modulo, n))
    if hasattr(old, "decide"):
        print("diff-gate scenarios, rc equal: %d/%d" % (d_equal, d_total))
        for label, c in sorted(d_diff.items()):
            print("  differs: %s x%d" % (label, c))
    for cls, c in sorted(only_old.items()):
        v, ln = first[("old", cls)]
        print("only the old gate reports: %s x%d (first: version %d, line %s)" % (cls, c, v, ln))
    for cls, c in sorted(only_new.items()):
        v, ln = first[("new", cls)]
        print("only the new profile reports: %s x%d (first: version %d, line %s)" % (cls, c, v, ln))
    return 0


if __name__ == "__main__":
    sys.exit(main())
