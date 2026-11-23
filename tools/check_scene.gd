extends Node2D
# Escena de oleada mínima para tools/check_mod.py: imita los nombres de nodos de la
# escena de oleada del juego (TileMap/Outline, Camera, capas, WaveTimer) para probar
# la sincronización host → cliente sin el juego.

const TEX_PATH := "res://test_icon.tres"

var _players := []
var _t := 0.0
var _entity: Node2D


func _ready() -> void:
	if not ResourceLoader.exists(TEX_PATH):
		var img := Image.new()
		img.create(16, 16, false, Image.FORMAT_RGBA8)
		img.fill(Color.orange)
		var it := ImageTexture.new()
		it.create_from_image(img)
		ResourceSaver.save(TEX_PATH, it)
	var tex = load(TEX_PATH)
	var tm := TileMap.new()
	tm.name = "TileMap"
	var ts := TileSet.new()
	ts.create_tile(0)
	ts.tile_set_texture(0, tex)
	ts.tile_set_region(0, Rect2(0, 0, 16, 16))
	tm.tile_set = ts
	for x in 10:
		for y in 8:
			tm.set_cell(x, y, 0)
	add_child(tm)
	var outline := NinePatchRect.new()
	outline.name = "Outline"
	outline.rect_size = Vector2(12 * 64, 10 * 64)
	tm.add_child(outline)
	var cam := Camera2D.new()
	cam.name = "Camera"
	add_child(cam)
	cam.current = true
	for n in ["Materials", "Consumables", "Births", "Entities", "PlayerProjectiles", "EnemyProjectiles", "Effects", "Explosions"]:
		var layer: Node2D = YSort.new() if n == "Entities" else Node2D.new()
		layer.name = n
		add_child(layer)
	_entity = Node2D.new()
	var anim := Node2D.new()
	anim.name = "Animation"
	_entity.add_child(anim)
	var sp := Sprite.new()
	sp.texture = tex
	sp.modulate = Color(1, 0.5, 0.5)
	anim.add_child(sp)
	get_node("Entities").add_child(_entity)
	var wt := Timer.new()
	wt.name = "WaveTimer"
	add_child(wt)
	wt.start(60)


func _process(delta: float) -> void:
	_t += delta
	_entity.position = Vector2(100 + 50 * cos(_t), 100 + 50 * sin(_t))
