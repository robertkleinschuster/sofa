#!/bin/bash
# crashcheck.sh SECONDS LABEL: every 30 s create a NEW directory via NSFileManager and count
# "Job appears to have crashed" lines in system.log; stop at the first crash (exit 1).
# NSFM=path of the canary binary (default /Users/imac/src/smcfan/nsfm).
# Guards against the 2026-11-17 crash wave (see README).
DUR=$1; LBL=$2; L=/var/log/system.log; NSFM=${NSFM:-/Users/imac/src/smcfan/nsfm}
base=$(grep -c "appears to have crashed" $L); t0=$(date +%s); n=0
while [ $(( $(date +%s) - t0 )) -lt $DUR ]; do
  n=$((n+1)); p=/tmp/nsfmtest-$$-$n
  "$NSFM" "$p/sub" >/dev/null 2>&1; rc=$?
  c=$(( $(grep -c "appears to have crashed" $L) - base ))
  echo "$(date +%T) $LBL #$n rc=$rc new_crash_lines=$c"
  rm -rf "/tmp/nsfmtest-$$-$n"
  if [ $rc -ne 0 ] || [ $c -gt 0 ]; then echo "ABSTURZ erkannt"; exit 1; fi
  sleep 30
done
echo "$LBL sauber: $n Tests, 0 Abstürze"
