#!/usr/bin/env python3
"""Analyse short.csv (2026-11-18): per-test summary, H1 equilibria, fan x sensor effect matrix."""
import csv, sys, math, collections
rows = []
with open(sys.argv[1]) as f:
    rd = csv.reader(f); head = next(rd); n = len(head)
    for r in rd:
        if len(r) > n:                      # load label contained commas
            extra = len(r) - n
            r = r[:2] + [','.join(r[2:3 + extra])] + r[3 + extra:]
        d = dict(zip(head, r))
        for k in head:
            if k not in ('test', 'load', 'mode'):
                try: d[k] = float(d[k])
                except ValueError: d[k] = math.nan
        rows.append(d)
T = collections.OrderedDict()
prev = None
for r in rows:                               # a new run of a test: name repeats after a gap or label change
    k = r['test']
    if prev and prev['test'] == r['test'] and (r['epoch'] - prev['epoch'] > 30 or r['load'] != prev['load']):
        n2 = 2
        while f"{k}#{n2}" in T: n2 += 1
        k = f"{k}#{n2}"
    elif prev and prev['test'] == r['test']:
        k = list(T)[-1]
    elif k in T:
        n2 = 2
        while f"{k}#{n2}" in T: n2 += 1
        k = f"{k}#{n2}"
    T.setdefault(k, []).append(r); prev = r
SENS = [h for h in head if h.startswith('T') and h != 'test'] + ['HDD']
def mean(rs, k):
    v = [r[k] for r in rs if not math.isnan(r[k])]; return sum(v) / len(v) if v else math.nan
def slope(rs, k):                            # deg C per minute over the last half of the test
    rs = rs[len(rs) // 2:]
    pts = [(r['epoch'], r[k]) for r in rs if not math.isnan(r[k])]
    if len(pts) < 4: return math.nan
    mx = sum(p[0] for p in pts) / len(pts); my = sum(p[1] for p in pts) / len(pts)
    den = sum((p[0] - mx) ** 2 for p in pts)
    return 60 * sum((p[0] - mx) * (p[1] - my) for p in pts) / den if den else math.nan
print('== tests')
for name, rs in T.items():
    a, b = rs[:2], rs[-3:]
    dur = (rs[-1]['epoch'] - rs[0]['epoch']) / 60
    print(f"{name:14s} {rs[0]['load'][:26]:26s} {dur:4.1f} min fans {mean(b,'F0Ac'):5.0f}/{mean(b,'F1Ac'):5.0f}/{mean(b,'F2Ac'):5.0f} cpu {mean(b,'cpu_pct'):4.0f}%")
    print('   ' + '  '.join(f"{k} {mean(a,k):.1f}->{mean(b,k):.1f} ({slope(rs,k):+.2f}/min)" for k in SENS))
# effect matrix: each max step vs mean of the surrounding baselines (end values)
print('\n== effect matrix (deg C change at the end of 6 min vs surrounding baselines; per 100 rpm)')
order = list(T)
for fan, key, base_rpm, max_rpm in (('ODD', 'M-ODD-max', 1150, 2500), ('HDD', 'M2-HDD-max', 1290, 5500), ('CPU', 'M2-CPU-max', 1500, 2100)):
    if key not in T: continue
    i = order.index(key); pre, post = T[order[i - 1]], T[order[i + 1]] if i + 1 < len(order) else None
    st = T[key]; ac = mean(st[-3:], {'ODD': 'F0Ac', 'HDD': 'F1Ac', 'CPU': 'F2Ac'}[fan])
    d100 = (ac - base_rpm) / 100
    cells = []
    for k in SENS:
        base = mean(pre[-3:], k) if not post else (mean(pre[-3:], k) + mean(post[-3:], k)) / 2
        cells.append(f"{k} {(mean(st[-3:], k) - base):+.1f} ({(mean(st[-3:], k) - base) / d100:+.2f}/100)")
    print(f"{fan} {base_rpm}->{ac:.0f}: " + ', '.join(cells))

# ---- cool-down phases: rate and exponential fit T(t) = Teq + (T0 - Teq) * exp(-t / tau)
def expfit(rs, k):
    pts = [(r['epoch'] - rs[0]['epoch'], r[k]) for r in rs if not math.isnan(r[k])]
    if len(pts) < 5: return (math.nan, math.nan)
    best = (1e18, math.nan, math.nan)
    for tau in [x * 10 for x in range(3, 361)]:         # 30 s .. 60 min
        e = [math.exp(-t / tau) for t, _ in pts]
        # linear least squares for Teq, A in T = Teq + A*e
        n = len(pts); se = sum(e); see = sum(x * x for x in e); sy = sum(y for _, y in pts); sey = sum(x * y for x, (_, y) in zip(e, pts))
        den = n * see - se * se
        if abs(den) < 1e-12: continue
        A = (n * sey - se * sy) / den; teq = (sy - A * se) / n
        err = sum((teq + A * x - y) ** 2 for x, (_, y) in zip(e, pts))
        if err < best[0]: best = (err, tau, teq)
    return best[1], best[2]
print('\n== cool-down / all-max phases (rate over first 2 min, tau and equilibrium from exp fit)')
for name, rs in T.items():
    if 'Abkühl' not in name and 'max-hold' not in name: continue
    w = [r for r in rs if r['epoch'] - rs[0]['epoch'] <= 120]
    out = []
    for k in ['TC0P', 'TCXc', 'TG0D', 'TO0P', 'Tp1P', 'Tp2H', 'Tp3H', 'TPCD', 'Tm0P', 'TL0P', 'HDD']:
        rate = (w[-1][k] - w[0][k]) / max(1, (w[-1]['epoch'] - w[0]['epoch']) / 60) if len(w) > 1 else math.nan
        tau, teq = expfit(rs, k)
        out.append(f"{k} {rate:+.2f}/min tau {tau:.0f}s eq {teq:.1f}")
    print(f"{name} [{rs[0]['load'][:30]}] {(rs[-1]['epoch']-rs[0]['epoch'])/60:.1f} min: " + ', '.join(out))
