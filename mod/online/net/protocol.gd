extends Reference
# Protocolo de mensajes del mod. Cada mensaje es un Dictionary con la clave "t"
# (tipo) serializado con var2bytes (sin objetos: bytes2var no los permite).

const PROTOCOL_VERSION := 6
const DEFAULT_PORT := 24565
const MAX_CLIENTS := 3  # host + 3 = 4 jugadores (máximo del co-op)

# Canales ENet
const CH_CONTROL := 0   # confiable: handshake, lobby, estado
const CH_INPUT := 1     # no confiable: input de clientes, ping
const CH_SNAPSHOT := 2  # no confiable: snapshots del mundo
const CH_UI := 3        # confiable: espejo de interfaz (menús y HUD)

# Tipos de mensaje
const HELLO := "hello"        # cliente → host: {proto, mod, game, name}
const WELCOME := "welcome"    # host → cliente: {id, host_name}
const REJECT := "reject"      # host → cliente: {reason}
const PEERS := "peers"        # host → clientes: {list: [{id, name, ping}]}
const PING := "ping"          # {ts}
const PONG := "pong"          # {ts}
const INPUT_AXES := "in"      # cliente → host (no confiable): {s: seq, mv: Vector2, aim: Vector2}
const INPUT_UI := "ui"        # cliente → host (confiable): {a: acción base, p: bool presionado}

# Sincronización del mundo (host → clientes)
const WAVE_START := "wstart"  # confiable: mapa de la oleada {w, h, tiles, cells, outline, bg, tile_size}
const WAVE_END := "wend"      # confiable: la oleada terminó (menús)
const DEFS := "defs"          # confiable: definiciones de sprites {list: [[id, def], ...]}
const SNAP := "snap"          # no confiable: {s: seq, n: tamaño, b: PoolByteArray comprimido}
const SOUND := "snd"          # no confiable: {l: [[ruta, volumen_db, tono, posición o null], ...]}
const UI_MIRROR := "uim"      # confiable: {n: tamaño, b: payload comprimido} (ver ui_mirror_host.gd)

# Capas de dibujo del visor (mismo orden que la escena de oleada del juego)
const LAYERS := ["Materials", "Consumables", "Births", "Entities", "PlayerProjectiles", "EnemyProjectiles", "Effects", "Explosions"]
const LAYER_YSORT := 3

# Cuantización de snapshots
const ROT_SCALE := 10000.0   # radianes * ROT_SCALE → int16
const SCALE_SCALE := 1000.0  # escala * SCALE_SCALE → int16
const FLAG_FLIP_H := 1
const FLAG_FLIP_V := 2
const FLAG_MODULATE := 4

# Acciones de UI que el cliente reenvía (nombres base, sin sufijo de dispositivo)
const UI_ACTIONS := [
	"ui_accept", "ui_select", "ui_cancel", "ui_info", "ui_pause", "ui_ban",
	"ui_left", "ui_right", "ui_up", "ui_down", "ltrigger", "rtrigger",
]
const UI_REPEAT_ACTIONS := ["ui_left", "ui_right", "ui_up", "ui_down"]


static func encode(msg: Dictionary) -> PoolByteArray:
	return var2bytes(msg)


static func decode(data: PoolByteArray):
	var value = bytes2var(data)
	if typeof(value) != TYPE_DICTIONARY or not value.has("t"):
		return null
	return value
