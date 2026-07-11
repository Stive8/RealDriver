class_name TerrainSampler
extends RefCounted
## Fuente única de verdad para la altura del terreno (Fase R-2).
##
## Muestrea la grilla `terrain` de map.json (schema 1.2) con interpolación bilineal,
## fórmula ESPEJO exacta de la de `generate_map.py` (`height_at`). Sin nodos, sin estado
## global: se instancia y se pasa por referencia (map_loader.gd lo expone público).
##
## Compatibilidad: `setup({})` (terrain ausente o schema < 1.2) deja la grilla vacía y
## `height_at` devuelve siempre 0.0 (modo plano, igual que antes de este bloque).

var _cell_size: float = 30.0
var _nx: int = 0
var _nz: int = 0
var _origin_x: float = 0.0
var _origin_z: float = 0.0
var _heights: PackedFloat32Array = PackedFloat32Array()

## Altura máxima de la grilla (relativa a base_elevation). 0.0 en modo plano.
var max_height: float = 0.0


func setup(terrain: Dictionary) -> void:
	if terrain.is_empty():
		_nx = 0
		_nz = 0
		_heights = PackedFloat32Array()
		max_height = 0.0
		return

	_cell_size = float(terrain.get("cell_size", 30.0))
	_nx = int(terrain.get("nx", 0))
	_nz = int(terrain.get("nz", 0))
	_origin_x = float(terrain.get("origin_x", 0.0))
	_origin_z = float(terrain.get("origin_z", 0.0))

	var raw: Array = terrain.get("heights", [])
	_heights = PackedFloat32Array()
	_heights.resize(raw.size())
	max_height = 0.0
	for i in range(raw.size()):
		var h := float(raw[i])
		_heights[i] = h
		max_height = maxf(max_height, h)


## Altura del terreno en (x, z), interpolada bilinealmente entre los 4 nodos de la celda
## que contiene el punto. Fuera de la grilla, el clamp fija la altura del borde (el mundo
## se extiende plano). Sin offsets: cada consumidor aplica los suyos (ROAD_LIFT, etc.).
func height_at(x: float, z: float) -> float:
	if _nx < 2 or _nz < 2:
		return 0.0

	var gx: float = clampf((x - _origin_x) / _cell_size, 0.0, float(_nx) - 1.001)
	var gz: float = clampf((z - _origin_z) / _cell_size, 0.0, float(_nz) - 1.001)
	var i: int = int(floor(gx))
	var j: int = int(floor(gz))
	var fx: float = gx - i
	var fz: float = gz - j

	var h00: float = _heights[j * _nx + i]
	var h10: float = _heights[j * _nx + i + 1]
	var h01: float = _heights[(j + 1) * _nx + i]
	var h11: float = _heights[(j + 1) * _nx + i + 1]

	return lerpf(lerpf(h00, h10, fx), lerpf(h01, h11, fx), fz)
