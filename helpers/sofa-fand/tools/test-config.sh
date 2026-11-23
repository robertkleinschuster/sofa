#!/bin/bash
# test-config.sh - the learned layer's validator against the reference config (offline, no root,
# reads the SMC only for the machine). Every safety rule has a case that must be refused and the
# legitimate changes a case that must pass. Run: make test
set -u
cd "$(dirname "$0")/.."
B=./sofa-fand; C=sofa-fand.conf
T=$(mktemp -d "${TMPDIR:-/tmp}/fand-cfg.XXXXXX"); trap 'rm -rf "$T"' EXIT
fails=0
case_() {   # NAME EXPECT(ok|refused) GREP-IN-OUTPUT layer-lines...
  local name=$1 expect=$2 want=$3; shift 3
  printf '%s\n' "$@" > "$T/l.conf"
  out=$($B check -c $C -l "$T/l.conf" 2>&1); rc=$?
  local got=ok; [ $rc = 3 ] && got=refused; [ $rc != 0 ] && [ $rc != 3 ] && got="error($rc)"
  if [ "$got" = "$expect" ] && { [ -z "$want" ] || grep -q -- "$want" <<<"$out"; }; then echo "  ok   $name"
  else echo "  FAIL $name: expected $expect${want:+ with '$want'}, got $got: $(grep -E 'learned|^[^ ]' <<<"$out" | tail -1)"; fails=$((fails+1)); fi
}
echo "learned layer validation:"
$B check -c $C -l /nonexistent >/dev/null 2>&1 && echo "  ok   no layer" || { echo "  FAIL no layer"; fails=$((fails+1)); }
case_ "empty layer"                      ok      "learned layer: none" "# nothing yet"
case_ "earlier curve (-2) passes"        ok      "learned shift -2.0"  "shift 0 TG0D -2"
case_ "rest cooler passes (free)"        ok      "profile ruhe 1.0"     "profile ruhe 1"
case_ "rest quieter at warn is refused"  refused "asks .* at warn"      "profile ruhe 3"
case_ "added curve passes"               ok      "(learned)"            "curve 2 TS0P 45:0 48:900"
case_ "a full step passes"               ok      "3 lines in effect"    "shift 0 TG0D -2" "shift 2 Tp2H -1" "profile playback -5 -2"
case_ "later curve at warn is refused"   refused "asks .* at warn"      "shift 0 TG0D 2"
case_ "shift beyond 8 C is refused"      refused "beyond 8"             "shift 0 TG0D -9"
case_ "in use: idle quieter refused"     refused "only get cooler"      "profile idle -1"
case_ "in use: playback volume quieter"  refused "only get cooler"      "profile playback -4 -1"
case_ "profile beyond 8 C is refused"    refused "beyond 8"             "profile ruhe 9"
case_ "shift on a missing curve"         refused "no reference curve"   "shift 1 TG0D -1"
case_ "unknown sensor"                   refused "bad shift"            "shift 0 TXXX -1"
case_ "unknown line"                     refused "unknown line"         "trip TG0D 90"
case_ "curve above fan max"              refused "above fan max"        "curve 2 TS0P 45:0 48:3000"
case_ "falling curve"                    refused "must rise"            "curve 0 TS0P 45:900 48:600"
case_ "one bad line refuses all"         refused ""                     "shift 0 TG0D -2" "shift 0 TG0D 2"
# the refused layer must leave the reference alone (no partial application)
printf 'shift 0 TG0D -2\nshift 0 TO0P 9\n' > "$T/l.conf"
if $B check -c $C -l "$T/l.conf" 2>/dev/null | grep -q "learned shift"; then echo "  FAIL refused layer applied partly"; fails=$((fails+1)); else echo "  ok   refused layer leaves the reference alone"; fi
# reference rules that come from the machine
sed 's/^fan 0 name ODD max 2500/fan 0 name ODD max 2600/' $C > "$T/r.conf"
$B check -c "$T/r.conf" -l /nonexistent >/dev/null 2>&1 && { echo "  FAIL fan max above the SMC accepted"; fails=$((fails+1)); } || echo "  ok   fan max above the SMC is refused"
sed 's/^sensor TS0P /sensor TZ9Q /' $C | sed 's/ TS0P / TZ9Q /' > "$T/r.conf"
$B check -c "$T/r.conf" -l /nonexistent 2>&1 | grep -q "does not exist on this Mac" && echo "  ok   a sensor the Mac lacks is refused" || { echo "  FAIL missing sensor accepted"; fails=$((fails+1)); }
grep -v "^sensor TL0P" $C | sed 's/^curve 0 TL0P.*//; s/^curve 2 TL0P.*//; s/^floor 0 TL0P.*//' > "$T/r.conf"; echo "sensor TL0P" >> "$T/r.conf"
$B check -c "$T/r.conf" -l /nonexistent 2>&1 | grep -q "sensor TL0P trip 60.4 warn 54.4" && echo "  ok   trip/warn derived from Apple's limits" || { echo "  FAIL Apple limits not derived"; fails=$((fails+1)); }
[ $fails = 0 ] && echo "==> all ok" || { echo "==> $fails failed"; exit 1; }
