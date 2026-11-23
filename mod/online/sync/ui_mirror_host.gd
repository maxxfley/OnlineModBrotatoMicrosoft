extends Node
# Host: "espejo de interfaz". Recorre los Control visibles de la escena actual
# (menús, tienda, mejoras, HUD de la oleada) y envía a los clientes una descripción
# de cada uno (tipo, rectángulo en pantalla, texto, texturas, estilos, fuentes).
# Los recursos (texturas, fuentes, StyleBox) se describen una sola vez: por ruta
# si son archivos, o por sus propiedades si están embebidos en una escena/tema.
# Solo se envían los controles que cambiaron (mensajes confiables y ordenados).
#
# Reemplaza a la transmisión de pantalla por imagen: leer el viewport hace
# crashear al motor de Seaven.

const Protocol = preload("res://online_mod/net/protocol.gd")

const HZ := 30.0
const WAVE_SCENE := "res://main.tscn"

# Propiedades que se copian de recursos embebidos (sin archivo propio).
const RES_PROPS := {
	"AtlasTexture": ["atlas", "region", "margin", "filter_clip"],
	"StyleBoxEmpty": ["content_margin_left", "content_margin_top", "content_margin_right", "content_margin_bottom"],
	"StyleBoxFlat": ["bg_color", "draw_center", "skew",
		"border_width_left", "border_width_top", "border_width_right", "border_width_bottom",
		"border_color", "border_blend",
		"corner_radius_top_left", "corner_radius_top_right", "corner_radius_bottom_right", "corner_radius_bottom_left",
		"corner_detail", "expand_margin_left", "expand_margin_top", "expand_margin_right", "expand_margin_bottom",
		"shadow_color", "shadow_size", "shadow_offset", "anti_aliasing", "anti_aliasing_size",
		"content_margin_left", "content_margin_top", "content_margin_right", "content_margin_bottom"],
	"StyleBoxTexture": ["texture", "normal_map", "region_rect", "margin_left", "margin_top", "margin_right", "margin_bottom",
		"expand_margin_left", "expand_margin_top", "expand_margin_right", "expand_margin_bottom",
		"axis_stretch_horizontal", "axis_stretch_vertical", "draw_center", "modulate_color",
		"content_margin_left", "content_margin_top", "content_margin_right", "content_margin_bottom"],
	"StyleBoxLine": ["color", "grow_begin", "grow_end", "thickness", "vertical",
		"content_margin_left", "content_margin_top", "content_margin_right", "content_margin_bottom"],
	"Shader": ["code"],
	"DynamicFont": ["font_data", "size", "outline_size", "outline_color", "use_mipmaps", "use_filter",
		"extra_spacing_top", "extra_spacing_bottom", "extra_spacing_char", "extra_spacing_space"],
}

# draw mode de BaseButton → nombres de estilo/color del tema
const BUTTON_STYLES := ["normal", "pressed", "hover", "disabled", "pressed"]
const BUTTON_COLORS := ["font_color", "font_color_pressed", "font_color_hover", "font_color_disabled", "font_color_pressed"]

var session = null
var logger = null

var _timer := 0.0
var _force_full := true
var _sent := {}        # key → hash de la última descripción enviada
var _order_hash := 0
var _res_ids := {}     # instance_id del recurso → id
var _res_count := 0
var _new_defs := []
var _stats_time := 0.0
var _stats_bytes := 0


func _ready() -> void:
	pause_mode = Node.PAUSE_MODE_PROCESS


func on_peer_joined(_peer_id: int, _peer_name: String) -> void:
	_force_full = true


func _process(delta: float) -> void:
	if session == null or not session.is_host() or session.ready_peer_count() == 0:
		_force_full = true
		return
	_stats_time += delta
	if _stats_time >= 10.0:
		_log("Interfaz: %.1f KB/s, %d controles, %d recursos" % [_stats_bytes / 1024.0 / _stats_time, _sent.size(), _res_count])
		_stats_time = 0.0
		_stats_bytes = 0
	_timer -= delta
	if _timer > 0.0:
		return
	_timer = 1.0 / HZ
	_send_update()


