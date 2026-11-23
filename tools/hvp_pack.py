"""Reempaquetador de .hvp: toma un .hvp original y le aplica un overlay de archivos.

- Los archivos del overlay reemplazan (o agregan) entradas en la misma ruta relativa.
- Las entradas no tocadas se copian tal cual (bloque comprimido + checksum original).
- Las entradas nuevas/reemplazadas se guardan sin comprimir (type 0), checksum = 0.
- El hash del header se recalcula (CRC32 de la tabla de índice).

Uso: python -I hvp_pack.py <original.hvp> <salida.hvp> <carpeta_overlay>
Ver docs/hvp_format.md.
"""
import os
import struct
import sys
import zlib

ALIGN = 16


class Node:
    def __init__(self, name, is_dir, rec=None):
        self.name = name
        self.is_dir = is_dir
        self.rec = rec          # registro original (None si es nuevo)
        self.children = []      # solo dirs
        self.content = None     # bytes nuevos (None = copiar original)


def sort_key(name):
    return name.upper()


def load_tree(data):
    count = struct.unpack_from('<I', data, 8)[0]
    names_len = struct.unpack_from('<I', data, 16)[0]
    names = data[20:20 + names_len]
    base = 20 + names_len
    recs = [struct.unpack_from('<7I', data, base + i * 28) for i in range(count)]

    def name(o):
        return names[o:names.find(bytes(1), o)].decode('utf-8')

    def build(idx, nm):
        r = recs[idx]
        node = Node(nm, r[1] == 4, r)
        if node.is_dir:
            for c in range(r[6], r[6] + r[5]):
                node.children.append(build(c, name(recs[c][4])))
        return node

    return build(0, ''), count


def apply_overlay(root, overlay_dir):
    changed = []
    for dirpath, _dirs, files in os.walk(overlay_dir):
        for fn in files:
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, overlay_dir).replace(os.sep, '/')
            parts = rel.split('/')
            node = root
            for part in parts[:-1]:
                nxt = next((c for c in node.children if c.name == part), None)
                if nxt is None:
                    nxt = Node(part, True)
                    node.children.append(nxt)
                    node.children.sort(key=lambda n: sort_key(n.name))
                elif not nxt.is_dir:
                    raise ValueError(f"{part} es archivo, no carpeta ({rel})")
                node = nxt
            leaf = next((c for c in node.children if c.name == parts[-1]), None)
            if leaf is None:
                leaf = Node(parts[-1], False)
                node.children.append(leaf)
                node.children.sort(key=lambda n: sort_key(n.name))
                changed.append(('+', rel))
            else:
                changed.append(('M', rel))
            with open(full, 'rb') as f:
                leaf.content = f.read()
    return changed


def serialize(root, orig_data):
    # Orden de registros como el original: se escribe el bloque de hijos de un
    # directorio y luego se recursa en cada subdirectorio (hijos siempre contiguos).
    order = [root]

    def add_blocks(n):
        order.extend(n.children)
        for c in n.children:
            if c.is_dir:
                add_blocks(c)

    add_blocks(root)
    index_of = {id(n): k for k, n in enumerate(order)}

    # Orden de los datos: archivos en DFS preorden
    data_order = []

    def add_files(n):
        for c in n.children:
            if c.is_dir:
                add_files(c)
            else:
                data_order.append(c)

    add_files(root)

    # Tabla de nombres (deduplicada, en orden DFS preorden como el original)
    names = bytearray()
    name_off = {}

    def add_names(n):
        for c in n.children:
            if c.name not in name_off:
                name_off[c.name] = len(names)
                names.extend(c.name.encode('utf-8') + bytes(1))
            if c.is_dir:
                add_names(c)

    add_names(root)
    names_len = len(names)

    header_tail = orig_data[0:16]  # version, reserved, count (se reescribe), hash
    table_start = 20 + names_len
    data_start = table_start + 28 * len(order)
    data_start = (data_start + ALIGN - 1) // ALIGN * ALIGN

    blobs = bytearray()
    file_info = {}
    for n in data_order:
        if n.content is not None:
            typ, chk, usize, blob = 0, 0, len(n.content), n.content
        else:
            r = n.rec
            typ, chk, usize = r[1], r[2], r[3]
            blob = orig_data[r[5]:r[5] + r[6]]
        blobs += bytes((-len(blobs)) % ALIGN)
        file_info[id(n)] = (typ, chk, usize, data_start + len(blobs), len(blob))
        blobs += blob

    recs = []
    for n in order:
        h = zlib.crc32(n.name.encode('utf-8')) if n is not root else 0
        noff = name_off.get(n.name, 0)
        if n.is_dir:
            first = index_of[id(n.children[0])] if n.children else 0
            recs.append((h, 4, 0, 0, noff, len(n.children), first))
        else:
            typ, chk, usize, off, size = file_info[id(n)]
            recs.append((h, typ, chk, usize, noff, off, size))

    index = b''.join(struct.pack('<7I', *r) for r in recs)
    out = bytearray()
    out += header_tail[0:8]
    out += struct.pack('<I', len(order))
    out += struct.pack('<I', zlib.crc32(index))  # hash del header = CRC32 del índice
    out += struct.pack('<I', names_len)
    out += names
    out += index
    out += bytes(data_start - len(out))
    out += blobs
    out += bytes((-len(out)) % ALIGN)
    return bytes(out), len(order)


def main():
    src, dst, overlay = sys.argv[1], sys.argv[2], sys.argv[3]
    data = open(src, 'rb').read()
    root, count = load_tree(data)
    changed = apply_overlay(root, overlay) if os.path.isdir(overlay) else []
    out, new_count = serialize(root, data)
    with open(dst, 'wb') as f:
        f.write(out)
    for kind, rel in changed:
        print(f"  {kind} {rel}")
    print(f"{count} -> {new_count} entradas, {len(data)} -> {len(out)} bytes")


if __name__ == '__main__':
    main()
