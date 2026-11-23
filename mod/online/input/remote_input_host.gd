extends Node
# Host: convierte el input de cada cliente en un "mando virtual" local.
#
# Cada cliente recibe un dispositivo virtual (8..11, el rango que el juego reserva
# para dispositivos de debug). Se crean las acciones "<accion>_<dev>" en el InputMap
# y se les inyecta el estado recibido:
#   - ejes (movimiento / apuntado): Input.action_press con fuerza, se leen por polling;
#   - UI: Input.parse_input_event(InputEventAction), porque los menús leen en _input.
# Así el co-op local del juego trata al jugador remoto como a cualquier mando.

const Protocol = preload("res://online_mod/net/protocol.gd")

const FIRST_VIRTUAL_DEVICE := 8
const VIRTUAL_DEVICE_COUNT := 4
const GAMEPAD_XBOX_TYPE := 1  # CoopService.PlayerType.GAMEPAD_XBOX
const AXIS_TIMEOUT_MS := 500  # sin paquetes de ejes en este tiempo → soltar ejes
const AXIS_LOG_INTERVAL_MS := 1000

const MOVE_ACTIONS := ["analog_move_left", "analog_move_right", "analog_move_up", "analog_move_down"]
const AIM_ACTIONS := ["rjoy_left", "rjoy_right", "rjoy_up", "rjoy_down"]

signal remote_player_left(peer_name, device)

var logger = null
# devices[peer_id] = {device, last_seq, last_axes_ms, pressed_ui: {}}
var devices := {}
var _focus_override_active := false
var _saved_focus_settings := {}
var _reserved := {}  # nombre → dispositivo: quien se reconecta retoma su mismo jugador


func _ready() -> void:
	var coop = _coop_service()
	if coop and not coop.is_connected("connected_players_updated", self, "_on_connected_players_updated"):
		coop.connect("connected_players_updated", self, "_on_connected_players_updated")


func _exit_tree() -> void:
	_restore_focus_settings()


func on_peer_joined(peer_id: int, peer_name: String) -> void:
	var device := _free_device()
	if _reserved.has(peer_name) and _is_device_free(_reserved[peer_name]):
		device = _reserved[peer_name]
	if device < 0:
		_log("Sin dispositivos virtuales libres para %s" % peer_name)
		return
	_reserved[peer_name] = device
	devices[peer_id] = {"device": device, "name": peer_name, "last_seq": -1, "last_axes_ms": 0, "pressed_ui": {}}
	_ensure_actions()
	_apply_focus_override()
	_log("%s → dispositivo virtual %d (mantener Aceptar para unirse en la selección de personaje)" % [peer_name, device])


func on_peer_left(peer_id: int) -> void:
	if not devices.has(peer_id):
		return
	var d = devices[peer_id]
	emit_signal("remote_player_left", d.name, d.device)
	_release_all(d)
	devices.erase(peer_id)
	_log("%s liberó el dispositivo virtual %d" % [d.name, d.device])
	if devices.empty():
		_restore_focus_settings()


