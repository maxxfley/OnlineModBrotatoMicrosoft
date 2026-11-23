extends CanvasLayer
# Panel del modo online (fase 1): hostear / unirse por IP:puerto, estado y ping.
# Se abre/cierra con F9 (detectado por polling en OnlineMod, porque las escenas
# del juego pueden consumir eventos de teclado en _input).

const Protocol = preload("res://online_mod/net/protocol.gd")

var session = null  # session.gd

var _panel: PanelContainer
var _ip_edit: LineEdit
var _port_edit: LineEdit
var _host_btn: Button
var _join_btn: Button
var _leave_btn: Button
var _status_label: Label
var _peers_label: Label
var _messages_label: Label
var _hint_label: Label
var _messages := []
var _ips_label: Label

const CONFIG_PATH := "user://online_mod.cfg"


func _ready() -> void:
	layer = 120
	_build()
	session.connect("state_changed", self, "_on_state_changed")
	session.connect("peers_changed", self, "_on_peers_changed")
	session.connect("message", self, "_on_message")
	_refresh()
	_panel.visible = false


func toggle() -> void:
	_panel.visible = not _panel.visible
	if _panel.visible:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		_refresh()


func is_open() -> bool:
	return _panel.visible


func _build() -> void:
	_hint_label = Label.new()
	_hint_label.rect_position = Vector2(12, 6)
	_hint_label.modulate = Color(1, 1, 1, 0.55)
	add_child(_hint_label)

	# Crédito del autor, arriba a la derecha.
	var credit := Label.new()
	credit.text = "by: maxxfley  github: maxxfley"
	credit.align = Label.ALIGN_RIGHT
	credit.anchor_left = 1.0
	credit.anchor_right = 1.0
	credit.margin_left = -500
	credit.margin_right = -12
	credit.margin_top = 2
	credit.modulate = Color(1, 1, 1, 0.55)
	credit.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(credit)

	_panel = PanelContainer.new()
	_panel.rect_position = Vector2(1440, 20)
	_panel.rect_min_size = Vector2(460, 0)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.08, 0.1, 0.92)
	style.set_corner_radius_all(6)
	style.content_margin_left = 14
	style.content_margin_right = 14
	style.content_margin_top = 10
	style.content_margin_bottom = 10
	_panel.add_stylebox_override("panel", style)
	add_child(_panel)

	var box := VBoxContainer.new()
	box.add_constant_override("separation", 8)
	_panel.add_child(box)

	var title := Label.new()
	title.text = "Brotato Online (F9 para cerrar)"
	box.add_child(title)

	var row := HBoxContainer.new()
	box.add_child(row)
	_ip_edit = LineEdit.new()
	_ip_edit.text = _load_setting("ip", "127.0.0.1")
	_ip_edit.placeholder_text = "IP del host"
	_ip_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_ip_edit)
	_port_edit = LineEdit.new()
	_port_edit.text = str(_load_setting("port", Protocol.DEFAULT_PORT))
	_port_edit.rect_min_size = Vector2(90, 0)
	row.add_child(_port_edit)

	var buttons := HBoxContainer.new()
	box.add_child(buttons)
	_host_btn = _make_button("Hostear", "_on_host_pressed", buttons)
	_join_btn = _make_button("Unirse", "_on_join_pressed", buttons)
	_leave_btn = _make_button("Desconectar", "_on_leave_pressed", buttons)

	_ips_label = Label.new()
	_ips_label.modulate = Color(1, 1, 1, 0.7)
	_ips_label.autowrap = true
	_ips_label.rect_min_size = Vector2(430, 0)
	_ips_label.text = "Tus IPs (pasale una a tus amigos): " + _local_ips()
	box.add_child(_ips_label)

	_status_label = Label.new()
	box.add_child(_status_label)
	_peers_label = Label.new()
	box.add_child(_peers_label)
	_messages_label = Label.new()
	_messages_label.modulate = Color(0.8, 0.85, 1.0)
	_messages_label.autowrap = true
	_messages_label.rect_min_size = Vector2(430, 0)
	box.add_child(_messages_label)


func _make_button(text: String, method: String, parent: Node) -> Button:
	var b := Button.new()
	b.text = text
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.focus_mode = Control.FOCUS_NONE
	b.connect("pressed", self, method)
	parent.add_child(b)
	return b


func _port() -> int:
	var p := int(_port_edit.text)
	return p if p > 0 and p < 65536 else Protocol.DEFAULT_PORT


func _on_host_pressed() -> void:
	_save_settings()
	session.host(_port())


func _on_join_pressed() -> void:
	_save_settings()
	session.join(_ip_edit.text.strip_edges(), _port())


func _load_setting(key: String, default):
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_PATH) != OK:
		return default
	return cfg.get_value("lobby", key, default)


func _save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.load(CONFIG_PATH)
	cfg.set_value("lobby", "ip", _ip_edit.text.strip_edges())
	cfg.set_value("lobby", "port", _port())
	cfg.save(CONFIG_PATH)


# IPv4 de esta PC (red local y adaptadores de VPN como Radmin/ZeroTier/Tailscale).
func _local_ips() -> String:
	var ips := []
	for a in IP.get_local_addresses():
		var ip: String = a
		if ip.find(":") != -1 or ip.begins_with("127.") or ip.begins_with("169.254."):
			continue
		ips.append(ip)
	return PoolStringArray(ips).join(", ") if not ips.empty() else "(no se encontraron)"


func _on_leave_pressed() -> void:
	session.leave()


func _on_state_changed(_s: int) -> void:
	_refresh()


func _on_peers_changed(_p: Dictionary) -> void:
	_refresh()


func _on_message(text: String) -> void:
	_messages.append(text)
	while _messages.size() > 5:
		_messages.pop_front()
	_messages_label.text = PoolStringArray(_messages).join("\n")


func _refresh() -> void:
	var S = session.State
	var offline: bool = session.state == S.OFFLINE
	_host_btn.disabled = not offline
	_join_btn.disabled = not offline
	_leave_btn.disabled = offline
	_ip_edit.editable = offline
	_port_edit.editable = offline

	var status := "Desconectado"
	if session.state == S.HOSTING:
		status = "Hosteando (%d conectados)" % _ready_count()
	elif session.state == S.CONNECTING:
		status = "Conectando..."
	elif session.state == S.HANDSHAKE:
		status = "Verificando versiones..."
	elif session.state == S.CONNECTED:
		status = "Conectado a %s — ping %s" % [session.host_name, _fmt_ping(session.ping_ms)]
	_status_label.text = "Estado: " + status

	var lines := []
	if session.state == S.HOSTING or session.state == S.CONNECTED:
		lines.append("• %s (host)" % session.host_name)
		for id in session.peers:
			var p = session.peers[id]
			if p.ready:
				var me: String = " (vos)" if id == session.my_id else ""
				lines.append("• %s%s — %s" % [p.name, me, _fmt_ping(p.ping)])
	_peers_label.text = PoolStringArray(lines).join("\n")

	var hint: String = "Online Mod v%s — F9" % session.mod_version
	if not offline:
		hint += " — " + status
	_hint_label.text = hint


func _ready_count() -> int:
	var n := 0
	for id in session.peers:
		if session.peers[id].ready:
			n += 1
	return n


func _fmt_ping(ms: int) -> String:
	return "%d ms" % ms if ms >= 0 else "— ms"
