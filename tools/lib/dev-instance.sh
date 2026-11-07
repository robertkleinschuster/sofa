# Sourced by the test tools that drive a dev instance (test-home, test-downloads, test-playback,
# test-parse). The instance's readiness signal is "fifo ready" in its log.

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

# log_mark LOG: a position in LOG; log_since MARK LOG: the lines written after it. (The suites had
# "sed -n MARK,\$p", which includes line MARK itself - the last line before the mark: a negative
# check "X did not happen after the mark" failed when X was logged just before it, 2026-11-07.)
log_mark() { wc -l < "$1" | tr -d ' '; }
log_since() { tail -n +$(($1 + 1)) "$2"; }
