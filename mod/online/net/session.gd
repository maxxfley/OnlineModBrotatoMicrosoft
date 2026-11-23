extends Node
# Sesión online: lógica de host/cliente sobre el transporte.
# Fase 1: handshake con verificación de versiones, lista de jugadores y ping.

signal state_changed(state)
signal peers_changed(peers)
signal message(text)
signal peer_joined(peer_id, peer_name)  # host: cliente aceptado
signal peer_left(peer_id)               # host: cliente desconectado
signal input_received(peer_id, msg)     # host: input de un cliente
signal sync_received(msg)                # cliente: mensaje de sincronización del host

const Protocol = preload("res://online_mod/net/protocol.gd")
const Transport = preload("res://online_mod/net/enet_transport.gd")

enum State { OFFLINE, HOSTING, CONNECTING, HANDSHAKE, CONNECTED }

const PING_INTERVAL := 1.0
const HANDSHAKE_TIMEOUT := 5.0
const PING_LOG_EVERY := 5  # loguear pings cada N intervalos

var state: int = State.OFFLINE
var mod_version := ""
var local_name := "Player"
var logger = null
# peers[id] = {name, ping, ready(bool), since}
var peers := {}
var host_name := ""
var my_id := 0
var ping_ms := -1

var _transport: Node
var _ping_timer := 0.0
var _ping_count := 0


func _ready() -> void:
	_transport = Transport.new()
	_transport.name = "Transport"
	add_child(_transport)
	_transport.connect("peer_connected", self, "_on_peer_connected")
	_transport.connect("peer_disconnected", self, "_on_peer_disconnected")
	_transport.connect("connected_to_server", self, "_on_connected_to_server")
	_transport.connect("connection_failed", self, "_on_connection_failed")
	_transport.connect("server_disconnected", self, "_on_server_disconnected")
	_transport.connect("packet_received", self, "_on_packet")


func is_host() -> bool:
	return state == State.HOSTING


func is_client() -> bool:
	return state in [State.CONNECTING, State.HANDSHAKE, State.CONNECTED]


func host(port: int) -> int:
	var err: int = _transport.host(port, Protocol.MAX_CLIENTS)
	if err != OK:
		_say("No se pudo hostear en el puerto %d (error %d)" % [port, err])
		return err
	peers.clear()
	my_id = 1
	host_name = local_name
	_set_state(State.HOSTING)
	_say("Hosteando en el puerto %d" % port)
	return OK


func join(address: String, port: int) -> int:
	var err: int = _transport.join(address, port)
	if err != OK:
		_say("No se pudo conectar a %s:%d (error %d)" % [address, port, err])
		return err
	peers.clear()
	_set_state(State.CONNECTING)
	_say("Conectando a %s:%d..." % [address, port])
	return OK


func leave() -> void:
	if state == State.OFFLINE:
		return
	if state == State.HOSTING:
		for id in peers:
			if peers[id].ready:
				emit_signal("peer_left", id)
	_transport.close()
	peers.clear()
	ping_ms = -1
	my_id = 0
	_set_state(State.OFFLINE)
	emit_signal("peers_changed", peers)
	_say("Desconectado")


func _process(delta: float) -> void:
	if state == State.OFFLINE:
		return
	_ping_timer -= delta
	if _ping_timer <= 0.0:
		_ping_timer = PING_INTERVAL
		_send_pings()
	if state == State.HOSTING:
		_check_handshake_timeouts()


# --- host ---

func _on_peer_connected(id: int) -> void:
	if state != State.HOSTING:
		return
	peers[id] = {"name": "?", "ping": -1, "ready": false, "since": OS.get_ticks_msec()}
	_log("Peer %d conectado desde %s, esperando hello" % [id, _transport.get_peer_address(id)])


func _on_peer_disconnected(id: int) -> void:
	if state != State.HOSTING or not peers.has(id):
		return
	var was_ready: bool = peers[id].ready
	var peer_name: String = peers[id].name
	peers.erase(id)
	if was_ready:
		_say("%s se desconectó" % peer_name)
		emit_signal("peer_left", id)
		_broadcast_peers()


