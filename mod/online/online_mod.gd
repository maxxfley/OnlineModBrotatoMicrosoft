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
const WorldSyncHost = preload("res://online_mod/sync/world_sync_host.gd")
const WaveViewerClient = preload("res://online_mod/sync/wave_viewer_client.gd")
const UiMirrorHost = preload("res://online_mod/sync/ui_mirror_host.gd")
const UiMirrorClient = preload("res://online_mod/sync/ui_mirror_client.gd")
const WaitOverlay = preload("res://online_mod/ui/wait_overlay.gd")
const SoundSync = preload("res://online_mod/sync/sound_sync.gd")

const TOGGLE_KEY := KEY_F9
const DEV_AUTOCONNECT_DELAY := 4.0

var logger: Node
var session: Node
var lobby: CanvasLayer
var input_host: Node
var input_client: Node
var sync_host: Node
var viewer: Node2D
var ui_host: Node
var ui_client: CanvasLayer
var wait_overlay: CanvasLayer
var sound_sync: Node

var _toggle_was_down := false
var _autoconnect_timer := -1.0
var _selftest_t := -1.0
var _selftest_seq := 0
var _fps_log_timer := 5.0
var _selftest_dropped := false


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

	sync_host = WorldSyncHost.new()
	sync_host.name = "WorldSyncHost"
	sync_host.session = session
	sync_host.logger = logger
	sync_host.input_host = input_host
	add_child(sync_host)
	session.connect("peer_joined", sync_host, "on_peer_joined")

	viewer = WaveViewerClient.new()
	viewer.name = "WaveViewer"
	viewer.logger = logger
	viewer.session = session
	viewer.input_client = input_client
	add_child(viewer)
	session.connect("sync_received", viewer, "on_sync")
	viewer.connect("viewing_changed", input_client, "set_viewing")

	ui_host = UiMirrorHost.new()
	ui_host.name = "UiMirrorHost"
	ui_host.session = session
	ui_host.logger = logger
	add_child(ui_host)
	session.connect("peer_joined", ui_host, "on_peer_joined")

	ui_client = UiMirrorClient.new()
	ui_client.name = "UiMirror"
	ui_client.logger = logger
	add_child(ui_client)
	session.connect("sync_received", ui_client, "on_sync")
	ui_client.connect("showing_changed", input_client, "set_screen")

	sound_sync = SoundSync.new()
	sound_sync.name = "SoundSync"
	sound_sync.session = session
	sound_sync.logger = logger
	add_child(sound_sync)
	session.connect("sync_received", sound_sync, "on_sync")

	wait_overlay = WaitOverlay.new()
	wait_overlay.name = "WaitOverlay"
	wait_overlay.logger = logger
	wait_overlay.input_host = input_host
	add_child(wait_overlay)
	input_host.connect("remote_player_left", wait_overlay, "on_remote_player_left")
	session.connect("peer_joined", wait_overlay, "on_peer_joined")

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

	if session.state == session.State.CONNECTED:
		_fps_log_timer -= delta
		if _fps_log_timer <= 0.0:
			_fps_log_timer = 5.0
			logger.info("[perf] FPS cliente: %d | visor %s | target_fps %d | vsync %s" % [
				Engine.get_frames_per_second(), "activo" if viewer.active else "inactivo",
				Engine.target_fps, str(OS.vsync_enabled)])

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
	if state == session.State.HOSTING or (state == session.State.OFFLINE and not session.reconnecting):
		input_host.reset()
		wait_overlay.reset()
	if state == session.State.CONNECTED:
		input_client.start(session.host_name)
		if BuildConfig.DEV_AUTOCONNECT and OS.get_environment("ONLINE_MOD_SELFTEST") == "1":
			_selftest_t = 0.0
			input_client.suspended = true  # el auto-test envía su propio input
	elif session.reconnecting:
		input_client.show_reconnecting()
		viewer.reset()
		ui_client.reset()
	elif state == session.State.OFFLINE:
		input_client.stop()
		viewer.reset()
		ui_client.reset()


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
		if not _selftest_dropped:
			_selftest_dropped = true
			get_tree().create_timer(1.5, true).connect("timeout", session, "_connection_lost", ["[selftest] corte simulado"])


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
