extends CanvasLayer
# Cliente: reconstruye la interfaz del host (ver ui_mirror_host.gd) con los
# recursos del juego local. Todos los controles son hijos directos de una raíz a
# pantalla completa, ordenados como en el host (capa, luego orden del árbol).

const Protocol = preload("res://online_mod/net/protocol.gd")

signal showing_changed(showing)

var logger = null
var showing := false

var _root: Control
var _backdrop: ColorRect
var _nodes := {}     # key → {node, type}
var _res := {}       # id → Resource
var _have_state := false
var _msgs := 0
var _failed_shaders := {}
# Interpolación: cada control va de su transformación anterior a la nueva durante el
# intervalo entre actualizaciones, calculado en cada cuadro del cliente.
const UPDATE_INTERVAL_MS := 1000.0 / 60.0
const SNAP_DISTANCE := 300.0  # saltos grandes (cambio de pantalla) no se interpolan
var _animating := {}  # key → {from_pos, to_pos, from_scale, to_scale, from_rot, to_rot, from_mod, to_mod}
var _last_update_ms := 0


func _ready() -> void:
	layer = 104
	pause_mode = Node.PAUSE_MODE_PROCESS
	_backdrop = ColorRect.new()
	_backdrop.color = Color.black
	_backdrop.anchor_right = 1.0
	_backdrop.anchor_bottom = 1.0
	_backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_backdrop.visible = false
	add_child(_backdrop)
	_root = Control.new()
	_root.anchor_right = 1.0
	_root.anchor_bottom = 1.0
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.visible = false
	add_child(_root)


func on_sync(msg: Dictionary) -> void:
	if msg.t != Protocol.UI_MIRROR:
		return
	var raw: PoolByteArray = msg.b
	raw = raw.decompress(int(msg.n), File.COMPRESSION_DEFLATE)
	var payload = bytes2var(raw)
	if typeof(payload) != TYPE_DICTIONARY:
		_log("Mensaje de interfaz inválido")
		return
	if payload.full:
		_clear()
		_have_state = true
	if not _have_state:
		return  # todavía no llegó el estado completo
	for d in payload.defs:
		_res[int(d[0])] = _build_res(d[1])
	for key in payload.rm:
		_remove(key)
	_finish_animations()
	for entry in payload.upd:
		_apply(entry)
	_last_update_ms = OS.get_ticks_msec()
	if payload.has("order"):
		var i := 0
		for key in payload.order:
			var n = _nodes.get(key)
			if n != null:
				_root.move_child(n.node, i)
				i += 1
	# En menús no hay mundo detrás: fondo negro. En la oleada se ve el visor.
	_backdrop.visible = not payload.w
	_msgs += 1
	if payload.full:
		var shaded := 0
		for key in _nodes:
			if _nodes[key].node.material is ShaderMaterial:
				shaded += 1
		_log("Interfaz del host: %d controles (%d con shader), %d recursos" % [_nodes.size(), shaded, _res.size()])
	_set_showing(true)


func _process(_delta: float) -> void:
	if _animating.empty():
		return
	var alpha: float = clamp((OS.get_ticks_msec() - _last_update_ms) / UPDATE_INTERVAL_MS, 0.0, 1.0)
	for key in _animating:
		_step(_animating[key], alpha)


func _step(a: Dictionary, alpha: float) -> void:
	var c = a.node
	if not is_instance_valid(c):
		return
	c.rect_position = a.from_pos.linear_interpolate(a.to_pos, alpha)
	c.rect_rotation = lerp(a.from_rot, a.to_rot, alpha)
	c.rect_scale = a.from_scale.linear_interpolate(a.to_scale, alpha)
	c.modulate = a.from_mod.linear_interpolate(a.to_mod, alpha)


# Antes de aplicar una actualización nueva, los controles que estaban en camino
# quedan en su destino (los que no cambian ya no se animan).
func _finish_animations() -> void:
	for key in _animating:
		_step(_animating[key], 1.0)
	_animating.clear()


func reset() -> void:
	_clear()
	_have_state = false
	_backdrop.visible = false
	_set_showing(false)


func _clear() -> void:
	_animating.clear()
	for key in _nodes:
		_nodes[key].node.queue_free()
	_nodes.clear()
	_res.clear()


func _set_showing(value: bool) -> void:
	_root.visible = value
	if value != showing:
		showing = value
		emit_signal("showing_changed", value)


