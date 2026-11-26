#!/bin/bash
# The learner against data from a known law (make test): every sensor group is cooled by exactly one
# fan, heated by one power input; two die sensors also follow their chip's power at once (TG0D 0.3 C/W
# of the GPU, TCXc 0.2 C/W of the CPU), which the learner must find - and give no board sensor. Tp3H
# sits in the CPU fan's warm air (0.2 C/min of heat while that fan runs, whatever its speed): the
# learner must give it fan-air terms and its free-run error must stay small; sensors without warm air
# must not get them. The fitted model must name that fan as the one that matters, its
# free-run error must stay small, `init` must produce a reference that parses, and a dry run must
# change nothing. Needs the SMC (power/ambient key names, sensor existence), no root.
set -u
B=${B:-./sofa-fand}; C=${C:-sofa-fand.conf}
T=$(mktemp -d /tmp/sofa-fand-learn.XXXXXX); trap 'rm -rf "$T"' EXIT
fails=0
ok()   { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; fails=$((fails+1)); }
echo "learner:"
$B init > "$T/init.conf" 2>/dev/null && $B check -c "$T/init.conf" -l /nonexistent >/dev/null 2>&1 && ok "init reference parses" || fail "init reference does not parse"
mkdir -p "$T/data"
# the last 4 days, one row per minute; every 90 min new fan speeds, power and profile (fixed seed)
awk -v t0=$(( $(date +%s) / 60 * 60 - 4 * 86400 )) 'BEGIN {
  srand(7)
  split("TG0D TG0H TC0P TCXc TC0c TC1c TC2c TC3c TO0P Tp2H Tp1P Tp3H TPCD Tm0P TL0P TS0P TA0P HDD", S, " ")
  # group: 0 = GPU heat, ODD fan; 2 = CPU heat, CPU fan; 1 = rest heat, HDD fan
  split("0 0 2 2 2 2 2 2 0 2 2 2 0 0 0 1 9 1", G, " ")
  printf "#epoch,mode,profile,vol,cpu,gpu,F0Ac,F0Tg,F1Ac,F1Tg,F2Ac,F2Tg,PDTR,PCPT,PG0R"
  for (i = 1; i <= 18; i++) printf ",%s", S[i]; printf "\n"
  for (i = 1; i <= 18; i++) T[i] = 40
  split("ruhe idle playback", P, " ")
  for (m = 0; m < 5760; m++) {
    if (m % 90 == 0) {
      f0 = int(rand() * 3) * 1250; f1 = int(rand() * 3) * 1500; f2 = int(rand() * 3) * 1050
      pc = 3 + rand() * 27; pg = 4 + rand() * 11; prof = P[int(m / 90) % 3 + 1]
    }
    amb = 21 + 2 * sin(m / 1440 * 6.2832); pr = 30
    printf "%d,curve,%s,,0.10,0.10,%d,%d,%d,%d,%d,%d,%.2f,%.2f,%.2f", t0 + m * 60, prof, f0, f0, f1, f1, f2, f2, pr + pc + pg, pc, pg
    for (i = 1; i <= 18; i++) {
      g = G[i]
      if (g == 9) { T[i] = amb; printf ",%.2f", amb; continue }
      h = g == 0 ? pg : g == 2 ? pc : pr; rpm = g == 0 ? f0 : g == 2 ? f2 : f1
      air = S[i] == "Tp3H" && f2 > 0 ? 0.2 : 0
      T[i] += 0.08 * h / 10 + air - (0.01 + 0.03 * rpm / 1000) * (T[i] - amb)
      off = S[i] == "TG0D" ? 0.3 * pg : S[i] == "TCXc" ? 0.2 * pc : 0
      printf ",%.2f", T[i] + off + (rand() - 0.5) * 0.1
    }
    printf "\n"
  }
}' > "$T/data/$(date +%F).csv"   # one file: the loader filters rows by time, files by name
$B learn -n -d "$T/data" -c $C --no-ident > "$T/report.md" 2>&1 || { fail "learn -n failed"; cat "$T/report.md"; }
# the dominant fan per sensor, from the report's "fan effect" column
dominant() { grep "^| $1 |" "$T/report.md" | awk -F'|' '{ n = split($10, p, ","); best = ""; bv = -1; for (i = 1; i <= n; i++) { split(p[i], q, " "); if (q[2] + 0 > bv) { bv = q[2] + 0; best = q[1] } } print best }'; }
rmse()     { grep "^| $1 |" "$T/report.md" | awk -F'|' '{ split($8, a, "/"); print a[1] + 0 }'; }
for s in TG0D TPCD TL0P; do [ "$(dominant $s)" = ODD ] && ok "$s: ODD fan found" || fail "$s: dominant fan $(dominant $s), want ODD"; done
for s in TCXc Tp2H Tp1P; do [ "$(dominant $s)" = CPU ] && ok "$s: CPU fan found" || fail "$s: dominant fan $(dominant $s), want CPU"; done
for s in HDD TS0P;       do [ "$(dominant $s)" = HDD ] && ok "$s: HDD fan found" || fail "$s: dominant fan $(dominant $s), want HDD"; done
for s in TG0D TCXc HDD Tp3H; do r=$(rmse $s); awk -v r="$r" 'BEGIN { exit !(r > 0 && r < 0.3) }' && ok "$s: free-run error $r C" || fail "$s: free-run error '$r' (want < 0.3)"; done
# the instant offsets, from the report's "instant C/W" column ("GPU 0.30, CPU 0.00" or "-")
instant()  { grep "^| $1 |" "$T/report.md" | awk -F'|' '{ g = 0; c = 0; if (match($11, /GPU [0-9.]+/)) g = substr($11, RSTART + 4, RLENGTH - 4) + 0; if (match($11, /CPU [0-9.]+/)) c = substr($11, RSTART + 4, RLENGTH - 4) + 0; print g, c }'; }
near()     { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a - b < 0.051 && b - a < 0.051) }'; }
set -- $(instant TG0D); near "$1" 0.3 && near "$2" 0 && ok "TG0D: instant offset GPU $1 found" || fail "TG0D: instant offset GPU $1 CPU $2, want 0.3 / 0"
set -- $(instant TCXc); near "$1" 0 && near "$2" 0.2 && ok "TCXc: instant offset CPU $2 found" || fail "TCXc: instant offset GPU $1 CPU $2, want 0 / 0.2"
for s in TPCD HDD TS0P; do set -- $(instant $s); near "$1" 0 && near "$2" 0 && ok "$s: no instant offset" || fail "$s: instant offset GPU $1 CPU $2, want none"; done
# the fan-air terms, from the report's "fan air C" column ("ODD 0.0, HDD 0.0, CPU 2.7" or "-")
fanair()   { grep "^| $1 |" "$T/report.md" | awk -F'|' '{ v = $12; gsub(/ /, "", v); if (v == "-") { print "-"; exit } c = 0; if (match(v, /CPU[0-9.]+/)) c = substr(v, RSTART + 3, RLENGTH - 3) + 0; print c }'; }
a=$(fanair Tp3H); awk -v a="$a" 'BEGIN { exit !(a != "-" && a > 1) }' && ok "Tp3H: fan air of the CPU fan found ($a C)" || fail "Tp3H: fan air '$a', want the CPU fan's"
for s in TPCD HDD TS0P TG0D; do a=$(fanair $s); [ "$a" = "-" ] && ok "$s: no fan air" || fail "$s: fan air '$a', want none"; done
grep -q "quieter moves allowed" "$T/report.md" && ok "validated model allows quieter moves" || fail "quieter moves not allowed: $(grep 'quieter moves' "$T/report.md")"
grep -q "^## Step" "$T/report.md" && ok "search reports a step decision" || fail "no step section"
[ $fails = 0 ] && echo "==> all ok" || { echo "==> $fails failed"; exit 1; }
