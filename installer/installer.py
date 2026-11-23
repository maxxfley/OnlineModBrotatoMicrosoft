"""Instalador de Brotato Online (versión Microsoft Store / Xbox / Game Pass).

No distribuye archivos del juego: toma el boot.hvp que el usuario ya tiene, guarda una
copia del original y escribe uno nuevo con el código del mod agregado (más una línea
de autoload en project.godot). "Desinstalar" vuelve a poner el original.

Empaquetado: ver installer/build_installer.py (PyInstaller, un único .exe).
"""
import hashlib
import json
import os
import string
import subprocess
import sys
import threading
import tkinter as tk
from tkinter import filedialog, messagebox

if getattr(sys, 'frozen', False):
    BUNDLE = sys._MEIPASS  # carpeta temporal donde PyInstaller descomprime los datos
else:
    BUNDLE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    sys.path.insert(0, os.path.join(BUNDLE, 'tools'))

import mod_overlay  # noqa: E402

if getattr(sys, 'frozen', False):
    MOD_SRC = os.path.join(BUNDLE, 'online_mod_src')
    VERSION_FILE = os.path.join(BUNDLE, 'VERSION')
else:
    MOD_SRC = os.path.join(BUNDLE, 'mod', 'online')
    VERSION_FILE = os.path.join(BUNDLE, 'mod', 'VERSION')

MOD_VERSION = open(VERSION_FILE, encoding='utf-8').read().strip()
STATE_DIR = os.path.join(os.environ.get('LOCALAPPDATA', os.path.expanduser('~')), 'BrotatoOnlineMod')
BACKUP = os.path.join(STATE_DIR, 'boot.hvp.orig')
STATE_FILE = os.path.join(STATE_DIR, 'estado.json')
GAME_REL = os.path.join('XboxGames', 'Brotato', 'Content')


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def find_game_dirs():
    found = []
    for letter in string.ascii_uppercase:
        d = f'{letter}:\\{GAME_REL}'
        if os.path.isfile(os.path.join(d, 'boot.hvp')):
            found.append(d)
    return found


def game_running() -> bool:
    try:
        out = subprocess.run(['tasklist', '/FI', 'IMAGENAME eq Brotato.exe', '/NH'],
                             capture_output=True, text=True, creationflags=0x08000000).stdout
        return 'brotato.exe' in out.lower()
    except OSError:
        return False


def load_state() -> dict:
    try:
        with open(STATE_FILE, encoding='utf-8') as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_state(state: dict):
    os.makedirs(STATE_DIR, exist_ok=True)
    with open(STATE_FILE, 'w', encoding='utf-8') as f:
        json.dump(state, f, indent=2)


def write_atomic(path: str, data: bytes):
    tmp = path + '.online_tmp'
    with open(tmp, 'wb') as f:
        f.write(data)
    os.replace(tmp, path)


def status_of(game_dir: str) -> str:
    try:
        data = open(os.path.join(game_dir, 'boot.hvp'), 'rb').read()
        if mod_overlay.is_modded(data):
            v = load_state().get('mod_version', '?')
            return f'Mod instalado (v{v})'
        return 'Juego original (sin el mod)'
    except Exception as e:  # noqa: BLE001
        return f'No se pudo leer boot.hvp: {e}'


def install(game_dir: str, log):
    target = os.path.join(game_dir, 'boot.hvp')
    current = open(target, 'rb').read()
    if mod_overlay.is_modded(current):
        if not os.path.isfile(BACKUP):
            raise RuntimeError('El juego ya tiene una versión del mod y no encuentro la copia del original.\n'
                               'Reparalo desde la app Xbox (Brotato → Administrar → Archivos → '
                               'Verificar y reparar) y volvé a instalar.')
        orig = open(BACKUP, 'rb').read()
        if mod_overlay.is_modded(orig):
            raise RuntimeError('La copia guardada del original no es válida. Repará el juego desde la app Xbox.')
        log('El mod ya estaba instalado: se actualiza usando la copia del original.')
    else:
        # boot.hvp original (o uno nuevo tras una actualización del juego): se guarda la copia.
        orig = current
        os.makedirs(STATE_DIR, exist_ok=True)
        write_atomic(BACKUP, orig)
        log(f'Copia del original guardada en {BACKUP}')
    log('Generando el boot.hvp con el mod (puede tardar unos segundos)...')
    out, count, _changed = mod_overlay.build_patched_hvp(orig, MOD_SRC, MOD_VERSION)
    write_atomic(target, out)
    check = open(target, 'rb').read()
    if not mod_overlay.is_modded(check) or sha256(check) != sha256(out):
        raise RuntimeError('La verificación del archivo escrito falló.')
    save_state({'game_dir': game_dir, 'mod_version': MOD_VERSION,
                'orig_sha256': sha256(orig), 'mod_sha256': sha256(out)})
    log(f'Listo: Brotato Online v{MOD_VERSION} instalado ({count} archivos en el paquete).')