func _send_update() -> void:
	var scene = get_tree().current_scene
	if scene == null:
		return
	var in_wave: bool = scene.filename == WAVE_SCENE
	var full := _force_full
	if full:
		# Un cliente nuevo no conoce nada: se reenvían recursos y controles.
		_force_full = false
		_sent.clear()
		_res_ids.clear()
		_res_count = 0
		_order_hash = 0
	_new_defs = []

	var by_layer := {}
	_walk(scene, 0, false, in_wave, by_layer)
	if in_wave:
		# Números de daño y textos flotantes: son Label en el mundo (no en una capa de
		# interfaz). Se envían en coordenadas de pantalla, encima de la oleada.
		var texts = scene.get_node_or_null("FloatingTexts")
		if texts:
			_walk(texts, -1, true, in_wave, by_layer)
	var layers := by_layer.keys()
	layers.sort()

	var order := []
	var updates := []
	var seen := {}
	for layer in layers:
		for entry in by_layer[layer]:
			var key = entry[0]
			order.append(key)
			seen[key] = true
			var h: int = hash(var2bytes(entry))
			if _sent.get(key, 0) != h:
				_sent[key] = h
				updates.append(entry)
	var removed := []
	for key in _sent.keys():
		if not seen.has(key):
			_sent.erase(key)
			removed.append(key)
	var order_hash: int = hash(var2bytes(order))
	var order_changed := order_hash != _order_hash
	_order_hash = order_hash

	if not full and updates.empty() and removed.empty() and not order_changed and _new_defs.empty():
		return
	var payload := {"full": full, "w": in_wave, "defs": _new_defs, "upd": updates, "rm": removed}
	if order_changed or full:
		payload.order = order
	var raw := var2bytes(payload)
	var packed: PoolByteArray = raw.compress(File.COMPRESSION_DEFLATE)
	session.broadcast(Protocol.CH_UI, true, {"t": Protocol.UI_MIRROR, "n": raw.size(), "b": packed})
	_stats_bytes += packed.size()
	if full:
		_log("Interfaz completa enviada: %d controles, %d recursos, %d KB" % [order.size(), _new_defs.size(), packed.size() / 1024])


# --- recorrido ---

func _walk(node: Node, layer: int, in_layer: bool, in_wave: bool, out: Dictionary) -> void:
	for child in node.get_children():
		if child is Viewport:
			continue
		if child is CanvasLayer:
			# Fondo (capas negativas) y capas que siguen la cámara son del mundo.
			if child.layer < 0 or child.follow_viewport_enable or child.get("visible") == false:
				continue
			_walk(child, child.layer, true, in_wave, out)
			continue
		if child is CanvasItem:
			if not child.visible:
				continue
			if child is Control and (in_layer or not in_wave):
				var entry = _describe(child)
				if entry != null:
					if not out.has(layer):
						out[layer] = []
					out[layer].append(entry)
		if child.get_child_count() > 0:
			_walk(child, layer, in_layer, in_wave, out)


