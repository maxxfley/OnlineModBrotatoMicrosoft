extends Node2D
# Cliente: dibuja la oleada del host a partir de los mensajes de sincronización.
# No simula nada: crea Sprites con las mismas texturas del juego y los ubica según
# los snapshots, interpolando posiciones entre los dos últimos recibidos.

const Protocol = preload("res://online_mod/net/protocol.gd")

const GROUND_TILESET := "res://resources/tiles/ground_tiles.tres"
const OUTLINE_TEXTURE := "res://resources/tiles/tiles_outline.png"
const RENDER_DELAY_MS := 100  # dibujar en el pasado para interpolar siempre

signal viewing_changed(active)

var logger = null
var active := false
var session = null       # para conocer el id propio
var input_client = null  # historial de inputs propios (predicción)

var _defs := {}            # id → def
var _textures := {}        # ruta → Texture (o null si falló)
var _world: Node2D
var _layers := []
var _camera: Camera2D
var _bg_layer: CanvasLayer
var _bg: TextureRect
var _entities := {}        # key → {node, sprites: [], defs: [], from, to}
var _queue := []          # snapshots decodificados, ordenados por tiempo del host
var _applied = null
var _clock_offset = null  # ms locales - ms del host (mínimo observado)
var _last_seq := 0
var _hidden_scene_items := []
var _snap_count := 0
var _fx_scenes := {}  # ruta → PackedScene (o null)
# Predicción del jugador propio
var _own_key = null
var _own_speed := 0.0
var _pred_pos = null      # posición predicha (Vector2) o null
var _pred_error := Vector2.ZERO  # corrección pendiente, se desvanece de a poco
var _map_rect := Rect2()
const PRED_ERROR_DECAY := 12.0   # 1/s: qué tan rápido se absorben las correcciones
const PRED_SNAP_DISTANCE := 200.0  # error mayor (teletransporte, muerte): saltar directo


func _ready() -> void:
	pause_mode = Node.PAUSE_MODE_PROCESS
	visible = false


func on_sync(msg: Dictionary) -> void:
	var t = msg.t
	if t == Protocol.DEFS:
		for entry in msg.get("list", []):
			_defs[int(entry[0])] = entry[1]
	elif t == Protocol.WAVE_START:
		_start_wave(msg)
	elif t == Protocol.WAVE_END:
		_stop_wave()
		_log("Oleada terminada (menús: fase 4)")
	elif t == Protocol.SNAP:
		if active:
			_apply_snapshot(msg)


func reset() -> void:
	_stop_wave()
	_defs.clear()
	_last_seq = 0


# --- oleada ---

func _start_wave(msg: Dictionary) -> void:
	_stop_wave()
	_world = Node2D.new()
	_world.name = "World"
	add_child(_world)

	var tile_map := TileMap.new()
	var ts = load(GROUND_TILESET) if ResourceLoader.exists(GROUND_TILESET) else null
	if ts:
		ts = ts.duplicate()
		var tex = _texture(str(msg.get("tiles", "")))
		if tex:
			ts.tile_set_texture(0, tex)
		tile_map.tile_set = ts
		tile_map.cell_quadrant_size = 64
		var cells: PoolIntArray = msg.get("cells", PoolIntArray())
		var i := 0
		while i + 2 < cells.size():
			var packed := cells[i + 2]
			tile_map.set_cell(cells[i], cells[i + 1], 0, false, false, false, Vector2(packed & 0xFFFF, (packed >> 16) & 0xFFFF))
			i += 3
	_world.add_child(tile_map)
	var outline := NinePatchRect.new()
	outline.texture = _texture(OUTLINE_TEXTURE)
	outline.show_behind_parent = true
	outline.modulate = msg.get("outline_mod", Color.white)
	var r: Rect2 = msg.get("outline_rect", Rect2())
	_map_rect = Rect2(r.position + Vector2(64, 64), r.size - Vector2(128, 128))
	outline.rect_position = r.position
	outline.rect_size = r.size
	outline.patch_margin_left = 64
	outline.patch_margin_top = 64
	outline.patch_margin_right = 64
	outline.patch_margin_bottom = 64
	outline.axis_stretch_horizontal = NinePatchRect.AXIS_STRETCH_MODE_TILE
	outline.axis_stretch_vertical = NinePatchRect.AXIS_STRETCH_MODE_TILE
	outline.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tile_map.add_child(outline)

	_layers = []
	for li in Protocol.LAYERS.size():
		var layer: Node2D = YSort.new() if li == Protocol.LAYER_YSORT else Node2D.new()
		layer.name = Protocol.LAYERS[li]
		_world.add_child(layer)
		_layers.append(layer)

	_camera = Camera2D.new()
	_camera.pause_mode = Node.PAUSE_MODE_PROCESS
	_world.add_child(_camera)
	_camera.current = true

	_bg_layer = CanvasLayer.new()
	_bg_layer.layer = -10
	add_child(_bg_layer)
	_bg = TextureRect.new()
	var colors: PoolColorArray = msg.get("bg_colors", PoolColorArray())
	if colors.size() > 0:
		var g := Gradient.new()
		g.colors = colors
		g.offsets = msg.get("bg_offsets", PoolRealArray())
		var gt := GradientTexture.new()
		gt.gradient = g
		_bg.texture = gt
	_bg.anchor_right = 1.0
	_bg.anchor_bottom = 1.0
	_bg.margin_left = 1920.0
	_bg.margin_right = 1080.0
	_bg.margin_bottom = 840.0
	_bg.rect_rotation = 89.9906
	_bg.expand = true
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bg_layer.add_child(_bg)


	_hide_game_scene()
	visible = true
	active = true
	_snap_count = 0
	emit_signal("viewing_changed", true)
	_log("Visor de oleada %s iniciado (%d celdas)" % [str(msg.get("wave", "?")), msg.get("cells", PoolIntArray()).size() / 3])


