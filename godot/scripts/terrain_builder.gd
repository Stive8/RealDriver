class_name TerrainBuilder
extends RefCounted
## Construye la malla de terreno (heightmap) y su colisión (Fase R-2).
##
## Un vértice por nodo de la grilla `terrain` (contrato map.json 1.2), en su posición
## mundial con su altura; 2 triángulos por celda. El orden de vértices reproduce el
## mismo winding que road_builder.gd usa para sus tiras (visible/iluminado desde +Y),
## así que SurfaceTool.generate_normals() produce normales suavizadas hacia arriba.
## Material: el ground.tres existente (toon shader, sin tocar). Colisión: trimesh en
## un StaticBody3D + CollisionShape3D, hijos del nodo devuelto.

const GROUND_MATERIAL_PATH := "res://materials/ground.tres"

## Tamaño del quad de compatibilidad cuando `terrain` está vacío o el esquema es viejo:
## equivale al plano 1400x1400 de la Fase 0 (mismo tamaño, misma colisión).
const FLAT_FALLBACK_SIZE := 1400.0


static func build(terrain: Dictionary) -> Node3D:
	var grid: Dictionary = terrain if not terrain.is_empty() else _flat_fallback_grid()

	var cell_size: float = float(grid["cell_size"])
	var nx: int = int(grid["nx"])
	var nz: int = int(grid["nz"])
	var origin_x: float = float(grid["origin_x"])
	var origin_z: float = float(grid["origin_z"])
	var heights: Array = grid["heights"]

	var world_w := float(nx - 1) * cell_size
	var world_d := float(nz - 1) * cell_size

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	for j in range(nz - 1):
		for i in range(nx - 1):
			var x0 := origin_x + i * cell_size
			var x1 := x0 + cell_size
			var z0 := origin_z + j * cell_size
			var z1 := z0 + cell_size

			var v00 := Vector3(x0, float(heights[j * nx + i]), z0)
			var v10 := Vector3(x1, float(heights[j * nx + i + 1]), z0)
			var v01 := Vector3(x0, float(heights[(j + 1) * nx + i]), z1)
			var v11 := Vector3(x1, float(heights[(j + 1) * nx + i + 1]), z1)

			var uv00 := Vector2((x0 - origin_x) / world_w, (z0 - origin_z) / world_d)
			var uv10 := Vector2((x1 - origin_x) / world_w, (z0 - origin_z) / world_d)
			var uv01 := Vector2((x0 - origin_x) / world_w, (z1 - origin_z) / world_d)
			var uv11 := Vector2((x1 - origin_x) / world_w, (z1 - origin_z) / world_d)

			# Winding igual al de road_builder.gd (validado): normal suavizada hacia +Y.
			st.set_uv(uv10); st.add_vertex(v10)
			st.set_uv(uv11); st.add_vertex(v11)
			st.set_uv(uv00); st.add_vertex(v00)

			st.set_uv(uv00); st.add_vertex(v00)
			st.set_uv(uv11); st.add_vertex(v11)
			st.set_uv(uv01); st.add_vertex(v01)

	st.generate_normals()
	st.set_material(load(GROUND_MATERIAL_PATH))
	var mesh := st.commit()

	var root := Node3D.new()
	root.name = "Terrain"

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "TerrainMesh"
	mesh_instance.mesh = mesh
	root.add_child(mesh_instance)

	var static_body := StaticBody3D.new()
	static_body.name = "TerrainCollision"
	var shape := mesh.create_trimesh_shape()
	if shape == null:
		push_error("TerrainBuilder: no se pudo crear trimesh shape del terreno")
	else:
		var col := CollisionShape3D.new()
		col.name = "TerrainShape"
		col.shape = shape
		static_body.add_child(col)
	root.add_child(static_body)

	return root


static func _flat_fallback_grid() -> Dictionary:
	var half := FLAT_FALLBACK_SIZE * 0.5
	return {
		"cell_size": FLAT_FALLBACK_SIZE,
		"nx": 2, "nz": 2,
		"origin_x": -half, "origin_z": -half,
		"heights": [0.0, 0.0, 0.0, 0.0],
	}
