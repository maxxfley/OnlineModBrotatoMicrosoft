extends Node
# Host: transmite a los clientes lo que se ve en la oleada.
#
# No conoce los tipos de entidad del juego: recorre las capas de dibujo de la escena
# de oleada (Entities, Materials, proyectiles...) y por cada entidad envía sus Sprite /
# AnimatedSprite visibles (textura, frame, transformación relativa, modulate).
# Las texturas se describen una sola vez ("defs", confiable) y los snapshots solo
# llevan ids (no confiable, comprimido) a SNAPSHOT_HZ.

const Protocol = preload("res://online_mod/net/protocol.gd")

const WAVE_SCENE := "res://main.tscn"
const SNAPSHOT_HZ := 20.0
const SPRITE_CACHE_MS := 1000  # cada cuánto se vuelve a buscar sprites dentro de una entidad
const MAX_SPRITES_PER_ENTITY := 255

var session = null
var logger = null

var _scene: Node = null
var _in_wave := false
var _wave_start_msg := {}
var _timer := 0.0
var _seq := 0
var _defs := {}          # firma → id
var _def_list := []      # [[id, def], ...] para clientes nuevos
var _pending_defs := []
var _sprite_cache := {}  # entidad instance_id → {t: ms, sprites: [nodos]}
var _stats_timer := 0.0
var _bytes_sent := 0


func _ready() -> void:
	pause_mode = Node.PAUSE_MODE_PROCESS


func on_peer_joined(peer_id: int, _peer_name: String) -> void:
	if not _def_list.empty():
		session.send_to_peer(peer_id, Protocol.CH_CONTROL, true, {"t": Protocol.DEFS, "list": _def_list})
	if _in_wave and not _wave_start_msg.empty():
		session.send_to_peer(peer_id, Protocol.CH_CONTROL, true, _wave_start_msg)


func _process(delta: float) -> void:
	if session == null or not session.is_host():
		if _in_wave:
			_in_wave = false
		return
	var scene = get_tree().current_scene
	var is_wave: bool = scene != null and scene.filename == WAVE_SCENE
	if is_wave and (not _in_wave or scene != _scene):
		_scene = scene
		_in_wave = true
		_sprite_cache.clear()
		call_deferred("_send_wave_start")
	elif not is_wave and _in_wave:
		_in_wave = false
		_scene = null
		_wave_start_msg = {}
		session.broadcast(Protocol.CH_CONTROL, true, {"t": Protocol.WAVE_END})
		_log("Fin de oleada enviado")
	if not _in_wave or session.ready_peer_count() == 0 or _wave_start_msg.empty():
		return
	_timer -= delta
	if _timer > 0.0:
		return
	_timer = 1.0 / SNAPSHOT_HZ
	_send_snapshot()
	_stats_timer += 1.0 / SNAPSHOT_HZ
	if _stats_timer >= 10.0:
		_log("Snapshots: %.1f KB/s por cliente, %d defs" % [_bytes_sent / 1024.0 / _stats_timer, _def_list.size()])
		_stats_timer = 0.0
		_bytes_sent = 0


# --- inicio de oleada: mapa ---

func _send_wave_start() -> void:
	if not is_instance_valid(_scene):
		return
	var tile_map = _scene.get_node_or_null("TileMap")
	if tile_map == null or not tile_map is TileMap:
		_log("Escena de oleada sin TileMap")
		return
	var cells := PoolIntArray()
	for c in tile_map.get_used_cells():
		var ac: Vector2 = tile_map.get_cell_autotile_coord(int(c.x), int(c.y))
		cells.append(int(c.x))
		cells.append(int(c.y))
		cells.append(int(ac.x) | (int(ac.y) << 16))
	var tex = tile_map.tile_set.tile_get_texture(0)
	var msg := {
		"t": Protocol.WAVE_START,
		"tiles": tex.resource_path if tex else "",
		"cells": cells,
		"outline_mod": Color.white,
		"outline_rect": Rect2(),
		"bg_colors": PoolColorArray(),
		"bg_offsets": PoolRealArray(),
		"wave": _run_data_value("current_wave", 0),
	}
	var outline = tile_map.get_node_or_null("Outline")
	if outline is Control:
		msg.outline_mod = outline.modulate
		msg.outline_rect = Rect2(outline.rect_position, outline.rect_size)
	var bg = _scene.get_node_or_null("CanvasLayer/Background")
	if bg is TextureRect and bg.texture is GradientTexture and bg.texture.gradient:
		msg.bg_colors = bg.texture.gradient.colors
		msg.bg_offsets = bg.texture.gradient.offsets
	_wave_start_msg = msg
	session.broadcast(Protocol.CH_CONTROL, true, msg)
	_log("Inicio de oleada %s enviado (%d celdas, tiles %s)" % [str(msg.wave), cells.size() / 3, msg.tiles])


