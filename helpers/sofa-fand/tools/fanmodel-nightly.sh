#!/bin/bash
# fanmodel-nightly.sh - nightly stage-2 report (LaunchDaemon de.sofa.fanmodel, user imac, 04:00).
# Learns from all sofa-fanlearn data, writes ~/Library/Logs/fanmodel/YYYY-MM-DD/{report.md,
# sofa-fand.conf.proposal}; nothing is applied. Keeps 30 days. Low priority (nice, background I/O).
set -u
T=/Users/imac/src/sofa/helpers/sofa-fand/tools
OUT=/Users/imac/Library/Logs/fanmodel/$(date +%Y-%m-%d)
mkdir -p "$OUT"
PH=(); for p in /Users/imac/Library/Logs/fan-ident-*/phases.csv; do [ -f "$p" ] && PH+=(--phases "$p"); done
/opt/local/bin/python3 -I $T/fanmodel.py /Users/imac/Library/Logs/sofa-fanlearn /usr/local/etc/sofa-fand.conf \
  --out "$OUT" --state /Users/imac/Library/Logs/fanmodel --check /usr/local/sbin/sofa-fand ${PH[@]+"${PH[@]}"} > "$OUT/run.log" 2>&1
echo "rc=$?" >> "$OUT/run.log"
ln -sfn "$OUT" /Users/imac/Library/Logs/fanmodel/latest
find /Users/imac/Library/Logs/fanmodel -mindepth 1 -maxdepth 1 -type d -name '20??-??-??' -mtime +30 -exec rm -rf {} +
