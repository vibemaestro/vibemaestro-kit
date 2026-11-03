"""The example extension of vibemaestro-brain: one JSON object in on stdin, one out on stdout (the contract is in the brain's
README, section Extensions). It never writes a file: brain writes what it answers, under `ext.example`.

- check `add` / `supersede` of a session: `--ticket ABC-1` is required on an add (64 without it, 1 when it is not like ABC-1);
  its data is {"ticket": …}, and the add's note counts the sessions with a ticket. A supersede that names a new ticket
  replaces it; without one, brain carries the old entry over.
- check `broke`: a note naming how often the rule broke, this one included.
- owner `vouch TAG` (pin): the dialog shows `tag TAG`; the tag `no` is refused; the decision stores {"tag": TAG}.
- owner `shelve ID POINTER` (archive of a lesson or a fact): the dialog shows how often the item held, and how many of those
  an import brought; the pointer `nowhere` is refused; the op stores {"shelved": true}.
- start: one line counting the live sessions with a ticket, and on the card one naming them.
- record: one line counting the sessions added in the period with a ticket.
- read: `brain ext example tickets` lists them; anything else is refused (64).
"""
import json
import re
import sys

TICKET = re.compile(r"[A-Z]+-[0-9]+")


def tickets(state, live_only=True):
    """{session id: ticket} of the session items that carry one."""
    out = {}
    for it in state["items"].values():
        t = ((it.get("ext") or {}).get("example") or {}).get("ticket")
        if it["id"].startswith("S") and t and (not live_only or it["status"] == "live"):
            out[it["id"]] = t
    return out


def check(q):
    if q["verb"] in ("add", "supersede"):
        t = q["options"].get("--ticket")
        if t is None:
            if q["verb"] == "add":
                return {"refuse": {"rc": 64, "message": "a session names its ticket: --ticket ABC-1"}}
            return {}
        if not TICKET.fullmatch(t):
            return {"refuse": {"rc": 1, "message": "--ticket %s is not like ABC-1" % t}}
        n = len(tickets(q["state"])) + (q["verb"] == "add")
        return {"data": {"ticket": t}, "note": "ticket %s noted (%d live session%s with a ticket)" % (t, n, "" if n == 1 else "s")}
    rule = q["op"].get("id") or "[%s]" % q["op"].get("soul")
    n = 1 + sum(1 for op in q["ops"] if op.get("op") == "evidence" and op.get("result") == "broke"
                and (op.get("id") or "[%s]" % op.get("soul")) == rule)
    return {"note": "%s broke %d time%s: tell the owner" % (rule, n, "" if n == 1 else "s")}


def owner(q):
    if q["effect"] == "pin":
        tag = q["args"]["tag"]
        if tag == "no":
            return {"refuse": {"message": "the tag no is refused"}}
        return {"detail": "tag %s" % tag} if q["phase"] == "ask" else {"data": {"tag": tag}}
    if q["pointer"] == "nowhere":
        return {"refuse": {"message": "a shelved item goes somewhere"}}
    held = [op for op in q["ops"] if op.get("op") == "evidence" and op.get("id") == q["id"] and op.get("result") == "held"]
    imported = sum(1 for op in held if "import" in op)
    detail = "held %d%s" % (len(held), ", %d imported from a bundle" % imported if imported else "")
    return {"detail": detail} if q["phase"] == "ask" else {"data": {"shelved": True}}


def start(q):
    live = tickets(q["state"])
    lines = ["%d live session%s with a ticket" % (len(live), "" if len(live) == 1 else "s")]
    if q["card"]:
        lines.append("tickets: " + (" ".join("%s %s" % kv for kv in sorted(live.items())) or "none"))
    return {"lines": lines}


def record(q):
    n = sum(1 for it in q["state"]["items"].values() if it["id"].startswith("S") and not it.get("supersedes")
            and ((it.get("ext") or {}).get("example") or {}).get("ticket"))
    return {"lines": ["- sessions with a ticket: %d" % n]}


def read(q):
    if q["args"] != ["tickets"]:
        return {"refuse": {"rc": 64, "message": "brain ext example tickets"}}
    return {"lines": ["%s %s" % kv for kv in sorted(tickets(q["state"], live_only=False).items())] or ["no tickets"]}


def answer(q):
    return {"check": check, "owner": owner, "start": start, "record": record, "read": read}[q["call"]](q)


def main():
    sys.stdout.write(json.dumps(answer(json.loads(sys.stdin.read()))))


if __name__ == "__main__":
    main()
