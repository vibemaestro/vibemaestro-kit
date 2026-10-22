# shellcheck shell=bash
# =============================================================================
# Network guard shared by every suite (sourced by lib.sh; no PASS/FAIL names here)
# =============================================================================
# `curl`, `wget`, `nc` and `ssh` shims go first in PATH. Each appends its name and arguments to NET_LOG and exits 97, so a
# code path that reaches the network fails loudly where it runs and leaves a trace the suite checks at its end. The log
# path is baked into each shim, so it survives `env -i` and a subshell that resets the environment.
# A suite that never installed the guard (NET_LOG unset) has nothing to check.
# =============================================================================

NET_TOOLS="curl wget nc ssh"

# net_guard_install <scratch dir> — create the shims under <dir>/netshim, empty the log, put them first in PATH.
net_guard_install() {
  local d="$1/netshim" n
  mkdir -p "$d"
  NET_LOG="$1/net.log"; : > "$NET_LOG"
  for n in $NET_TOOLS; do
    printf '#!/bin/sh\nprintf "%%s %%s\\n" "%s" "$*" >> "%s"\nexit 97\n' "$n" "$NET_LOG" > "$d/$n"
    chmod +x "$d/$n"
  done
  export NET_LOG NET_SHIM_DIR="$d"
  PATH="$d:$PATH"; export PATH
}

# net_guard_empty — rc 0 when no shim was called (or no guard installed); otherwise prints the calls and returns 1.
net_guard_empty() {
  [ -n "${NET_LOG:-}" ] || return 0
  [ ! -s "$NET_LOG" ] && return 0
  head -c 400 "$NET_LOG"
  return 1
}
