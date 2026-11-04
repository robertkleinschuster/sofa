#!/usr/bin/env python3
"""relink.py <root> <libdir>: copy every /opt/local dylib that any Mach-O under <root>
needs into <libdir> and rewrite all references to @loader_path-relative paths."""
import os, subprocess, sys, shutil
root, libdir = map(os.path.abspath, sys.argv[1:3])
os.makedirs(libdir, exist_ok=True)
def macho(p):
    try:
        with open(p,'rb') as f: m=f.read(4)
    except OSError: return False
    return m in (b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xca\xfe\xba\xbe')
def deps(p):
    out=subprocess.run(['otool','-L',p],capture_output=True,text=True).stdout.splitlines()[1:]
    return [l.strip().split(' (')[0] for l in out]
def tid(p):
    out=subprocess.run(['otool','-D',p],capture_output=True,text=True).stdout.splitlines()[1:]
    return out[0].strip() if out else None
files=[]
for d,_,fs in os.walk(root):
    for f in fs:
        p=os.path.join(d,f)
        if not os.path.islink(p) and macho(p): files.append(p)
# real path of our own framework binary etc: map original install names of files inside root
own={}
for p in files:
    i=tid(p)
    if i and i.startswith('/opt/local'): own[i]=p
todo=list(files); done=set()
while todo:
    p=todo.pop()
    if p in done: continue
    done.add(p)
    os.chmod(p, os.stat(p).st_mode | 0o200)
    args=[]
    i=tid(p)
    if i and i.startswith('/opt/local'):
        args+=['-id','@rpath/'+os.path.basename(i)]
    for dep in deps(p):
        if not dep.startswith('/opt/local'): continue
        if dep==i: continue
        tgt=own.get(dep)
        if not tgt:
            tgt=os.path.join(libdir, os.path.basename(dep))
            if not os.path.exists(tgt):
                shutil.copy2(os.path.realpath(dep), tgt)
                own[dep]=tgt; todo.append(tgt)
            own[dep]=tgt
        rel=os.path.relpath(tgt, os.path.dirname(p))
        args+=['-change',dep,'@loader_path/'+rel]
    if args:
        r=subprocess.run(['install_name_tool']+args+[p],capture_output=True,text=True)
        if r.returncode: print('ERR',p,r.stderr.strip())
left=[(p,d) for p in done for d in deps(p) if d.startswith('/opt/local')]
print(len(done),'mach-o files,',len(os.listdir(libdir)),'libs; unresolved:',len(left))
for x in left[:10]: print('  ',x)
