"""Extractor del formato .hvp (paquete del port Microsoft Store de Brotato).

Formato (deducido por ingeniería inversa, ver docs/hvp_format.md):
  Header (20 bytes): u32 version(0x00060000), u32 0, u32 entry_count, u32 hash?, u32 names_len
  Tabla de nombres: names_len bytes, strings terminados en \0
  entry_count registros de 28 bytes (7 x u32 LE):
    dir : name_crc32, type=4, 0, 0, name_off, child_count, first_child_index
    file: name_crc32, type, content_checksum(?), uncompressed_size, name_off, data_offset, stored_size
          type 1 = LZO1X, type 0 = sin comprimir
  El registro 0 es la raíz (nombre vacío, crc32 = 0).

Uso: python -I hvp_extract.py <archivo.hvp> <carpeta_salida> [--list]
"""
import os
import struct
import sys


def lzo1x_decompress(src: bytes, out_size: int) -> bytes:
    """Descompresor LZO1X (port de la lógica de minilzo)."""
    out = bytearray()
    ip = 0

    def copy_match(dist, length):
        ref = len(out) - dist
        if ref < 0:
            raise ValueError("distancia inválida")
        for _ in range(length):
            out.append(out[ref]); ref += 1

    def read_len(base):
        nonlocal ip
        t = 0
        while src[ip] == 0:
            t += 255; ip += 1
        t += base + src[ip]; ip += 1
        return t

    state = 0  # literales copiados en la última instrucción (0, 1-3, 4+)
    t = src[ip]
    if t > 17:
        ip += 1
        n = t - 17
        out += src[ip:ip + n]; ip += n
        state = 4 if n >= 4 else n
    while True:
        t = src[ip]; ip += 1
        if t < 16:
            if state == 0:
                n = (read_len(15) if t == 0 else t) + 3
                out += src[ip:ip + n]; ip += n
                state = 4
                continue
            elif state < 4:
                dist = 1 + (t >> 2) + (src[ip] << 2); ip += 1
                copy_match(dist, 2)
            else:
                dist = 1 + 0x800 + (t >> 2) + (src[ip] << 2); ip += 1
                copy_match(dist, 3)
        elif t >= 64:
            length = (t >> 5) - 1 + 2
            dist = 1 + ((t >> 2) & 7) + (src[ip] << 3); ip += 1
            copy_match(dist, length)
        elif t >= 32:
            length = (read_len(31) if (t & 31) == 0 else (t & 31)) + 2
            d = src[ip] | (src[ip + 1] << 8); ip += 2
            copy_match(1 + (d >> 2), length)
            t = d
        else:  # 16..31
            length = (read_len(7) if (t & 7) == 0 else (t & 7)) + 2
            d = src[ip] | (src[ip + 1] << 8); ip += 2
            dist = ((t & 8) << 11) + (d >> 2)
            if dist == 0:
                break  # fin de stream
            copy_match(dist + 0x4000, length)
            t = d
        n = t & 3
        out += src[ip:ip + n]; ip += n
        state = n
    if len(out) != out_size:
        raise ValueError(f"tamaño inesperado {len(out)} != {out_size}")
    return bytes(out)


def parse(data: bytes):
    count = struct.unpack_from('<I', data, 8)[0]
    names_len = struct.unpack_from('<I', data, 16)[0]
    names = data[20:20 + names_len]
    base = 20 + names_len
    recs = [struct.unpack_from('<7I', data, base + i * 28) for i in range(count)]

    def name(o):
        return names[o:names.find(b'\0', o)].decode('utf-8')

    files = []

    def walk(idx, path):
        _h, typ, _chk, usize, _noff, a, b = recs[idx]
        if typ == 4:
            for c in range(b, b + a):
                child = name(recs[c][4])
                walk(c, f"{path}/{child}" if path else child)
        elif typ in (0, 1):  # 0 = sin comprimir, 1 = LZO1X
            files.append((path, a, b, usize, typ))
        else:
            raise ValueError(f"tipo desconocido {typ} en {idx}")

    walk(0, '')
    return files


def main():
    src, dst = sys.argv[1], sys.argv[2]
    list_only = '--list' in sys.argv
    data = open(src, 'rb').read()
    files = parse(data)
    errors = 0
    for path, off, csize, usize, typ in files:
        if list_only:
            print(f"{usize:>10} {path}")
            continue
        blob = data[off:off + csize]
        try:
            content = blob if typ == 0 else lzo1x_decompress(blob, usize)
        except Exception as e:  # noqa: BLE001
            errors += 1
            print(f"ERROR {path}: {e}")
            continue
        out = os.path.join(dst, *path.split('/'))
        os.makedirs(os.path.dirname(out), exist_ok=True)
        with open(out, 'wb') as f:
            f.write(content)
    print(f"{len(files)} archivos, {errors} errores")


if __name__ == '__main__':
    main()
