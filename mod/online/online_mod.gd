extends Node
# Autoload principal del mod online (registrado como "OnlineMod" en project.godot
# por el instalador). Crea logger, sesión de red y panel de lobby.

const BuildConfig = preload("res://online_mod/build_config.gd")
const Logger = preload("res://online_mod/util/logger.gd")
const Session = preload("res://online_mod/net/session.gd")
const LobbyPanel = preload("res://online_mod/ui/lobby_panel.gd")
const Protocol = preload("res://online_mod/net/protocol.gd")
const RemoteInputHost = preload("res://online_mod/input/remote_input_host.gd")
const LocalInputClient = preload("res://online_mod/input/local_input_client.gd")

const TOGGLE_KEY := KEY_F9
const DEV_AUTOCONNECT_DELAY := 4.0

var logger: Node
var session: Node
var lobby: CanvasLayer
var input_host: Node
var input_client: Node

var _toggle_was_down := false
var _autoconnect_timer := -1.0
var _selftest_t := -1.0
var _selftest_seq := 0


func _ready() -> void:
	pause_mode = Node.PAUSE_MODE_PROCESS

	logger = Logger.new()
	logger.name = "Logger"
	add_child(logger)
	logger.setup(BuildConfig.DEV_LOG_SINK_PORT > 0, BuildConfig.DEV_LOG_SINK_PORT)

	session = Session.new()
	session.name = "Session"
	session.mod_version = BuildConfig.MOD_VERSION
	session.local_name = _get_local_name()
	session.logger = logger
	add_child(session)
	session.connect("state_changed", self, "_on_state_changed")

	input_host = RemoteInputHost.new()
	input_host.name = "RemoteInputHost"
	input_host.logger = logger
	add_child(input_host)
	session.connect("peer_joined", input_host, "on_peer_joined")
	session.connect("peer_left", input_host, "on_peer_left")
	session.connect("input_received", input_host, "on_input")

	input_client = LocalInputClient.new()
	input_client.name = "LocalInputClient"
	input_client.session = session
	input_client.logger = logger
	add_child(input_client)

	lobby = LobbyPanel.new()
	lobby.name = "LobbyPanel"
	lobby.session = session
	add_child(lobby)

	get_tree().connect("node_added", self, "_on_node_added")

	logger.info("OnlineMod v%s cargado | juego %s | motor %s | build %s" % [
		BuildConfig.MOD_VERSION, _game_version(), Engine.get_version_info().string,
		"DEV" if BuildConfig.DEV_AUTOCONNECT else "release"])

	if BuildConfig.DEV_AUTOCONNECT:
		_autoconnect_timer = DEV_AUTOCONNECT_DELAY


func _process(delta: float) -> void:
	# F9 por polling: las escenas del juego pueden marcar los eventos como manejados.
	var down := Input.is_key_pressed(TOGGLE_KEY)
	if down and not _toggle_was_down:
		lobby.toggle()
		input_client.suspended = lobby.is_open()
	_toggle_was_down = down

	if _selftest_t >= 0.0:
		_run_selftest(delta)

	if _autoconnect_timer > 0.0:
		_autoconnect_timer -= delta
		if _autoconnect_timer <= 0.0:
			_dev_autoconnect()


# Desarrollo: la primera instancia hostea; si el puerto está ocupado, se une a 127.0.0.1.
func _dev_autoconnect() -> void:
	logger.tag = "auto"
	if session.host(Protocol.DEFAULT_PORT) == OK:
		logger.tag = "HOST"
	else:
		logger.tag = "CLIENT"
		session.join("127.0.0.1", Protocol.DEFAULT_PORT)


func _on_state_changed(state: int) -> void:
	if state == session.State.HOSTING:
		logger.tag = "HOST"
	elif state != session.State.OFFLINE:
		logger.tag = "CLIENT"
	if state == session.State.CONNECTED:
		input_client.start(session.host_name)
		if BuildConfig.DEV_AUTOCONNECT and OS.get_environment("ONLINE_MOD_SELFTEST") == "1":
			_selftest_t = 0.0
			input_client.suspended = true  # el auto-test envía su propio input
	else:
		input_client.stop()


# Desarrollo (ONLINE_MOD_SELFTEST=1): el cliente envía una secuencia de input
# sintética para verificar la inyección en el host sin intervención humana.
func _run_selftest(delta: float) -> void:
	var before := _selftest_t
	_selftest_t += delta
	var steps := [
		[0.5, {"t": Protocol.INPUT_UI, "a": "ui_accept", "p": true}],
		[1.5, {"t": Protocol.INPUT_UI, "a": "ui_accept", "p": false}],
		[2.0, {"t": Protocol.INPUT_UI, "a": "ui_down", "p": true}],
		[2.1, {"t": Protocol.INPUT_UI, "a": "ui_down", "p": false}],
	]
	for step in steps:
		if before < step[0] and _selftest_t >= step[0]:
			session.send_to_host(Protocol.CH_CONTROL, true, step[1])
	if _selftest_t >= 2.5 and _selftest_t < 3.5:
		_selftest_seq += 1
		session.send_to_host(Protocol.CH_INPUT, false, {"t": Protocol.INPUT_AXES, "s": _selftest_seq, "mv": Vector2(1, 0), "aim": Vector2(0, -0.5)})
	elif _selftest_t >= 3.5:
		_selftest_seq += 1
		session.send_to_host(Protocol.CH_INPUT, false, {"t": Protocol.INPUT_AXES, "s": _selftest_seq, "mv": Vector2.ZERO, "aim": Vector2.ZERO})
		logger.info("[selftest] secuencia enviada")
		_selftest_t = -1.0


# Muestra la versión del mod junto a la del juego en el menú principal, sin
# modificar los scripts del juego (se aplica al aparecer el nodo VersionLabel).
func _on_node_added(node: Node) -> void:
	if node.name == "VersionLabel" and node is Label:
		call_deferred("_tag_version_label", node)


func _tag_version_label(label: Label) -> void:
	if is_instance_valid(label) and label.text.find("Online") == -1:
		label.text += "  |  Online Mod v%s" % BuildConfig.MOD_VERSION


func _get_local_name() -> String:
	if Engine.has_singleton("OS_Seaven"):
		var os_seaven = Engine.get_singleton("OS_Seaven")
		if os_seaven.has_method("get_gamertag"):
			var tag = os_seaven.call("get_gamertag")
			if typeof(tag) == TYPE_STRING and tag != "":
				return tag
	return "Player %d" % (OS.get_process_id() % 1000)


func _game_version() -> String:
	var pd = get_node_or_null("/root/ProgressData")
	return str(pd.VERSION) if pd else "?"