func _stop_wave() -> void:
	if not active:
		return
	active = false
	visible = false
	_entities.clear()
	_queue.clear()
	_applied = null
	_own_key = null
	_pred_pos = null
	_layers = []
	for n in [_world, _bg_layer]:
		if is_instance_valid(n):
			n.queue_free()
	_world = null
	_camera = null
	_restore_game_scene()
	emit_signal("viewing_changed", false)


# Oculta la escena local del cliente (menú pausado) mientras se ve la oleada.
func _hide_game_scene() -> void:
	_hidden_scene_items.clear()
	var scene = get_tree().current_scene
	if scene == null:
		return
	if scene is CanvasItem and scene.visible:
		scene.visible = false
		_hidden_scene_items.append(scene)
	for child in scene.get_children():
		if child is CanvasLayer and child.get("visible") == true:
			child.set("visible", false)
			_hidden_scene_items.append(child)


func _restore_game_scene() -> void:
	for item in _hidden_scene_items:
		if is_instance_valid(item):
			item.set("visible", true)
	_hidden_scene_items.clear()


# --- snapshots ---

# Los snapshots se decodifican al llegar y se guardan en un buffer. El cliente dibuja
# RENDER_DELAY_MS en el pasado (según el reloj del host), siempre entre dos snapshots
# conocidos: así el movimiento es suave aunque los paquetes lleguen con variaciones.
func _apply_snapshot(msg: Dictionary) -> void:
	var seq := int(msg.get("s", 0))
	if seq <= _last_seq and _last_seq - seq < 1000:
		return
	_last_seq = seq
	var raw: PoolByteArray = msg.b
	raw = raw.decompress(int(msg.n), File.COMPRESSION_DEFLATE)
	if raw.size() != int(msg.n):
		_log("Snapshot %d corrupto" % seq)
		return
	var buf := StreamPeerBuffer.new()
	buf.big_endian = false
	buf.data_array = raw
	var host_t := buf.get_u32()
	var state := {"t": host_t, "cam": Vector2(buf.get_float(), buf.get_float()), "zoom": buf.get_float(),
			"ents": [], "pos": {}, "spr": {}, "fx": msg.get("fx", [])}
	var entity_count := buf.get_u16()
	for _e in entity_count:
		var key := buf.get_u32()
		var layer := buf.get_u8()
		var pos := Vector2(buf.get_float(), buf.get_float())
		var sprite_count := buf.get_u8()
		var sprites := []
		for _si in sprite_count:
			var sp := [buf.get_u16(), buf.get_16(), buf.get_16(), buf.get_16(), buf.get_16(), buf.get_16(),
					buf.get_u16(), buf.get_16(), buf.get_u8(), Color.white]
			if sp[8] & Protocol.FLAG_MODULATE:
				sp[9] = Color8(buf.get_u8(), buf.get_u8(), buf.get_u8(), buf.get_u8())
			sprites.append(sp)
		state.ents.append([key, layer, pos, sprites])
		state.pos[key] = pos
		state.spr[key] = sprites
	# Diferencia de relojes: se toma el mínimo observado (el paquete más rápido) y se
	# deja derivar lentamente hacia arriba por si los relojes se separan.
	var offset: int = OS.get_ticks_msec() - host_t
	if _clock_offset == null or offset < _clock_offset:
		_clock_offset = offset
	else:
		_clock_offset += 1 if offset > _clock_offset + 5 else 0
	_reconcile(msg.get("me", {}), state)
	_queue.append(state)
	if _queue.size() > 30:
		_queue.pop_front()
	_snap_count += 1
	if _snap_count == 1:
		_log("Primer snapshot: %d entidades, %d defs conocidas" % [entity_count, _defs.size()])