func _describe(c: Control):
	var type := ""
	var p := {}
	if c is TextureButton:
		type = "TextureButton"
		var mode: int = c.get_draw_mode()
		var tex: Texture = c.texture_normal
		if mode == BaseButton.DRAW_DISABLED and c.texture_disabled:
			tex = c.texture_disabled
		elif (mode == BaseButton.DRAW_PRESSED or mode == BaseButton.DRAW_HOVER_PRESSED) and c.texture_pressed:
			tex = c.texture_pressed
		elif mode == BaseButton.DRAW_HOVER and c.texture_hover:
			tex = c.texture_hover
		p = {"t": _res(tex), "fo": _res(c.texture_focused) if c.has_focus() else -1,
				"ex": c.expand, "sm": c.stretch_mode, "fh": c.flip_h, "fv": c.flip_v}
	elif c is Button:
		type = "Button"
		var mode: int = clamp(c.get_draw_mode(), 0, 4)
		p = {"tx": c.text, "ic": _res(c.icon), "f": _res(c.get_font("font")),
				"fc": c.get_color(BUTTON_COLORS[mode]), "sb": _res(c.get_stylebox(BUTTON_STYLES[mode])),
				"fs": _res(c.get_stylebox("focus")) if c.has_focus() else -1,
				"al": c.align, "fl": c.flat, "ei": c.expand_icon, "cl": c.clip_text}
	elif c is Label:
		type = "Label"
		p = {"tx": c.text, "al": c.align, "va": c.valign, "aw": c.autowrap, "cl": c.clip_text,
				"up": c.uppercase, "pv": c.percent_visible, "f": _res(c.get_font("font")),
				"fc": c.get_color("font_color"), "sc": c.get_color("font_color_shadow"),
				"om": c.get_color("font_outline_modulate"),
				"so": Vector2(c.get_constant("shadow_offset_x"), c.get_constant("shadow_offset_y")),
				"ls": c.get_constant("line_spacing"), "sb": _res(c.get_stylebox("normal"))}
	elif c is RichTextLabel:
		type = "RichTextLabel"
		p = {"tx": c.bbcode_text if c.bbcode_enabled else c.text, "bb": c.bbcode_enabled,
				"pv": c.percent_visible, "fn": _res(c.get_font("normal_font")), "fb": _res(c.get_font("bold_font")),
				"fi": _res(c.get_font("italics_font")), "fm": _res(c.get_font("mono_font")),
				"dc": c.get_color("default_color"), "sc": c.get_color("font_color_shadow"),
				"so": Vector2(c.get_constant("shadow_offset_x"), c.get_constant("shadow_offset_y")),
				"ls": c.get_constant("line_separation"), "sb": _res(c.get_stylebox("normal"))}
	elif c is TextureRect:
		type = "TextureRect"
		p = {"t": _res(c.texture), "ex": c.expand, "sm": c.stretch_mode, "fh": c.flip_h, "fv": c.flip_v}
	elif c is NinePatchRect:
		type = "NinePatchRect"
		p = {"t": _res(c.texture), "rr": c.region_rect, "dc": c.draw_center,
				"m": [c.patch_margin_left, c.patch_margin_top, c.patch_margin_right, c.patch_margin_bottom],
				"ah": c.axis_stretch_horizontal, "av": c.axis_stretch_vertical}
	elif c is ColorRect:
		type = "ColorRect"
		p = {"c": c.color}
	elif c is TextureProgress:
		type = "TextureProgress"
		p = {"u": _res(c.texture_under), "p": _res(c.texture_progress), "o": _res(c.texture_over),
				"r": c.ratio, "fm": c.fill_mode, "tu": c.tint_under, "tp": c.tint_progress, "to": c.tint_over,
				"np": c.nine_patch_stretch,
				"m": [c.stretch_margin_left, c.stretch_margin_top, c.stretch_margin_right, c.stretch_margin_bottom]}
	elif c is ProgressBar:
		type = "ProgressBar"
		p = {"bg": _res(c.get_stylebox("bg")), "fg": _res(c.get_stylebox("fg")), "r": c.ratio}
	elif c is PanelContainer or c is Panel:
		type = "Panel"
		p = {"sb": _res(c.get_stylebox("panel"))}
	else:
		return null
	# Materiales con shader (p. ej. el viñeteado de daño: un ColorRect blanco que el
	# shader vuelve transparente). Sin copiarlos, el cliente lo vería opaco.
	if c.material is ShaderMaterial and c.material.shader:
		p.sh = _res(c.material.shader)
		if p.sh < 0:
			return null  # efecto que no se puede reproducir: mejor no mostrarlo
		p.sp = _shader_params(c.material)
	var t: Transform2D = c.get_global_transform_with_canvas()
	return [c.get_instance_id(), type, t.origin, t.get_rotation(), t.get_scale(), c.rect_size, _modulate(c), p]


func _shader_params(m: ShaderMaterial) -> Dictionary:
	var out := {}
	for info in VisualServer.shader_get_param_list(m.shader.get_rid()):
		var pname: String = info.name
		var v = m.get_shader_param(pname)
		if v is Resource:
			v = ["__r", _res(v)]
		out[pname] = v
	return out


func _modulate(c: CanvasItem) -> Color:
	var col: Color = c.self_modulate
	var n = c
	while n != null and n is CanvasItem:
		col *= n.modulate
		n = n.get_parent()
	return col


# --- recursos ---

# Devuelve el id del recurso (-1 si no hay o no se puede describir) y, si es nuevo,
# agrega su descripción a _new_defs (los recursos anidados van antes).
func _res(r) -> int:
	if r == null or not r is Resource:
		return -1
	var iid: int = r.get_instance_id()
	if _res_ids.has(iid):
		return _res_ids[iid]
	var def = null
	var path: String = r.resource_path
	if path != "" and path.find("::") == -1:
		def = {"p": path}
	elif r is Shader and path.find("::") != -1 and path.find(".tscn::") == -1:
		# Shader embebido en un recurso (p. ej. un ShaderMaterial .tres): en el motor de
		# Seaven los shaders vienen precompilados (sin código), así que el cliente carga
		# el recurso contenedor y usa su shader.
		def = {"sub": path.split("::")[0]}
	else:
		var cls: String = r.get_class()
		if r is Shader:
			cls = "Shader"  # el motor de Seaven podría usar una subclase propia
		if RES_PROPS.has(cls):
			var props := {}
			for name_ in RES_PROPS[cls]:
				var v = r.get(name_)
				if v is Resource:
					props[name_] = ["__r", _res(v)]
				else:
					props[name_] = v
			def = {"k": cls, "pr": props}
	var id := -1
	if r is Shader:
		_log("Shader %s: clase %s, %d caracteres, %s" % [path, r.get_class(), str(r.code).length(),
				"se envía" if def != null else "NO se puede enviar"])
	if def != null:
		id = _res_count
		_res_count += 1
		_new_defs.append([id, def])
	_res_ids[iid] = id
	return id


func _log(text: String) -> void:
	if logger:
		logger.info("[ui-host] " + text)
