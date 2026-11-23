extends Node
# Transporte ENet aislado del resto del mod. No usa la API de RPC de Godot ni
# toca get_tree().network_peer: envía/recibe paquetes crudos por canal.
# Si en el futuro se cambia de transporte (p. ej. WebRTC), solo cambia este archivo.

signal peer_connected(peer_id)
signal peer_disconnected(peer_id)
signal connected_to_server()
signal connection_failed()
signal server_disconnected()
signal packet_received(peer_id, data)

const CHANNEL_COUNT := 3
const TARGET_BROADCAST := 0
const TARGET_SERVER := 1
const MODE_UNRELIABLE := 0
const MODE_RELIABLE := 2

var _peer = null  # NetworkedMultiplayerENet (via ClassDB)
var is_server := false


func is_active() -> bool:
	return _peer != null


func get_unique_id() -> int:
	return _peer.call("get_unique_id") if _peer else 0


func host(port: int, max_clients: int) -> int:
	close()
	var peer = _new_peer()
	if peer == null:
		return ERR_UNAVAILABLE
	peer.set("server_relay", false)
	var err: int = peer.call("create_server", port, max_clients)
	if err != OK:
		return err
	_attach(peer)
	is_server = true
	return OK


func join(address: String, port: int) -> int:
	close()
	var peer = _new_peer()
	if peer == null:
		return ERR_UNAVAILABLE
	var err: int = peer.call("create_client", address, port)
	if err != OK:
		return err
	_attach(peer)
	is_server = false
	return OK


func close() -> void:
	if _peer:
		_peer.call("close_connection")
	_peer = null
	is_server = false


func send(target: int, channel: int, reliable: bool, data: PoolByteArray) -> void:
	if _peer == null:
		return
	_peer.set("transfer_channel", channel)
	_peer.set("transfer_mode", MODE_RELIABLE if reliable else MODE_UNRELIABLE)
	_peer.call("set_target_peer", target)
	_peer.call("put_packet", data)


func kick(peer_id: int) -> void:
	if _peer and is_server:
		_peer.call("disconnect_peer", peer_id, false)


func get_peer_address(peer_id: int) -> String:
	if _peer and is_server:
		return _peer.call("get_peer_address", peer_id)
	return ""


func _new_peer():
	if not ClassDB.class_exists("NetworkedMultiplayerENet"):
		return null
	var peer = ClassDB.instance("NetworkedMultiplayerENet")
	peer.set("channel_count", CHANNEL_COUNT)
	peer.set("always_ordered", false)
	return peer


func _attach(peer) -> void:
	_peer = peer
	peer.connect("peer_connected", self, "_on_peer_connected")
	peer.connect("peer_disconnected", self, "_on_peer_disconnected")
	peer.connect("connection_succeeded", self, "_on_connection_succeeded")
	peer.connect("connection_failed", self, "_on_connection_failed")
	peer.connect("server_disconnected", self, "_on_server_disconnected")


func _process(_delta: float) -> void:
	if _peer == null:
		return
	_peer.call("poll")
	while _peer != null and _peer.call("get_available_packet_count") > 0:
		var sender: int = _peer.call("get_packet_peer")
		var data: PoolByteArray = _peer.call("get_packet")
		emit_signal("packet_received", sender, data)


func _on_peer_connected(id: int) -> void:
	emit_signal("peer_connected", id)


func _on_peer_disconnected(id: int) -> void:
	emit_signal("peer_disconnected", id)


func _on_connection_succeeded() -> void:
	emit_signal("connected_to_server")


func _on_connection_failed() -> void:
	_peer = null
	emit_signal("connection_failed")


func _on_server_disconnected() -> void:
	_peer = null
	emit_signal("server_disconnected")