# --- controles ---

func _remove(key) -> void:
	_animating.erase(key)
	var n = _nodes.get(key)
	if n != null:
		n.node.queue_free()
		_nodes.erase(key)


func _apply(e: Array) -> void:
	var key = e[0]
	var type: String = e[1]
	var n = _nodes.get(key)
	if n != null and n.type != type:
		_remove(key)
		n = null
	if n == null:
		var node := _create(type)
		if node == null:
			return
		node.mouse_filter = Control.MOUSE_FILTER_IGNORE
		node.focus_mode = Control.FOCUS_NONE
		_root.add_child(node)
		n = {"node": node, "type": type, "new": true}
		_nodes[key] = n
	var c: Control = n.node
	var to_pos: Vector2 = e[2]
	var to_rot: float = rad2deg(e[3])
	var to_scale: Vector2 = e[4]
	var to_mod: Color = e[6]
	c.rect_size = e[5]
	if n.has("new") or c.rect_position.distance_to(to_pos) > SNAP_DISTANCE:
		n.erase("new")
		_animating.erase(key)
		c.rect_position = to_pos
		c.rect_rotation = to_rot
		c.rect_scale = to_scale
		c.modulate = to_mod
	else:
		_animating[key] = {"node": c, "from_pos": c.rect_position, "to_pos": to_pos,
				"from_rot": c.rect_rotation, "to_rot": to_rot, "from_scale": c.rect_scale, "to_scale": to_scale,
				"from_mod": c.modulate, "to_mod": to_mod}
	var p: Dictionary = e[7]
	_apply_material(c, p)
	if type == "TextureRect":
		c.texture = _r(p.t)
		c.expand = p.ex
		c.stretch_mode = p.sm
		c.flip_h = p.fh
		c.flip_v = p.fv
	elif type == "TextureButton":
		c.texture = _r(p.t)
		c.expand = p.ex
		c.stretch_mode = p.sm
		c.flip_h = p.fh
		c.flip_v = p.fv
		var focus: TextureRect = c.get_child(0)
		focus.texture = _r(p.fo)
		focus.visible = focus.texture != null
		focus.expand = p.ex
		focus.stretch_mode = p.sm
	elif type == "Label":
		_font(c, "font", p.f)
		_style(c, "normal", p.sb)
		c.add_color_override("font_color", p.fc)
		c.add_color_override("font_color_shadow", p.sc)
		c.add_color_override("font_outline_modulate", p.om)
		c.add_constant_override("shadow_offset_x", int(p.so.x))
		c.add_constant_override("shadow_offset_y", int(p.so.y))
		c.add_constant_override("line_spacing", p.ls)
		c.align = p.al
		c.valign = p.va
		c.autowrap = p.aw
		c.clip_text = p.cl
		c.uppercase = p.up
		c.text = p.tx
		c.percent_visible = p.pv
	elif type == "RichTextLabel":
		_font(c, "normal_font", p.fn)
		_font(c, "bold_font", p.fb)
		_font(c, "italics_font", p.fi)
		_font(c, "mono_font", p.fm)
		_style(c, "normal", p.sb)
		c.add_color_override("default_color", p.dc)
		c.add_color_override("font_color_shadow", p.sc)
		c.add_constant_override("shadow_offset_x", int(p.so.x))
		c.add_constant_override("shadow_offset_y", int(p.so.y))
		c.add_constant_override("line_separation", p.ls)
		c.scroll_active = false
		c.bbcode_enabled = p.bb
		if p.bb:
			if c.bbcode_text != p.tx:
				c.bbcode_text = p.tx
		elif c.text != p.tx:
			c.text = p.tx
		c.percent_visible = p.pv
	elif type == "Button":
		_font(c, "font", p.f)
		var sb = _r(p.sb)
		for s in ["normal", "hover", "pressed", "disabled"]:
			if sb:
				c.add_stylebox_override(s, sb)
			else:
				c.add_stylebox_override(s, StyleBoxEmpty.new())
		var fs = _r(p.fs)
		c.add_stylebox_override("focus", fs if fs else StyleBoxEmpty.new())
		for col in ["font_color", "font_color_hover", "font_color_pressed", "font_color_disabled"]:
			c.add_color_override(col, p.fc)
		c.text = p.tx
		c.icon = _r(p.ic)
		c.align = p.al
		c.flat = p.fl
		c.expand_icon = p.ei
		c.clip_text = p.cl
	elif type == "NinePatchRect":
		c.texture = _r(p.t)
		c.region_rect = p.rr
		c.draw_center = p.dc
		c.patch_margin_left = p.m[0]
		c.patch_margin_top = p.m[1]
		c.patch_margin_right = p.m[2]
		c.patch_margin_bottom = p.m[3]
		c.axis_stretch_horizontal = p.ah
		c.axis_stretch_vertical = p.av
	elif type == "ColorRect":
		c.color = p.c
	elif type == "TextureProgress":
		c.texture_under = _r(p.u)
		c.texture_progress = _r(p.p)
		c.texture_over = _r(p.o)
		c.fill_mode = p.fm
		c.tint_under = p.tu
		c.tint_progress = p.tp
		c.tint_over = p.to
		c.nine_patch_stretch = p.np
		c.stretch_margin_left = p.m[0]
		c.stretch_margin_top = p.m[1]
		c.stretch_margin_right = p.m[2]
		c.stretch_margin_bottom = p.m[3]
		c.max_value = 1.0
		c.step = 0.0
		c.value = p.r
	elif type == "ProgressBar":
		_style(c, "bg", p.bg)
		_style(c, "fg", p.fg)
		c.percent_visible = false
		c.max_value = 1.0
		c.step = 0.0
		c.value = p.r
	elif type == "Panel":
		_style(c, "panel", p.sb)


