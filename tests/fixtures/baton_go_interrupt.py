"""baton_go_interrupt.py <scripts dir> keep|replace <baton go arguments...>: run `baton.py go` in this process with an interrupt
in the window between go's signature and the run's own guard (need_bash at the top of the run raises Interrupted once a
signature is recorded). With `replace`, the signature file is first rewritten, as another signer would. Prints the exit code,
the number of signature files left and the last log line's event and result. Used by tests/test-baton.sh (fam_go_attack).
"""
import os
import sys

sys.path.insert(0, sys.argv[1])
import baton  # noqa: E402

how, argv = sys.argv[2], sys.argv[3:]
real_need_bash = baton.need_bash


def need_bash():
    rec = baton.RUN.get("signed")
    if rec and os.path.exists(rec[1]):
        if how == "replace":
            with open(rec[1], "a", encoding="utf-8") as f:
                f.write(" ")
        raise baton.Interrupted()
    real_need_bash()


baton.need_bash = need_bash
rc = baton.main(argv)
st = baton.state_dir()
sigs = [n for n in os.listdir(os.path.join(st, "signatures")) if n.endswith(".json")]
with open(os.path.join(st, "log.tsv"), encoding="utf-8") as f:
    last = f.read().split("\n")[-2].split("\t")
sys.__stdout__.write("rc %d; signatures %d; last %s %s\n" % (rc, len(sigs), last[1], last[9]))