func on_input(peer_id: int, msg: Dictionary) -> void:
	if not devices.has(peer_id):
		return
	var d = devices[peer_id]
	_ensure_actions()
	if msg.t == Protocol.INPUT_AXES:
		var seq := int(msg.get("s", 0))
		if seq <= d.last_seq:
			return  # paquete viejo o duplicado (canal no confiable)
		d.last_seq = seq
		d.last_axes_ms = OS.get_ticks_msec()
		var mv = msg.get("mv", Vector2.ZERO)
		var aim = msg.get("aim", Vector2.ZERO)
		_set_axes(d.device, MOVE_ACTIONS, mv)
		_set_axes(d.device, AIM_ACTIONS, aim)
		if typeof(mv) == TYPE_VECTOR2 and typeof(aim) == TYPE_VECTOR2 and (mv != Vector2.ZERO or aim != Vector2.ZERO) 				and d.last_axes_ms - d.get("last_axes_log_ms", 0) > AXIS_LOG_INTERVAL_MS:
			d["last_axes_log_ms"] = d.last_axes_ms
			_log("%s (dev %d) mv=%s aim=%s seq=%d → fuerza analog_move_right_%d=%.2f rjoy_up_%d=%.2f" % [
					d.name, d.device, str(mv), str(aim), seq,
					d.device, Input.get_action_strength("analog_move_right_%d" % d.device),
					d.device, Input.get_action_strength("rjoy_up_%d" % d.device)])
	elif msg.t == Protocol.INPUT_UI:
		var action := str(msg.get("a", ""))
		if not action in Protocol.UI_ACTIONS:
			return
		var pressed := bool(msg.get("p", false))
		_send_ui_event(d.device, action, pressed)
		_log("%s (dev %d) %s %s" % [d.name, d.device, action, "presionado" if pressed else "soltado"])
		if pressed:
			d.pressed_ui[action] = true
		else:
			d.pressed_ui.erase(action)


func get_device_for_peer(peer_id: int) -> int:
	return devices[peer_id].device if devices.has(peer_id) else -1


func _process(_delta: float) -> void:
	var now := OS.get_ticks_msec()
	for peer_id in devices:
		var d = devices[peer_id]
		if d.last_axes_ms > 0 and now - d.last_axes_ms > AXIS_TIMEOUT_MS:
			_set_axes(d.device, MOVE_ACTIONS, Vector2.ZERO)
			_set_axes(d.device, AIM_ACTIONS, Vector2.ZERO)
			d.last_axes_ms = 0


# --- inyección ---

func _set_axes(device: int, actions: Array, v) -> void:
	if typeof(v) != TYPE_VECTOR2:
		v = Vector2.ZERO
	v = v.clamped(1.0)
	_set_strength("%s_%d" % [actions[0], device], max(0.0, -v.x))
	_set_strength("%s_%d" % [actions[1], device], max(0.0, v.x))
	_set_strength("%s_%d" % [actions[2], device], max(0.0, -v.y))
	_set_strength("%s_%d" % [actions[3], device], max(0.0, v.y))


func _set_strength(action: String, strength: float) -> void:
	if not InputMap.has_action(action):
		return
	if strength > 0.0:
		Input.action_press(action, strength)
	elif Input.is_action_pressed(action):
		Input.action_release(action)


func _send_ui_event(device: int, action: String, pressed: bool) -> void:
	var full := "%s_%d" % [action, device]
	if not InputMap.has_action(full):
		return
	var ev := InputEventAction.new()
	ev.action = full
	ev.pressed = pressed
	ev.strength = 1.0 if pressed else 0.0
	ev.device = device
	Input.parse_input_event(ev)


func _release_all(d: Dictionary) -> void:
	_set_axes(d.device, MOVE_ACTIONS, Vector2.ZERO)
	_set_axes(d.device, AIM_ACTIONS, Vector2.ZERO)
	for action in d.pressed_ui.keys():
		_send_ui_event(d.device, action, false)
	d.pressed_ui.clear()


# --- acciones de los dispositivos virtuales ---

# El juego reconstruye el InputMap (InputService: load_from_globals + copia por
# dispositivo) al cambiar opciones de control, lo que borra acciones agregadas.
# Se verifica en cada uso y se recrean si faltan.
func _ensure_actions() -> void:
	if InputMap.has_action("ui_accept_%d" % FIRST_VIRTUAL_DEVICE) and InputMap.has_action("analog_move_left_%d" % FIRST_VIRTUAL_DEVICE):
		return
	var created := 0
	for action in InputMap.get_actions():
		var a := str(action)
		if _has_device_suffix(a):
			continue
		var deadzone := InputMap.action_get_deadzone(a)
		for i in VIRTUAL_DEVICE_COUNT:
			var full := "%s_%d" % [a, FIRST_VIRTUAL_DEVICE + i]
			if not InputMap.has_action(full):
				InputMap.add_action(full, deadzone)
				created += 1
	_log("Acciones de dispositivos virtuales creadas: %d" % created)


