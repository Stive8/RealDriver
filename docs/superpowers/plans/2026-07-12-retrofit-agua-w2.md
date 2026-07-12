# Retrofit Agua — Fase W-2 (Godot: ribbon_util, water_builder, tableros) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. No GDScript test framework exists in this project (confirmed by the prior Fase C-3 plan) — verification is headless Godot runs (`godot --headless --path . --quit-after N`, checking printed diagnostics and absence of `SCRIPT ERROR`) plus a human visual checklist, since 3D/UI behavior can't be observed by the agent.

**Goal:** Consume the schema-1.4 `map.json` fields that Fase W-1 already produces (`roads[].layer`/`.deck`, `water_areas[]`, `water_ways[]`) on the Godot client: extract the road-ribbon offset math into a shared `RibbonUtil`, build a new `WaterBuilder` that renders water areas/ways, add a "tablero" (bridge deck) rendering branch to `RoadBuilder` (chord elevation + box + separate collision), and make traffic vehicles interpolate their height across deck edges instead of sampling terrain per-frame.

**Architecture:** One new pure-geometry helper (`ribbon_util.gd`), one new mesh builder (`water_builder.gd`) mirroring the existing `RoadBuilder`/`BuildingBuilder` static-class pattern, two new material resources reusing the existing shared `toon.gdshader`, additive changes to `road_builder.gd`'s deck branch, and additive parallel-array/interpolation changes to `traffic_graph.gd`/`traffic_manager.gd`. `map_loader.gd` gets exactly one new instantiation call (`WaterBuilder.build(...)`, inserted between terrain and roads) — every other cross-file wiring (deck/layer flowing into the traffic graph) is already automatic today because `TrafficGraph.build(roads, controls)` passes whole road dictionaries through by reference.

**Tech Stack:** Godot 4.4 stable GDScript, static typing where reasonable, no autoloads, snake_case, one script = one responsibility (existing project conventions).

## Global Constraints

- **Do not touch:** `terrain_sampler.gd`, `terrain_builder.gd` (or its collision), `vehicle.gd`, camera, game modes, minimap, any shader file, the backend, or the `terrain` JSON schema. Traffic decision-logic (yielding, intersections, AI planning) is untouched — only the two listed additive changes (edge_deck storage, Y-interpolation in `_apply_pose`) are in scope for `traffic_graph.gd`/`traffic_manager.gd`.
- **No new files beyond:** `godot/scripts/ribbon_util.gd`, `godot/scripts/water_builder.gd`, `godot/materials/water.tres`, `godot/materials/road_deck_underside.tres` (see Task 3 for why this fourth file is needed beyond the original file list — a `# DECISION_PENDIENTE` comment documents the reasoning at its point of use).
- `MITER_COS_CLAMP := 0.35` — the exact existing clamp value in `road_builder.gd:11`, moved verbatim into `RibbonUtil`, never changed.
- `ROAD_LIFT := 0.10` (existing, `road_builder.gd:6`) stays the lift for all vehicle-drivable surfaces (normal roads and bridge decks alike). `WATER_LIFT := 0.05` (new) for water — this ordering (water below roads) is intentional: "agua +0.05 < calzada +0.10".
- **Caja de tablero:** cara inferior a exactamente `-0.5 m` relative to the top ribbon at each vertex (not relative to terrain), winding inverted relative to the top ribbon, plus two vertical side walls. Underside/sides use a fixed color = the road material's existing `albedo_color` (`Color(0.227451, 0.227451, 0.25098)`) × 0.8 = `Color(0.1819608, 0.1819608, 0.200784)`.
- **Colisión de tableros:** the top ribbon of every bridge deck ALSO goes into a separate collision-only trimesh (`StaticBody3D`/`CollisionShape3D`), in addition to the normal visual mesh. Leave `collision_layer`/`collision_mask` unset on it (Godot default = layer 1) — this exactly matches how `TerrainCollision`/`RoadsCollision`/`BuildingsCollision` already do it (confirmed: none of them set these properties explicitly), and the vehicle's `collision_mask = 3` (set in `vehicle.tscn`, untouched) already covers layer 1.
- **Regla de emergencia — empalme roto:** if a `deck == "bridge"` road's first or last point does NOT appear as an endpoint of any OTHER road (using the exact `"%.2f|%.2f"` key format `TrafficGraph.FUSE_FMT` already uses), that road is drapeado normally instead of built as a deck — counted and printed, never silently built as a floating disconnected chord.
- **Water polygons:** same 4-step shape validation as `BuildingBuilder` (`_clean_footprint`/shoelace-orient + `Geometry2D.triangulate_polygon`, discard+count on failure), edges subdivided to a max of 15 m before triangulation.
- **Water ways:** flat cross-section — both ribbon edges at each cross-section use the height sampled at the **centerline** point, not each edge's own position (this is the one place `RibbonUtil`'s 2D offsets are consumed without per-edge height sampling, unlike roads).
- Diagnostics required by the spec: water polygon/triangle counts, deck/collision counts, and a road-ribbon vertex/triangle count proving no regression on normal roads — printed via `print()`, no test framework exists.
- ≥ 60 fps and load time < 20 s remain acceptance criteria (human-verified, not agent-verified).

---

## Task 1: Extract `ribbon_util.gd` from `road_builder.gd` (pure refactor, non-regression)

**Files:**
- Create: `godot/scripts/ribbon_util.gd`
- Modify: `godot/scripts/road_builder.gd`

**Interfaces:**
- Produces: `RibbonUtil.compute_offsets(points: Array, half_width: float) -> Dictionary` returning `{"a": Array[Vector2], "b": Array[Vector2]}`, same length as `points`. Consumed by `road_builder.gd` (this task, and again in Task 3 for the deck branch) and `water_builder.gd` (Task 2).
- Consumes: nothing beyond GDScript builtins (`Vector2`).

