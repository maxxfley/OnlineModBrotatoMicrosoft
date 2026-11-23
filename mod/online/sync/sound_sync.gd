extends Node
# Sonido en el cliente.
# Host: el juego reproduce los efectos con dos gestores (SoundManager y
# SoundManager2D) que reutilizan un grupo de AudioStreamPlayer. Se revisan esos
# reproductores cada cuadro y, cuando uno empieza a sonar, se envía qué sonido es.
# Cliente: reproduce el mismo sonido con los gestores de su propio juego (respeta
# su volumen y configuración; los sonidos 2D se ubican según la cámara del visor).

const Protocol = preload("res://online_mod/net/protocol.gd")

const MANAGERS := ["/root/SoundManager", "/root/SoundManager2D"]
const MAX_PER_PACKET := 24

var session = null
var logger = null

var _state := {}     # host: reproductor instance_id → [sonando, stream id, posición de reproducción]
var _streams := {}   # cliente: ruta → AudioStream (o null)
var _sent := 0
var _played := 0
var _stats_timer := 0.0


func _ready() -> void:
	pause_mode = Node.PAUSE_MODE_PROCESS


func _process(delta: float) -> void:
	_stats_timer += delta
	if _stats_timer >= 30.0:
		if _sent > 0 or _played > 0:
			_log("Sonidos en 30 s: %d enviados, %d reproducidos" % [_sent, _played])
		_stats_timer = 0.0
		_sent = 0
		_played = 0
	if session == null or not session.is_host() or session.ready_peer_count() == 0:
		return
	var events := []
	for mi in MANAGERS.size():
		var manager = get_node_or_null(MANAGERS[mi])
		if manager == null:
			continue
		for p in manager.get_children():
			if p is AudioStreamPlayer or p is AudioStreamPlayer2D:
				_check_player(p, mi == 1, events)
	if not events.empty():
		_sent += events.size()
		session.broadcast(Protocol.CH_SNAPSHOT, false, {"t": Protocol.SOUND, "l": events})


func _check_player(p, positional: bool, events: Array) -> void:
	var key: int = p.get_instance_id()
	var playing: bool = p.playing
	var stream_id: int = p.stream.get_instance_id() if p.stream else 0
	var pos: float = p.get_playback_position() if playing else 0.0
	var prev = _state.get(key)
	_state[key] = [playing, stream_id, pos]
	if not playing or p.stream == null:
		return
	var started: bool = prev == null or not prev[0] or prev[1] != stream_id or pos + 0.05 < prev[2]
	if not started or events.size() >= MAX_PER_PACKET:
		return
	var path: String = p.stream.resource_path
	if path == "" or path.find("::") != -1:
		return
	events.append([path, p.volume_db, p.pitch_scale, p.global_position if positional else null])


# --- cliente ---

func on_sync(msg: Dictionary) -> void:
	if msg.t != Protocol.SOUND:
		return
	var sm = get_node_or_null(MANAGERS[0])
	var sm2d = get_node_or_null(MANAGERS[1])
	for e in msg.l:
		var path: String = e[0]
		if not _streams.has(path):
			_streams[path] = load(path) if ResourceLoader.exists(path) else null
		var stream = _streams[path]
		if stream == null:
			continue
		# El gestor del juego sortea el tono en ±pitch_rand: se usa la desviación del host.
		var pitch_rand: float = abs(float(e[2]) - 1.0)
		if e[3] != null and sm2d:
			sm2d.play(stream, e[3], float(e[1]), pitch_rand, false)
		elif sm:
			sm.play(stream, float(e[1]), pitch_rand, false)
		_played += 1


func _log(text: String) -> void:
	if logger:
		logger.info("[sonido] " + text)
