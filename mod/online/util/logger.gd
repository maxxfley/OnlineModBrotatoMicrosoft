extends Node
# Logger del mod: escribe en user://online_mod.log y, en builds de desarrollo,
# envía cada línea por TCP a un receptor local (tools/log_sink.py) para poder
# leer los logs desde fuera del contenedor GDK.

const LOG_PATH := "user://online_mod.log"
const SINK_RETRY_SEC := 2.0
const MAX_PENDING := 500

var tag := "?"
var _file: File
var _sink = null  # StreamPeerTCP (via ClassDB)
var _sink_enabled := false
var _sink_host := "127.0.0.1"
var _sink_port := 0
var _sink_retry := 0.0
var _pending := []


func setup(enable_sink: bool, sink_port: int) -> void:
	_file = File.new()
	if _file.open(LOG_PATH, File.WRITE) != OK:
		_file = null
	_sink_enabled = enable_sink and ClassDB.class_exists("StreamPeerTCP")
	_sink_port = sink_port


func info(msg: String) -> void:
	_write("INFO", msg)


func warn(msg: String) -> void:
	_write("WARN", msg)


func error(msg: String) -> void:
	_write("ERROR", msg)


func _write(level: String, msg: String) -> void:
	var line := "[%s][%d][%s][%s] %s" % [_timestamp(), OS.get_process_id(), tag, level, msg]
	print(line)
	if _file:
		_file.store_line(line)
		_file.flush()
	if _sink_enabled:
		_pending.append(line)
		if _pending.size() > MAX_PENDING:
			_pending.pop_front()


func _process(delta: float) -> void:
	if not _sink_enabled:
		return
	if _sink == null:
		_sink_retry -= delta
		if _sink_retry > 0.0:
			return
		_sink_retry = SINK_RETRY_SEC
		_sink = ClassDB.instance("StreamPeerTCP")
		if _sink.call("connect_to_host", _sink_host, _sink_port) != OK:
			_sink = null
		return
	var status: int = _sink.call("get_status")
	if status == 2:  # STATUS_CONNECTED
		flush_now()
	elif status == 3 or status == 0:  # STATUS_ERROR / STATUS_NONE
		_sink = null


# Envía ya lo pendiente al receptor (útil antes de una operación que podría colgar el juego).
func flush_now() -> void:
	if _sink == null or int(_sink.call("get_status")) != 2:
		return
	while not _pending.empty():
		var data: PoolByteArray = (_pending.pop_front() + "\n").to_utf8()
		_sink.call("put_data", data)


func _timestamp() -> String:
	var t := OS.get_time()
	return "%02d:%02d:%02d.%03d" % [t.hour, t.minute, t.second, OS.get_ticks_msec() % 1000]
