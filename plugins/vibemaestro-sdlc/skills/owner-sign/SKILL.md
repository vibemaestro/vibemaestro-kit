---
name: owner-sign
description: "Use when: the owner types /vibemaestro-sdlc:owner-sign or says \"ký các mục đang chờ\" (user-invoked only): the owner signs the baton runs waiting in the queue, from a Claude Code session of their own. Lists the pending items with their cards, then one owner dialog per item the owner picks."
disable-model-invocation: true
---

# owner-sign: the owner signs the queued runs

A session that needs the owner's signature and must keep working queues the run (`go --queue`); the owner signs it here, in
an interactive Claude Code session of their own on this machine, when they choose. Standard: the plugin's `docs/batonrun.md`
(section 6, the owner's queue).

Not here: the session that queued the items (the hook denies the sign there, with no dialog, also after `/clear`), a sandbox,
a call carrying an `agent_id`, a `-p` run.

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
5. Report one line per item: `signed`, or the refusal line the command printed. The session that queued the item learns it by
   itself (`log --wait-queued`); nothing to send to it.
