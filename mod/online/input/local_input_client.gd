extends Node
# Cliente: captura el input local (teclado o mando) y lo envía al host.
#   - Ejes de movimiento y apuntado a ~60 Hz por canal no confiable (con secuencia).
#   - Acciones de UI (presionar/soltar) por canal confiable, con repetición propia
#     para las direcciones mantenidas (como el eco de menús del juego).
# Mientras está activo, el juego local queda pausado (los menús del cliente no
# deben reaccionar a sus propias teclas) y se muestra un cartel.

const Protocol = preload("res://online_mod/net/protocol.gd")

const SEND_INTERVAL := 1.0 / 60.0
const REPEAT_DELAY := 0.3
const REPEAT_INTERVAL := 0.09
const HISTORY_MAX := 180  # ~3 s de inputs para la predicción

var session = null
var logger = null
var suspended := false  # p. ej. con el panel F9 abierto
# Historial para la predicción del jugador propio: [seq, movimiento, segundos aplicados].
# El visor descarta lo que el host ya confirmó y re-simula el resto.
var history := []
var current_move := Vector2.ZERO

var _active := false
var _seq := 0
var _send_timer := 0.0
var _last_mv := Vector2.ZERO
var _last_aim := Vector2.ZERO
var _ui_pressed := {}
var _repeat_timers := {}
var _paused_by_us := false
var _overlay: CanvasLayer
var _overlay_root: Control
var _overlay_label: Label
var _viewing_wave := false
var _viewing_screen := false


func _ready() -> void:
	pause_mode = Node.PAUSE_MODE_PROCESS
	_build_overlay()


func start(host_name: String) -> void:
	_active = true
	_seq = 0
	history.clear()
	_ui_pressed.clear()
	_repeat_timers.clear()
	if not get_tree().paused:
		get_tree().paused = true
		_paused_by_us = true
	_overlay_label.text = "Conectado a la partida de %s\nTu teclado/mando controla tu jugador en la pantalla del host.\n(F9: panel online)" % host_name
	_update_overlay()
	_log("Enviando input al host")


# Con el visor de oleada activo se oculta el cartel (el cliente ve la partida).
func set_viewing(viewing: bool) -> void:
	_viewing_wave = viewing
	_update_overlay()


# Con la pantalla del host visible (menús) también se oculta el cartel.
func set_screen(showing: bool) -> void:
	_viewing_screen = showing
	_update_overlay()


func _update_overlay() -> void:
	_overlay_root.visible = _active and not _viewing_wave and not _viewing_screen


# Conexión perdida: se deja de enviar input, pero el juego local sigue pausado
# (con un cartel) mientras se reintenta.
func show_reconnecting() -> void:
	_active = false
	_viewing_wave = false
	_viewing_screen = false
	current_move = Vector2.ZERO
	history.clear()
	_overlay_label.text = "Se perdió la conexión con el host.\nReconectando..."
	_overlay_root.visible = true


func stop() -> void:
	if not _active and not _paused_by_us and not _overlay_root.visible:
		return
	_active = false
	_overlay_root.visible = false
	if _paused_by_us:
		get_tree().paused = false
		_paused_by_us = false
	_log("Input remoto detenido")


func _process(delta: float) -> void:
	if not _active:
		return
	if suspended:
		_release_everything()
		return
	_process_ui(delta)
	# Ejes a 60 Hz fijos (aunque no cambien): cada número de secuencia representa un
	# tramo de tiempo, lo que permite al visor re-simular los inputs no confirmados.
	_send_timer -= delta
	if _send_timer <= 0.0:
		_send_timer += SEND_INTERVAL
		if _send_timer < 0.0:
			_send_timer = SEND_INTERVAL
		var mv := _read_movement()
		var aim := Input.get_vector("rjoy_left", "rjoy_right", "rjoy_up", "rjoy_down")
		_last_mv = mv
		_last_aim = aim
		_seq += 1
		session.send_to_host(Protocol.CH_INPUT, false, {"t": Protocol.INPUT_AXES, "s": _seq, "mv": mv, "aim": aim})
		history.append([_seq, mv, 0.0])
		if history.size() > HISTORY_MAX:
			history.pop_front()
	current_move = _last_mv
	if not history.empty():
		history.back()[2] += delta


func _read_movement() -> Vector2:
	var analog := Input.get_vector("analog_move_left", "analog_move_right", "analog_move_up", "analog_move_down")
	var buttons := Input.get_vector("button_move_left", "button_move_right", "button_move_up", "button_move_down")
	return analog if analog.length() > buttons.length() else buttons


