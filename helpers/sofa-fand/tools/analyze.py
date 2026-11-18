#!/usr/bin/env python3
"""Step-response analysis of night.csv: per test summary + fan x sensor sensitivity matrix."""
import csv, sys, math, collections

path = sys.argv[1]
rows = list(csv.DictReader(open(path)))
for r in rows:
    for k, v in r.items():
        if k not in ('test', 'load', 'mode'):
            try: r[k] = float(v)
            except ValueError: r[k] = math.nan
tests = collections.OrderedDict()
for r in rows:
    tests.setdefault(r['test'], []).append(r)

SENS = ['TC0P', 'TCXc', 'TG0D', 'TG0H', 'TO0P', 'Tp1P', 'Tp2H', 'Tp3H', 'TPCD', 'Tm0P', 'TL0P', 'TS0P', 'TS2P', 'HDD', 'TA0P']
FANS = ['F0Ac', 'F1Ac', 'F2Ac']

def tail_mean(rs, k, n=6):
    v = [r[k] for r in rs[-n:] if not math.isnan(r[k])]
    return sum(v) / len(v) if v else math.nan

def tau63(rs, k):
    if len(rs) < 6: return math.nan
    t0 = rs[0]['epoch']; a = tail_mean(rs[:3], k, 3); b = tail_mean(rs, k)
    if math.isnan(a) or math.isnan(b) or abs(b - a) < 0.6: return math.nan
    goal = a + 0.63 * (b - a)
    for r in rs:
        v = r[k]
        if not math.isnan(v) and ((b > a and v >= goal) or (b < a and v <= goal)):
            return r['epoch'] - t0
    return math.nan

print('== tests')
summ = {}
for name, rs in tests.items():
    dur = rs[-1]['epoch'] - rs[0]['epoch']
    end = {k: tail_mean(rs, k) for k in SENS + FANS + ['cpu_pct', 'gpu_pm4']}
    start = {k: tail_mean(rs[:3], k, 3) for k in SENS + FANS}
    summ[name] = (rs, start, end)
    print(f"{name:28s} {rs[0]['load'][:22]:22s} {rs[0]['mode']:5s} want {int(rs[0]['want0']):5d}/{int(rs[0]['want1']):5d}/{int(rs[0]['want2']):5d} "
          f"{dur/60:5.1f} min | fans {end['F0Ac']:5.0f}/{end['F1Ac']:5.0f}/{end['F2Ac']:5.0f} | "
          + ' '.join(f"{k}={end[k]:.1f}" for k in ['TC0P', 'TG0D', 'TO0P', 'Tp2H', 'Tp1P', 'TL0P', 'HDD'])
          + f" | cpu {end['cpu_pct']:.0f}% gpu {end['gpu_pm4']:.0f}")

# step pairs: a step test directly preceded by a baseline test in the same block
print('\n== step responses (delta to the preceding baseline end, per 100 rpm; tau63 in s)')
names = list(tests)
for i, name in enumerate(names):
    rs, start, end = summ[name]
    if i == 0 or rs[0]['mode'] != 'force': continue
    prs, pstart, pend = summ[names[i - 1]]
    if prs[0]['mode'] != 'force' or prs[0]['load'] != rs[0]['load']: continue
    dfan = [end[f] - pend[f] for f in FANS]
    moved = [j for j in range(3) if abs(dfan[j]) > 150]
    if len(moved) != 1: continue
    j = moved[0]; d100 = dfan[j] / 100.0
    # drift correction: average the baseline before and the return-to-baseline after the step
    nxt = summ[names[i + 1]] if i + 1 < len(names) else None
    use_next = nxt and nxt[0][0]['mode'] == 'force' and nxt[0][0]['load'] == rs[0]['load'] and all(
        abs(nxt[2][f] - pend[f]) < 150 for f in FANS)
    out = []
    for k in SENS:
        base = (pend[k] + nxt[2][k]) / 2 if use_next else pend[k]
        dT = end[k] - base
        out.append(f"{k} {dT / d100:+.2f} (τ {tau63(rs, k):.0f})")
    print(f"{name} [{rs[0]['load'][:18]}]{' drift-corr' if use_next else ''} F{j} {pend[FANS[j]]:.0f}->{end[FANS[j]]:.0f}: " + ', '.join(out))