func _check_handshake_timeouts() -> void:
	var now := OS.get_ticks_msec()
	for id in peers.keys():
		var p = peers[id]
		if not p.ready and now - p.since > HANDSHAKE_TIMEOUT * 1000:
			_log("Peer %d sin hello a tiempo, expulsado" % id)
			peers.erase(id)
			_transport.kick(id)


func _handle_hello(id: int, msg: Dictionary) -> void:
	if not peers.has(id):
		return
	var reason := ""
	if int(msg.get("proto", -1)) != Protocol.PROTOCOL_VERSION:
		reason = "Versión de protocolo distinta (host %d, cliente %s)" % [Protocol.PROTOCOL_VERSION, str(msg.get("proto"))]
	elif str(msg.get("mod", "")) != mod_version:
		reason = "Versión del mod distinta (host %s, cliente %s)" % [mod_version, str(msg.get("mod"))]
	elif str(msg.get("game", "")) != _game_version():
		reason = "Versión del juego distinta (host %s, cliente %s)" % [_game_version(), str(msg.get("game"))]
	if reason != "":
		_log("Rechazando peer %d: %s" % [id, reason])
		_send(id, Protocol.CH_CONTROL, true, {"t": Protocol.REJECT, "reason": reason})
		peers.erase(id)
		# dar tiempo a que salga el REJECT antes de cortar
		get_tree().create_timer(0.5).connect("timeout", _transport, "kick", [id])
		return
	peers[id].name = str(msg.get("name", "Player"))
	peers[id].ready = true
	_send(id, Protocol.CH_CONTROL, true, {"t": Protocol.WELCOME, "id": id, "host_name": local_name})
	_say("%s se unió" % peers[id].name)
	emit_signal("peer_joined", id, peers[id].name)
	_broadcast_peers()


func _broadcast_peers() -> void:
	var list := []
	for id in peers:
		if peers[id].ready:
			list.append({"id": id, "name": peers[id].name, "ping": peers[id].ping})
	_send(Transport.TARGET_BROADCAST, Protocol.CH_CONTROL, true, {"t": Protocol.PEERS, "list": list, "host_name": local_name})
	emit_signal("peers_changed", peers)


# --- cliente ---

func _on_connected_to_server() -> void:
	my_id = _transport.get_unique_id()
	_set_state(State.HANDSHAKE)
	_log("Conectado (id %d), enviando hello" % my_id)
	_send(Transport.TARGET_SERVER, Protocol.CH_CONTROL, true, {
		"t": Protocol.HELLO,
		"proto": Protocol.PROTOCOL_VERSION,
		"mod": mod_version,
		"game": _game_version(),
		"name": local_name,
	})


func _on_connection_failed() -> void:
	_say("No se pudo conectar al host")
	leave()


func _on_server_disconnected() -> void:
	_say("El host cerró la conexión")
	leave()


func _handle_welcome(msg: Dictionary) -> void:
	host_name = str(msg.get("host_name", "Host"))
	_set_state(State.CONNECTED)
	_say("Conectado a la partida de %s" % host_name)


func _handle_reject(msg: Dictionary) -> void:
	_say("Rechazado por el host: %s" % str(msg.get("reason", "?")))
	leave()


func _handle_peers(msg: Dictionary) -> void:
	peers.clear()
	for p in msg.get("list", []):
		peers[int(p.id)] = {"name": p.name, "ping": p.ping, "ready": true, "since": 0}
	emit_signal("peers_changed", peers)


# --- comunes ---

func _send_pings() -> void:
	var msg := {"t": Protocol.PING, "ts": OS.get_ticks_msec()}
	_ping_count += 1
	if _ping_count % PING_LOG_EVERY == 0:
		_log_pings()
	if state == State.HOSTING:
		for id in peers:
			if peers[id].ready:
				_send(id, Protocol.CH_INPUT, false, msg)
		_broadcast_peers()
	elif state == State.CONNECTED:
		_send(Transport.TARGET_SERVER, Protocol.CH_INPUT, false, msg)