func _has_device_suffix(action: String) -> bool:
	var idx := action.find_last("_")
	return idx > 0 and action.substr(idx + 1).is_valid_integer()


# Al dejar de hostear se olvidan las reservas.
func reset() -> void:
	for peer_id in devices.keys():
		on_peer_left(peer_id)
	_reserved.clear()


# ¿El dispositivo pertenece a un jugador que ya está en la partida (unido en el co-op)?
func is_device_in_game(device: int) -> bool:
	var coop = _coop_service()
	if coop == null or typeof(coop.get("connected_players")) != TYPE_ARRAY:
		return false
	for entry in coop.connected_players:
		if int(entry[0]) == device:
			return true
	return false


func _is_device_free(device: int) -> bool:
	for peer_id in devices:
		if devices[peer_id].device == device:
			return false
	return true


func _free_device() -> int:
	var used := []
	for peer_id in devices:
		used.append(devices[peer_id].device)
	# Primero dispositivos sin reserva (no quitarle el lugar a quien se está reconectando).
	var reserved := _reserved.values()
	for i in VIRTUAL_DEVICE_COUNT:
		var dev: int = FIRST_VIRTUAL_DEVICE + i
		if not dev in used and not dev in reserved:
			return dev
	for i in VIRTUAL_DEVICE_COUNT:
		if not (FIRST_VIRTUAL_DEVICE + i) in used:
			return FIRST_VIRTUAL_DEVICE + i
	return -1


# Los dispositivos virtuales no tienen nombre de joypad, así que el juego los
# registraría como teclado+mouse. Se corrigen a mando Xbox para que apunten con
# el stick derecho y muestren íconos de mando.
func _on_connected_players_updated(connected_players: Array) -> void:
	for entry in connected_players:
		var dev := int(entry[0])
		if dev >= FIRST_VIRTUAL_DEVICE and dev < FIRST_VIRTUAL_DEVICE + VIRTUAL_DEVICE_COUNT and int(entry[1]) != GAMEPAD_XBOX_TYPE:
			entry[1] = GAMEPAD_XBOX_TYPE
			_log("Jugador remoto (dispositivo %d) unido; tipo corregido a mando" % dev)


# --- foco de ventana ---

# Con jugadores remotos, el host no debe pausarse ni ignorar input al perder el foco.
func _apply_focus_override() -> void:
	if _focus_override_active:
		return
	var pd = get_node_or_null("/root/ProgressData")
	if pd == null or typeof(pd.settings) != TYPE_DICTIONARY:
		return
	for key in ["pause_on_focus_lost", "on_lost_focus"]:
		if pd.settings.has(key):
			_saved_focus_settings[key] = pd.settings[key]
	if pd.settings.has("pause_on_focus_lost"):
		pd.settings.pause_on_focus_lost = false
	if pd.settings.has("on_lost_focus") and int(pd.settings.on_lost_focus) == 2:
		pd.settings.on_lost_focus = 0
	_focus_override_active = true
	_log("Pausa por pérdida de foco desactivada mientras haya jugadores remotos")


func _restore_focus_settings() -> void:
	if not _focus_override_active:
		return
	var pd = get_node_or_null("/root/ProgressData")
	if pd and typeof(pd.settings) == TYPE_DICTIONARY:
		for key in _saved_focus_settings:
			pd.settings[key] = _saved_focus_settings[key]
	_saved_focus_settings.clear()
	_focus_override_active = false
	_log("Configuración de foco restaurada")


func _coop_service():
	return get_node_or_null("/root/CoopService")


func _log(text: String) -> void:
	if logger:
		logger.info("[input-host] " + text)
