extends Node3D

const MAP_PATH := "res://data/map.json"


func _ready() -> void:
	var start_ms := Time.get_ticks_msec()

	var file := FileAccess.open(MAP_PATH, FileAccess.READ)
	if file == null:
		push_error("No se pudo abrir %s" % MAP_PATH)
		return

	var json_text := file.get_as_text()
	file.close()

	var data = JSON.parse_string(json_text)
	if typeof(data) != TYPE_DICTIONARY:
		push_error("map.json no es un JSON válido")
		return

	var roads: Array = data.get("roads", [])
	var buildings: Array = data.get("buildings", [])

	var roads_mesh := RoadBuilder.build(roads)
	add_child(roads_mesh)

	var buildings_mesh := BuildingBuilder.build(buildings)
	add_child(buildings_mesh)

	var elapsed_ms := Time.get_ticks_msec() - start_ms
	print("%d vías, %d edificios, %d ms" % [roads.size(), buildings.size(), elapsed_ms])