# --- snapshots ---

func _send_snapshot() -> void:
	if not is_instance_valid(_scene):
		return
	var buf := StreamPeerBuffer.new()
	buf.big_endian = false
	buf.put_u32(OS.get_ticks_msec())
	var cam = _scene.get_node_or_null("Camera")
	if cam is Camera2D:
		var center: Vector2 = cam.get_camera_screen_center()
		buf.put_float(center.x)
		buf.put_float(center.y)
		buf.put_float(cam.zoom.x)
	else:
		buf.put_float(0.0)
		buf.put_float(0.0)
		buf.put_float(1.0)
	var count_pos := buf.get_position()
	buf.put_u16(0)
	var entity_count := 0
	var now := OS.get_ticks_msec()
	var live := {}
	for li in Protocol.LAYERS.size():
		var layer = _scene.get_node_or_null(Protocol.LAYERS[li])
		if layer == null:
			continue
		for entity in layer.get_children():
			if not entity is Node2D or not entity.is_visible_in_tree():
				continue
			var sprites := _entity_sprites(entity, now)
			live[entity.get_instance_id()] = true
			if sprites.empty():
				continue
			if _write_entity(buf, entity, li, sprites) and entity_count < 65535:
				entity_count += 1
	for key in _sprite_cache.keys():
		if not live.has(key):
			_sprite_cache.erase(key)
	var end := buf.get_position()
	buf.seek(count_pos)
	buf.put_u16(entity_count)
	buf.seek(end)

	if not _pending_defs.empty():
		session.broadcast(Protocol.CH_CONTROL, true, {"t": Protocol.DEFS, "list": _pending_defs})
		_pending_defs = []

	var raw: PoolByteArray = buf.data_array
	_seq += 1
	var msg := {"t": Protocol.SNAP, "s": _seq, "n": raw.size(), "b": raw.compress(File.COMPRESSION_DEFLATE), "hud": _hud()}
	_bytes_sent += msg.b.size()
	session.broadcast(Protocol.CH_SNAPSHOT, false, msg)


func _entity_sprites(entity: Node2D, now: int) -> Array:
	var key := entity.get_instance_id()
	var cached = _sprite_cache.get(key)
	if cached == null or now - cached.t > SPRITE_CACHE_MS:
		var found := []
		_collect_sprites(entity, found)
		cached = {"t": now, "sprites": found}
		_sprite_cache[key] = cached
	return cached.sprites


func _collect_sprites(node: Node, out: Array) -> void:
	for child in node.get_children():
		if child is CanvasLayer or child is Viewport:
			continue
		if child is Sprite or child is AnimatedSprite:
			out.append(child)
		if child.get_child_count() > 0:
			_collect_sprites(child, out)