This task makes **zero** behavioral change — it moves the exact perpendicular/miter-join math already in `road_builder.gd:65-103` into a new static, parametrized function, and updates `_add_road_strip` to call it. The current `MITER_COS_CLAMP := 0.35` constant and its `# DECISION_PENDIENTE` comment move with the code (that comment documents an existing, already-made interpretation call from an earlier phase — preserve it verbatim, it is not something to re-litigate here).

- [ ] **Step 1: Create `ribbon_util.gd`**

```gdscript
class_name RibbonUtil
extends RefCounted
## Matematica de cintas (perpendiculares + bisectriz-miter), extraida de road_builder.gd
## (Fase W-2, contrato 5): parametrizada por ancho, SIN muestreo de altura -- reusada por
## road_builder.gd (vias normales y tableros) y water_builder.gd (vias de agua, seccion
## transversal plana muestreada en el eje, no por vertice de cinta).

## Tope de cos(theta/2) en el miter join; evita puntas en giros cerrados.
const MITER_COS_CLAMP := 0.35


## Calcula los dos bordes de una cinta 2D de semiancho `half_width` sobre la polilinea
## `points` (Array de pares [x, z]). Retorna {"a": Array[Vector2], "b": Array[Vector2]},
## mismo tamano que `points`, uno por vertice de la polilinea de entrada.
static func compute_offsets(points: Array, half_width: float) -> Dictionary:
	var n := points.size()
	var offsets_a: Array[Vector2] = []
	var offsets_b: Array[Vector2] = []

	for i in range(n):
		var center := Vector2(points[i][0], points[i][1])
		var offset_vec: Vector2

		if i == 0:
			var dir := (Vector2(points[1][0], points[1][1]) - center).normalized()
			offset_vec = Vector2(dir.y, -dir.x) * half_width
		elif i == n - 1:
			var prev := Vector2(points[i - 1][0], points[i - 1][1])
			var dir := (center - prev).normalized()
			offset_vec = Vector2(dir.y, -dir.x) * half_width
		else:
			# DECISION_PENDIENTE (heredado de road_builder.gd, fase previa a W-2): el espec
			# dice "bisectriz de las direcciones adyacentes"; se interpreta como bisectriz
			# de las NORMALES de esas direcciones (miter join estandar), ya que la bisectriz
			# de las direcciones de viaje no produce un offset perpendicular a la via.
			var prev := Vector2(points[i - 1][0], points[i - 1][1])
			var next := Vector2(points[i + 1][0], points[i + 1][1])
			var dir_in := (center - prev).normalized()
			var dir_out := (next - center).normalized()
			var normal_in := Vector2(dir_in.y, -dir_in.x)
			var normal_out := Vector2(dir_out.y, -dir_out.x)
			var bisector_sum := normal_in + normal_out
			if bisector_sum.length() < 0.001:
				# Giro de ~180 grados: la bisectriz colapsa, usar la normal de entrada.
				offset_vec = normal_in * half_width
			else:
				var bisector := bisector_sum.normalized()
				var cos_half := sqrt(maxf(0.0, (1.0 + dir_in.dot(dir_out)) * 0.5))
				var miter_len := half_width / maxf(MITER_COS_CLAMP, cos_half)
				offset_vec = bisector * miter_len

		offsets_a.append(center + offset_vec)
		offsets_b.append(center - offset_vec)

	return {"a": offsets_a, "b": offsets_b}
```

- [ ] **Step 2: Update `road_builder.gd` to consume it**

Replace `_add_road_strip` (current lines 65-117) with:

```gdscript
static func _add_road_strip(st: SurfaceTool, points: Array, half_width: float, sampler: TerrainSampler) -> void:
	var offsets := RibbonUtil.compute_offsets(points, half_width)
	var offsets_a: Array[Vector2] = offsets["a"]
	var offsets_b: Array[Vector2] = offsets["b"]
	var n := points.size()

	for i in range(n - 1):
		var va0 := _ribbon_vertex(offsets_a[i], sampler)
		var vb0 := _ribbon_vertex(offsets_b[i], sampler)
		var va1 := _ribbon_vertex(offsets_a[i + 1], sampler)
		var vb1 := _ribbon_vertex(offsets_b[i + 1], sampler)

		st.add_vertex(va0)
		st.add_vertex(va1)
		st.add_vertex(vb0)

		st.add_vertex(vb0)
		st.add_vertex(va1)
		st.add_vertex(vb1)
```

Remove the now-unused `MITER_COS_CLAMP` constant from `road_builder.gd` (line 11) — it lives in `RibbonUtil` now. Leave `ROAD_LIFT`, `ROAD_SUBDIV_MAX_SEG`, `ROAD_MATERIAL_PATH` untouched.

- [ ] **Step 3: Non-regression diagnostic — add a vertex/triangle counter**

In `build()`, track a running vertex count across all `_add_road_strip` calls and print it. Change the `build()` signature area (current lines 15-44) — replace the loop and final print:

```gdscript
static func build(roads: Array, sampler: TerrainSampler) -> MeshInstance3D:
	var start_ms := Time.get_ticks_msec()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var roads_processed := 0
	var points_inserted := 0

	for road in roads:
		var points: Array = road["points"]
		if points.size() < 2:
			continue
		var densified := _densify_points(points)
		points_inserted += densified["inserted"]
		var half_width: float = float(road["width"]) * 0.5
		_add_road_strip(st, densified["points"], half_width, sampler)
		roads_processed += 1

	st.generate_normals()
	st.set_material(load(ROAD_MATERIAL_PATH))
	var mesh := st.commit()

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "Roads"
	mesh_instance.mesh = mesh

	var elapsed_ms := Time.get_ticks_msec() - start_ms
	var vtx_count: int = mesh.surface_get_array_len(0) if mesh.get_surface_count() > 0 else 0
	var tri_count := vtx_count / 3
	print("RoadBuilder: %d vías, %d puntos insertados por subdivisión, %d ms" % [
		roads_processed, points_inserted, elapsed_ms])
	print("RoadBuilder no-regresión: %d vértices / %d triángulos" % [vtx_count, tri_count])
	return mesh_instance
```