func _log_pings() -> void:
	if state == State.HOSTING:
		var parts := []
		for id in peers:
			if peers[id].ready:
				parts.append("%s=%dms" % [peers[id].name, peers[id].ping])
		_log("Ping clientes: %s" % ("ninguno" if parts.empty() else PoolStringArray(parts).join(", ")))
	elif state == State.CONNECTED:
		_log("Ping al host: %dms | jugadores: %d" % [ping_ms, peers.size() + 1])


func _on_packet(sender: int, data: PoolByteArray) -> void:
	var msg = Protocol.decode(data)
	if msg == null:
		_log("Paquete inválido de %d" % sender)
		return
	var t = msg.t
	if t == Protocol.PING:
		_send(sender, Protocol.CH_INPUT, false, {"t": Protocol.PONG, "ts": msg.get("ts", 0)})
	elif t == Protocol.PONG:
		var rtt: int = OS.get_ticks_msec() - int(msg.get("ts", 0))
		if state == State.HOSTING and peers.has(sender):
			peers[sender].ping = rtt
		else:
			ping_ms = rtt
			emit_signal("peers_changed", peers)
	elif t == Protocol.INPUT_AXES or t == Protocol.INPUT_UI:
		if state == State.HOSTING and peers.has(sender) and peers[sender].ready:
			emit_signal("input_received", sender, msg)
	elif t == Protocol.WAVE_START or t == Protocol.WAVE_END or t == Protocol.DEFS or t == Protocol.SNAP:
		if state == State.CONNECTED and sender == 1:
			emit_signal("sync_received", msg)
	elif t == Protocol.HELLO:
		if state == State.HOSTING:
			_handle_hello(sender, msg)
	elif t == Protocol.WELCOME:
		if state == State.HANDSHAKE:
			_handle_welcome(msg)
	elif t == Protocol.REJECT:
		_handle_reject(msg)
	elif t == Protocol.PEERS:
		if is_client():
			host_name = str(msg.get("host_name", host_name))
			_handle_peers(msg)
	else:
		_log("Mensaje desconocido '%s' de %d" % [str(t), sender])


# Host: envía a todos los clientes que terminaron el handshake.
func broadcast(channel: int, reliable: bool, msg: Dictionary) -> void:
	if state != State.HOSTING:
		return
	var data := Protocol.encode(msg)
	for id in peers:
		if peers[id].ready:
			_transport.send(id, channel, reliable, data)


# Host: envía a un cliente puntual.
func send_to_peer(peer_id: int, channel: int, reliable: bool, msg: Dictionary) -> void:
	if state == State.HOSTING and peers.has(peer_id) and peers[peer_id].ready:
		_send(peer_id, channel, reliable, msg)


func ready_peer_count() -> int:
	var n := 0
	for id in peers:
		if peers[id].ready:
			n += 1
	return n


# Cliente: envía un mensaje al host (solo si el handshake terminó).
func send_to_host(channel: int, reliable: bool, msg: Dictionary) -> void:
	if state == State.CONNECTED:
		_send(Transport.TARGET_SERVER, channel, reliable, msg)


func _send(target: int, channel: int, reliable: bool, msg: Dictionary) -> void:
	_transport.send(target, channel, reliable, Protocol.encode(msg))


func _set_state(s: int) -> void:
	state = s
	_log("Estado: %s" % State.keys()[s])
	emit_signal("state_changed", s)


func _game_version() -> String:
	var pd = get_node_or_null("/root/ProgressData")
	return str(pd.VERSION) if pd else "?"


func _say(text: String) -> void:
	_log(text)
	emit_signal("message", text)


func _log(text: String) -> void:
	if logger:
		logger.info("[session] " + text)
