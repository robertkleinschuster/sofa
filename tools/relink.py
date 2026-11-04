#!/usr/bin/env python3
"""Make a directory tree self-contained (macOS Mach-O).

relink.py <root> <libdir>   copy every /opt/local dylib that any Mach-O under <root> needs
                            (transitively) into <libdir>, rewrite all references to
                            @loader_path-relative paths, drop /opt/local LC_RPATHs.
relink.py --check <root>    fail if any Mach-O under <root> still depends on anything outside
                            /usr/lib, /System and @loader_path, or carries an LC_RPATH.

Exit status 1 on any error, so tools/make-release stops instead of shipping a broken bundle.
"""
import os, shutil, subprocess, sys

PREFIX = '/opt/local'
MAGIC = {b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'}


def is_macho(p):
    if os.path.islink(p) or not os.path.isfile(p):
        return False
    try:
        with open(p, 'rb') as f:
            return f.read(4) in MAGIC
    except OSError:
        return False


def machos(root):
    for d, _, fs in os.walk(root):
        for f in fs:
            p = os.path.join(d, f)
            if is_macho(p):
                yield p


def otool(args, p):
    return subprocess.run(['otool'] + args + [p], capture_output=True, text=True).stdout.splitlines()


def install_id(p):
    out = otool(['-D'], p)[1:]
    return out[0].strip() if out else None


def deps(p):
    """Dependencies without the file's own install name (otool -L lists it first for dylibs)."""
    own = install_id(p)
    out = [l.strip().split(' (')[0] for l in otool(['-L'], p)[1:]]
    if own and out and out[0] == own:
        out = out[1:]
    return out


def versions(p):
    """{install name: current version} from otool -L (incl. the file's own id)."""
    res = {}
    for l in otool(['-L'], p)[1:]:
        l = l.strip()
        if ' (' in l and 'current version ' in l:
            res[l.split(' (')[0]] = l.split('current version ')[1].rstrip(')')
    return res


def vkey(v):
    return tuple(int(x) for x in v.split('.') if x.isdigit())


def rpaths(p):
    lines = otool(['-l'], p)
    res = []
    for i, l in enumerate(lines):
        if l.strip() == 'cmd LC_RPATH':
            for k in lines[i + 1:i + 4]:
                k = k.strip()
                if k.startswith('path '):
                    res.append(k[5:].split(' (offset')[0])
    return res


def relink(root, libdir):
    root, libdir = os.path.abspath(root), os.path.abspath(libdir)
    os.makedirs(libdir, exist_ok=True)
    errors = []
    # realpath of a MacPorts library -> its file in the bundle
    placed = {}
    for p in machos(libdir):   # libraries already in the bundle (sofa-deploy reuses them)
        placed.setdefault('bundled:' + os.path.basename(p), p)
    files = list(machos(root))
    for p in files:            # Mach-Os that ARE MacPorts libraries (Python.framework/Python, ...)
        i = install_id(p)
        if i and i.startswith(PREFIX + '/') and os.path.exists(i):
            placed[os.path.realpath(i)] = p
    todo, done = list(files), set()
    while todo:
        p = todo.pop()
        if p in done:
            continue
        done.add(p)
        os.chmod(p, os.stat(p).st_mode | 0o200)
        args = []
        i = install_id(p)
        if i and not i.startswith('@'):
            args += ['-id', '@rpath/' + os.path.basename(p)]
        for rp in rpaths(p):
            if rp.startswith(PREFIX):
                args += ['-delete_rpath', rp]
        for dep in deps(p):
            if not dep.startswith(PREFIX + '/'):
                continue
            if not os.path.exists(dep):
                errors.append('%s: missing dependency %s' % (p, dep))
                continue
            real = os.path.realpath(dep)
            tgt = placed.get(real)
            if not tgt:
                name = os.path.basename(real)
                tgt = os.path.join(libdir, name)
                prev = placed.get('bundled:' + name)
                if prev and not os.path.exists(tgt):
                    tgt = prev
                if prev:
                    # library reused from an older bundle (sofa-deploy): it must have
                    # at least the version p was built against
                    need = versions(p).get(dep)
                    have = next(iter(versions(prev).values()), None)
                    if need and have and vkey(have) < vkey(need):
                        errors.append('%s: bundled %s is %s, needs %s -- build a new release'
                                      % (p, name, have, need))
                        continue
                if os.path.exists(tgt) and not prev:
                    # same file name from two different MacPorts libraries -> would collapse
                    errors.append('%s: name clash %s (%s)' % (p, name, real))
                    continue
                if not os.path.exists(tgt):
                    shutil.copy2(real, tgt)
                    todo.append(tgt)
                placed[real] = tgt
            rel = os.path.relpath(tgt, os.path.dirname(p))
            args += ['-change', dep, '@loader_path/' + rel]
        if args:
            r = subprocess.run(['install_name_tool'] + args + [p], capture_output=True, text=True)
            if r.returncode or 'error' in r.stderr:
                errors.append('%s: install_name_tool: %s' % (p, r.stderr.strip()))
    print('%d Mach-O files, %d libraries in %s' % (len(done), sum(1 for _ in machos(libdir)), libdir))
    return errors


def check(root):
    errors = []
    n = 0
    for p in machos(root):
        n += 1
        for rp in rpaths(p):
            errors.append('%s: LC_RPATH %s' % (p, rp))
        for dep in deps(p):
            if dep.startswith(('/usr/lib/', '/System/Library/')):
                continue
            if dep.startswith('@loader_path/'):
                tgt = os.path.normpath(os.path.join(os.path.dirname(p), dep[len('@loader_path/'):]))
                if not os.path.exists(tgt):
                    errors.append('%s: %s does not exist' % (p, dep))
                continue
            errors.append('%s: dependency outside the bundle: %s' % (p, dep))
    print('checked %d Mach-O files' % n)
    return errors


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == '--check':
        errs = check(sys.argv[2])
    elif len(sys.argv) == 3:
        errs = relink(sys.argv[1], sys.argv[2])
    else:
        sys.exit(__doc__)
    for e in errs[:30]:
        print('ERROR', e)
    sys.exit(1 if errs else 0)