# Aplica lo visual de un snapshot (entidades, sprites, partículas). Las posiciones
# las interpola _process.
func _apply_state(state: Dictionary) -> void:
	_camera.zoom = Vector2(state.zoom, state.zoom)
	var seen := {}
	for e in state.ents:
		var key = e[0]
		var ent = _entities.get(key)
		if ent == null or not is_instance_valid(ent.node):
			var node := Node2D.new()
			_layers[min(e[1], _layers.size() - 1)].add_child(node)
			node.position = e[2]
			ent = {"node": node, "sprites": [], "defs": []}
			_entities[key] = ent
		seen[key] = true
		var sprites: Array = e[3]
		_sync_sprite_count(ent, sprites.size())
		for si in sprites.size():
			var sp: Array = sprites[si]
			var s: Sprite = ent.sprites[si]
			if ent.defs[si] != sp[0]:
				if not _configure_sprite(s, sp[0]):
					s.visible = false
					continue
				ent.defs[si] = sp[0]
			s.visible = true
			s.position = Vector2(sp[1], sp[2])
			s.rotation = sp[3] / Protocol.ROT_SCALE
			s.scale = Vector2(sp[4] / Protocol.SCALE_SCALE, sp[5] / Protocol.SCALE_SCALE)
			s.frame = int(min(sp[6], s.hframes * s.vframes - 1))
			s.z_index = sp[7]
			s.flip_h = (sp[8] & Protocol.FLAG_FLIP_H) != 0
			s.flip_v = (sp[8] & Protocol.FLAG_FLIP_V) != 0
			s.modulate = sp[9]
	for key in _entities.keys():
		if not seen.has(key):
			var gone = _entities[key]
			if is_instance_valid(gone.node):
				gone.node.queue_free()
			_entities.erase(key)
	for fx in state.fx:
		_play_fx(fx)


# Armas girando, animación de "rebote" del cuerpo, etc.: transformaciones locales de
# los sprites interpoladas entre A y B (solo si el sprite no cambió de textura).
func _interpolate_sprites(ent: Dictionary, sa, sb, alpha: float) -> void:
	if sa == null or sb == null or sa.size() != sb.size() or sa.size() != ent.sprites.size():
		return
	for si in sa.size():
		var x: Array = sa[si]
		var y: Array = sb[si]
		if x[0] != y[0]:
			continue
		var s: Sprite = ent.sprites[si]
		s.position = Vector2(lerp(x[1], y[1], alpha), lerp(x[2], y[2], alpha))
		s.rotation = lerp_angle(x[3] / Protocol.ROT_SCALE, y[3] / Protocol.ROT_SCALE, alpha)
		s.scale = Vector2(lerp(x[4], y[4], alpha), lerp(x[5], y[5], alpha)) / Protocol.SCALE_SCALE


# --- predicción del jugador propio ---

# Con cada snapshot: partir de la posición real del host y re-simular los inputs que
# el host todavía no había recibido. La diferencia con lo que se venía mostrando se
# guarda como error y se desvanece de a poco (sin saltos visibles).
func _reconcile(me: Dictionary, state: Dictionary) -> void:
	if session == null or input_client == null:
		return
	var info = me.get(session.my_id)
	if info == null or not state.pos.has(info[0]):
		_own_key = null
		_pred_pos = null
		return
	if _own_key != info[0]:
		_log("Predicción activa: entidad %d, velocidad %.0f" % [info[0], float(info[1])])
	_own_key = info[0]
	_own_speed = float(info[1])
	var ack := int(info[2])
	var history: Array = input_client.history
	while not history.empty() and history[0][0] <= ack:
		history.pop_front()
	var pos: Vector2 = state.pos[_own_key]
	for h in history:
		pos += h[1].normalized() * _own_speed * h[2]
	pos = _clamp_to_map(pos)
	if _pred_pos != null:
		var shown: Vector2 = _pred_pos + _pred_error
		_pred_error = shown - pos
		if _pred_error.length() > PRED_SNAP_DISTANCE:
			_pred_error = Vector2.ZERO
	_pred_pos = pos


