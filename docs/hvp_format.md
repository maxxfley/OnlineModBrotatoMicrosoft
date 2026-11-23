# Formato `.hvp` (paquete del port Microsoft Store de Brotato)

El port de Microsoft Store/Game Pass lo hizo **Seaven Studio** sobre un fork
propio de Godot 3.x (motor "Seaven", `OS.get_name()` empieza con `"Seaven"`, expone
el singleton `OS_Seaven`). En lugar de un `.pck`, el juego trae dos paquetes:

| Archivo | Contenido |
|---|---|
| `boot.hvp` (~2.5 MB) | Scripts `.gd` **como código fuente** (no bytecode), `project.godot`, addons (incluye Mod Loader 6.3.0) |
| `data.hvp` (~383 MB) | Escenas `.tscn`, recursos `.tres`, texturas `.stex`, audio, traducciones, `.import` |

Extractor: `tools/hvp_extract.py`.

## Layout (little-endian)

```
Header (20 bytes)
  u32 version        = 0x00060000
  u32 reserved       = 0
  u32 entry_count
  u32 index_crc32    CRC32 (zlib) de la tabla de registros completa. El motor lo valida:
                     si no coincide, no carga el paquete ("Couldn't load project data").
  u32 names_len

Tabla de nombres (names_len bytes)
  strings UTF-8 terminados en \0 (solo el nombre del nodo, no la ruta)

Registros (entry_count x 28 bytes, 7 x u32)
  [0] name_crc32       CRC32 estándar (zlib) del nombre del nodo
  [1] type             4 = directorio, 1 = archivo LZO1X, 0 = archivo sin comprimir
  directorio:
    [2] 0  [3] 0  [4] name_off  [5] child_count  [6] first_child_index
  archivo:
    [2] content_checksum (sin identificar: no es CRC32/CRC32C/Adler32/Murmur3/MD5/SHA trunc.)
    [3] uncompressed_size
    [4] name_off
    [5] data_offset      (absoluto en el archivo)
    [6] stored_size

Datos
  Bloques LZO1X (o crudos si type = 0) en las posiciones indicadas.
```

- El registro 0 es la raíz (nombre vacío, crc32 = 0).
- Los hijos de un directorio son contiguos: `first_child_index .. +child_count`.

## Pendiente
- Identificar `content_checksum` (probado sin éxito: CRC32/CRC32C/bzip/mpeg, Adler32, FNV,
  djb2, sdbm, OAAT, xxHash32/64, Murmur3, MD5/SHA trunc., sobre contenido, LF, ruta y
  combinaciones). Falta saber si el motor lo valida.