func _write_entity(buf: StreamPeerBuffer, entity: Node2D, layer: int, sprites: Array) -> bool:
	var inv: Transform2D = entity.get_global_transform().affine_inverse()
	var records := []
	for s in sprites:
		if not is_instance_valid(s) or not s.is_visible_in_tree():
			continue
		var info := _sprite_def(s)
		if info.empty():
			continue
		records.append([s, info])
		if records.size() >= MAX_SPRITES_PER_ENTITY:
			break
	if records.empty():
		return false
	var pos: Vector2 = entity.global_position
	buf.put_u32(entity.get_instance_id() & 0xFFFFFFFF)
	buf.put_u8(layer)
	buf.put_float(pos.x)
	buf.put_float(pos.y)
	buf.put_u8(records.size())
	for r in records:
		var s = r[0]
		var info: Dictionary = r[1]
		var t: Transform2D = inv * s.get_global_transform()
		var sc: Vector2 = t.get_scale()
		var flags := 0
		if s.flip_h:
			flags |= Protocol.FLAG_FLIP_H
		if s.flip_v:
			flags |= Protocol.FLAG_FLIP_V
		var mod := _effective_modulate(s, entity)
		var has_mod := not mod.is_equal_approx(Color.white)
		if has_mod:
			flags |= Protocol.FLAG_MODULATE
		buf.put_u16(info.id)
		buf.put_16(int(clamp(round(t.origin.x), -32768, 32767)))
		buf.put_16(int(clamp(round(t.origin.y), -32768, 32767)))
		buf.put_16(int(clamp(round(t.get_rotation() * Protocol.ROT_SCALE), -32768, 32767)))
		buf.put_16(int(clamp(round(sc.x * Protocol.SCALE_SCALE), -32768, 32767)))
		buf.put_16(int(clamp(round(sc.y * Protocol.SCALE_SCALE), -32768, 32767)))
		buf.put_u16(info.frame)
		buf.put_16(int(clamp(s.z_index, -32768, 32767)))
		buf.put_u8(flags)
		if has_mod:
			buf.put_u8(int(clamp(mod.r, 0.0, 1.0) * 255.0))
			buf.put_u8(int(clamp(mod.g, 0.0, 1.0) * 255.0))
			buf.put_u8(int(clamp(mod.b, 0.0, 1.0) * 255.0))
			buf.put_u8(int(clamp(mod.a, 0.0, 1.0) * 255.0))
	return true


# Devuelve {id, frame} del sprite o {} si no se puede describir (textura sin ruta).
func _sprite_def(s) -> Dictionary:
	var tex: Texture = null
	var frame := 0
	var def := {}
	if s is Sprite:
		tex = s.texture
		frame = s.frame
		def = {"hf": s.hframes, "vf": s.vframes, "re": s.region_enabled, "rr": s.region_rect,
				"c": s.centered, "o": s.offset}
	else:
		if s.frames == null:
			return {}
		tex = s.frames.get_frame(s.animation, s.frame)
		def = {"hf": 1, "vf": 1, "re": false, "rr": Rect2(), "c": s.centered, "o": s.offset}
	if tex == null:
		return {}
	var path := tex.resource_path
	if path == "" or path.find("::") != -1:
		return {}
	def.tex = path
	var sig := "%s|%d|%d|%s|%s|%s|%s" % [path, def.hf, def.vf, str(def.re), str(def.rr), str(def.c), str(def.o)]
	var id = _defs.get(sig)
	if id == null:
		id = _def_list.size()
		if id > 65535:
			return {}
		_defs[sig] = id
		_def_list.append([id, def])
		_pending_defs.append([id, def])
	return {"id": id, "frame": frame}


func _effective_modulate(node: CanvasItem, root: Node) -> Color:
	var c: Color = node.self_modulate
	var n = node
	while n != null and n is CanvasItem:
		c *= n.modulate
		if n == root:
			break
		n = n.get_parent()
	return c


# --- HUD ---

func _hud() -> Dictionary:
	var hud := {"players": []}
	var wave_timer = _scene.get_node_or_null("WaveTimer")
	if wave_timer is Timer:
		hud.time = int(ceil(wave_timer.time_left))
	hud.wave = _run_data_value("current_wave", 0)
	var rd = get_node_or_null("/root/RunData")
	var players = _scene.get("_players")
	if rd == null or typeof(players) != TYPE_ARRAY:
		return hud
	for i in players.size():
		var p = players[i]
		var entry := {"hp": 0, "mhp": 1, "lvl": 0, "xp": 0.0, "xpn": 1.0, "gold": 0}
		if is_instance_valid(p) and p.get("current_stats") != null:
			entry.hp = int(p.current_stats.health)
			entry.mhp = max(1, int(p.max_stats.health))
		entry.lvl = rd.get_player_level(i)
		entry.xp = rd.get_player_xp(i)
		entry.xpn = rd.get_next_level_xp_needed(i)
		entry.gold = rd.get_player_gold(i)
		hud.players.append(entry)
	return hud


func _run_data_value(prop: String, default):
	var rd = get_node_or_null("/root/RunData")
	if rd == null:
		return default
	var v = rd.get(prop)
	return default if v == null else v


func _log(text: String) -> void:
	if logger:
		logger.info("[sync-host] " + text)
