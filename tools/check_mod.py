"""Verifica el mod con Godot 3.6.1 estándar (.tools/godot), sin el juego.

  python -I tools/check_mod.py            # chequeo de sintaxis de todos los .gd
  python -I tools/check_mod.py --run 15   # además corre 2 instancias (build DEV) N segundos:
                                          # la 1ª hostea, la 2ª se une; imprime sus logs

Arma un proyecto temporal con mod/online en res://online_mod/ y el autoload OnlineMod.
Sale con código 1 si hay errores de script.
"""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GODOT = os.path.join(ROOT, '.tools', 'godot', 'Godot_v3.6.1-stable_win64.exe')
NOISE = ('Godot Engine', 'OpenGL', 'WASAPI', 'Async. shader', 'Using GLES')


def make_project(dev: bool) -> str:
    proj = tempfile.mkdtemp(prefix='gdcheck_')
    with open(os.path.join(proj, 'project.godot'), 'w', newline='\n') as f:
        f.write('config_version=4\n\n[application]\n\nconfig/name="online_mod_check"\n'
                'run/main_scene="res://main.tscn"\n\n'
                '[autoload]\n\nOnlineMod="*res://online_mod/online_mod.gd"\n')
    with open(os.path.join(proj, 'main.tscn'), 'w', newline='\n') as f:
        f.write('[gd_scene format=2]\n\n[node name="Main" type="Node"]\n')
    dst = os.path.join(proj, 'online_mod')
    shutil.copytree(os.path.join(ROOT, 'mod', 'online'), dst)
    version = open(os.path.join(ROOT, 'mod', 'VERSION'), encoding='utf-8').read().strip()
    with open(os.path.join(dst, 'build_config.gd'), 'w', newline='\n') as f:
        f.write('extends Reference\n\n')
        f.write(f'const MOD_VERSION := "{version}"\n')
        f.write(f'const DEV_AUTOCONNECT := {"true" if dev else "false"}\n')
        f.write('const DEV_LOG_SINK_PORT := 0\n')
    return proj


def clean(text: str) -> list:
    return [l for l in text.splitlines() if l.strip() and not l.startswith(NOISE)]


def syntax_check(proj: str) -> bool:
    ok = True
    for dirpath, _d, files in os.walk(os.path.join(proj, 'online_mod')):
        for fn in sorted(files):
            if not fn.endswith('.gd'):
                continue
            rel = os.path.relpath(os.path.join(dirpath, fn), proj).replace(os.sep, '/')
            r = subprocess.run([GODOT, '--no-window', '--path', proj, '--check-only', '-s', f'res://{rel}'],
                               capture_output=True, text=True, encoding='utf-8',
                               errors='replace', timeout=60)
            errs = [l for l in clean(r.stdout + r.stderr) if 'ERROR' in l or 'at:' in l]
            print(f"{'ERR' if errs else 'ok '} {rel}")
            for l in errs:
                print('     ' + l)
            ok = ok and not errs
    return ok


def run_pair(proj: str, seconds: int) -> bool:
    procs = []
    for i in range(2):
        procs.append(subprocess.Popen([GODOT, '--no-window', '--path', proj],
                                      stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                      text=True, encoding='utf-8', errors='replace'))
        time.sleep(1.0)
    time.sleep(seconds)
    ok = True
    for i, p in enumerate(procs):
        p.kill()
        out, _ = p.communicate()
        lines = clean(out)
        print(f'===== instancia {i + 1} =====')
        for l in lines:
            print(l)
        if any('ERROR' in l or l.startswith('Error') for l in lines):
            ok = False
    return ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--run', type=int, default=0, help='segundos de prueba con 2 instancias')
    args = ap.parse_args()
    if not os.path.exists(GODOT):
        sys.exit(f'Falta Godot 3.6.1 en {GODOT}')
    proj = make_project(dev=args.run > 0)
    try:
        ok = syntax_check(proj)
        if ok and args.run:
            ok = run_pair(proj, args.run)
    finally:
        shutil.rmtree(proj, ignore_errors=True)
    print('RESULTADO:', 'OK' if ok else 'ERRORES')
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
