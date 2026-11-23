extends Node
# Sonda de diagnóstico: verifica que el motor Seaven cargue un autoload inyectado
# vía override.cfg y reporta capacidades del motor (red, rutas, versión).
# Muestra el resultado en pantalla y lo intenta guardar en archivos de log.
# No referencia clases opcionales por nombre (se usan vía ClassDB) para que el
# script compile aunque el fork no las incluya.

const NET_CLASSES := [
	"NetworkedMultiplayerENet", "NetworkedMultiplayerCustom", "MultiplayerAPI",
	"WebRTCPeerConnection", "WebRTCMultiplayer", "WebSocketClient", "WebSocketServer",
	"PacketPeerUDP", "UDPServer", "StreamPeerTCP", "TCP_Server", "HTTPRequest",
]
const TEST_PORT := 24565

var _lines := []


func _ready() -> void:
	if ProjectSettings.has_setting("online_mod/probe_loaded"):
		_add("Sonda ya cargada por otra ruta; esta instancia (%s) se descarta" % get_script().resource_path)
		queue_free()
		return
	ProjectSettings.set_setting("online_mod/probe_loaded", true)

	_add("=== ONLINE MOD PROBE OK ===")
	_add("Cargado desde: %s" % get_script().resource_path)
	_add("Nombre autoload: %s" % name)
	_add("OS.get_name(): %s" % OS.get_name())
	_add("Engine: %s" % str(Engine.get_version_info()))
	_add("Exe: %s" % OS.get_executable_path())
	_add("user data dir: %s" % OS.get_user_data_dir())
	_add("Debug build: %s" % str(OS.is_debug_build()))
	_add("Args: %s" % str(OS.get_cmdline_args()))
	_add("load_resource_pack: %s" % str(ProjectSettings.has_method("load_resource_pack")))
	for cls in NET_CLASSES:
		_add("%s: %s" % [cls, "SI" if ClassDB.class_exists(cls) else "NO"])
	_test_enet()
	_add("IPs locales: %s" % str(IP.get_local_addresses()))

	_write_logs()
	_show_overlay()


func _test_enet() -> void:
	if not ClassDB.class_exists("NetworkedMultiplayerENet"):
		_add("ENet test: clase no disponible")
		return
	var peer = ClassDB.instance("NetworkedMultiplayerENet")
	var err = peer.call("create_server", TEST_PORT, 4)
	_add("ENet create_server(%d): %s" % [TEST_PORT, "OK" if err == OK else "error %d" % err])
	if err == OK:
		peer.call("close_connection")


func _write_logs() -> void:
	var text := PoolStringArray(_lines).join("\n")
	var targets := [
		OS.get_executable_path().get_base_dir().plus_file("online_mod/probe_log.txt"),
		"user://online_mod_probe_log.txt",
	]
	for path in targets:
		var f := File.new()
		var err := f.open(path, File.WRITE)
		if err == OK:
			f.store_string(text)
			f.close()
			_add("Log escrito: %s" % path)
		else:
			_add("No se pudo escribir %s (error %d)" % [path, err])
	print(text)


func _show_overlay() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 128
	add_child(layer)
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.75)
	bg.rect_position = Vector2(10, 10)
	bg.rect_size = Vector2(1100, 30 + 24 * _lines.size())
	layer.add_child(bg)
	var label := Label.new()
	label.text = PoolStringArray(_lines).join("\n")
	label.rect_position = Vector2(20, 20)
	label.modulate = Color(0.4, 1, 0.4)
	layer.add_child(label)


func _add(line: String) -> void:
	_lines.append(line)
