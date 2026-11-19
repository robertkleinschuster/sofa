#!/usr/bin/env python3
"""fanmodel.py - self-optimisation of sofa-fand, stage 2 (issue #2): learn, simulate, propose.

    fanmodel.py LOGDIR CONF [--out DIR] [--phases CSV ...] [--check SOFA_FAND_BINARY] [--state DIR]

1. Learns a grey-box thermal model per sensor from sofa-fanlearn's CSVs (60 s means):
     dT/dt = a0 + b_cpu*PCPT + b_gpu*PG0R + b_rest*(PDTR-PCPT-PG0R)
             - (k0 + sum_f k_f * rpm_f/1000) * (T - TA0P)                    [deg C / min]
   heat from the measured SMC power, cooling proportional to airflow and temperature difference;
   heat and cooling coefficients constrained >= 0 (active-set least squares).
2. Checks it: free-running simulation of 2-h chunks the fit did not see (leave-one-chunk-out).
3. Simulates sofa-fand (curves, floors, profile shift, feed-forward, hysteresis, minrun, minon/
   minoff) against the model in operating points from the data (rest, screen on, playback, 2/4
   cores, rest under load) and each with a 5 deg C warmer room, from a cold and from a hot start
   (the worse counts, peaks not means), and searches curve offsets and profile shifts that are as
   quiet as possible while every sensor stays below its target and in use nothing gets warmer.
   Hard rule: at its sensor's warn temperature no curve may ask for less than it does today.
4. Writes report.md and sofa-fand.conf.proposal (checked with `sofa-fand check` if --check is
   given; a config that fails is written as .rejected). Nothing is applied.
5. Stage 3 in shadow mode (--state DIR): release gates (enough data and a good model in every
   mode), one small step towards the proposal (curves <= 2 deg C, profiles <= 1 deg C, simulated,
   checked) written as sofa-fand.conf.step, and a line in DIR/shadow.log saying what it would do.
   Daily measured metrics per mode (noise score, temperature peaks) go to DIR/metrics.csv - the
   before/after yardstick for real steps later. Nothing is applied in shadow mode.
Pure Python (runs on the iMac's MacPorts python3), no numpy.
"""
import math, os, re, subprocess, sys, time

# ----------------------------------------------------------------------------------- settings
TARGET = {   # steady-state targets (deg C): well below warn; HDD 43 = below Sofa's "warm" (user 2026-11-19)
    'TG0D': 66, 'TG0H': 68, 'TC0P': 60, 'TCXc': 80, 'TO0P': 46, 'Tp2H': 72, 'Tp1P': 66,
    'Tp3H': 70, 'TPCD': 64, 'Tm0P': 60, 'TL0P': 48, 'TS0P': 44, 'HDD': 43}
WARM_ROOM, WARM_SLACK = 5.0, 3.0   # stress: room this much warmer, targets relaxed by the slack
LOUD = {'ODD': 1.0, 'CPU': 1.5, 'HDD': 4.0}          # loudness weight per fan (user: HDD annoying)
PROFILE_NOISE = {'ruhe': 3.0, 'idle': 1.5, 'playback': 0.7, 'default': 1.0}
ON_COST = 0.4              # a running fan at all (x loudness x profile weight): starting is audible
OFFSETS = range(-8, 9)     # curve shift search range (deg C)
PROF_SHIFTS = {'ruhe': range(0, 9), 'idle': range(-6, -1), 'playback': range(-8, -3)}   # |base| <= 8 (cfg_load);
#   in use never quieter than the user set (2026-11-19: idle <= -2, playback <= -4)
KEEP_COOL = {'idle', 'playback'}   # in use: no sensor warmer than with the current config (+0.5)
SIM_H, SIM_DT = 4.0, 30.0  # simulated hours per operating point, step (s)
PEN = 200.0                # cost per deg C over a target
H_SLOW = {'HDD': 5}
GATE_MIN = {'Ruhe': 300, 'Bildschirm an': 300, 'Wiedergabe': 300}    # minutes of data per mode
GATE_RMSE, GATE_RMSE_OF = 2.5, {'TCXc': 3.5}                        # per-mode RMSE limit (deg C)
STEP_CURVE, STEP_PROF = 2, 1                                         # largest step per night (deg C)        # derivative half-window (min) per sensor: the drive reads whole deg C

# --------------------------------------------------------------------------------------- data
def num(x):
    try:
        v = float(x)
        return v if v == v else None
    except (TypeError, ValueError):
        return x if x not in ('', None) else None

