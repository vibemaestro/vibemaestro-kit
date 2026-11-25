---
name: owner-sign
description: "Use when: the owner types /vibemaestro-sdlc:owner-sign or says \"ký các mục đang chờ\" (user-invoked only): the owner signs the baton runs waiting in the queue, in the session that queued them or another. Lists the pending items with their cards, then one owner dialog per item the owner picks."
disable-model-invocation: true
---

# owner-sign: the owner signs the queued runs

A session that needs the owner's signature and must keep working queues the run (`go --queue`); the owner signs it here, in
an interactive Claude Code session on this machine (the one that queued it or another), when they choose. Standard: the plugin's `docs/batonrun.md`
(section 6, the owner's queue). A baton whose `Stops` names `secrets` is never in the queue: `go --queue`
refuses it (a secret is given only to a `run` or `go --row` phase), so such a run goes through `go` with the owner's dialog,
or `go --row`.

Not here: a sandbox, a call carrying an `agent_id`, a `-p` run.

The program is the launcher `<state-dir>/bin/baton`, until installed `python3 ${CLAUDE_PLUGIN_ROOT}/scripts/baton.py`.

1. Run `<program> log --queue`, bare, as its own call.
2. For each `pending` item, show the owner its card in plain text, in their language (Vietnamese by default), one block per
   item:

   ```
   Mục <id> — <name> (hết hạn <expires>)
   Script:   <Script>   Thư mục: <Dir>   Đối số: <Args>
   Làm gì:   <What>, then each numbered plan line
   Vì sao:   <Why>
   Ảnh hưởng: <Blast>
   Hoàn tác: <Undo>
   Dừng vì:  <each Stop line>
   Đã kiểm:  <Checked>
   ```

   Translate only the labels; copy every value exactly as `log --queue` printed it. A signed, expired, used or damaged item
   gets one line, no question. No pending item: say so and stop.
3. Ask which items to sign (AskUserQuestion, several may be picked; "all" is an answer). No answer is not a yes.
4. For each item picked, run the command `log --queue` printed for it, `<program> sign --by owner --queued <id>`, exactly,
   alone in its own Bash call: nothing before or after it, no variable, no pipe. Claude Code opens a dialog that shows the
   item's card; the owner's click there is the signature. Never answer the dialog, never run the command again after a refusal
   or a rejected dialog, never sign another way.
5. An item the owner no longer wants (or a signature `kit:plugin-update` names that will never run) is withdrawn instead: the
   command `<program> sign --by owner --void <id or binding>`, exactly, alone in its Bash call, through the same dialog.
6. Report one line per item: `signed`, or the refusal line the command printed. The session that queued the item learns it by
   itself (`log --wait-queued`); nothing to send to it.