func _apply_material(c: Control, p: Dictionary) -> void:
	var shader = _r(p.get("sh", -1))
	if not shader is Shader:
		if c.material != null:
			c.material = null
		return
	if not c.material is ShaderMaterial or c.material.shader != shader:
		var m := ShaderMaterial.new()
		m.shader = shader
		c.material = m
	var params: Dictionary = p.get("sp", {})
	# Si el shader recreado no compiló (no expone parámetros), se oculta el control:
	# sin el shader, por ejemplo, el viñeteado de daño es un rectángulo blanco opaco.
	if not params.empty() and VisualServer.shader_get_param_list(shader.get_rid()).empty():
		c.visible = false
		if not _failed_shaders.has(shader.get_instance_id()):
			_failed_shaders[shader.get_instance_id()] = true
			_log("Shader no compatible en el cliente; control oculto (%d parámetros esperados)" % params.size())
		return
	c.visible = true
	for pname in params:
		var v = params[pname]
		if typeof(v) == TYPE_ARRAY and v.size() == 2 and str(v[0]) == "__r":
			v = _r(v[1])
		c.material.set_shader_param(pname, v)


func _create(type: String) -> Control:
	if type == "TextureButton":
		var tr := TextureRect.new()
		var focus := TextureRect.new()
		focus.anchor_right = 1.0
		focus.anchor_bottom = 1.0
		focus.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tr.add_child(focus)
		return tr
	if type in ["TextureRect", "Label", "RichTextLabel", "Button", "NinePatchRect", "ColorRect",
			"TextureProgress", "ProgressBar", "Panel"]:
		return ClassDB.instance(type) as Control
	return null


func _font(c: Control, name_: String, id) -> void:
	var f = _r(id)
	if f is Font:
		c.add_font_override(name_, f)


func _style(c: Control, name_: String, id) -> void:
	var sb = _r(id)
	c.add_stylebox_override(name_, sb if sb is StyleBox else StyleBoxEmpty.new())


func _r(id):
	return _res.get(int(id)) if id != null and int(id) >= 0 else null


# --- recursos ---

func _build_res(def: Dictionary):
	if def.has("p"):
		var path: String = def.p
		if ResourceLoader.exists(path):
			return load(path)
		_log("Recurso no encontrado: %s" % path)
		return null
	if def.has("sub"):
		var base: String = def.sub
		var container = load(base) if ResourceLoader.exists(base) else null
		if container is ShaderMaterial:
			return container.shader
		if container is Shader:
			return container
		_log("No se pudo obtener el shader de %s" % base)
		return null
	if not def.has("k") or not ClassDB.can_instance(def.k):
		return null
	var r = ClassDB.instance(def.k)
	for name_ in def.pr:
		var v = def.pr[name_]
		if typeof(v) == TYPE_ARRAY and v.size() == 2 and str(v[0]) == "__r":
			v = _r(v[1])
			if v == null:
				continue
		r.set(name_, v)
	return r


func _log(text: String) -> void:
	if logger:
		logger.info("[ui] " + text)
