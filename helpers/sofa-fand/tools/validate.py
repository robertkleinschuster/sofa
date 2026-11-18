# validate.py CSV [since_epoch] - sanity check of sofa-fanlearn data
import sys, time
from collections import Counter
rows=[];h=None
for l in open(sys.argv[1]):
    l=l.rstrip('\n')
    if l.startswith('#'): h=l[1:].split(','); continue
    v=l.split(',')
    if len(v)!=len(h): print('FEHLER: Zeile mit %d statt %d Feldern'%(len(v),len(h))); continue
    rows.append(dict(zip(h,v)))
since=int(sys.argv[2]) if len(sys.argv)>2 else 0
r=[x for x in rows if int(x['epoch'])>=since and 'disp_pwr' in x]
if not r: print('keine Proben'); sys.exit()
ts=[int(x['epoch']) for x in r]; d=[b-a for a,b in zip(ts,ts[1:])]
print('Proben %d, %s–%s, Abstände %s, Lücken>30s: %d'%(len(r),time.strftime('%H:%M',time.localtime(ts[0])),time.strftime('%H:%M',time.localtime(ts[-1])),Counter(d).most_common(3),sum(1 for x in d if x>30)))
core=['cpu_raw','disp_pwr','bright','disk_wB_s','net_inB_s','F0Ac','F1Ac','F2Ac','PDTR','PCPT','PG0R','TG0D','TC0P','Tp2H','TL0P','TS0P','HDD']
bad=[k for k in core if k in h and sum(1 for x in r[1:] if x[k]=='')>len(r)//20]
print('Kernspalten mit >5%% Lücken: %s'%(bad or 'keine'))
ext=h.index('HDD')+1; ef=sum(1 for x in r if any(x[k]!='' for k in h[ext:])); print('Zusatzwerte in %d/%d Proben (Soll ~1/3)'%(ef,len(r)))
def rng(k):
    v=[float(x[k]) for x in r if x.get(k,'') not in ('',)]
    return (min(v),max(v)) if v else None
for k,lo,hi in [('PDTR',15,250),('PCPT',2,80),('Tp2H',20,100),('TG0D',20,95),('HDD',20,60),('F0Ac',0,2600),('F1Ac',0,5600),('F2Ac',0,2200),('bright',0,256)]:
    m=rng(k); ok=m and lo<=m[0] and m[1]<=hi
    print('%-6s %s %s'%(k,m,'ok' if ok else 'AUFFÄLLIG'))
