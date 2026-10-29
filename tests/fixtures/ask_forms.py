"""The ask rules of a printed permission block against real calls and mere mentions, read with the plugin's own matcher.

    python3 ask_forms.py <plugin scripts dir> <printed block> <launcher> <claude dir> <home> lead|real|mention

lead: the ask rules that start with `*`, one per line (none: empty). real: one line `<decision> <command>` per real spelling of a
`sign --by owner` or a mode change, as the kit prints it or a session types it; every one must be `ask`. mention: one line per
command that only mentions such a call and that some ask rule catches (none: empty). The spellings are written here from the
paths, not taken from baton.py, so a form the block drops shows as a decision other than `ask`.
"""
import json
import os
import sys

sys.path.insert(0, sys.argv[1])
import baton  # noqa: E402

block, L, cd, home, what = sys.argv[2:7]
rules, _probs = baton.read_rules([("printed", block)])
asks = [r for r in json.load(open(block))["permissions"]["ask"]]
SEAL = "--seal 0123456789abcdef.0123456789abcdef"
OWN = "sign --by " + "owner"


def progs():
    out = [L, '"%s"' % L, "'%s'" % L, "baton"]
    rel = os.path.relpath(L, home)
    if not rel.startswith(".."):
        out += ["~/" + rel, "$HOME/" + rel, '"$HOME/%s"' % rel]
    pys = [os.path.join(cd, "plugins", "cache", "vibemaestro", "vibemaestro-sdlc", "0.3.1", "scripts", "baton.py"),
           os.path.join(cd, "plugins", "cache", "vibemaestro", "vibemaestro-sdlc", "3d15f5b67818-be49dd83", "scripts", "baton.py"),
           os.path.join(cd, "plugins", "marketplaces", "vibemaestro", "plugins", "vibemaestro-sdlc", "scripts", "baton.py")]
    words = []
    for p in pys:
        words += [p, '"%s"' % p, "'%s'" % p]
        r = os.path.relpath(p, home)
        if not r.startswith(".."):
            words += ["~/" + r, "$HOME/" + r, '"$HOME/%s"' % r]
    return out + words + ["python3 " + w for w in words]


if what == "lead":
    for r in asks:
        if r.startswith("Bash(*"):
            print(r)
elif what == "real":
    for prog in progs():
        for tail in ("%s %s kit:merge-pr --pr 7" % (OWN, SEAL), OWN + " --queued 0123456789abcdef", "mode auto", "mode manual",
                     "mode trust github.com/acme/app", "mode untrust github.com/acme/app"):
            cmd = "%s %s" % (prog, tail)
            print("%s %s" % (baton.decide(rules, cmd)[0] or "none", cmd))
elif what == "mention":
    real = os.path.join(cd, "plugins", "cache", "vibemaestro", "vibemaestro-sdlc", "0.3.1", "scripts", "baton.py")
    mentions = [
        "printf 'next: %s %s %s kit:x\\n' | sandbox.sh send w -" % (L, OWN, SEAL),
        'echo "then run %s mode auto"' % L,
        "python3 - <<'EOF'\nprint('python3 %s %s %s kit:x')\nEOF" % (real, OWN, SEAL),
        "cat > note.md <<'EOF'\n%s mode auto\n~/.local/state/vibemaestro/baton/bin/baton %s %s kit:x\nEOF" % (L, OWN, SEAL),
        "'%s %s' is the line the owner clicks" % (L, OWN),
        'gh issue comment 561 --body "it asked for python3 %s mode auto"' % real,
        "gh issue create --title t --body 'baton %s and baton.py mode manual'" % OWN,
        '/usr/bin/gh issue comment 561 --body "%s mode auto and %s %s"' % (real, real, OWN),
        'git commit -m "docs: %s %s, then python3 %s mode auto"' % (L, OWN, real),
        "grep -rn 'baton %s' kb" % OWN, 'grep -rn "/baton mode auto" .',
        'python3 /tmp/edit.py --text "%s mode trust github.com/acme/app"' % real,
    ]
    for m in mentions:
        hit = [r for r in asks if baton.bash_matches(baton.RULE_RE.match(r).group(2), m)]
        if hit:
            print("%s <- %s" % (hit[0], m.split("\n")[0]))