def uninstall(game_dir: str, log):
    target = os.path.join(game_dir, 'boot.hvp')
    current = open(target, 'rb').read()
    if not mod_overlay.is_modded(current):
        log('El juego ya está en su versión original. No hay nada que desinstalar.')
        return
    if not os.path.isfile(BACKUP):
        raise RuntimeError('No encuentro la copia del original. Repará el juego desde la app Xbox '
                           '(Brotato → Administrar → Archivos → Verificar y reparar).')
    orig = open(BACKUP, 'rb').read()
    if mod_overlay.is_modded(orig):
        raise RuntimeError('La copia guardada no es válida. Repará el juego desde la app Xbox.')
    write_atomic(target, orig)
    log('Listo: se restauró el boot.hvp original. El mod quedó desinstalado.')


class App:
    def __init__(self, root: tk.Tk):
        self.root = root
        root.title(f'Brotato Online v{MOD_VERSION} — Instalador')
        root.resizable(False, False)
        pad = {'padx': 10, 'pady': 4}

        tk.Label(root, text=f'Brotato Online v{MOD_VERSION}', font=('Segoe UI', 14, 'bold')).pack(**pad)
        tk.Label(root, text='Multijugador online para Brotato (Microsoft Store / Xbox / Game Pass)',
                 font=('Segoe UI', 9)).pack(padx=10)

        frm = tk.Frame(root)
        frm.pack(fill='x', **pad)
        tk.Label(frm, text='Carpeta del juego:').pack(side='left')
        self.dir_var = tk.StringVar()
        tk.Entry(frm, textvariable=self.dir_var, width=48).pack(side='left', padx=4)
        tk.Button(frm, text='Buscar...', command=self.browse).pack(side='left')

        self.status_var = tk.StringVar()
        tk.Label(root, textvariable=self.status_var, font=('Segoe UI', 10, 'bold')).pack(**pad)

        btns = tk.Frame(root)
        btns.pack(**pad)
        self.install_btn = tk.Button(btns, text='Instalar / Actualizar', width=22, command=self.on_install)
        self.install_btn.pack(side='left', padx=6)
        self.uninstall_btn = tk.Button(btns, text='Desinstalar', width=16, command=self.on_uninstall)
        self.uninstall_btn.pack(side='left', padx=6)

        self.log_box = tk.Text(root, width=80, height=10, state='disabled', font=('Consolas', 9))
        self.log_box.pack(**pad)
        tk.Label(root, justify='left', font=('Segoe UI', 9), text=(
            'Cómo jugar: abrí Brotato y presioná F9. Uno toca "Hostear" y le pasa su IP al resto;\n'
            'los demás escriben esa IP y tocan "Unirse". Todos deben tener la misma versión del mod.\n'
            'Por internet: usen una VPN como Radmin VPN / ZeroTier / Tailscale (o abran el puerto\n'
            'UDP 24565 en el router del host). Si Windows pregunta por el firewall, permitilo.'
        )).pack(padx=10, pady=(0, 10))

        dirs = find_game_dirs()
        saved = load_state().get('game_dir')
        self.dir_var.set(saved if saved and os.path.isdir(saved) else (dirs[0] if dirs else ''))
        if not self.dir_var.get():
            self.log('No encontré Brotato en X:\\XboxGames\\Brotato\\Content. Elegí la carpeta con "Buscar...".')
        self.dir_var.trace_add('write', lambda *_: self.refresh())
        self.refresh()

    def log(self, text: str):
        def do():
            self.log_box.configure(state='normal')
            self.log_box.insert('end', text + '\n')
            self.log_box.see('end')
            self.log_box.configure(state='disabled')
        self.root.after(0, do)

    def browse(self):
        d = filedialog.askdirectory(title='Carpeta de Brotato (la que contiene boot.hvp)')
        if d:
            self.dir_var.set(os.path.normpath(d))

    def game_dir(self):
        d = self.dir_var.get().strip()
        if not os.path.isfile(os.path.join(d, 'boot.hvp')):
            messagebox.showerror('Carpeta inválida', 'En esa carpeta no está boot.hvp.\n'
                                 'Suele ser C:\\XboxGames\\Brotato\\Content.')
            return None
        return d

    def refresh(self):
        d = self.dir_var.get().strip()
        if os.path.isfile(os.path.join(d, 'boot.hvp')):
            self.status_var.set('Estado: ' + status_of(d))
        else:
            self.status_var.set('Estado: carpeta del juego no encontrada')

    def run(self, fn):
        d = self.game_dir()
        if not d:
            return
        if game_running():
            messagebox.showwarning('Brotato abierto', 'Cerrá Brotato antes de continuar.')
            return
        self.install_btn.configure(state='disabled')
        self.uninstall_btn.configure(state='disabled')

        def work():
            try:
                fn(d, self.log)
            except PermissionError:
                self.log('ERROR: Windows no dejó escribir en la carpeta del juego. '
                         'Probá ejecutar el instalador como administrador.')
            except Exception as e:  # noqa: BLE001
                self.log(f'ERROR: {e}')
            finally:
                self.root.after(0, self.done)
        threading.Thread(target=work, daemon=True).start()

    def done(self):
        self.install_btn.configure(state='normal')
        self.uninstall_btn.configure(state='normal')
        self.refresh()

    def on_install(self):
        self.run(install)

    def on_uninstall(self):
        self.run(uninstall)


def main():
    root = tk.Tk()
    App(root)
    root.mainloop()


if __name__ == '__main__':
    main()
