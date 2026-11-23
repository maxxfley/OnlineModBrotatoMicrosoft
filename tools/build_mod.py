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
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'tools'))

import mod_overlay  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dev', action='store_true')
    ap.add_argument('--log-port', type=int, default=24600)
    ap.add_argument('--src', default=os.path.join(ROOT, 'backup', 'boot.hvp.orig'))
    ap.add_argument('--out', default=os.path.join(ROOT, 'build', 'boot_mod.hvp'))
    args = ap.parse_args()

    version = open(os.path.join(ROOT, 'mod', 'VERSION'), encoding='utf-8').read().strip()
    data = open(args.src, 'rb').read()
    out, new_count, changed = mod_overlay.build_patched_hvp(
        data, os.path.join(ROOT, 'mod', 'online'), version, args.dev, args.log_port,
        overlay_dir=os.path.join(ROOT, 'build', 'overlay'))
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, 'wb') as f:
        f.write(out)
    for kind, rel in changed:
        print(f'  {kind} {rel}')
    print(f'Mod v{version} ({"DEV" if args.dev else "release"}) -> {args.out} ({new_count} entradas)')


if __name__ == '__main__':
    main()