func _process_ui(delta: float) -> void:
	for action in Protocol.UI_ACTIONS:
		if not InputMap.has_action(action):
			continue
		var down := _is_physically_pressed(action)
		var was_down: bool = _ui_pressed.get(action, false)
		if down and not was_down:
			_ui_pressed[action] = true
			_send_ui(action, true)
			if action in Protocol.UI_REPEAT_ACTIONS:
				_repeat_timers[action] = REPEAT_DELAY
		elif not down and was_down:
			_ui_pressed.erase(action)
			_repeat_timers.erase(action)
			_send_ui(action, false)
		elif down and _repeat_timers.has(action):
			_repeat_timers[action] -= delta
			if _repeat_timers[action] <= 0.0:
				_repeat_timers[action] = REPEAT_INTERVAL
				_send_ui(action, true)  # eco: nueva pulsación sin soltar


# Estado real de la acción según teclas/botones/ejes físicos. No se usa
# Input.is_action_pressed: con mando, el juego (InputService) emula la repetición de
# la cruceta y del stick con eventos "presionado" sin "soltado", y la acción queda
# trabada como presionada (la selección se movía sola en el host).
const STICK_DEADZONE := 0.5
const STICK_DIRS := {"ui_left": [JOY_AXIS_0, -1.0], "ui_right": [JOY_AXIS_0, 1.0],
		"ui_up": [JOY_AXIS_1, -1.0], "ui_down": [JOY_AXIS_1, 1.0]}

func _is_physically_pressed(action: String) -> bool:
	var pads := Input.get_connected_joypads()
	for ev in InputMap.get_action_list(action):
		if ev is InputEventKey:
			if ev.scancode != 0 and Input.is_key_pressed(ev.scancode):
				return true
			if ev.physical_scancode != 0 and Input.is_physical_key_pressed(ev.physical_scancode):
				return true
		elif ev is InputEventJoypadButton:
			for pad in pads:
				if Input.is_joy_button_pressed(pad, ev.button_index):
					return true
		elif ev is InputEventJoypadMotion:
			for pad in pads:
				var v := Input.get_joy_axis(pad, ev.axis)
				if v * ev.axis_value > 0.0 and abs(v) > STICK_DEADZONE:
					return true
		elif ev is InputEventMouseButton:
			if Input.is_mouse_button_pressed(ev.button_index):
				return true
	# El juego navega los menús con el stick izquierdo aunque no esté en el InputMap.
	if STICK_DIRS.has(action):
		var dir: Array = STICK_DIRS[action]
		for pad in pads:
			var v := Input.get_joy_axis(pad, dir[0])
			if v * dir[1] > STICK_DEADZONE:
				return true
	return false


func _send_ui(action: String, pressed: bool) -> void:
	session.send_to_host(Protocol.CH_CONTROL, true, {"t": Protocol.INPUT_UI, "a": action, "p": pressed})


func _release_everything() -> void:
	current_move = Vector2.ZERO
	for action in _ui_pressed.keys():
		_send_ui(action, false)
	_ui_pressed.clear()
	_repeat_timers.clear()
	if _last_mv != Vector2.ZERO or _last_aim != Vector2.ZERO:
		_last_mv = Vector2.ZERO
		_last_aim = Vector2.ZERO
		_seq += 1
		session.send_to_host(Protocol.CH_INPUT, false, {"t": Protocol.INPUT_AXES, "s": _seq, "mv": Vector2.ZERO, "aim": Vector2.ZERO})


func _build_overlay() -> void:
	_overlay = CanvasLayer.new()
	_overlay.layer = 110
	add_child(_overlay)
	_overlay_root = Control.new()
	_overlay_root.anchor_right = 1.0
	_overlay_root.anchor_bottom = 1.0
	_overlay_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay_root.visible = false
	_overlay.add_child(_overlay_root)
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.7)
	bg.anchor_right = 1.0
	bg.anchor_bottom = 1.0
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay_root.add_child(bg)
	_overlay_label = Label.new()
	_overlay_label.anchor_right = 1.0
	_overlay_label.anchor_bottom = 1.0
	_overlay_label.align = Label.ALIGN_CENTER
	_overlay_label.valign = Label.VALIGN_CENTER
	_overlay_root.add_child(_overlay_label)


func _log(text: String) -> void:
	if logger:
		logger.info("[input-client] " + text)
