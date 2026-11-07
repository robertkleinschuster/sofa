# Sourced by the test tools that drive a dev instance (test-home, test-downloads, test-playback,
# test-parse, test-schema, test-startup, test-updater). The instance's readiness signal is
# "fifo ready" in its log. Waits are deadlines, not delays: they return as soon as the state is
# reached, so a generous one costs nothing - a short one failed whole suites when the real app
# was busy next to test-all (2026-11-07: 10 s / 5 s, a loaded machine needs more).

# dev_wait_ready PID LOG: until the instance is ready - exits the tool if it ended first or is not
# ready after 30 s (a loaded machine - a port build next to the suites - needs more than a few s).
dev_wait_ready() {
  local pid=$1 log=$2 i
  for i in $(seq 1 300); do
    grep -q 'fifo ready' "$log" 2>/dev/null && return 0
    kill -0 "$pid" 2>/dev/null || { echo "dev instance exited before it was ready:"; tail -5 "$log" 2>/dev/null | sed 's/^/    /'; exit 1; }
    sleep 0.1
  done
  echo "dev instance not ready after 30 s:"; tail -5 "$log" 2>/dev/null | sed 's/^/    /'; exit 1
}

# dev_wait_exit PID [SECONDS]: until the process has ended (default 30 s); 1 if it still runs.
dev_wait_exit() {
  local pid=$1 i
  for i in $(seq 1 $(( ${2:-30} * 10 ))); do kill -0 "$pid" 2>/dev/null || return 0; sleep 0.1; done
  return 1
}

# log_mark LOG: a position in LOG; log_since MARK LOG: the lines written after it. (The suites had
# "sed -n MARK,\$p", which includes line MARK itself - the last line before the mark: a negative
# check "X did not happen after the mark" failed when X was logged just before it, 2026-11-07.)
log_mark() { wc -l < "$1" | tr -d ' '; }
log_since() { tail -n +$(($1 + 1)) "$2"; }
