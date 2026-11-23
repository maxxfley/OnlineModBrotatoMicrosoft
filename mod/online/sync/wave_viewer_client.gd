extends Node2D
# Cliente: dibuja la oleada del host a partir de los mensajes de sincronización.
# No simula nada: crea Sprites con las mismas texturas del juego y los ubica según
# los snapshots, interpolando posiciones entre los dos últimos recibidos.

const Protocol = preload("res://online_mod/net/protocol.gd")

const GROUND_TILESET := "res://resources/tiles/ground_tiles.tres"
const OUTLINE_TEXTURE := "res://resources/tiles/tiles_outline.png"
const SNAPSHOT_INTERVAL := 1.0 / 20.0

signal viewing_changed(active)

var logger = null
var active := false

var _defs := {}            # id → def
var _textures := {}        # ruta → Texture (o null si falló)
var _world: Node2D
var _layers := []
var _camera: Camera2D
var _bg_layer: CanvasLayer
var _bg: TextureRect
var _hud_layer: CanvasLayer
var _hud_label: Label
var _entities := {}        # key → {node, sprites: [], defs: [], from, to}
var _cam_from := Vector2.ZERO
var _cam_to := Vector2.ZERO
var _last_snap_ms := 0
var _last_seq := 0
var _hidden_scene_items := []
var _snap_count := 0


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

	_hud_layer = CanvasLayer.new()
	_hud_layer.layer = 100
	add_child(_hud_layer)
	_hud_label = Label.new()
	_hud_label.rect_position = Vector2(20, 20)
	_hud_label.rect_scale = Vector2(2, 2)
	_hud_label.add_color_override("font_color_shadow", Color.black)
	_hud_layer.add_child(_hud_label)

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
	_layers = []
	for n in [_world, _bg_layer, _hud_layer]:
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
	buf.get_u32()  # tiempo del host (reservado)
	var cam := Vector2(buf.get_float(), buf.get_float())
	var zoom := buf.get_float()
	_cam_from = _camera.position if _snap_count > 0 else cam
	_cam_to = cam
	_camera.zoom = Vector2(zoom, zoom)

	var seen := {}
	var entity_count := buf.get_u16()
	for _e in entity_count:
		var key := buf.get_u32()
		var layer := buf.get_u8()
		var pos := Vector2(buf.get_float(), buf.get_float())
		var sprite_count := buf.get_u8()
		var ent = _entities.get(key)
		if ent == null or not is_instance_valid(ent.node):
			var node := Node2D.new()
			_layers[min(layer, _layers.size() - 1)].add_child(node)
			node.position = pos
			ent = {"node": node, "sprites": [], "defs": [], "from": pos, "to": pos}
			_entities[key] = ent
		else:
			ent.from = ent.node.position
			ent.to = pos
		seen[key] = true
		_sync_sprite_count(ent, sprite_count)
		for si in sprite_count:
			var def_id := buf.get_u16()
			var lx := buf.get_16()
			var ly := buf.get_16()
			var rot := buf.get_16() / Protocol.ROT_SCALE
			var sx := buf.get_16() / Protocol.SCALE_SCALE
			var sy := buf.get_16() / Protocol.SCALE_SCALE
			var frame := buf.get_u16()
			var z := buf.get_16()
			var flags := buf.get_u8()
			var mod := Color.white
			if flags & Protocol.FLAG_MODULATE:
				mod = Color8(buf.get_u8(), buf.get_u8(), buf.get_u8(), buf.get_u8())
			var s: Sprite = ent.sprites[si]
			if ent.defs[si] != def_id:
				if not _configure_sprite(s, def_id):
					s.visible = false
					continue
				ent.defs[si] = def_id
			s.visible = true
			s.position = Vector2(lx, ly)
			s.rotation = rot
			s.scale = Vector2(sx, sy)
			s.frame = int(min(frame, s.hframes * s.vframes - 1))
			s.z_index = z
			s.flip_h = (flags & Protocol.FLAG_FLIP_H) != 0
			s.flip_v = (flags & Protocol.FLAG_FLIP_V) != 0
			s.modulate = mod
	for key in _entities.keys():
		if not seen.has(key):
			var gone = _entities[key]
			if is_instance_valid(gone.node):
				gone.node.queue_free()
			_entities.erase(key)
	_last_snap_ms = OS.get_ticks_msec()
	_snap_count += 1
	if _snap_count == 1:
		_log("Primer snapshot: %d entidades, %d defs conocidas" % [entity_count, _defs.size()])
	_update_hud(msg.get("hud", {}))


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
	if not active or _snap_count == 0:
		return
	var alpha: float = clamp((OS.get_ticks_msec() - _last_snap_ms) / 1000.0 / SNAPSHOT_INTERVAL, 0.0, 1.0)
	_camera.position = _cam_from.linear_interpolate(_cam_to, alpha)
	for key in _entities:
		var ent = _entities[key]
		ent.node.position = ent.from.linear_interpolate(ent.to, alpha)


# --- HUD (provisorio: texto) ---

func _update_hud(hud: Dictionary) -> void:
	var lines := []
	lines.append("Oleada %s   %ss" % [str(hud.get("wave", "?")), str(hud.get("time", "?"))])
	var players: Array = hud.get("players", [])
	for i in players.size():
		var p = players[i]
		lines.append("J%d  Vida %d/%d   Nv %d (%d/%d)   Materiales %d" % [
			i + 1, p.hp, p.mhp, p.lvl, int(p.xp), int(p.xpn), p.gold])
	_hud_label.text = PoolStringArray(lines).join("\n")


func _log(text: String) -> void:
	if logger:
		logger.info("[viewer] " + text)