def load_logs(d):
    rows = []
    for fn in sorted(os.listdir(d)):
        if not re.match(r'^\d{4}-\d\d-\d\d\.csv$', fn): continue
        h = None
        for line in open(os.path.join(d, fn), encoding='utf-8', errors='replace'):
            line = line.rstrip('\n')
            if line.startswith('#'): h = line[1:].split(','); continue
            if not h: continue
            v = line.split(',')
            if len(v) != len(h): continue
            rows.append({k: num(x) for k, x in zip(h, v)})
    rows.sort(key=lambda r: r['epoch'])
    return rows

def bin60(rows):
    bins, order = {}, []
    for r in rows:
        b = int(r['epoch'] // 60)
        if b not in bins: bins[b] = []; order.append(b)
        bins[b].append(r)
    out = []
    for b in order:
        rs = bins[b]; d = {'t': b * 60}
        for k in set().union(*[r.keys() for r in rs]):
            vals = [r[k] for r in rs if isinstance(r.get(k), float)]
            if vals: d[k] = sum(vals) / len(vals)
            else:
                s = [r[k] for r in rs if isinstance(r.get(k), str)]
                if s: d[k] = s[-1]
        out.append(d)
    return out

NEED = ('PDTR', 'PCPT', 'PG0R', 'TA0P', 'F0Ac', 'F1Ac', 'F2Ac')
def ok(d, s): return all(isinstance(d.get(k), float) for k in NEED + (s,))

def regs(d, T):
    dT = T - d['TA0P']; rest = d['PDTR'] - d['PCPT'] - d['PG0R']
    return [1.0, d['PCPT'] / 10, d['PG0R'] / 10, rest / 10, -dT,
            -dT * d['F0Ac'] / 1000, -dT * d['F1Ac'] / 1000, -dT * d['F2Ac'] / 1000]
NONNEG = range(1, 8)       # everything but the intercept: heat >= 0, cooling >= 0

def solve(A, b):
    n = len(b); M = [A[i][:] + [b[i]] for i in range(n)]
    for c in range(n):
        p = max(range(c, n), key=lambda r: abs(M[r][c])); M[c], M[p] = M[p], M[c]
        if abs(M[c][c]) < 1e-15: return None
        for r in range(n):
            if r != c:
                f = M[r][c] / M[c][c]
                for k in range(c, n + 1): M[r][k] -= f * M[c][k]
    return [M[i][n] / M[i][i] for i in range(n)]

def nnls(A, b):
    """least squares with the NONNEG coefficients >= 0: drop the most negative, solve again"""
    free = list(range(len(b)))
    while True:
        th = solve([[A[i][j] for j in free] for i in free], [b[i] for i in free])
        if th is None: return None
        full = [0.0] * len(b)
        for i, j in enumerate(free): full[j] = th[i]
        neg = [(full[j], j) for j in free if j in NONNEG and full[j] < 0]
        if not neg: return full
        free.remove(min(neg)[1])

def fit(ser, s, skip=None, lam=1e-3):
    h = H_SLOW.get(s, 2)
    p = 8; A = [[0.0] * p for _ in range(p)]; b = [0.0] * p; n = 0
    for i in range(h, len(ser) - h):
        a, c, d = ser[i - h], ser[i + h], ser[i]
        if skip and (skip(a) or skip(c) or skip(d)): continue      # nothing of a held-out chunk
        if c['t'] - a['t'] != 2 * h * 60 or not (ok(a, s) and ok(c, s) and ok(d, s)): continue
        y = (c[s] - a[s]) / (2 * h); x = regs(d, d[s]); n += 1
        for j in range(p):
            b[j] += x[j] * y
            for k in range(p): A[j][k] += x[j] * x[k]
    for j in range(p): A[j][j] += lam * max(A[j][j], 1e-9)
    return (nnls(A, b) if n > 30 else None), n

def freerun(seg, s, th):
    T = None; err = []
    for i in range(len(seg) - 1):
        d = seg[i]
        if not ok(d, s) or seg[i + 1]['t'] - d['t'] != 60: T = None; continue
        if T is None: T = d[s]
        T += sum(a * b for a, b in zip(th, regs(d, T)))
        if isinstance(seg[i + 1].get(s), float): err.append((T - seg[i + 1][s], seg[i + 1].get('profile')))
    return err

def chunks(ser, sec=7200):
    out, cur = [], []
    for d in ser:
        if cur and d['t'] - cur[0]['t'] >= sec: out.append(cur); cur = []
        cur.append(d)
    if cur: out.append(cur)
    return [c for c in out if len(c) > 30]

# ------------------------------------------------------------------------------ sofa-fand conf
def parse_conf(path):
    c = {'sens': {}, 'fans': {}, 'prof': {}, 'ff': (0, 0), 'lines': open(path).read().split('\n')}
    for i, line in enumerate(c['lines']):
        t = line.split('#')[0].split()
        if not t: continue
        if t[0] == 'sensor':
            kv = dict(zip(t[2::2], t[3::2])); c['sens'][t[1]] = {'ff': kv.get('ff', ''), 'warn': float(kv['warn']), 'trip': float(kv['trip'])}
        elif t[0] == 'fan':
            n = int(t[1]); kv = dict(zip(t[2::2], t[3::2]))
            c['fans'][n] = {'name': kv['name'], 'max': float(kv['max']), 'minrun': float(kv['minrun']), 'hyst': float(kv['hyst']),
                            'minon': float(kv.get('minon', 0)), 'minoff': float(kv.get('minoff', 0)),
                            'pw': float(kv.get('profile_weight', 1)), 'fw': float(kv.get('ff_weight', 1)), 'curves': [], 'floors': []}
        elif t[0] == 'curve':
            c['fans'][int(t[1])]['curves'].append({'key': t[2], 'pts': [tuple(map(float, p.split(':'))) for p in t[3:]], 'line': i})
        elif t[0] == 'floor':
            c['fans'][int(t[1])]['floors'].append((t[2], float(t[3]), float(t[4])))
        elif t[0] == 'profile':
            c['prof'][t[1]] = (float(t[2]), float(t[3]) if len(t) > 3 else 0.0, i)
        elif t[0] == 'feedforward':
            c['ff'] = (float(t[1]), float(t[2]))
    return c

def interp(pts, t):
    if t <= pts[0][0]: return pts[0][1]
    for (t0, r0), (t1, r1) in zip(pts, pts[1:]):
        if t < t1: return r0 + (r1 - r0) * (t - t0) / (t1 - t0)
    return pts[-1][1]

def prof_base(conf, offs, p): return offs.get(('prof', p), conf['prof'].get(p, (0, 0, -1))[0])

def warn_demand(conf, offs, n, ci):
    """lowest rpm curve (n, ci) asks for at its sensor's warn temperature, over all profiles and
    volumes (feed-forward ignored = worst case)"""
    f = conf['fans'][n]; cv = f['curves'][ci]; w = conf['sens'][cv['key']]['warn']
    shifts = [0.0] + [prof_base(conf, offs, p) + vs * v for p, (b, vs, _) in conf['prof'].items() for v in (0.0, 1.0)]
    return min(interp(cv['pts'], w - f['pw'] * sh - offs.get((n, ci), 0)) for sh in shifts)

# --------------------------------------------------------------------------- closed-loop sim
def simulate(conf, model, sc, offs, hot):
    """sofa-fand + model in operating point sc; returns peak temps, mean rpm^2, mean rpm, on share"""
    if hot:
        T = {s: conf['sens'][s]['warn'] - 3 if s in conf['sens'] else sc['TA0P'] + 25 for s in model}
        rpm = {n: f['max'] for n, f in conf['fans'].items()}
    else:
        T = {s: sc['TA0P'] + 10 for s in model}; rpm = {n: 0.0 for n in conf['fans']}
    on_since = {n: 0.0 for n in rpm}; off_since = {n: -1e9 for n in rpm}
    base = prof_base(conf, offs, sc['profile']); vs = conf['prof'].get(sc['profile'], (0, 0, -1))[1]
    shift = base + vs * sc.get('vol', 0.5)
    ffc, ffg = conf['ff']
    steps = int(SIM_H * 3600 / SIM_DT); q = steps * 3 // 4
    peak = {s: -1e9 for s in T}; r2 = {n: 0.0 for n in rpm}; r1 = {n: 0.0 for n in rpm}; on = {n: 0 for n in rpm}; m = 0
    for k in range(steps):
        now = k * SIM_DT
        d = {'PDTR': sc['PDTR'], 'PCPT': sc['PCPT'], 'PG0R': sc['PG0R'], 'TA0P': sc['TA0P'],
             'F0Ac': rpm.get(0, 0), 'F1Ac': rpm.get(1, 0), 'F2Ac': rpm.get(2, 0)}
        for s, th in model.items():
            T[s] += SIM_DT / 60 * sum(a * b for a, b in zip(th, regs(d, T[s])))
        for n, f in conf['fans'].items():
            up = dn = 0.0; urgent = False
            for ci, cv in enumerate(f['curves']):
                key = cv['key']
                if key not in T: continue
                ffk = conf['sens'].get(key, {}).get('ff', '')
                ff = (ffc * sc['cpu'] if ffk in ('cpu', 'both') else 0) + (ffg * sc['gpu'] if ffk in ('gpu', 'both') else 0)
                te = T[key] + f['fw'] * ff - f['pw'] * shift - offs.get((n, ci), 0)
                up = max(up, interp(cv['pts'], te)); dn = max(dn, interp(cv['pts'], te + f['hyst']))
                if T[key] >= conf['sens'][key]['warn']: urgent = True
            fl = max([r for key, t0, r in f['floors'] if key in T and T[key] >= t0] or [0])
            urgent = urgent or fl > 0
            up, dn = max(up, fl), max(dn, fl)
            cur = rpm[n]
            want = up if up > cur else (dn if dn < cur else cur)
            if 0 < want < f['minrun']: want = f['minrun']
            if cur <= 0 < want and not urgent and now - off_since[n] < f['minoff']: want = 0       # minoff
            want = max(want, fl)
            if cur > 0 and want <= 0 and now - on_since[n] < f['minon']: want = max(f['minrun'], cur)  # minon
            want = min(want, f['max'])
            if cur <= 0 < want: on_since[n] = now
            if cur > 0 >= want: off_since[n] = now
            rpm[n] = want
        if k >= q:
            for s in T: peak[s] = max(peak[s], T[s])
            for n in rpm: r2[n] += rpm[n] ** 2; r1[n] += rpm[n]; on[n] += rpm[n] > 0
            m += 1
    return peak, {n: v / m for n, v in r2.items()}, {n: v / m for n, v in r1.items()}, {n: v / m for n, v in on.items()}

def evaluate(conf, model, sc, offs):
    """worse of cold and hot start"""
    a = simulate(conf, model, sc, offs, False); b = simulate(conf, model, sc, offs, True)
    peak = {s: max(a[0][s], b[0][s]) for s in a[0]}
    pick = lambda i: {n: max(a[i][n], b[i][n]) for n in a[i]}
    return peak, pick(1), pick(2), pick(3)

def cost(conf, model, scs, offs, base=None, detail=False):
    tot = 0.0; rows = []
    for i, sc in enumerate(scs):
        peak, r2, r1, onf = evaluate(conf, model, sc, offs)
        noise = sum(LOUD.get(conf['fans'][n]['name'], 1) * (r2[n] / 1e6 + ON_COST * onf[n]) for n in r2)
        noise *= PROFILE_NOISE.get(sc['profile'], 1)
        slack = WARM_SLACK if sc.get('warm') else 0
        over = {s: peak[s] - (TARGET[s] + slack) for s in peak if s in TARGET and peak[s] > TARGET[s] + slack}
        if base and sc['profile'] in KEEP_COOL:
            for s in peak:
                if peak[s] > base[i][s] + 0.5: over[s] = max(over.get(s, 0), peak[s] - base[i][s] - 0.5)
        warn = {s: peak[s] for s in peak if s in conf['sens'] and peak[s] >= conf['sens'][s]['warn']}
        tot += noise + PEN * sum(over.values()) + 10 * PEN * len(warn)
        rows.append({'sc': sc, 'peak': peak, 'rpm': r1, 'on': onf, 'noise': noise, 'over': over, 'warn': warn})
    return (tot, rows) if detail else tot

# --------------------------------------------------------------------------- operating points
def scenarios(ser, phases):
    def ph_of(t):
        for p in phases:
            if p[0] <= t < p[1]: return p[2], p[3]
        return None, None
    test = lambda d: ph_of(d['t'])[0] is not None
    groups = [
        ('Ruhe (Bildschirm aus)', lambda d: not test(d) and d.get('profile') == 'ruhe' and d.get('cpu', 1) < 0.05, 'ruhe', None),
        ('Bildschirm an, Leerlauf', lambda d: not test(d) and d.get('profile') == 'idle' and d.get('cpu', 1) < 0.1, 'idle', None),
        ('Wiedergabe', lambda d: not test(d) and d.get('profile') == 'playback', 'playback', None),
        ('2 Kerne, Bildschirm an', lambda d: ph_of(d['t'])[0] == 'B3', 'idle', 0.5),
        ('4 Kerne, Bildschirm aus', lambda d: ph_of(d['t'])[0] == 'B4' and ph_of(d['t'])[1] != 'cool', 'default', 1.0),
        ('Ruhe unter Last (4 Kerne, z. B. Backup)', lambda d: ph_of(d['t'])[0] == 'B4' and ph_of(d['t'])[1] != 'cool', 'ruhe', 1.0),
    ]
    out = []
    for name, sel, prof, cpu in groups:
        ds = [d for d in ser if sel(d) and ok(d, 'TA0P')]
        if len(ds) < 10: continue
        mean = lambda k: sum(x[k] for x in ds if isinstance(x.get(k), float)) / max(1, sum(1 for x in ds if isinstance(x.get(k), float)))
        sc = {'name': name, 'profile': prof, 'n': len(ds), 'PDTR': mean('PDTR'), 'PCPT': mean('PCPT'), 'PG0R': mean('PG0R'), 'TA0P': mean('TA0P')}
        cpus = [x.get('cpu') for x in ds if isinstance(x.get('cpu'), float)]
        sc['cpu'] = cpu if cpu is not None else (sum(cpus) / len(cpus) if cpus else 0.0)
        gpus = [x['gpu'] for x in ds if isinstance(x.get('gpu'), float)]
        sc['gpu'] = sum(gpus) / len(gpus) if gpus else 0.0
        vols = [x['vol'] for x in ds if isinstance(x.get('vol'), float)]
        sc['vol'] = sum(vols) / len(vols) if vols else 0.5      # sofa-fand's default without a volume
        out.append(sc)
        w = dict(sc); w['name'] = name + ', Raum +%g °C' % WARM_ROOM; w['TA0P'] += WARM_ROOM; w['warm'] = True
        out.append(w)
    return out

def render(conf, offs):
    lines = conf['lines'][:]; notes = []
    for key, o in sorted(offs.items(), key=lambda kv: str(kv[0])):
        if key[0] == 'prof':
            pi = conf['prof'][key[1]][2]; old = lines[pi]; t = old.split('#')[0].split(); t[2] = '%g' % o
            lines[pi] = ' '.join(t) + '   # fanmodel: was ' + old.split('#')[0].split()[2]
            notes.append((key, old.split('#')[0].strip(), lines[pi].split('#')[0].strip())); continue
        n, ci = key; cv = conf['fans'][n]['curves'][ci]; old = lines[cv['line']]
        lines[cv['line']] = 'curve %d %-4s %s   # fanmodel: %+d °C' % (n, cv['key'], ' '.join('%g:%g' % (t + o, r) for t, r in cv['pts']), o)
        notes.append((key, old.split('#')[0].strip(), lines[cv['line']].split('#')[0].strip()))
    return lines, notes

def check_conf(checker, path):
    if not checker: return None, 'nicht geprüft (kein --check)'
    r = subprocess.run([checker, 'check', '-c', path], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
    return r.returncode == 0, ('sofa-fand check: ok' if r.returncode == 0 else 'sofa-fand check FEHLGESCHLAGEN: ' + (r.stdout.strip().splitlines() or ['?'])[-1][:200])

MODE = {'ruhe': 'Ruhe', 'idle': 'Bildschirm an', 'playback': 'Wiedergabe'}
def metrics(conf, ser, since):
    """measured per mode over the bins since `since`: minutes, noise score, temperature peaks"""
    out = {}
    for m in MODE.values():
        ds = [d for d in ser if d['t'] >= since and MODE.get(d.get('profile')) == m]
        if not ds: continue
        def noise(d):
            return sum(LOUD.get(f['name'], 1) * ((d.get('F%dAc' % n) or 0) ** 2 / 1e6 + ON_COST * ((d.get('F%dAc' % n) or 0) > 100))
                       for n, f in conf['fans'].items() if isinstance(d.get('F%dAc' % n), float))
        def p95(k):
            v = sorted(d[k] for d in ds if isinstance(d.get(k), float)); return v[int(len(v) * 0.95)] if v else float('nan')
        hdd_on = sum(1 for d in ds if (d.get('F1Ac') or 0) > 100) / len(ds)
        out[m] = {'min': len(ds), 'noise': sum(noise(d) for d in ds) / len(ds), 'hdd_on': hdd_on,
                  'Tp2H': p95('Tp2H'), 'TG0D': p95('TG0D'), 'TC0P': p95('TC0P'), 'HDD': p95('HDD')}
    return out

# --------------------------------------------------------------------------------------- main
def main():
    a = sys.argv[1:]
    if len(a) < 2: print(__doc__); sys.exit(2)
    logdir, confp = a[0], a[1]; outdir = '.'; phfiles = []; checker = None; state = None
    i = 2
    while i < len(a):
        if a[i] == '--out': outdir = a[i + 1]; i += 2
        elif a[i] == '--phases': phfiles.append(a[i + 1]); i += 2
        elif a[i] == '--check': checker = a[i + 1]; i += 2
        elif a[i] == '--state': state = a[i + 1]; i += 2
        else: print('unknown argument', a[i]); sys.exit(2)
    t0 = time.time()
    conf = parse_conf(confp)
    phases = []
    for p in phfiles:
        for line in list(open(p))[1:]:
            v = line.strip().split(',')
            if len(v) >= 4: phases.append((int(v[0]), int(v[1]), v[2], v[3]))
    ser = bin60(load_logs(logdir))
    sensors = sorted({cv['key'] for f in conf['fans'].values() for cv in f['curves']})
    rep = ['# Lüftermodell und Kurvenvorschlag', '',
           'Erzeugt %s aus %d Minuten Daten (%s bis %s). Nichts wurde angewendet.' % (
               time.strftime('%Y-%m-%d %H:%M'), len(ser), time.strftime('%d.%m. %H:%M', time.localtime(ser[0]['t'])),
               time.strftime('%d.%m. %H:%M', time.localtime(ser[-1]['t']))), '',
           '## Modellgüte', '',
           'Freier Simulationslauf über 2-h-Abschnitte, die beim Lernen ganz weggelassen wurden (°C).', '',
           '| Sensor | Lernpunkte | RMSE | 90 %-Fehler | max | Abschnitte |', '|---|---|---|---|---|---|']
    model = {}; cs = chunks(ser); bymode = {}
    for s in sensors:
        th, n = fit(ser, s)
        if not th: rep.append('| %s | %d | – | – | – | zu wenig Daten |' % (s, n)); continue
        model[s] = th; errs = []
        for c in cs:
            lo, hi = c[0]['t'], c[-1]['t']
            t2, _ = fit(ser, s, skip=lambda d: lo <= d['t'] <= hi)
            if t2: errs += freerun(c, s, t2)
        for e, pr in errs:
            m = {'ruhe': 'Ruhe', 'idle': 'Bildschirm an', 'playback': 'Wiedergabe'}.get(pr, 'Test/sonst')
            bymode.setdefault(s, {}).setdefault(m, []).append(e)
        errs = [e for e, _ in errs]
        if errs:
            ae = sorted(abs(e) for e in errs)
            rep.append('| %s | %d | %.1f | %.1f | %.1f | %d |' % (s, n, math.sqrt(sum(e * e for e in errs) / len(errs)), ae[int(len(ae) * 0.9)], ae[-1], len(cs)))
    modes = ['Ruhe', 'Bildschirm an', 'Wiedergabe', 'Test/sonst']
    rep += ['', 'Je Betriebsart (RMSE °C, in Klammern Minuten): erst wenn „Wiedergabe“ ähnlich gut ist wie der Rest, taugt ein Vorschlag für die Wiedergabe.', '',
            '| Sensor | ' + ' | '.join(modes) + ' |', '|---' * (len(modes) + 1) + '|']
    for s in sorted(bymode):
        cells = []
        for m in modes:
            e = bymode[s].get(m, [])
            cells.append('%.1f (%d)' % (math.sqrt(sum(x * x for x in e) / len(e)), len(e)) if e else '–')
        rep.append('| %s | %s |' % (s, ' | '.join(cells)))
    missing = [s for s in sensors if s not in model]
    rep += ['', '## Wirkung der Lüfter (gelernt)', '',
            'Kühlwirkung je 1000 U/min relativ zur Eigenkühlung ohne Lüfter (k_Lüfter / k0): 1,0 = 1000 U/min verdoppeln die Wärmeabfuhr.',
            'Wärme je 10 W: CPU-Package (PCPT), GPU (PG0R), Rest (Bildschirm, Netzteil, Platte …) in °C/min.', '',
            '| Sensor | ODD | HDD | CPU | Wärme CPU | GPU | Rest |', '|---|---|---|---|---|---|---|']
    for s, th in model.items():
        k0 = max(th[4], 1e-6)
        rep.append('| %s | %.2f | %.2f | %.2f | %.3f | %.3f | %.3f |' % (s, th[5] / k0, th[6] / k0, th[7] / k0, th[1], th[2], th[3]))
    scs = scenarios(ser, phases)
    if not scs: print('no operating points found'); sys.exit(1)
    base_rows = cost(conf, model, scs, {}, detail=True)[1]
    btemps = [r['peak'] for r in base_rows]
    base_cost = cost(conf, model, scs, {}, base=btemps)
    curves = [(n, ci) for n, f in conf['fans'].items() for ci, cv in enumerate(f['curves']) if cv['key'] in model]
    wreq = {k: warn_demand(conf, {}, *k) for k in curves}
    def feasible(o):   # hard rule: at warn no curve asks for less than today
        return all(warn_demand(conf, o, *k) >= wreq[k] - 1 for k in curves)
    vars_ = curves + [('prof', p) for p in PROF_SHIFTS if p in conf['prof']]
    offs = {}; best = base_cost
    for it in range(3):
        improved = False
        for key in vars_:
            dflt = conf['prof'][key[1]][0] if key[0] == 'prof' else 0
            cur = offs.get(key, dflt)
            for o in (PROF_SHIFTS[key[1]] if key[0] == 'prof' else OFFSETS):
                if o == cur: continue
                trial = dict(offs); trial[key] = o
                if not feasible(trial): continue
                c = cost(conf, model, scs, trial, base=btemps)
                if c < best - 1e-6: best, offs, improved = c, trial, True
        if not improved: break
    offs = {k: v for k, v in offs.items() if (k[0] == 'prof' and v != conf['prof'][k[1]][0]) or (k[0] != 'prof' and v)}
    new_cost, new_rows = cost(conf, model, scs, offs, base=btemps, detail=True)
    bound = [k for k, v in offs.items() if k[0] != 'prof' and v in (min(OFFSETS), max(OFFSETS))] + \
            [k for k, v in offs.items() if k[0] == 'prof' and v in (min(PROF_SHIFTS[k[1]]), max(PROF_SHIFTS[k[1]]))]
    show = ['Tp2H', 'TC0P', 'TG0D', 'TL0P', 'HDD']
    rep += ['', '## Betriebspunkte: jetzige Config gegen Vorschlag', '',
            'Simuliert je %g h von kaltem und heißem Start, gezählt wird der schlechtere; Temperaturen = Spitze im letzten Viertel. '
            'Ziele: %s (Raum +%g °C: Ziele +%g °C). Im Gebrauch (Bildschirm an, Wiedergabe) darf kein Sensor wärmer werden als jetzt.' % (
                SIM_H, ', '.join('%s %g' % kv for kv in TARGET.items()), WARM_ROOM, WARM_SLACK), '',
            '| Betriebspunkt | Lüfter ODD / HDD / CPU jetzt → Vorschlag | %s jetzt → Vorschlag | kleinster Abstand zu warn | über Ziel (Vorschlag) |' % ' / '.join(show),
            '|---|---|---|---|---|']
    def fans(r): return ' / '.join(('%.0f' % r['rpm'][n] + (' (%d %%)' % round(100 * r['on'][n]) if 0.02 < r['on'][n] < 0.98 else '')) for n in sorted(r['rpm']))
    def margin(r): s = min(r['peak'], key=lambda s: conf['sens'][s]['warn'] - r['peak'][s]); return '%s %.1f' % (s, conf['sens'][s]['warn'] - r['peak'][s])
    for r1, r2 in zip(base_rows, new_rows):
        rep.append('| %s | %s → %s | %s → %s | %s → %s | %s |' % (
            r1['sc']['name'], fans(r1), fans(r2), '/'.join('%.0f' % r1['peak'].get(s, float('nan')) for s in show),
            '/'.join('%.0f' % r2['peak'].get(s, float('nan')) for s in show), margin(r1), margin(r2),
            ', '.join('%s +%.1f' % kv for kv in sorted(r2['over'].items())) or '–'))
    rep += ['', 'Gesamtkosten (Lautstärke gewichtet + Strafe für Zielüberschreitung): jetzt %.1f, Vorschlag %.1f.' % (base_cost, new_cost), '',
            '## Vorgeschlagene Änderungen', '']
    if not offs: rep.append('Keine: die jetzige Config ist im Modell schon optimal.')
    lines, notes = render(conf, offs)
    for key, old, new in notes:
        o = offs[key]
        if key[0] == 'prof': rep.append('- `%s` → `%s` (Profil %s%s)' % (old, new, key[1], ', am Suchrand' if key in bound else ''))
        else: rep.append('- `%s` → `%s` (%s %+d °C, %s%s)' % (old, new, conf['fans'][key[0]]['name'], o, 'später/leiser' if o > 0 else 'früher/kühler', ', am Suchrand' if key in bound else ''))
    os.makedirs(outdir, exist_ok=True)
    prop = os.path.join(outdir, 'sofa-fand.conf.proposal')
    open(prop, 'w').write('\n'.join(lines))
    good, verdict = check_conf(checker, prop)
    if good is False: os.replace(prop, prop + '.rejected'); verdict += ', verworfen'
    # ---- stage 3, shadow mode: gates, one small step, log what it would do
    if state:
        os.makedirs(state, exist_ok=True)
        minutes = {m: sum(1 for d in ser if MODE.get(d.get('profile')) == m) for m in GATE_MIN}
        why = ['%s: %d von %d min Daten' % (m, minutes[m], GATE_MIN[m]) for m in GATE_MIN if minutes[m] < GATE_MIN[m]]
        for sn, per in sorted(bymode.items()):
            for m in GATE_MIN:
                e = per.get(m, [])
                if e:
                    r = math.sqrt(sum(x * x for x in e) / len(e))
                    if r > GATE_RMSE_OF.get(sn, GATE_RMSE): why.append('%s %s: Modellfehler %.1f °C' % (sn, m, r))
        if good is False: why.append('Vorschlag besteht sofa-fand check nicht')
        step = {}
        for key, o in offs.items():
            if key[0] == 'prof':
                cur = conf['prof'][key[1]][0]; step[key] = cur + max(-STEP_PROF, min(STEP_PROF, o - cur))
            else: step[key] = max(-STEP_CURVE, min(STEP_CURVE, o))
        step = {k: v for k, v in step.items() if (k[0] == 'prof' and v != conf['prof'][k[1]][0]) or (k[0] != 'prof' and v)}
        if step and not feasible(step): why.append('Schritt verletzt die harte Regel an der Warngrenze'); step = {}
        stxt = 'keiner'
        if step:
            sc_cost, sc_rows = cost(conf, model, scs, step, base=btemps, detail=True)
            if sc_cost > base_cost + 1e-6: why.append('Schritt ist im Modell nicht besser (%.1f statt %.1f)' % (sc_cost, base_cost))
            neww = sorted({'%s (%s)' % (k, r['sc']['name']) for r, b in zip(sc_rows, base_rows) for k in r['warn'] if k not in b['warn']})
            if neww: why.append('Schritt erreicht im Modell eine neue Warngrenze: ' + ', '.join(neww[:3]))
            slines, snotes = render(conf, step)
            sp = os.path.join(outdir, 'sofa-fand.conf.step'); open(sp, 'w').write('\n'.join(slines))
            sgood, sverd = check_conf(checker, sp)
            if sgood is False: os.replace(sp, sp + '.rejected'); why.append('Schritt besteht sofa-fand check nicht')
            stxt = ', '.join(('Profil %s %g→%g' % (k[1], conf['prof'][k[1]][0], v)) if k[0] == 'prof' else
                             ('%s/%s %+d °C' % (conf['fans'][k[0]]['name'], conf['fans'][k[0]]['curves'][k[1]]['key'], v)) for k, v in sorted(step.items(), key=lambda kv: str(kv[0])))
        released = not why and bool(step)
        line = '%s | Freigabe: %s | Schritt: %s | Schattenbetrieb: nichts angewendet' % (
            time.strftime('%Y-%m-%d %H:%M'), 'ja' if released else 'nein (' + '; '.join(why[:6]) + (' …' if len(why) > 6 else '') + ')', stxt)
        open(os.path.join(state, 'shadow.log'), 'a').write(line + '\n')
        mt = metrics(conf, ser, ser[-1]['t'] - 86400)
        mp = os.path.join(state, 'metrics.csv'); new = not os.path.exists(mp)
        with open(mp, 'a') as f:
            if new: f.write('date,mode,minutes,noise,hdd_fan_on,Tp2H_p95,TG0D_p95,TC0P_p95,HDD_p95\n')
            for m, v in mt.items():
                f.write('%s,%s,%d,%.3f,%.3f,%.1f,%.1f,%.1f,%.1f\n' % (time.strftime('%Y-%m-%d'), m, v['min'], v['noise'], v['hdd_on'], v['Tp2H'], v['TG0D'], v['TC0P'], v['HDD']))
        rep += ['', '## Stufe 3 (Schattenbetrieb)', '', line.split(' | ', 1)[1].replace(' | ', '  \n'), '',
                'Gemessen in den letzten 24 h (Lautstärke-Maß, Spitzen = 95 %-Wert):', '',
                '| Betriebsart | Minuten | Lautstärke | HDD-Lüfter an | Tp2H | TG0D | TC0P | HDD |', '|---|---|---|---|---|---|---|---|']
        for m, v in mt.items():
            rep.append('| %s | %d | %.2f | %d %% | %.1f | %.1f | %.1f | %.1f |' % (m, v['min'], v['noise'], round(100 * v['hdd_on']), v['Tp2H'], v['TG0D'], v['TC0P'], v['HDD']))
    rep += ['', 'Config-Prüfung: %s.' % verdict, '', '## Grenzen', '',
            '- Das Modell ist so gut wie seine Daten: Raumtemperaturen und Lasten außerhalb des Gesehenen sind Extrapolation (deshalb der Warm-Raum-Fall).',
            '- TA0P (ein Sensor im Gehäuse) dient als Umgebung und wird im Betriebspunkt festgehalten; bei leiseren Lüftern steigt er in Wirklichkeit leicht, die Simulation ist dort etwas optimistisch.',
            '- Verschoben werden nur ganze Kurven (%d…%+d °C) und Profil-Grundwerte; Floors, Warn- und Abschaltgrenzen bleiben. Harte Regel: an der Warngrenze fordert keine Kurve weniger als heute.' % (min(OFFSETS), max(OFFSETS))]
    if missing: rep.append('- Ohne Modell (zu wenig Daten), ihre Kurven bleiben: %s.' % ', '.join(missing))
    if bound: rep.append('- Am Rand des Suchbereichs (Ergebnis ist eine Ecke, kein freies Optimum): %s.' % ', '.join(str(k) for k in bound))
    rep += ['', 'Rechenzeit %.0f s.' % (time.time() - t0)]
    open(os.path.join(outdir, 'report.md'), 'w').write('\n'.join(rep) + '\n')
    print('\n'.join(rep))

if __name__ == '__main__':
    main()