(`_densify_points` and `_ribbon_vertex` are unchanged — do not touch them in this task.)

- [ ] **Step 4: Headless verification — byte-equivalent output**

Run BEFORE committing (capture the baseline from the currently-committed, unmodified `road_builder.gd` — i.e. run this once on a clean checkout before Step 1-3's edits, or read the equivalent count from a `git stash` round-trip):

```bash
cd godot && "/c/Users/Brayhan/AppData/Local/Programs/Godot/Godot_v4.4-stable_win64_console.exe" --headless --path . --quit-after 3 2>&1 | grep -E "RoadBuilder|SCRIPT ERROR"
```

Since the *baseline* build (pre-Step-3) doesn't print a vertex/triangle count yet, get the baseline number by temporarily adding the same one-line print to the **unmodified** `_add_road_strip`/`build()` (or by computing it via `git stash` + a throwaway print + `git stash pop`), run once, note the number, then run again against the Step 1-3 code. **Expected: identical vertex and triangle counts, and identical `%d vías`/`%d puntos insertados` numbers** (Jordán currently: 527 vías per the W-1 regeneration). No `SCRIPT ERROR`. Report both numbers explicitly in the task report — this is the "no-regresión OBLIGATORIA" proof the phase requires.

- [ ] **Step 5: Commit**

```bash
git add godot/scripts/ribbon_util.gd godot/scripts/road_builder.gd
git commit -m "$(cat <<'EOF'
refactor(w-2): godot - extrae ribbon_util.gd de road_builder.gd (sin cambio de comportamiento)

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: `water_builder.gd` + `materials/water.tres`, wired into `map_loader.gd`

**Files:**
- Create: `godot/scripts/water_builder.gd`
- Create: `godot/materials/water.tres`
- Modify: `godot/scripts/map_loader.gd`

**Interfaces:**
- Consumes: `RibbonUtil.compute_offsets(points, half_width)` (Task 1). `TerrainSampler.height_at(x, z) -> float` (existing, unchanged).
- Produces: `WaterBuilder.build(water_areas: Array, water_ways: Array, sampler: TerrainSampler) -> MeshInstance3D`. Called once from `map_loader.gd`.

- [ ] **Step 1: `water_builder.gd`**

```gdscript
class_name WaterBuilder
extends RefCounted
## Malla de agua (Fase W-2, ESPEC_SESION_RETROFIT_AGUA_V2, contrato 5): poligonos
## (water_areas) triangulados + cintas de eje (water_ways) de seccion plana. Una sola
## malla, sin colision propia (vadear un cruce sin puente es valido por diseno).

const WATER_LIFT := 0.05
const WATER_MATERIAL_PATH := "res://materials/water.tres"
## Subdivision maxima de arista antes de triangular un poligono de agua (contrato 5).
const WATER_EDGE_SUBDIV_MAX := 15.0


static func build(water_areas: Array, water_ways: Array, sampler: TerrainSampler) -> MeshInstance3D:
	var start_ms := Time.get_ticks_msec()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var areas_built := 0
	var areas_discarded := 0
	var tris_count := 0
	for area in water_areas:
		var n_tris := _add_water_area(st, area, sampler)
		if n_tris > 0:
			areas_built += 1
			tris_count += n_tris
		else:
			areas_discarded += 1

	var ways_built := 0
	for way in water_ways:
		if _add_water_way(st, way, sampler):
			ways_built += 1

	st.generate_normals()
	st.set_material(load(WATER_MATERIAL_PATH))
	var mesh := st.commit()

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "Water"
	mesh_instance.mesh = mesh

	var elapsed_ms := Time.get_ticks_msec() - start_ms
	print("WaterBuilder: %d polígonos (%d descartados, %d tris), %d cintas de agua, %d ms" % [
		areas_built, areas_discarded, tris_count, ways_built, elapsed_ms])
	return mesh_instance


## Cierra la huella, orienta CCW (mismo criterio shoelace que BuildingBuilder), sin el
## punto de cierre duplicado.
static func _clean_footprint(footprint: Array) -> Array[Vector2]:
	var points: Array[Vector2] = []
	for p in footprint:
		points.append(Vector2(p[0], p[1]))
	if points.size() > 1 and points[0].is_equal_approx(points[points.size() - 1]):
		points.remove_at(points.size() - 1)
	if _signed_area_xz(points) > 0.0:
		points.reverse()
	return points


static func _signed_area_xz(points: Array[Vector2]) -> float:
	var area := 0.0
	var n := points.size()
	for i in range(n):
		var a := points[i]
		var b := points[(i + 1) % n]
		area += a.x * b.y - b.x * a.y
	return area


## Reinserta puntos por interpolacion lineal en cada arista del anillo (incluida la de
## cierre) para que ninguna supere `max_len` antes de triangular.
static func _subdivide_ring(points: Array[Vector2], max_len: float) -> Array[Vector2]:
	var result: Array[Vector2] = []
	var n := points.size()
	for i in range(n):
		var a := points[i]
		var b := points[(i + 1) % n]
		result.append(a)
		var seg_len := a.distance_to(b)
		var steps := maxi(1, int(ceil(seg_len / max_len)))
		for s in range(1, steps):
			result.append(a.lerp(b, float(s) / float(steps)))
	return result


## Construye un polígono de agua. Retorna el número de triángulos emitidos (0 si se
## descarta: huella degenerada o Geometry2D.triangulate_polygon falla -- regla histórica
## de edificios, contrato 2 W-1).
static func _add_water_area(st: SurfaceTool, area: Dictionary, sampler: TerrainSampler) -> int:
	var points := _clean_footprint(area.get("footprint", []))
	if points.size() < 3:
		return 0
	var subdivided := _subdivide_ring(points, WATER_EDGE_SUBDIV_MAX)
	var polygon := PackedVector2Array(subdivided)
	var triangles := Geometry2D.triangulate_polygon(polygon)
	if triangles.is_empty():
		return 0
	for i in range(0, triangles.size(), 3):
		st.add_vertex(_water_vertex(subdivided[triangles[i]], sampler))
		st.add_vertex(_water_vertex(subdivided[triangles[i + 1]], sampler))
		st.add_vertex(_water_vertex(subdivided[triangles[i + 2]], sampler))
	return triangles.size() / 3


## Cinta de eje de sección PLANA: a diferencia de road_builder.gd (cada vértice de cinta
## se apoya en el terreno bajo su propia posición), aquí AMBOS bordes de cada sección
## comparten la altura muestreada en el CENTRO (contrato 5) -- el agua es horizontal de
## lado a lado, no sigue el peralte lateral del terreno.
static func _add_water_way(st: SurfaceTool, way: Dictionary, sampler: TerrainSampler) -> bool:
	var points: Array = way.get("points", [])
	if points.size() < 2:
		return false
	var half_width: float = float(way.get("width", 3.0)) * 0.5
	var offsets := RibbonUtil.compute_offsets(points, half_width)
	var offsets_a: Array[Vector2] = offsets["a"]
	var offsets_b: Array[Vector2] = offsets["b"]
	var n := points.size()

	for i in range(n - 1):
		var center0 := Vector2(points[i][0], points[i][1])
		var center1 := Vector2(points[i + 1][0], points[i + 1][1])
		var y0 := sampler.height_at(center0.x, center0.y) + WATER_LIFT
		var y1 := sampler.height_at(center1.x, center1.y) + WATER_LIFT

		var va0 := Vector3(offsets_a[i].x, y0, offsets_a[i].y)
		var vb0 := Vector3(offsets_b[i].x, y0, offsets_b[i].y)
		var va1 := Vector3(offsets_a[i + 1].x, y1, offsets_a[i + 1].y)
		var vb1 := Vector3(offsets_b[i + 1].x, y1, offsets_b[i + 1].y)

		st.add_vertex(va0)
		st.add_vertex(va1)
		st.add_vertex(vb0)

		st.add_vertex(vb0)
		st.add_vertex(va1)
		st.add_vertex(vb1)

	return true


static func _water_vertex(p: Vector2, sampler: TerrainSampler) -> Vector3:
	return Vector3(p.x, sampler.height_at(p.x, p.y) + WATER_LIFT, p.y)
```

`_clean_footprint`/`_signed_area_xz` duplicate `BuildingBuilder`'s private helpers deliberately (same ~10-line algorithm, contract 5 explicitly asks for "mismas reglas de forma que edificios") — this is intentional, low-risk local duplication rather than reaching into `BuildingBuilder`'s underscore-prefixed internals from another class, which would create fragile cross-file coupling for a handful of lines.

- [ ] **Step 2: `materials/water.tres`**

```
[gd_resource type="ShaderMaterial" format=3]

[ext_resource type="Shader" path="res://shaders/toon.gdshader" id="1_toon"]

[resource]
shader = ExtResource("1_toon")
shader_parameter/use_vertex_color = false
shader_parameter/albedo_color = Color(0.290196, 0.490196, 0.580392, 1)
```

`Color(0.290196, 0.490196, 0.580392)` = `#4a7d94` (the exact hex the broader spec's constants table specifies), expressed as a single flat material `albedo_color` rather than a per-vertex `COLOR` — water has exactly one uniform color across the whole mesh ("vertex color único"), so a fixed material albedo produces an identical visual result to painting every vertex the same color, with less code and following the same pattern `road.tres`/`ground.tres` already use for single-color surfaces (only `building.tres` uses `use_vertex_color = true`, because buildings vary color per building).

- [ ] **Step 3: Wire into `map_loader.gd`**

Insert between the terrain block (ends at the existing line `print("terreno %dx%d, ...")`) and the `# --- Roads geometry + collision ---` comment:

```gdscript
	# --- Agua (Fase W-2, ESPEC_SESION_RETROFIT_AGUA_V2, contrato 5): ANTES que calles
	# (jerarquía visual: agua +0.05 < calzada +0.10). Ausente en JSON < 1.4 -> listas
	# vacías -> WaterBuilder construye una malla vacía sin error (compatibilidad). ---
	var water_areas: Array = data.get("water_areas", [])
	var water_ways: Array = data.get("water_ways", [])
	var water_mesh := WaterBuilder.build(water_areas, water_ways, terrain_sampler)
	add_child(water_mesh)

	# --- Roads geometry + collision ---
	var roads_mesh := RoadBuilder.build(roads, terrain_sampler)
```

Nothing else in `map_loader.gd` changes for this task — `roads`/`buildings`/`controls` extraction, the traffic graph construction, vehicle spawn, and HUD setup are all untouched.

- [ ] **Step 4: Headless verification**

Run: `cd godot && "/c/Users/Brayhan/AppData/Local/Programs/Godot/Godot_v4.4-stable_win64_console.exe" --headless --path . --quit-after 3 2>&1 | tail -30`
Expected: `WaterBuilder: 3 polígonos (0 descartados, N tris), 3 cintas de agua, M ms` (Jordán's packaged map has exactly 3 `water_areas` and 3 `water_ways` per the W-1 regeneration numbers), no `SCRIPT ERROR`, `RoadBuilder`/`BuildingBuilder`/`TrafficGraph` lines unchanged from Task 1's baseline (roads=527, buildings=4916).

- [ ] **Step 5: Commit**

```bash
git add godot/scripts/water_builder.gd godot/materials/water.tres godot/scripts/map_loader.gd
git commit -m "$(cat <<'EOF'
feat(w-2): godot - water_builder.gd + instanciacion en map_loader

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: `road_builder.gd` — rama `deck` (cuerda + caja + colisión) + `materials/road_deck_underside.tres`

**Files:**
- Modify: `godot/scripts/road_builder.gd`
- Create: `godot/materials/road_deck_underside.tres`

**Interfaces:**
- Consumes: `RibbonUtil.compute_offsets(points, half_width)` (Task 1, reused here for the deck's own ribbon offsets — identical 2D math to normal roads, only the height source differs). `road.get("deck")`/`road.get("id")` (already present in the JSON since Fase W-1; not previously read anywhere in Godot).
- Produces: `RoadBuilder.build(roads, sampler)`'s return value (a `MeshInstance3D`) now has an extra child `StaticBody3D` (named `RoadDecksCollision`) when any deck exists — `map_loader.gd`'s existing `_wrap_trimesh_collision(roads_mesh, "Roads")` reparents `roads_mesh` (and everything nested under it, including this new child) as a whole subtree, so **no change to `map_loader.gd` is needed for this task** — verify this by reading `map_loader.gd:168-184`'s `_wrap_trimesh_collision`, which does `static_body.add_child(mesh_instance)`, moving `mesh_instance` and its existing children together.

**`# DECISION_PENDIENTE` this task introduces:** the broader spec's contract 4 says "Vertex color: el de la vía, oscurecido ×0.8 en inferior/costados" — but `road_builder.gd`/`road.tres` do not use per-vertex color anywhere today (confirmed: `road.tres` has `shader_parameter/use_vertex_color = false`, a single flat `albedo_color`; grepping `road_builder.gd` for `set_color` returns zero matches). Retrofitting vertex-color support into the verified, working normal-road rendering path just to satisfy this one line would touch code far beyond the deck feature itself. Instead, this task creates a **second small material** (`road_deck_underside.tres`) with a fixed albedo = the road's existing color × 0.8, applied to a second mesh surface containing only the underside+sides — producing the exact same visual result (a uniformly darker underside) without any risk to the verified normal-road path. Document this with a `# DECISION_PENDIENTE` comment at the point of use in code.

- [ ] **Step 1: `materials/road_deck_underside.tres`**

```
[gd_resource type="ShaderMaterial" format=3]

[ext_resource type="Shader" path="res://shaders/toon.gdshader" id="1_toon"]

[resource]
shader = ExtResource("1_toon")
shader_parameter/use_vertex_color = false
shader_parameter/albedo_color = Color(0.1819608, 0.1819608, 0.200784, 1)
```

(`road.tres`'s `Color(0.227451, 0.227451, 0.25098)` × 0.8, computed exactly: `0.227451*0.8=0.1819608`, `0.25098*0.8=0.200784`.)

- [ ] **Step 2: Add deck constants + endpoint-sharing helper**

Add to the constants block at the top of `road_builder.gd` (after `ROAD_MATERIAL_PATH`):

```gdscript
## Contrato 4 (ESPEC_SESION_RETROFIT_AGUA_V2, W-2): caja de tablero -- cara inferior este
## tanto por debajo de la cinta superior en cada vertice (no del terreno).
const DECK_BOX_DROP := 0.5
const DECK_UNDERSIDE_MATERIAL_PATH := "res://materials/road_deck_underside.tres"
```

Add near the bottom of the file (after `_ribbon_vertex`):

```gdscript
## Cuenta cuantas vias comparten cada extremo (clave "%.2f|%.2f", MISMO formato que
## TrafficGraph.FUSE_FMT) -- usado por la regla de emergencia "empalme roto" (contrato 4):
## si un extremo de una via deck=bridge no aparece en ninguna OTRA via, esa via se
## drapea como normal en vez de construirse como tablero.
static func _count_endpoint_occurrences(roads: Array) -> Dictionary:
	var counts := {}
	for road in roads:
		var points: Array = road.get("points", [])
		if points.size() < 2:
			continue
		for p in [points[0], points[points.size() - 1]]:
			var key := "%.2f|%.2f" % [float(p[0]), float(p[1])]
			counts[key] = counts.get(key, 0) + 1
	return counts


static func _has_broken_splice(points: Array, endpoint_counts: Dictionary) -> bool:
	for p in [points[0], points[points.size() - 1]]:
		var key := "%.2f|%.2f" % [float(p[0]), float(p[1])]
		if endpoint_counts.get(key, 0) < 2:
			return true
	return false
```

- [ ] **Step 3: `_add_deck_strip` — chord elevation + box + collision**

```gdscript
## Tablero de puente (contrato 4, W-2): cuerda entre extremos (NO muestrea terreno por
## vertice), mas caja (cara inferior + costados) y colision aparte para la cinta superior.
static func _add_deck_strip(st: SurfaceTool, st_box: SurfaceTool, st_collision: SurfaceTool, points: Array, half_width: float, sampler: TerrainSampler) -> void:
	var n := points.size()
	var offsets := RibbonUtil.compute_offsets(points, half_width)
	var offsets_a: Array[Vector2] = offsets["a"]
	var offsets_b: Array[Vector2] = offsets["b"]

	var p0 := Vector2(points[0][0], points[0][1])
	var pN := Vector2(points[n - 1][0], points[n - 1][1])
	var h0 := sampler.height_at(p0.x, p0.y)
	var hN := sampler.height_at(pN.x, pN.y)

	var cum: Array[float] = [0.0]
	for i in range(n - 1):
		var a := Vector2(points[i][0], points[i][1])
		var b := Vector2(points[i + 1][0], points[i + 1][1])
		cum.append(cum[i] + a.distance_to(b))
	var total_len: float = cum[n - 1]

	var top_heights: Array[float] = []
	for i in range(n):
		var t: float = 0.0 if total_len <= 0.0 else cum[i] / total_len
		top_heights.append(lerpf(h0, hN, t) + ROAD_LIFT)

	for i in range(n - 1):
		var ya0 := Vector3(offsets_a[i].x, top_heights[i], offsets_a[i].y)
		var yb0 := Vector3(offsets_b[i].x, top_heights[i], offsets_b[i].y)
		var ya1 := Vector3(offsets_a[i + 1].x, top_heights[i + 1], offsets_a[i + 1].y)
		var yb1 := Vector3(offsets_b[i + 1].x, top_heights[i + 1], offsets_b[i + 1].y)

		# Cinta superior (visual, mismo material que vías normales -- mismo st que build()).
		st.add_vertex(ya0)
		st.add_vertex(ya1)
		st.add_vertex(yb0)
		st.add_vertex(yb0)
		st.add_vertex(ya1)
		st.add_vertex(yb1)

		# Colisión aparte, SOLO la cinta superior (contrato 4).
		st_collision.add_vertex(ya0)
		st_collision.add_vertex(ya1)
		st_collision.add_vertex(yb0)
		st_collision.add_vertex(yb0)
		st_collision.add_vertex(ya1)
		st_collision.add_vertex(yb1)

		# Caja: cara inferior (DECK_BOX_DROP por debajo, winding invertido) + costados.
		var za0 := Vector3(ya0.x, ya0.y - DECK_BOX_DROP, ya0.z)
		var zb0 := Vector3(yb0.x, yb0.y - DECK_BOX_DROP, yb0.z)
		var za1 := Vector3(ya1.x, ya1.y - DECK_BOX_DROP, ya1.z)
		var zb1 := Vector3(yb1.x, yb1.y - DECK_BOX_DROP, yb1.z)

		st_box.add_vertex(za0)
		st_box.add_vertex(zb0)
		st_box.add_vertex(za1)
		st_box.add_vertex(za1)
		st_box.add_vertex(zb0)
		st_box.add_vertex(zb1)

		# Costado A (borde offsets_a).
		st_box.add_vertex(za0)
		st_box.add_vertex(ya1)
		st_box.add_vertex(za1)
		st_box.add_vertex(za0)
		st_box.add_vertex(ya0)
		st_box.add_vertex(ya1)

		# Costado B (borde offsets_b, orden espejado respecto al costado A).
		st_box.add_vertex(zb0)
		st_box.add_vertex(zb1)
		st_box.add_vertex(yb1)
		st_box.add_vertex(zb0)
		st_box.add_vertex(yb1)
		st_box.add_vertex(yb0)
```

- [ ] **Step 4: Wire the deck branch + box/collision surfaces into `build()`**

Replace `build()` (as it stands after Task 1's Step 3) with:

```gdscript
static func build(roads: Array, sampler: TerrainSampler) -> MeshInstance3D:
	var start_ms := Time.get_ticks_msec()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var st_box := SurfaceTool.new()
	st_box.begin(Mesh.PRIMITIVE_TRIANGLES)
	var st_collision := SurfaceTool.new()
	st_collision.begin(Mesh.PRIMITIVE_TRIANGLES)

	var roads_processed := 0
	var points_inserted := 0
	var decks_built := 0
	var broken_splices := 0
	var has_deck_geometry := false

	var endpoint_counts := _count_endpoint_occurrences(roads)

	for road in roads:
		var points: Array = road["points"]
		if points.size() < 2:
			continue
		var deck: String = String(road.get("deck", ""))
		var is_deck_bridge := deck == "bridge" and not _has_broken_splice(points, endpoint_counts)

		var densified := _densify_points(points)
		points_inserted += densified["inserted"]
		var half_width: float = float(road["width"]) * 0.5

		if is_deck_bridge:
			_add_deck_strip(st, st_box, st_collision, densified["points"], half_width, sampler)
			has_deck_geometry = true
			decks_built += 1
		else:
			if deck == "bridge":
				broken_splices += 1
				print("RoadBuilder: vía id=%s deck=bridge con extremo sin empalme; drapeada como normal (regla de emergencia, contrato 4)" % str(road.get("id", "?")))
			_add_road_strip(st, densified["points"], half_width, sampler)
		roads_processed += 1

	st.generate_normals()
	var mesh := ArrayMesh.new()
	st.set_material(load(ROAD_MATERIAL_PATH))
	st.commit(mesh)

	if has_deck_geometry:
		st_box.generate_normals()
		st_box.set_material(load(DECK_UNDERSIDE_MATERIAL_PATH))
		st_box.commit(mesh)

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "Roads"
	mesh_instance.mesh = mesh

	var decks_with_collision := 0
	if has_deck_geometry:
		mesh_instance.add_child(_build_deck_collision(st_collision))
		decks_with_collision = decks_built

	var elapsed_ms := Time.get_ticks_msec() - start_ms
	var vtx_count: int = mesh.surface_get_array_len(0) if mesh.get_surface_count() > 0 else 0
	var tri_count := vtx_count / 3
	print("RoadBuilder: %d vías, %d puntos insertados por subdivisión, %d tableros (%d con colisión), %d empalmes rotos, %d ms" % [
		roads_processed, points_inserted, decks_built, decks_with_collision, broken_splices, elapsed_ms])
	print("RoadBuilder no-regresión: %d vértices / %d triángulos (superficie 0, cinta superior)" % [vtx_count, tri_count])
	return mesh_instance


static func _build_deck_collision(st_collision: SurfaceTool) -> StaticBody3D:
	var mesh := st_collision.commit()
	var body := StaticBody3D.new()
	body.name = "RoadDecksCollision"
	var shape := CollisionShape3D.new()
	shape.shape = mesh.create_trimesh_shape()
	body.add_child(shape)
	return body
```

Note the switch from `var mesh := st.commit()` to `var mesh := ArrayMesh.new(); st.commit(mesh)` — this mirrors `BuildingBuilder.build()`'s exact pattern (`var mesh := ArrayMesh.new(); st_walls.commit(mesh); st_tops.commit(mesh)`) for appending a second surface conditionally. For roads with no bridges, this must still produce the identical single-surface mesh as before — verify this explicitly in Step 5's headless check (surface 0's vertex/triangle count must match Task 1's baseline number **exactly**, since normal-road geometry generation is byte-for-byte unchanged; only the container the surface commits into changed).

- [ ] **Step 5: Headless verification**

Run: `cd godot && "/c/Users/Brayhan/AppData/Local/Programs/Godot/Godot_v4.4-stable_win64_console.exe" --headless --path . --quit-after 3 2>&1 | tail -30`

Expected:
- `RoadBuilder: 527 vías, ... 5 tableros (5 con colisión), 0 empalmes rotos, ... ms` — Jordán's packaged map has exactly 5 roads with `deck=bridge` (confirmed live in the W-1-regenerated `godot/data/map.json`), and their endpoints should splice cleanly against neighboring drapeada roads in real OSM data (0 broken splices expected, but **report the real number** — if it's nonzero, that's a legitimate finding, not a bug to suppress).
- `RoadBuilder no-regresión: N vértices / M triángulos` where **N/M must exactly match Task 1's baseline** for surface 0 (the deck tops use `st`, the SAME surface as normal roads — the ribbon triangle count per deck road is unaffected by becoming a deck, only its Y-coordinates and the two NEW surfaces change).
- No `SCRIPT ERROR`, no `Invalid get index`, no stack traces.

- [ ] **Step 6: Commit**

```bash
git add godot/scripts/road_builder.gd godot/materials/road_deck_underside.tres
git commit -m "$(cat <<'EOF'
feat(w-2): godot - rama deck en road_builder.gd (cuerda + caja + colision)

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Tráfico — `edge_deck` en el grafo + interpolación de `y` en tableros (Contrato 7, W-2)

**Files:**
- Modify: `godot/scripts/traffic_graph.gd`
- Modify: `godot/scripts/traffic_manager.gd`

**Interfaces:**
- Produces: `TrafficGraph.edge_deck: Array[String]` — new parallel array alongside the existing `edge_from`/`edge_to`/`edge_highway`/`edge_width`/`edge_oneway`/`edge_length` (same index space, one entry per edge, `""` when the road has no `deck`). Consumed by `traffic_manager.gd`'s `_apply_pose`.
- Consumes: `road.get("deck", "")` (already present in the JSON since Fase W-1).

Only the road-decision-logic-free parts of these two files change: no yielding/priority/AI-planning code is touched.

- [ ] **Step 1: `traffic_graph.gd` — `edge_deck` parallel array**

Add the new array declaration next to the existing edge arrays (after `var edge_length: PackedFloat32Array = PackedFloat32Array()`):

```gdscript
var edge_deck: Array[String] = []
```

Update `_add_edge`'s signature and body (current lines 101-111):

```gdscript
func _add_edge(a: int, b: int, rid: int, hw: String, w: float, ow: int, deck: String) -> void:
	var eidx := edge_from.size()
	edge_from.append(a)
	edge_to.append(b)
	edge_road_id.append(rid)
	edge_highway.append(hw)
	edge_width.append(w)
	edge_oneway.append(ow)
	edge_length.append(node_pos[a].distance_to(node_pos[b]))
	edge_deck.append(deck)
	node_edges[a].append(eidx)
	node_edges[b].append(eidx)
```

Update `_build_nodes_and_edges` (current lines 67-85) to read and pass the new field:

```gdscript
func _build_nodes_and_edges(roads: Array) -> void:
	for road in roads:
		var pts: Array = road.get("points", [])
		if pts.size() < 2:
			continue
		var rid := int(road.get("id", -1))
		var hw := String(road.get("highway", ""))
		var w := float(road.get("width", 6.0))
		# v1.1 retrocompatible: oneway ausente = 0 (bidireccional).
		var ow := int(road.get("oneway", 0))
		# Fase W-2 (contrato 7): deck ausente = "" (via normal, sin interpolacion de y).
		var deck := String(road.get("deck", ""))

		var prev_node := _get_or_add_node(pts[0])
		for i in range(1, pts.size()):
			var cur_node := _get_or_add_node(pts[i])
			if cur_node == prev_node:
				continue
			_add_edge(prev_node, cur_node, rid, hw, w, ow, deck)
			prev_node = cur_node
```

- [ ] **Step 2: `traffic_manager.gd` — interpolate `y` on deck edges in `_apply_pose`**

In `_apply_pose` (starts at the current line ~915), replace only the Y-computation at the end of the function (currently the last two lines: `var ground_y := _sampler.height_at(pos2.x, pos2.y)` and the `Transform3D(...)` line) with:

```gdscript
	# Fase W-2 (contrato 7): en aristas con deck (bridge/tunnel), la y se interpola
	# linealmente entre las alturas de los DOS extremos de la arista por la fraccion
	# recorrida (agent.s / len_e), en vez de muestrear terreno cada frame en pos2 -- el
	# tablero es una cuerda recta entre extremos, no sigue el relieve punto a punto.
	var ground_y: float
	if _graph.edge_deck[agent.edge] != "":
		var y_entry := _sampler.height_at(entry.x, entry.y)
		var far_node := _graph.edge_to[agent.edge] if agent.dir == 1 else _graph.edge_from[agent.edge]
		var far_pos := _graph.node_pos[far_node]
		var y_far := _sampler.height_at(far_pos.x, far_pos.y)
		var t := clampf(agent.s / len_e, 0.0, 1.0)
		ground_y = lerpf(y_entry, y_far, t)
	else:
		ground_y = _sampler.height_at(pos2.x, pos2.y)
	var basis := Basis(Vector3.UP, agent.yaw)
	agent.body.global_transform = Transform3D(basis, Vector3(pos2.x, ground_y, pos2.y))
```

(`entry` and `len_e` are already computed earlier in `_apply_pose`, at its current lines 916-918 — reuse them, don't recompute. Remove the now-superseded `var basis := Basis(Vector3.UP, agent.yaw)` / `var ground_y := _sampler.height_at(pos2.x, pos2.y)` / `agent.body.global_transform = ...` lines that currently sit at the end of the function, replacing them with the block above in the same position.)

- [ ] **Step 3: Headless verification**

Run: `cd godot && "/c/Users/Brayhan/AppData/Local/Programs/Godot/Godot_v4.4-stable_win64_console.exe" --headless --path . --quit-after 5 2>&1 | grep -E "TrafficGraph|SCRIPT ERROR|Invalid get index"`
Expected: `[TrafficGraph] nodos:... aristas:...` line unchanged in node/edge counts from before this task (adding `edge_deck` doesn't change graph topology, only annotates existing edges). No `SCRIPT ERROR`. Traffic agent behavior itself can't be observed headless — flagged for the human checklist (Task 5).

- [ ] **Step 4: Commit**

```bash
git add godot/scripts/traffic_graph.gd godot/scripts/traffic_manager.gd
git commit -m "$(cat <<'EOF'
feat(w-2): trafico - edge_deck en el grafo + interpolacion de y en tableros

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Regresión completa + checklist humano

**No new files.** This closes the phase.

- [ ] **Step 1: Full headless boot, final diagnostic capture**

```bash
cd godot && "/c/Users/Brayhan/AppData/Local/Programs/Godot/Godot_v4.4-stable_win64_console.exe" --headless --path . --quit-after 5 2>&1
```

Confirm every diagnostic line the phase requires is present and consistent with earlier tasks: `WaterBuilder: 3 polígonos (0 descartados, N tris), 3 cintas de agua, ... ms`; `RoadBuilder: 527 vías, ... 5 tableros (5 con colisión), 0 empalmes rotos, ... ms`; `RoadBuilder no-regresión: <N> vértices / <M> triángulos` matching Task 1's pre-deck baseline exactly; `[TrafficGraph] nodos:... aristas:...` matching the pre-W-2 baseline; no `SCRIPT ERROR`, no `Invalid get index`, no stack traces. `≥ 60 fps`/`carga < 20 s` are not verifiable headless — flag them for the human.

- [ ] **Step 2: Hand off the human checklist**

- **Nuevo:** cauces azules visibles con orillas (agua ligeramente hundida respecto a las orillas, gracias a la excavación de W-1); conducir POR ENCIMA de al menos un puente (de los 5 con `deck=bridge`) sin caer — la colisión del tablero debe sostener el auto en todo el recorrido; mirar el mismo puente desde abajo — el tablero debe verse opaco (caja visible, no un plano flotante sin espesor) con costados visibles (no caras negras/culled); ver a un auto de tráfico cruzar ese puente sin hundirse ni flotar (la interpolación de `y` de Tarea 4 debe mantenerlo pegado al tablero); si algún cruce de cauce NO tiene puente, confirmar que se vadea con una bajada/subida suave (comportamiento ya validado en Fase W-1, sin cambios aquí).
- **Regresión:** conducción libre 3 minutos por Jordán — calles, edificios, tráfico y props como siempre; contrarreloj completo con récords intactos; minimapa idéntico; ≥ 60 fps; carga < 20 s.
- Si el envoltorio de la caja del tablero se ve con la orientación de cara equivocada (negro/invisible desde algún ángulo), es la única pieza de geometría de esta fase que el agente no pudo verificar visualmente (sin acceso al viewport 3D) — anotar el ángulo exacto donde falla; el arreglo es intercambiar 2 vértices en el triángulo correspondiente dentro de `_add_deck_strip` (Tarea 3, Paso 3), no requiere rediseño.

## Self-Review Notes

1. **Spec coverage:** Contract 5's `RibbonUtil` extraction + non-regression proof → Task 1. Contract 5's `WaterBuilder` (polígonos, subdivisión 15 m, cintas de eje plano, `water.tres`, orden terreno→agua→calles) → Task 2. Contract 4's tablero (cuerda, caja, colisión aparte, regla de emergencia de empalme roto) → Task 3. Contract 7's herencia de `deck` por arista + interpolación de `y` → Task 4. Diagnósticos y checklist humano completo → Task 5.
2. **Placeholder scan:** none — every step has complete, ready-to-transcribe code or an exact command with a concrete expected signal (Jordán's real counts — 527 roads, 5 bridges, 3 water areas, 3 water ways — are known from the W-1 regeneration and used as concrete expected values throughout).
3. **Type consistency:** `RibbonUtil.compute_offsets()`'s return shape (`{"a": Array[Vector2], "b": Array[Vector2]}`) is identical at all three call sites (`road_builder.gd`'s `_add_road_strip` and `_add_deck_strip`, Tasks 1 and 3; `water_builder.gd`'s `_add_water_way`, Task 2). `WaterBuilder.build(water_areas, water_ways, sampler)`'s signature (Task 2) matches its only call site in `map_loader.gd` exactly. `TrafficGraph.edge_deck`'s type (`Array[String]`) and index space (same as `edge_from`/`edge_to`/etc.) match how `traffic_manager.gd` reads it (Task 4, `_graph.edge_deck[agent.edge]`). `_add_edge`'s new `deck` parameter (Task 4) is threaded through from `_build_nodes_and_edges`'s new `road.get("deck", "")` read at its only call site.
