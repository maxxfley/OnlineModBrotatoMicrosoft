"""Genera el instalador distribuible: dist/BrotatoOnline-Instalador-v<versión>.exe

Empaqueta installer/installer.py + tools/{mod_overlay,hvp_extract,hvp_pack}.py + el
código del mod (mod/online) + mod/VERSION en un único .exe con PyInstaller.
No incluye ningún archivo del juego.

Uso: python -I installer/build_installer.py
Requiere: pip install pyinstaller
"""
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def main():
    version = open(os.path.join(ROOT, 'mod', 'VERSION'), encoding='utf-8').read().strip()
    name = f'BrotatoOnline-Instalador-v{version}'
    work = os.path.join(ROOT, 'build', 'pyinstaller')
    shutil.rmtree(work, ignore_errors=True)
    sep = os.pathsep  # ';' en Windows
    cmd = [
        sys.executable, '-m', 'PyInstaller', '--noconfirm', '--onefile', '--windowed',
        '--name', name,
        '--distpath', os.path.join(ROOT, 'dist'),
        '--workpath', work,
        '--specpath', work,
        '--paths', os.path.join(ROOT, 'tools'),
        '--add-data', f'{os.path.join(ROOT, "mod", "online")}{sep}online_mod_src',
        '--add-data', f'{os.path.join(ROOT, "mod", "VERSION")}{sep}.',
        os.path.join(ROOT, 'installer', 'installer.py'),
    ]
    subprocess.run(cmd, check=True)
    print(f'Instalador: {os.path.join(ROOT, "dist", name + ".exe")}')


if __name__ == '__main__':
    main()
