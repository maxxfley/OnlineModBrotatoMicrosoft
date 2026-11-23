"""Construye el boot.hvp con el mod online a partir del boot.hvp ORIGINAL.

Pasos:
  1. Lee project.godot del .hvp original y le agrega el autoload OnlineMod al final
     de la sección [autoload] (único cambio a archivos del juego).
  2. Arma el overlay en build/overlay: project.godot parcheado + mod/online/** en
     res://online_mod/ + build_config.gd generado.
  3. Empaqueta → build/boot_mod.hvp (o --out).

Uso:
  python -I tools/build_mod.py [--dev] [--log-port 24600] [--src backup/boot.hvp.orig] [--out build/boot_mod.hvp]
  --dev: activa auto-conexión (1ª instancia hostea, 2ª se une a 127.0.0.1) y envío de
         logs por TCP a tools/log_sink.py.
"""
import argparse
import os
import shutil
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'tools'))

import hvp_extract  # noqa: E402
import hvp_pack  # noqa: E402

AUTOLOAD_LINE = 'OnlineMod="*res://online_mod/online_mod.gd"'


def read_file_from_hvp(data: bytes, wanted: str) -> bytes:
    for path, off, size, usize, typ in hvp_extract.parse(data):
        if path == wanted:
            blob = data[off:off + size]
            return blob if typ == 0 else hvp_extract.lzo1x_decompress(blob, usize)
    raise FileNotFoundError(wanted)


def patch_project_godot(src: bytes) -> bytes:
    nl = b'\r\n' if b'\r\n' in src else b'\n'
    lines = src.split(nl)
    if any(l.strip() == AUTOLOAD_LINE.encode() for l in lines):
        return src
    try:
        start = next(i for i, l in enumerate(lines) if l.strip() == b'[autoload]')
    except StopIteration:
        raise ValueError('project.godot no tiene sección [autoload]')
    end = len(lines)
    for i in range(start + 1, len(lines)):
        if lines[i].startswith(b'['):
            end = i
            break
    last = start
    for i in range(start + 1, end):
        if lines[i].strip():
            last = i
    lines.insert(last + 1, AUTOLOAD_LINE.encode())
    return nl.join(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dev', action='store_true')
    ap.add_argument('--log-port', type=int, default=24600)
    ap.add_argument('--src', default=os.path.join(ROOT, 'backup', 'boot.hvp.orig'))
    ap.add_argument('--out', default=os.path.join(ROOT, 'build', 'boot_mod.hvp'))
    args = ap.parse_args()

    version = open(os.path.join(ROOT, 'mod', 'VERSION'), encoding='utf-8').read().strip()
    data = open(args.src, 'rb').read()

    overlay = os.path.join(ROOT, 'build', 'overlay')
    shutil.rmtree(overlay, ignore_errors=True)
    os.makedirs(overlay)

    project = patch_project_godot(read_file_from_hvp(data, 'project.godot'))
    with open(os.path.join(overlay, 'project.godot'), 'wb') as f:
        f.write(project)

    mod_dst = os.path.join(overlay, 'online_mod')
    shutil.copytree(os.path.join(ROOT, 'mod', 'online'), mod_dst)
    with open(os.path.join(mod_dst, 'build_config.gd'), 'w', encoding='utf-8', newline='\n') as f:
        f.write('extends Reference\n# Generado por tools/build_mod.py — no editar.\n\n')
        f.write(f'const MOD_VERSION := "{version}"\n')
        f.write(f'const DEV_AUTOCONNECT := {"true" if args.dev else "false"}\n')
        f.write(f'const DEV_LOG_SINK_PORT := {args.log_port if args.dev else 0}\n')

    root, _count = hvp_pack.load_tree(data)
    changed = hvp_pack.apply_overlay(root, overlay)
    out, new_count = hvp_pack.serialize(root, data)
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, 'wb') as f:
        f.write(out)
    for kind, rel in changed:
        print(f'  {kind} {rel}')
    print(f'Mod v{version} ({"DEV" if args.dev else "release"}) -> {args.out} ({new_count} entradas)')


if __name__ == '__main__':
    main()