func _predict(delta: float) -> void:
	if _own_key == null or _pred_pos == null or not _entities.has(_own_key):
		return
	_pred_pos = _clamp_to_map(_pred_pos + input_client.current_move.normalized() * _own_speed * delta)
	_pred_error *= max(0.0, 1.0 - PRED_ERROR_DECAY * delta)
	_entities[_own_key].node.position = _pred_pos + _pred_error


func _clamp_to_map(p: Vector2) -> Vector2:
	if _map_rect.size == Vector2.ZERO:
		return p
	return Vector2(clamp(p.x, _map_rect.position.x, _map_rect.end.x), clamp(p.y, _map_rect.position.y, _map_rect.end.y))


# Reproduce localmente una emisión de partículas del host (sangre, etc.).
func _play_fx(fx: Array) -> void:
	var path: String = fx[0]
	if not _fx_scenes.has(path):
		_fx_scenes[path] = load(path) if ResourceLoader.exists(path) else null
	var scene = _fx_scenes[path]
	if scene == null or _layers.size() <= 6:
		return
	var node = scene.instance()
	if not (node is CPUParticles2D or node is Particles2D):
		node.queue_free()
		return
	_layers[6].add_child(node)  # capa "Effects"
	node.global_position = fx[1]
	node.global_rotation = fx[2]
	node.global_scale = fx[4]
	node.amount = max(1, int(fx[3]))
	node.one_shot = true
	node.restart()
	var life: float = node.lifetime / max(0.01, node.speed_scale) + 0.5
	get_tree().create_timer(life, true).connect("timeout", node, "queue_free")


func _sync_sprite_count(ent: Dictionary, count: int) -> void:
	while ent.sprites.size() < count:
		var s := Sprite.new()
		s.visible = false
		ent.node.add_child(s)
		ent.sprites.append(s)
		ent.defs.append(-1)
	while ent.sprites.size() > count:
		var s = ent.sprites.pop_back()
		ent.defs.pop_back()
		if is_instance_valid(s):
			s.queue_free()


func _configure_sprite(s: Sprite, def_id: int) -> bool:
	var def = _defs.get(def_id)
	if def == null:
		return false
	var tex = _texture(def.tex)
	if tex == null:
		return false
	s.texture = tex
	s.hframes = max(1, int(def.hf))
	s.vframes = max(1, int(def.vf))
	s.region_enabled = def.re
	s.region_rect = def.rr
	s.centered = def.c
	s.offset = def.o
	return true


func _texture(path: String):
	if path == "":
		return null
	if not _textures.has(path):
		var res = load(path) if ResourceLoader.exists(path) else null
		_textures[path] = res if res is Texture else null
		if _textures[path] == null:
			_log("No se pudo cargar la textura %s" % path)
	return _textures[path]


func _process(_delta: float) -> void:
	if not active or _queue.empty():
		return
	var render_t: float = OS.get_ticks_msec() - _clock_offset - RENDER_DELAY_MS
	# A = último snapshot con t <= render_t; B = el siguiente (para interpolar).
	var ai := 0
	while ai + 1 < _queue.size() and _queue[ai + 1].t <= render_t:
		ai += 1
	var a: Dictionary = _queue[ai]
	if a != _applied:
		_applied = a
		_apply_state(a)
	while ai > 0:
		_queue.pop_front()  # los anteriores a A ya no se necesitan
		ai -= 1
	var b = _queue[1] if _queue.size() > 1 else null
	var alpha := 0.0
	if b != null and b.t > a.t:
		alpha = clamp((render_t - a.t) / float(b.t - a.t), 0.0, 1.0)
	_camera.position = a.cam.linear_interpolate(b.cam, alpha) if b != null else a.cam
	for key in _entities:
		var ent = _entities[key]
		var pa = a.pos.get(key)
		if pa == null:
			continue
		var pb = b.pos.get(key, pa) if b != null else pa
		if key != _own_key or _pred_pos == null:  # el propio lo ubica _predict
			ent.node.position = pa.linear_interpolate(pb, alpha)
		if b != null:
			_interpolate_sprites(ent, a.spr.get(key), b.spr.get(key), alpha)
	_predict(_delta)


func _log(text: String) -> void:
	if logger:
		logger.info("[viewer] " + text)
