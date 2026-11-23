"""Lógica compartida para generar un boot.hvp con el mod online.

La usan tools/build_mod.py (desarrollo) y el instalador (installer/installer.py),
así ambos producen exactamente el mismo resultado a partir del boot.hvp original.

Único cambio a archivos del juego: una línea de autoload en project.godot. El resto
es el código propio del mod, agregado en res://online_mod/.
"""
import os
import shutil
import tempfile

import hvp_extract
import hvp_pack

AUTOLOAD_LINE = 'OnlineMod="*res://online_mod/online_mod.gd"'


def read_file_from_hvp(data: bytes, wanted: str) -> bytes:
    for path, off, size, usize, typ in hvp_extract.parse(data):
        if path == wanted:
            blob = data[off:off + size]
            return blob if typ == 0 else hvp_extract.lzo1x_decompress(blob, usize)
    raise FileNotFoundError(wanted)


def is_modded(data: bytes) -> bool:
    """True si el boot.hvp ya tiene el autoload del mod."""
    project = read_file_from_hvp(data, 'project.godot')
    return any(l.strip() == AUTOLOAD_LINE.encode() for l in project.splitlines())


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


def build_patched_hvp(orig: bytes, mod_src_dir: str, version: str,
                      dev: bool = False, log_port: int = 0, overlay_dir: str = None):
    """Devuelve (bytes del boot.hvp con el mod, cantidad de entradas, cambios).

    orig: boot.hvp ORIGINAL (sin el mod).
    mod_src_dir: carpeta con el código del mod (mod/online).
    overlay_dir: si se indica, el overlay se arma ahí (y queda para inspección);
                 si no, en una carpeta temporal que se borra al terminar.
    """
    if is_modded(orig):
        raise ValueError('El boot.hvp de origen ya tiene el mod: hace falta el original.')
    tmp = None
    if overlay_dir is None:
        tmp = tempfile.mkdtemp(prefix='brotato_online_')
        overlay_dir = tmp
    else:
        shutil.rmtree(overlay_dir, ignore_errors=True)
        os.makedirs(overlay_dir)
    try:
        project = patch_project_godot(read_file_from_hvp(orig, 'project.godot'))
        with open(os.path.join(overlay_dir, 'project.godot'), 'wb') as f:
            f.write(project)
        mod_dst = os.path.join(overlay_dir, 'online_mod')
        shutil.copytree(mod_src_dir, mod_dst)
        with open(os.path.join(mod_dst, 'build_config.gd'), 'w', encoding='utf-8', newline='\n') as f:
            f.write('extends Reference\n# Generado al construir el mod — no editar.\n\n')
            f.write(f'const MOD_VERSION := "{version}"\n')
            f.write(f'const DEV_AUTOCONNECT := {"true" if dev else "false"}\n')
            f.write(f'const DEV_LOG_SINK_PORT := {log_port if dev else 0}\n')
        root, _count = hvp_pack.load_tree(orig)
        changed = hvp_pack.apply_overlay(root, overlay_dir)
        out, new_count = hvp_pack.serialize(root, orig)
        return out, new_count, changed
    finally:
        if tmp:
            shutil.rmtree(tmp, ignore_errors=True)
