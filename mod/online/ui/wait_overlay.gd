extends CanvasLayer
# Host: si un jugador remoto que está en la partida se desconecta durante una
# oleada, se pausa el juego y se espera su reconexión (hasta WAIT_SECONDS, o hasta
# que el host presione SKIP_KEY para seguir sin esperar).

const WAIT_SECONDS := 60.0
const SKIP_KEY := KEY_F10
const WAVE_SCENE := "res://main.tscn"

var logger = null
var input_host = null

var _waiting := {}  # nombre → true
var _time_left := 0.0
var _paused_by_us := false
var _root: Control
var _label: Label


func _ready() -> void:
	layer = 115
	pause_mode = Node.PAUSE_MODE_PROCESS
	_root = Control.new()
	_root.anchor_right = 1.0
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.visible = false
	add_child(_root)
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.75)
	bg.rect_size = Vector2(1920, 110)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(bg)
	_label = Label.new()
	_label.rect_size = Vector2(1920, 110)
	_label.align = Label.ALIGN_CENTER
	_label.valign = Label.VALIGN_CENTER
	_label.rect_scale = Vector2(1, 1)
	_root.add_child(_label)


func on_remote_player_left(peer_name: String, device: int) -> void:
	var scene = get_tree().current_scene
	if scene == null or scene.filename != WAVE_SCENE or input_host == null or not input_host.is_device_in_game(device):
		return
	_waiting[peer_name] = true
	_time_left = WAIT_SECONDS
	if not get_tree().paused:
		get_tree().paused = true
		_paused_by_us = true
	_root.visible = true
	_log("%s se desconectó en plena oleada: partida pausada esperando reconexión" % peer_name)


func on_peer_joined(_peer_id: int, peer_name: String) -> void:
	if _waiting.erase(peer_name):
		_log("%s volvió" % peer_name)
		if _waiting.empty():
			_resume()


func _process(delta: float) -> void:
	if _waiting.empty():
		return
	_time_left -= delta
	var names := PoolStringArray(_waiting.keys()).join(", ")
	_label.text = "%s se desconectó. Esperando reconexión... %ds\n(F10: seguir sin esperar)" % [names, int(ceil(_time_left))]
	if _time_left <= 0.0 or Input.is_key_pressed(SKIP_KEY):
		_log("Se continúa sin esperar a %s" % names)
		_waiting.clear()
		_resume()


func _resume() -> void:
	_root.visible = false
	if _paused_by_us:
		get_tree().paused = false
		_paused_by_us = false


func reset() -> void:
	_waiting.clear()
	_resume()


func _log(text: String) -> void:
	if logger:
		logger.info("[espera] " + text)
