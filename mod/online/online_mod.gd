extends Node
# Autoload principal del mod online (registrado como "OnlineMod" en project.godot
# por el instalador). Crea logger, sesión de red y panel de lobby.

const BuildConfig = preload("res://online_mod/build_config.gd")
const Logger = preload("res://online_mod/util/logger.gd")
const Session = preload("res://online_mod/net/session.gd")
const LobbyPanel = preload("res://online_mod/ui/lobby_panel.gd")
const Protocol = preload("res://online_mod/net/protocol.gd")

const TOGGLE_KEY := KEY_F9
const DEV_AUTOCONNECT_DELAY := 4.0

var logger: Node
var session: Node
var lobby: CanvasLayer

var _toggle_was_down := false
var _autoconnect_timer := -1.0


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
	_toggle_was_down = down

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
