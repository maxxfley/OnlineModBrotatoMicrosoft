"""Receptor de logs para builds de desarrollo del mod.

Las instancias del juego (build --dev) se conectan por TCP y envían una línea por log.
Se imprime todo por stdout y se guarda en build/logs/session.log.

Uso: python -I tools/log_sink.py [--port 24600]
"""
import argparse
import os
import socket
import threading

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
lock = threading.Lock()


def handle(conn, addr, out):
    buf = b''
    with conn:
        while True:
            try:
                chunk = conn.recv(4096)
            except OSError:
                break
            if not chunk:
                break
            buf += chunk
            while b'\n' in buf:
                line, buf = buf.split(b'\n', 1)
                text = line.decode('utf-8', 'replace')
                with lock:
                    print(text, flush=True)
                    out.write(text + '\n')
                    out.flush()
    with lock:
        print(f'[sink] conexión cerrada {addr}', flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--port', type=int, default=24600)
    args = ap.parse_args()
    os.makedirs(os.path.join(ROOT, 'build', 'logs'), exist_ok=True)
    out = open(os.path.join(ROOT, 'build', 'logs', 'session.log'), 'a', encoding='utf-8')
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(('127.0.0.1', args.port))
    srv.listen()
    print(f'[sink] escuchando en 127.0.0.1:{args.port}', flush=True)
    while True:
        conn, addr = srv.accept()
        print(f'[sink] conexión {addr}', flush=True)
        threading.Thread(target=handle, args=(conn, addr, out), daemon=True).start()


if __name__ == '__main__':
    main()
