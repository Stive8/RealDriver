# Retrofit Agua — Fase W-4 (elevación sintética por capas, rampas, y_resuelta) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. No GDScript/Python test framework exists in this project — verification is headless Godot runs (`godot --headless --path . --quit-after N`, checking printed diagnostics and absence of `SCRIPT ERROR`) plus the pipeline CLI's own printed stats, plus a human visual/driving checklist for anything 3D the agent cannot observe.

**Goal:** Implement contract 6 + contract 7's W-4 slice of `ESPEC_SESION_RETROFIT_AGUA_V2.md`: replace W-2's "cuerda simple" (straight chord, no minimum elevation) with the generalized formula `h(t) = max(cuerda(t), height_at(t) + capa*LAYER_CLEARANCE)`, add single-pass ramp propagation so an elevated road's approach roads climb up to meet it instead of ending in a cliff, replace the "collision/box only for decks" rule with a uniform "any segment more than `ELEVATED_EPS` above local terrain gets collision+box" rule, and replace traffic's per-edge `deck` flag with a per-node `y_resuelta` the agent compares against raw terrain to decide whether to interpolate.

**Architecture:** `road_builder.gd`'s existing deck branch is generalized in place (same file, same responsibility — no split). `traffic_graph.gd` drops the W-2-era `edge_deck`/`edge_deck_y_from`/`edge_deck_y_to` fields entirely and gains `node_y_resuelta`/`node_elevated`, computed by duplicating road_builder.gd's elevation+ramp math at node-resolution granularity — the same "small local duplication over cross-class reach-in" convention `water_builder.gd` (W-2) and `traffic_graph.gd`'s own `_count_road_endpoint_occurrences`/`_has_broken_splice` (W-3) already established in this codebase; no new shared file is introduced (the master spec's file-creation list for this whole 4-phase project — `ribbon_util.gd`, `water_builder.gd`, `materials/water.tres` — is exhaustive and W-4 adds nothing to it). W-3's `capa_efectiva` intersection guard (`edge_capa`, `mixed_capa_intersections`, `_same_capa`) is completely untouched — W-4 only replaces the Y-height mechanism, never the yielding-decision logic.

**Tech Stack:** Godot 4.4 stable GDScript (static typing where reasonable), Python 3 stdlib + `requests` (citygen, unmodified by this phase), no autoloads, snake_case, one script = one responsibility (existing project conventions).

## Global Constraints

- **Do not touch:** `terrain_sampler.gd`, `terrain_builder.gd` (or its collision), `vehicle.gd`, camera, minimap, any shader file, the backend, `ribbon_util.gd`, `water_builder.gd`, or any `citygen/`/pipeline file. This phase touches **only** `godot/scripts/road_builder.gd`, `godot/scripts/traffic_graph.gd`, `godot/scripts/traffic_manager.gd`. **No new files.**
- **Explicitly out of scope for this whole 4-phase block, including W-4 (verbatim from the master spec's role/limits section):** tunnels with their own elevation or terrain holes (tunnels stay drapeados normally, feeding only the graph/stats — completely unchanged by this phase), OSM relations/multipolygons, water animation/transparency/waves, water collision, pedestrians, docks/boats, water in the navigation graph, pillars/columns under viaducts, railings/parapets, special shadows, more than 3 layer levels (clamp), curve-smoothed ramps (ramps are linear by design), iterative elevation solvers (ramp propagation is single-pass, no chaining beyond one road per endpoint).
- **Height doctrine (closed exceptions):** `TerrainSampler` remains the sole truth for the TERRAIN itself. The only two height exceptions in the whole project: (a) elevated roads use contract 6's formula (cuerda in W-2, `max(cuerda, terreno + capa*LAYER_CLEARANCE)` from W-4 onward — this phase changes exception (a)'s formula, nothing else); (b) water deforms the grid in the pipeline (untouched here). No third case.
- **`_is_elevated(road)`:** `deck == "bridge"` OR (`road.has("layer")` AND `int(road["layer"]) > 0`). Tunnels (`deck == "tunnel"`) are never elevated — always normal drapeado, exactly as W-2 left them. `layer < 0` without `tunnel` is treated as capa 0 (drapeada), i.e. also never elevated.
- **`_elev_capa(road)`:** `int(road["layer"])` if `road.has("layer")`, else `1` (for `deck=="bridge"` without an explicit `layer`); clamped to `[1, 3]`.
- **`LAYER_CLEARANCE = 5.0`**, **`RAMP_LENGTH = 60.0`**, **`RAMP_MAX_GRADE = 0.15`**, **`ELEVATED_EPS = 0.5`** — all `[ESTRUCTURAL]`, exact values from the spec's constants table.
- **Regression semantics for this phase are NOT "identical Y heights"** — that's expected to change for some existing bridges (that's the point: contract 6 explicitly targets the case W-3's human checklist found live in Jordán, a real bridge with ~0.8 m clearance over the road it crosses, exactly what `max(cuerda, terreno+capa*5)` exists to fix). What must stay unchanged: (1) vertex/triangle **counts** for the whole `Roads` mesh (topology/tessellation is untouched, only Y values move — the established `RoadBuilder no-regresión: N vértices / M triángulos` diagnostic must still match `47094/15698` exactly); (2) any elevated road that already had **more** than `capa*LAYER_CLEARANCE` of natural clearance (a chord over a real valley/river, like Honda's `id=71` bridge from W-3) must render at the **same height as before**, since `max()` picks the chord there unchanged — this is the phase's explicit human regression check, not a nice-to-have.

---

## Task 1: `road_builder.gd` — generalized elevation formula + uniform box/collision rule

**Files:**
- Modify: `godot/scripts/road_builder.gd`

**Interfaces:**
- Produces: `RoadBuilder._is_elevated(road: Dictionary) -> bool`, `RoadBuilder._elev_capa(road: Dictionary) -> int`, `RoadBuilder._compute_elevated_heights(densified_points, original_points, capa, sampler) -> Array[float]`, `RoadBuilder._compute_elevated_endpoint_heights(roads, endpoint_counts, sampler) -> Dictionary` (key `"%.2f|%.2f"` → resolved height float, consumed by Task 2's ramp logic and duplicated in Task 3's `traffic_graph.gd`), `RoadBuilder._add_elevated_strip(st, st_box, st_collision, points, half_width, heights, sampler) -> Dictionary` (`{"has_box": bool, "collision_len": float}`, consumed again by Task 2 for ramps).
- Consumes: `RibbonUtil.compute_offsets` (unchanged), `sampler.height_at` (unchanged), `road.get("layer")`/`road.get("deck")` (present since W-1).

This task replaces the `deck=="bridge"`-only branch with the general `_is_elevated` condition and the `max()` formula, and replaces `_add_deck_strip`'s "always box+collision" with a per-segment `ELEVATED_EPS` check. It does **not** add ramps yet (Task 2) — non-elevated roads render exactly as before via unchanged `_add_road_strip`.

- [ ] **Step 1: Add new constants**

In the constants block (after the existing `DECK_UNDERSIDE_MATERIAL_PATH`, current line 14):

```gdscript
## Contrato 6 (ESPEC_SESION_RETROFIT_AGUA_V2, W-4): generaliza la cuerda simple de W-2.
## Metros de despeje sintético por nivel de capa sobre el terreno LOCAL en cada punto de
## una vía elevada (no solo en sus extremos).
const LAYER_CLEARANCE := 5.0
## Contrato 6 (W-4): umbral de despeje sobre terreno que activa caja+colisión -- reemplaza
## la regla "solo deck" de W-2; una sola regla cubre tableros Y rampas (Tarea 2).
const ELEVATED_EPS := 0.5
```

(`RAMP_LENGTH`/`RAMP_MAX_GRADE` are added in Task 2, where they're first used.)

- [ ] **Step 2: `_is_elevated` / `_elev_capa`**

Add near the bottom of the file, after `_has_broken_splice`:

```gdscript
## Contrato 6 (W-4): una vía es "elevada" si es tablero (deck=bridge) o tiene layer>0
## explícito. layer<0 sin tunnel se trata como capa 0 (drapeada) -- NO es elevada. Los
## túneles (deck=tunnel) NUNCA son elevados: drapeado normal, sin cambios desde W-2.
static func _is_elevated(road: Dictionary) -> bool:
	var deck: String = String(road.get("deck", ""))
	if deck == "bridge":
		return true
	if road.has("layer") and int(road["layer"]) > 0:
		return true
	return false


## Contrato 6 (W-4): capa = layer si existe (clamp [1,3]); si no, 1 (deck=bridge sin layer).
static func _elev_capa(road: Dictionary) -> int:
	var raw: int = int(road["layer"]) if road.has("layer") else 1
	return clampi(raw, 1, 3)
```

- [ ] **Step 3: Arc-length helpers**

Add alongside the above (these generalize the inline cumulative-distance loop `_add_deck_strip` used to have):

```gdscript
static func _arc_length(points: Array) -> float:
	var total := 0.0
	for i in range(points.size() - 1):
		var a := Vector2(points[i][0], points[i][1])
		var b := Vector2(points[i + 1][0], points[i + 1][1])
		total += a.distance_to(b)
	return total


static func _cumulative_arc_length(points: Array) -> Array[float]:
	var cum: Array[float] = [0.0]
	for i in range(points.size() - 1):
		var a := Vector2(points[i][0], points[i][1])
		var b := Vector2(points[i + 1][0], points[i + 1][1])
		cum.append(cum[i] + a.distance_to(b))
	return cum
```

- [ ] **Step 4: `_compute_elevated_heights`**

```gdscript
## Contrato 6 (W-4): h_tablero(t) = max(cuerda(t), height_at(t) + capa*LAYER_CLEARANCE) +
## ROAD_LIFT, evaluado en cada punto de `densified_points`. `original_points` ancla h0/hN y
## la longitud total de arco de la cuerda -- misma equivalencia densificado/original que W-3
## ya estableció (la densificación solo inserta puntos colineales, así que el arco y la
## fracción t en cualquier punto compartido son idénticos calculados sobre cualquiera de
## las dos listas).
static func _compute_elevated_heights(densified_points: Array, original_points: Array, capa: int, sampler: TerrainSampler) -> Array[float]:
	var p0 := Vector2(original_points[0][0], original_points[0][1])
	var pN := Vector2(original_points[original_points.size() - 1][0], original_points[original_points.size() - 1][1])
	var h0 := sampler.height_at(p0.x, p0.y)
	var hN := sampler.height_at(pN.x, pN.y)
	var total_len := _arc_length(original_points)

	var n := densified_points.size()
	var cum := _cumulative_arc_length(densified_points)
	var heights: Array[float] = []
	for i in range(n):
		var t: float = 0.0 if total_len <= 0.0 else cum[i] / total_len
		var chord := lerpf(h0, hN, t)
		var p := Vector2(densified_points[i][0], densified_points[i][1])
		var floor_h := sampler.height_at(p.x, p.y) + float(capa) * LAYER_CLEARANCE
		heights.append(maxf(chord, floor_h) + ROAD_LIFT)
	return heights
```

- [ ] **Step 5: `_compute_elevated_endpoint_heights`**

```gdscript
## Contrato 6 (W-4): altura resuelta de cada extremo de vía elevada Y CONSTRUIDA (sin
## empalme roto) -- ancla para las rampas de aproximación de sus vías vecinas (Tarea 2). En
## el extremo exacto (t=0 o t=1) la cuerda vale EXACTAMENTE height_at(extremo) por
## construcción, así que el máximo con el término de capa siempre lo gana (capa>=1 =>
## +LAYER_CLEARANCE>=5m>0): el extremo resuelto es SIEMPRE
## height_at(extremo) + capa*LAYER_CLEARANCE + ROAD_LIFT, sin necesidad de evaluar max().
static func _compute_elevated_endpoint_heights(roads: Array, endpoint_counts: Dictionary, sampler: TerrainSampler) -> Dictionary:
	var result := {}
	for road in roads:
		var points: Array = road.get("points", [])
		if points.size() < 2:
			continue
		if not _is_elevated(road):
			continue
		if _has_broken_splice(points, endpoint_counts):
			continue
		var capa := _elev_capa(road)
		var p0 := Vector2(points[0][0], points[0][1])
		var pN := Vector2(points[points.size() - 1][0], points[points.size() - 1][1])
		var h0 := sampler.height_at(p0.x, p0.y) + float(capa) * LAYER_CLEARANCE + ROAD_LIFT
		var hN := sampler.height_at(pN.x, pN.y) + float(capa) * LAYER_CLEARANCE + ROAD_LIFT
		result["%.2f|%.2f" % [p0.x, p0.y]] = h0
		result["%.2f|%.2f" % [pN.x, pN.y]] = hN
	return result
```

- [ ] **Step 6: `_add_elevated_strip` replaces `_add_deck_strip`**

Delete `_add_deck_strip` (current lines 139-213) entirely and replace it with:

```gdscript
## Contrato 6 (W-4): cinta con alturas ARBITRARIAS por vértice, ya resueltas por el
## llamador (tablero elevado en esta tarea; rampa en la Tarea 2 -- misma función para
## ambas). Reemplaza a _add_deck_strip de W-2: la regla de caja+colisión ya no es "todo o
## nada por vía", es POR SEGMENTO según su despeje sobre el terreno local (ELEVATED_EPS) --
## "una sola regla cubre tableros Y rampas" (contrato 6).
static func _add_elevated_strip(st: SurfaceTool, st_box: SurfaceTool, st_collision: SurfaceTool, points: Array, half_width: float, heights: Array[float], sampler: TerrainSampler) -> Dictionary:
	var offsets := RibbonUtil.compute_offsets(points, half_width)
	var offsets_a: Array[Vector2] = offsets["a"]
	var offsets_b: Array[Vector2] = offsets["b"]
	var n := points.size()
	var has_box := false
	var collision_len := 0.0

	for i in range(n - 1):
		var ya0 := Vector3(offsets_a[i].x, heights[i], offsets_a[i].y)
		var yb0 := Vector3(offsets_b[i].x, heights[i], offsets_b[i].y)
		var ya1 := Vector3(offsets_a[i + 1].x, heights[i + 1], offsets_a[i + 1].y)
		var yb1 := Vector3(offsets_b[i + 1].x, heights[i + 1], offsets_b[i + 1].y)

		# Cinta superior (visual, mismo material que vías normales -- mismo st que build()).
		st.add_vertex(ya0)
		st.add_vertex(ya1)
		st.add_vertex(yb0)
		st.add_vertex(yb0)
		st.add_vertex(ya1)
		st.add_vertex(yb1)

		# Despeje sobre terreno LOCAL en cada extremo del segmento (eje de la vía, no los
		# bordes -- suficiente para decidir "elevado" sin duplicar el muestreo por borde).
		var p0 := Vector2(points[i][0], points[i][1])
		var p1 := Vector2(points[i + 1][0], points[i + 1][1])
		var clr0 := heights[i] - sampler.height_at(p0.x, p0.y)
		var clr1 := heights[i + 1] - sampler.height_at(p1.x, p1.y)
		if clr0 > ELEVATED_EPS or clr1 > ELEVATED_EPS:
			has_box = true
			collision_len += p0.distance_to(p1)

			# Colisión aparte, SOLO la cinta superior (contrato 4/6).
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

	return {"has_box": has_box, "collision_len": collision_len}
```

- [ ] **Step 7: Wire into `build()`**

Replace `build()` (current lines 17-87) with (Task 2 will extend the `else` branch to add ramps — for now it still falls through to plain `_add_road_strip`):

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
	var elevated_built := 0
	var broken_splices := 0
	var ramps_built := 0
	var residual_steps := 0
	var has_box_geometry := false
	var elevated_collision_len := 0.0

	var endpoint_counts := _count_endpoint_occurrences(roads)
	var endpoint_heights := _compute_elevated_endpoint_heights(roads, endpoint_counts, sampler)

	for road in roads:
		var points: Array = road["points"]
		if points.size() < 2:
			continue
		var is_elev := _is_elevated(road)
		var is_elev_built := is_elev and not _has_broken_splice(points, endpoint_counts)

		var densified := _densify_points(points)
		points_inserted += densified["inserted"]
		var half_width: float = float(road["width"]) * 0.5

		if is_elev_built:
			var capa := _elev_capa(road)
			var heights := _compute_elevated_heights(densified["points"], points, capa, sampler)
			var res := _add_elevated_strip(st, st_box, st_collision, densified["points"], half_width, heights, sampler)
			has_box_geometry = has_box_geometry or res["has_box"]
			elevated_collision_len += float(res["collision_len"])
			elevated_built += 1
		else:
			if is_elev:
				broken_splices += 1
				print("RoadBuilder: vía id=%s elevada (deck/layer) con extremo sin empalme; drapeada como normal (regla de emergencia, contrato 4/6)" % str(road.get("id", "?")))
			_add_road_strip(st, densified["points"], half_width, sampler)
		roads_processed += 1

	st.generate_normals()
	var mesh := ArrayMesh.new()
	st.set_material(load(ROAD_MATERIAL_PATH))
	st.commit(mesh)

	if has_box_geometry:
		st_box.generate_normals()
		# DECISION_PENDIENTE (heredado de W-2, sigue aplicando en W-4): el ESPEC prescribe
		# color de vértice ×0.8 para inferior/costados; road_builder.gd no usa color de
		# vértice en ningún lugar, así que se usa un segundo material con albedo
		# precomputado ×0.8 -- resultado visual idéntico, cero riesgo al camino verificado.
		st_box.set_material(load(DECK_UNDERSIDE_MATERIAL_PATH))
		st_box.commit(mesh)

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "Roads"
	mesh_instance.mesh = mesh

	if has_box_geometry:
		mesh_instance.add_child(_build_deck_collision(st_collision))

	var elapsed_ms := Time.get_ticks_msec() - start_ms
	var vtx_count: int = mesh.surface_get_array_len(0) if mesh.get_surface_count() > 0 else 0
	var tri_count := vtx_count / 3
	print("RoadBuilder: %d vías, %d puntos insertados por subdivisión, %d vías elevadas por capa, %d rampas generadas, %d escalones residuales, %.1f m de colisión elevada, %d empalmes rotos, %d ms" % [
		roads_processed, points_inserted, elevated_built, ramps_built, residual_steps, elevated_collision_len, broken_splices, elapsed_ms])
	print("RoadBuilder no-regresión: %d vértices / %d triángulos (superficie 0, cinta superior)" % [vtx_count, tri_count])
	return mesh_instance
```

`_build_deck_collision`, `_densify_points`, `_add_road_strip`, `_ribbon_vertex`, `_count_endpoint_occurrences`, `_has_broken_splice` are **unchanged** — do not touch them in this task.

Note the diagnostic string already includes `%d rampas generadas` / `%d escalones residuales` / always prints `0` for both in this task (Task 2 introduces the code path that increments them) — this is not a placeholder, it's an accurate report of this task's actual scope (no ramp logic exists yet).

- [ ] **Step 8: Headless verification**

Run: `cd godot && "/c/Users/Brayhan/AppData/Local/Programs/Godot/Godot_v4.4-stable_win64_console.exe" --headless --path . --quit-after 5 2>&1`

Expected:
- No `SCRIPT ERROR`, no `Invalid get index`.
- `RoadBuilder: 527 vías, 6040 puntos insertados por subdivisión, 5 vías elevadas por capa, 0 rampas generadas, 0 escalones residuales, <M> m de colisión elevada, 0 empalmes rotos, <N> ms` — Jordán's 5 known bridges (unchanged count from W-2/W-3) should still all build as elevated (`elevated_built=5`), `ramps_built`/`residual_steps` at `0` (not wired yet), `broken_splices=0` (matches W-2/W-3's established "0 empalmes rotos"). Report the real `<M>` (elevated collision meters) — no prior baseline exists for this exact number since it's new, but it must be `> 0`.
- `RoadBuilder no-regresión: 47094 vértices / 15698 triángulos` — **must match exactly** (topology/tessellation unchanged, only Y values of the 5 elevated roads may differ from before — that is expected and correct per this phase's Global Constraints, not a regression).
- `WaterBuilder`/`BuildingBuilder`/`TrafficGraph` lines unchanged from the pre-phase baseline (this task doesn't touch those systems).

Additionally, as a **targeted correctness check** (not just "no crash"): print (temporarily, remove before commit) the resolved height of the Calle 60 bridge segment near world `(-88.15, 285.5)` (road id 380 from W-3's investigation) and confirm it's now noticeably higher than the ~59.8 pre-W-4 value found during W-3's human checklist (expected: close to `terrain(~59.0) + 1*5.0 + ROAD_LIFT ≈ 64.1`, since that crossing has a real flat crossing, i.e. the `capa` term should win there now). Report the actual number you observe.

- [ ] **Step 9: Commit**

```bash
git add godot/scripts/road_builder.gd
git commit -m "$(cat <<'EOF'
feat(w-4): road_builder - generaliza elevacion a max(cuerda, terreno+capa*5) y regla uniforme de colision

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: `road_builder.gd` — rampas de aproximación

**Files:**
- Modify: `godot/scripts/road_builder.gd`

**Interfaces:**
- Consumes: `_compute_elevated_endpoint_heights` (Task 1), `_add_elevated_strip` (Task 1, same function — no new rendering path).
- Produces: `RoadBuilder._compute_ramp_heights(original_points, densified_points, endpoint_heights, sampler) -> Dictionary` (`{"is_ramp": bool, "heights": Array[float], "residual_steps": int}`), used only within `build()`.

- [ ] **Step 1: Add ramp constants**

After `ELEVATED_EPS` (added in Task 1):

```gdscript
## Contrato 6 (W-4): longitud de arco de la rampa de aproximación entre una vía elevada y
## sus vecinas a nivel.
const RAMP_LENGTH := 60.0
## Contrato 6 (W-4): pendiente máxima de una rampa; por encima, se acepta un escalón
## residual en vez de forzar más pendiente (no se encadena a la vía siguiente).
const RAMP_MAX_GRADE := 0.15
```

- [ ] **Step 2: `_height_at_arc_distance`**

```gdscript
## Altura "normal" interpolada a una distancia de arco exacta `dist` desde el extremo
## indicado (from_start) de la polilínea -- usada como objetivo al final de una zona de
## rampa que no cae exactamente en un vértice densificado existente. Si `dist` excede la
## longitud total, retorna la altura del extremo lejano (la rampa entonces cubre TODA la
## vía, el caso "toda la vía si es más corta" del contrato 6).
static func _height_at_arc_distance(normal_heights: Array[float], cum: Array[float], total_len: float, dist: float, from_start: bool) -> float:
	var target: float = dist if from_start else (total_len - dist)
	var n := cum.size()
	for i in range(n - 1):
		if cum[i] <= target and target <= cum[i + 1]:
			var seg: float = cum[i + 1] - cum[i]
			var f: float = 0.0 if seg <= 0.0 else (target - cum[i]) / seg
			return lerpf(normal_heights[i], normal_heights[i + 1], f)
	return normal_heights[n - 1] if target >= cum[n - 1] else normal_heights[0]
```

- [ ] **Step 3: `_apply_ramp_from_end`**

```gdscript
## Aplica el perfil de rampa desde un extremo (from_start=true: nodo-ancla en cum[0]=0.0;
## from_start=false: nodo-ancla en cum[dn-1]=total_len) sobre `heights` IN-PLACE, tomando el
## máximo con lo que ya hubiera -- cubre el caso raro de una vía que es rampa desde AMBOS
## extremos a la vez (# DECISION_PENDIENTE: el contrato no cubre este caso doble
## explícitamente; tomar el máximo punto a punto es la resolución más segura -- nunca hunde
## la rampa por debajo de lo que cualquiera de sus dos anclas exigiría, y coincide con la
## regla "nunca se hunde bajo el terreno" que ya rige cada rampa individual). Retorna 1 si
## esta rampa necesitó aceptar un escalón residual (pendiente > RAMP_MAX_GRADE), si no 0.
static func _apply_ramp_from_end(heights: Array[float], normal_heights: Array[float], cum: Array[float], total_len: float, h_nodo: float, from_start: bool) -> int:
	var dn := heights.size()
	var ramp_len: float = minf(RAMP_LENGTH, total_len)
	if ramp_len <= 0.0:
		return 0

	var target_normal := _height_at_arc_distance(normal_heights, cum, total_len, ramp_len, from_start)
	var max_drop := RAMP_MAX_GRADE * ramp_len
	var needed_drop := h_nodo - target_normal
	var target_at_end: float = target_normal
	var residual := 0
	if needed_drop > max_drop:
		target_at_end = h_nodo - max_drop
		residual = 1

	for i in range(dn):
		var d: float = cum[i] if from_start else (total_len - cum[i])
		if d > ramp_len:
			continue  # fuera de la zona de rampa de ESTE extremo (puede seguir siendo rampa del otro extremo)
		var frac: float = 0.0 if ramp_len <= 0.0 else d / ramp_len
		var h_ramp := lerpf(h_nodo, target_at_end, frac)
		var floor_h := normal_heights[i]
		heights[i] = maxf(heights[i], maxf(h_ramp, floor_h))
	return residual
```

- [ ] **Step 4: `_compute_ramp_heights`**

```gdscript
## Contrato 6 (W-4): si un extremo de esta vía (NO elevada) coincide con el extremo
## resuelto de una vía elevada construida (endpoint_heights, Tarea 1), esta vía se
## convierte en rampa desde ese extremo por hasta RAMP_LENGTH m de arco (o toda la vía si
## es más corta). Los vértices de rampa usan max(h_rampa(t), height_at(t)+ROAD_LIFT) --
## nunca se hunden bajo el terreno (contrato 6).
static func _compute_ramp_heights(original_points: Array, densified_points: Array, endpoint_heights: Dictionary, sampler: TerrainSampler) -> Dictionary:
	var n := original_points.size()
	var p_start := Vector2(original_points[0][0], original_points[0][1])
	var p_end := Vector2(original_points[n - 1][0], original_points[n - 1][1])
	var key_start := "%.2f|%.2f" % [p_start.x, p_start.y]
	var key_end := "%.2f|%.2f" % [p_end.x, p_end.y]

	var has_start := endpoint_heights.has(key_start)
	var has_end := endpoint_heights.has(key_end)
	if not has_start and not has_end:
		return {"is_ramp": false, "heights": [], "residual_steps": 0}

	var cum := _cumulative_arc_length(densified_points)
	var total_len: float = cum[cum.size() - 1]
	var dn := densified_points.size()

	var normal_heights: Array[float] = []
	for i in range(dn):
		var p := Vector2(densified_points[i][0], densified_points[i][1])
		normal_heights.append(sampler.height_at(p.x, p.y) + ROAD_LIFT)

	var heights: Array[float] = normal_heights.duplicate()
	var residual_steps := 0

	if has_start:
		var h_nodo: float = endpoint_heights[key_start]
		residual_steps += _apply_ramp_from_end(heights, normal_heights, cum, total_len, h_nodo, true)

	if has_end:
		var h_nodo2: float = endpoint_heights[key_end]
		residual_steps += _apply_ramp_from_end(heights, normal_heights, cum, total_len, h_nodo2, false)

	return {"is_ramp": true, "heights": heights, "residual_steps": residual_steps}
```

- [ ] **Step 5: Wire into `build()`'s `else` branch**

Replace the `else` branch of the `if is_elev_built:` block (introduced in Task 1 Step 7):

```gdscript
		else:
			if is_elev:
				broken_splices += 1
				print("RoadBuilder: vía id=%s elevada (deck/layer) con extremo sin empalme; drapeada como normal (regla de emergencia, contrato 4/6)" % str(road.get("id", "?")))
				_add_road_strip(st, densified["points"], half_width, sampler)
			else:
				var ramp := _compute_ramp_heights(points, densified["points"], endpoint_heights, sampler)
				if ramp["is_ramp"]:
					var heights: Array[float] = ramp["heights"]
					var res2 := _add_elevated_strip(st, st_box, st_collision, densified["points"], half_width, heights, sampler)
					has_box_geometry = has_box_geometry or res2["has_box"]
					elevated_collision_len += float(res2["collision_len"])
					ramps_built += 1
					residual_steps += int(ramp["residual_steps"])
				else:
					_add_road_strip(st, densified["points"], half_width, sampler)
```

(A broken-splice elevated road is still drapeada normally and is never itself a ramp candidate — `_compute_elevated_endpoint_heights` from Task 1 already excludes it from `endpoint_heights`, so no other road can ramp toward it either, correctly matching road_builder's own decision.)

- [ ] **Step 6: Headless verification**

Run: `cd godot && "/c/Users/Brayhan/AppData/Local/Programs/Godot/Godot_v4.4-stable_win64_console.exe" --headless --path . --quit-after 5 2>&1`

Expected:
- No `SCRIPT ERROR`, no `Invalid get index`.
- `RoadBuilder: 527 vías, ..., 5 vías elevadas por capa, <R> rampas generadas, <S> escalones residuales, <M2> m de colisión elevada, 0 empalmes rotos, ... ms` — report the real `<R>`/`<S>`/`<M2>` (Jordán's 5 bridges should each have up to 2 ramp neighbors if their approach roads are plain residential/secondary ways sharing their endpoints — `<R>` is expected to be `> 0` and likely close to `10` if all 10 endpoints have a non-elevated neighbor, but report whatever actually prints, don't force it). `<M2>` (elevated collision meters) should be `>=` Task 1's value (ramps add more collision-covered length).
- `RoadBuilder no-regresión: 47094 vértices / 15698 triángulos` — **must still match exactly** (ramps only move Y values of existing vertices on existing roads, they never add/remove roads or change subdivision counts).
- `WaterBuilder`/`BuildingBuilder`/`TrafficGraph` unchanged.

- [ ] **Step 7: Commit**

```bash
git add godot/scripts/road_builder.gd
git commit -m "$(cat <<'EOF'
feat(w-4): road_builder - rampas de aproximacion de una pasada para vias elevadas

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: `traffic_graph.gd` — `node_y_resuelta` reemplaza `edge_deck`

**Files:**
- Modify: `godot/scripts/traffic_graph.gd`

**Interfaces:**
- Removes: `edge_deck`, `edge_deck_y_from`, `edge_deck_y_to` (confirmed by grep to have exactly one consumer outside this file — `traffic_manager.gd`'s `_apply_pose`, replaced in Task 4).
- Produces: `TrafficGraph.node_y_resuelta: PackedFloat32Array` (index = node index, same space as `node_pos`), `TrafficGraph.node_elevated: Array[bool]` (same index space; precomputed once so `traffic_manager.gd` never needs to call `sampler.height_at` to decide "is this node elevated").
- Consumes: `sampler.height_at` (already a `build()` parameter since W-3), `road.get("layer")`/`road.get("deck")`.
- **Untouched:** `edge_capa`, `mixed_capa_intersections`, `_same_capa`, `_classify_nodes`'s guard, `_count_road_endpoint_occurrences`, `_has_broken_splice` — W-3's intersection guard is completely independent of this task and must not change.

This task duplicates `road_builder.gd`'s Task 1+2 elevation/ramp math at node-resolution granularity — same function names and structure as `road_builder.gd` so the two are easy to compare side-by-side and keep in sync, matching this codebase's established convention (`water_builder.gd` duplicating `building_builder.gd`'s footprint helpers; this file's own W-3 duplication of `road_builder.gd`'s broken-splice check).

- [ ] **Step 1: Remove the old deck-Y fields, add the new ones**

Replace (current lines 38-41):

```gdscript
var edge_deck: Array[String] = []
var edge_deck_y_from: PackedFloat32Array = PackedFloat32Array()  ## altura de cuerda de tablero en el nodo `from` (solo si edge_deck[i] != ""); 0.0 en aristas normales
var edge_deck_y_to: PackedFloat32Array = PackedFloat32Array()    ## idem, nodo `to`
var edge_capa: PackedInt32Array = PackedInt32Array()  ## capa_efectiva por arista (layer si existe; si no, bridge=+1/tunnel=-1/normal=0). Contrato 7, W-3.
```

with:

```gdscript
var edge_capa: PackedInt32Array = PackedInt32Array()  ## capa_efectiva por arista (layer si existe; si no, bridge=+1/tunnel=-1/normal=0). Contrato 7, W-3.
var node_y_resuelta: PackedFloat32Array = PackedFloat32Array()  ## índice -> altura final resuelta en ese punto (tablero/rampa/drapeado). Contrato 6/7, W-4: reemplaza edge_deck*.
var node_elevated: Array[bool] = []  ## índice -> |node_y_resuelta - terreno| > ELEVATED_EPS, precomputado una vez (evita muestrear terreno cada frame en traffic_manager.gd)
```

Add the new constant next to `FUSE_FMT` (current line 21-23 block):

```gdscript
const ELEVATED_EPS := 0.5  ## [ESTRUCTURAL] Contrato 6 (W-4), duplicado de road_builder.gd -- ver su comentario para la justificación de por qué se duplica en vez de referenciar cruzado.
```

- [ ] **Step 2: Duplicate the arc-length + elevation + ramp helpers**

Add these as new private-by-convention methods (not `static`, matching this file's existing style — `_count_road_endpoint_occurrences`/`_has_broken_splice` are instance methods here even though their `road_builder.gd` counterparts are `static`):

```gdscript
## Duplicado deliberado de road_builder.gd::_is_elevated (contrato 6, W-4) -- mismo
## convenio que _count_road_endpoint_occurrences/_has_broken_splice (W-3): pequeña
## duplicación local en vez de alcance cruzado a estáticos de otra clase. Mantener en
## sincronía con road_builder.gd si esa lógica cambia.
func _is_elevated(road: Dictionary) -> bool:
	var deck: String = String(road.get("deck", ""))
	if deck == "bridge":
		return true
	if road.has("layer") and int(road["layer"]) > 0:
		return true
	return false


func _elev_capa(road: Dictionary) -> int:
	var raw: int = int(road["layer"]) if road.has("layer") else 1
	return clampi(raw, 1, 3)


func _arc_length(points: Array) -> float:
	var total := 0.0
	for i in range(points.size() - 1):
		var a := Vector2(points[i][0], points[i][1])
		var b := Vector2(points[i + 1][0], points[i + 1][1])
		total += a.distance_to(b)
	return total


func _cumulative_arc_length(points: Array) -> Array[float]:
	var cum: Array[float] = [0.0]
	for i in range(points.size() - 1):
		var a := Vector2(points[i][0], points[i][1])
		var b := Vector2(points[i + 1][0], points[i + 1][1])
		cum.append(cum[i] + a.distance_to(b))
	return cum


## Duplicado de road_builder.gd::_compute_elevated_heights, evaluado sobre los puntos
## ORIGINALES de la vía (traffic_graph.gd no densifica -- W-3 ya estableció que la
## fracción de arco t es idéntica en los puntos compartidos entre la lista original y su
## versión densificada, así que evaluar directamente sobre los originales es equivalente).
func _compute_elevated_heights(points: Array, capa: int, sampler: TerrainSampler) -> Array[float]:
	var p0 := Vector2(points[0][0], points[0][1])
	var pN := Vector2(points[points.size() - 1][0], points[points.size() - 1][1])
	var h0 := sampler.height_at(p0.x, p0.y)
	var hN := sampler.height_at(pN.x, pN.y)
	var total_len := _arc_length(points)

	var n := points.size()
	var cum := _cumulative_arc_length(points)
	var heights: Array[float] = []
	for i in range(n):
		var t: float = 0.0 if total_len <= 0.0 else cum[i] / total_len
		var chord := lerpf(h0, hN, t)
		var p := Vector2(points[i][0], points[i][1])
		var floor_h := sampler.height_at(p.x, p.y) + float(capa) * LAYER_CLEARANCE_DUP
		heights.append(maxf(chord, floor_h) + ROAD_LIFT_DUP)
	return heights


func _compute_elevated_endpoint_heights(roads: Array, endpoint_counts: Dictionary, sampler: TerrainSampler) -> Dictionary:
	var result := {}
	for road in roads:
		var points: Array = road.get("points", [])
		if points.size() < 2:
			continue
		if not _is_elevated(road):
			continue
		if _has_broken_splice(points, endpoint_counts):
			continue
		var capa := _elev_capa(road)
		var p0 := Vector2(points[0][0], points[0][1])
		var pN := Vector2(points[points.size() - 1][0], points[points.size() - 1][1])
		var h0 := sampler.height_at(p0.x, p0.y) + float(capa) * LAYER_CLEARANCE_DUP + ROAD_LIFT_DUP
		var hN := sampler.height_at(pN.x, pN.y) + float(capa) * LAYER_CLEARANCE_DUP + ROAD_LIFT_DUP
		result["%.2f|%.2f" % [p0.x, p0.y]] = h0
		result["%.2f|%.2f" % [pN.x, pN.y]] = hN
	return result


func _height_at_arc_distance(normal_heights: Array[float], cum: Array[float], total_len: float, dist: float, from_start: bool) -> float:
	var target: float = dist if from_start else (total_len - dist)
	var n := cum.size()
	for i in range(n - 1):
		if cum[i] <= target and target <= cum[i + 1]:
			var seg: float = cum[i + 1] - cum[i]
			var f: float = 0.0 if seg <= 0.0 else (target - cum[i]) / seg
			return lerpf(normal_heights[i], normal_heights[i + 1], f)
	return normal_heights[n - 1] if target >= cum[n - 1] else normal_heights[0]


func _apply_ramp_from_end(heights: Array[float], normal_heights: Array[float], cum: Array[float], total_len: float, h_nodo: float, from_start: bool) -> void:
	var dn := heights.size()
	var ramp_len: float = minf(RAMP_LENGTH_DUP, total_len)
	if ramp_len <= 0.0:
		return
	var target_normal := _height_at_arc_distance(normal_heights, cum, total_len, ramp_len, from_start)
	var max_drop := RAMP_MAX_GRADE_DUP * ramp_len
	var needed_drop := h_nodo - target_normal
	var target_at_end: float = target_normal
	if needed_drop > max_drop:
		target_at_end = h_nodo - max_drop
	for i in range(dn):
		var d: float = cum[i] if from_start else (total_len - cum[i])
		if d > ramp_len:
			continue
		var frac: float = 0.0 if ramp_len <= 0.0 else d / ramp_len
		var h_ramp := lerpf(h_nodo, target_at_end, frac)
		heights[i] = maxf(heights[i], maxf(h_ramp, normal_heights[i]))


func _compute_ramp_heights(points: Array, endpoint_heights: Dictionary, sampler: TerrainSampler) -> Dictionary:
	var n := points.size()
	var p_start := Vector2(points[0][0], points[0][1])
	var p_end := Vector2(points[n - 1][0], points[n - 1][1])
	var key_start := "%.2f|%.2f" % [p_start.x, p_start.y]
	var key_end := "%.2f|%.2f" % [p_end.x, p_end.y]
	var has_start := endpoint_heights.has(key_start)
	var has_end := endpoint_heights.has(key_end)
	if not has_start and not has_end:
		return {"is_ramp": false, "heights": []}

	var cum := _cumulative_arc_length(points)
	var total_len: float = cum[cum.size() - 1]
	var normal_heights: Array[float] = []
	for i in range(n):
		var p := Vector2(points[i][0], points[i][1])
		normal_heights.append(sampler.height_at(p.x, p.y) + ROAD_LIFT_DUP)
	var heights: Array[float] = normal_heights.duplicate()

	if has_start:
		_apply_ramp_from_end(heights, normal_heights, cum, total_len, endpoint_heights[key_start], true)
	if has_end:
		_apply_ramp_from_end(heights, normal_heights, cum, total_len, endpoint_heights[key_end], false)
	return {"is_ramp": true, "heights": heights}
```

Add the three duplicated numeric constants next to `ELEVATED_EPS` (Step 1) — suffixed `_DUP` to make the duplication (and its必须-stay-in-sync relationship to `road_builder.gd`) impossible to miss at every call site:

```gdscript
const LAYER_CLEARANCE_DUP := 5.0  ## Duplicado de road_builder.gd::LAYER_CLEARANCE.
const RAMP_LENGTH_DUP := 60.0     ## Duplicado de road_builder.gd::RAMP_LENGTH.
const RAMP_MAX_GRADE_DUP := 0.15  ## Duplicado de road_builder.gd::RAMP_MAX_GRADE.
const ROAD_LIFT_DUP := 0.10       ## Duplicado de road_builder.gd::ROAD_LIFT (ya usado implícitamente por W-2's chord_y antes de esta tarea; ahora explícito).
```

- [ ] **Step 3: Compute `node_y_resuelta`/`node_elevated` in `build()`**

Add a new step to `build()` (current lines 59-66), after `_build_nodes_and_edges`:

```gdscript
func build(roads: Array, controls: Array, sampler: TerrainSampler) -> void:
	var t0 := Time.get_ticks_msec()
	_build_nodes_and_edges(roads, sampler)
	_resolve_node_heights(roads, sampler)
	_classify_nodes()
	_bind_controls(controls)
	_assign_controllers()
	_count_unconnected_crossings()
	build_ms = Time.get_ticks_msec() - t0
```

Add the new pass (place it after `_build_nodes_and_edges`, before `_classify_nodes`):

```gdscript
## Contrato 6/7 (W-4): resuelve node_y_resuelta/node_elevated para TODO nodo del grafo,
## duplicando la lógica de road_builder.gd -- primero las alturas de vías elevadas
## construidas (ancla para rampas), luego cada vía no-elevada se evalúa como posible
## rampa, y todo lo que queda sin tocar cae al drapeado normal (altura de terreno +
## ROAD_LIFT). Un nodo puede ser visitado por más de una vía; se toma el máximo (mismo
## criterio "nunca se hunde" que _apply_ramp_from_end ya usa internamente).
func _resolve_node_heights(roads: Array, sampler: TerrainSampler) -> void:
	node_y_resuelta.resize(node_pos.size())
	node_elevated.resize(node_pos.size())
	for i in range(node_pos.size()):
		node_y_resuelta[i] = sampler.height_at(node_pos[i].x, node_pos[i].y) + ROAD_LIFT_DUP

	var endpoint_counts := _count_road_endpoint_occurrences(roads)
	var endpoint_heights := _compute_elevated_endpoint_heights(roads, endpoint_counts, sampler)

	for road in roads:
		var pts: Array = road.get("points", [])
		if pts.size() < 2:
			continue
		var is_elev := _is_elevated(road)
		var is_elev_built := is_elev and not _has_broken_splice(pts, endpoint_counts)

		var heights: Array[float] = []
		var applies := false
		if is_elev_built:
			heights = _compute_elevated_heights(pts, _elev_capa(road), sampler)
			applies = true
		elif not is_elev:
			var ramp := _compute_ramp_heights(pts, endpoint_heights, sampler)
			if ramp["is_ramp"]:
				heights = ramp["heights"]
				applies = true

		if not applies:
			continue
		for i in range(pts.size()):
			var key := FUSE_FMT % [float(pts[i][0]), float(pts[i][1])]
			var idx: int = _fuse.get(key, -1)
			if idx == -1:
				continue
			node_y_resuelta[idx] = maxf(node_y_resuelta[idx], heights[i])

	for i in range(node_pos.size()):
		var terrain_h := sampler.height_at(node_pos[i].x, node_pos[i].y)
		node_elevated[i] = absf(node_y_resuelta[i] - terrain_h) > ELEVATED_EPS
```

(`_fuse` already maps `"%.2f|%.2f"` → node index, populated by `_get_or_add_node` during `_build_nodes_and_edges` which already ran — this reuses that dictionary rather than rebuilding it, exactly mirroring how nodes were identified during graph construction.)

- [ ] **Step 4: Update `_add_edge`/`_build_nodes_and_edges` to drop the removed fields**

In `_build_nodes_and_edges` (current lines 99-161), remove the `chord_y`/`is_built_deck`/`deck` computation block used only for the old `edge_deck*` fields (current lines 111-150), and simplify the edge-adding call. Replace the whole function body with:

```gdscript
func _build_nodes_and_edges(roads: Array, sampler: TerrainSampler) -> void:
	var endpoint_counts := _count_road_endpoint_occurrences(roads)

	for road in roads:
		var pts: Array = road.get("points", [])
		if pts.size() < 2:
			continue
		var rid := int(road.get("id", -1))
		var hw := String(road.get("highway", ""))
		var w := float(road.get("width", 6.0))
		# v1.1 retrocompatible: oneway ausente = 0 (bidireccional).
		var ow := int(road.get("oneway", 0))
		var raw_deck := String(road.get("deck", ""))

		# Fase W-3 (contrato 7): capa_efectiva de la vía completa -- layer del tag OSM si
		# existe, si no bridge/tunnel/normal. Sin cambios en W-4 (el guarda de W-3 es
		# independiente de node_y_resuelta).
		var capa: int
		if road.has("layer"):
			capa = int(road["layer"])
		elif raw_deck == "bridge":
			capa = 1
		elif raw_deck == "tunnel":
			capa = -1
		else:
			capa = 0

		var prev_node := _get_or_add_node(pts[0])
		for i in range(1, pts.size()):
			var cur_node := _get_or_add_node(pts[i])
			if cur_node == prev_node:
				# Puntos consecutivos idénticos tras redondeo: no hay segmento.
				continue
			_add_edge(prev_node, cur_node, rid, hw, w, ow, capa)
			prev_node = cur_node
```

And `_add_edge` (current lines 177-191) drops the removed parameters:

```gdscript
func _add_edge(a: int, b: int, rid: int, hw: String, w: float, ow: int, capa: int) -> void:
	var eidx := edge_from.size()
	edge_from.append(a)
	edge_to.append(b)
	edge_road_id.append(rid)
	edge_highway.append(hw)
	edge_width.append(w)
	edge_oneway.append(ow)
	edge_length.append(node_pos[a].distance_to(node_pos[b]))
	edge_capa.append(capa)
	node_edges[a].append(eidx)
	node_edges[b].append(eidx)
```

`_get_or_add_node`, `_classify_nodes`, `_same_capa`, `_bind_controls`, `_assign_controllers`, `_count_unconnected_crossings`, and everything below `print_diagnostics` (the debug overlay) are **unchanged**.

- [ ] **Step 5: Diagnostic print**

In `print_diagnostics` (current lines 350-361), add one line after the `intersecciones con capa mixta excluidas` line:

```gdscript
func print_diagnostics() -> void:
	var bd := _controller_breakdown()
	print("[TrafficGraph] nodos:%d  aristas:%d  intersecciones:%d  terminales:%d" % [
		node_pos.size(), edge_from.size(), intersections.size(), terminals.size()])
	print("[TrafficGraph] controladores -> signal:%d  priority_stop:%d  priority_pure:%d" % [
		bd[0], bd[1], bd[2]])
	print("[TrafficGraph] controles vinculados:%d  descartados:%d" % [
		controls_bound, controls_discarded])
	print("[TrafficGraph] cruces no conectados:%d  (%.1f%% de cruces visibles)" % [
		unconnected_crossings, unconnected_crossings_pct()])
	print("[TrafficGraph] intersecciones con capa mixta excluidas: %d" % mixed_capa_intersections)
	print("[TrafficGraph] nodos con y_resuelta != terreno: %d" % _count_elevated_nodes())
	print("[TrafficGraph] construccion: %d ms" % build_ms)


func _count_elevated_nodes() -> int:
	var n := 0
	for e in node_elevated:
		if e:
			n += 1
	return n
```

- [ ] **Step 6: Headless verification**

Run: `cd godot && "/c/Users/Brayhan/AppData/Local/Programs/Godot/Godot_v4.4-stable_win64_console.exe" --headless --path . --quit-after 5 2>&1`

Expected:
- No `SCRIPT ERROR`, no `Invalid get index` (in particular, watch for an out-of-bounds on `node_y_resuelta`/`node_elevated` if `resize()` ordering is wrong — both must be sized to `node_pos.size()` before any indexed write).
- `[TrafficGraph] nodos:1493  aristas:1809  intersecciones:619  terminales:152` and `intersecciones con capa mixta excluidas: 3` — **unchanged from the W-3 baseline** (this task only replaces the Y-height mechanism; topology and the W-3 guard are untouched).
- New line `[TrafficGraph] nodos con y_resuelta != terreno: N` — report the real `N` (expect it to be noticeably larger than the old edge-based deck count, since ramps now also count as elevated at every ramped point, not just the 5 bridges' own vertices).
- `RoadBuilder`/`WaterBuilder`/`BuildingBuilder` lines unchanged (this task touches only `traffic_graph.gd`).

- [ ] **Step 7: Commit**

```bash
git add godot/scripts/traffic_graph.gd
git commit -m "$(cat <<'EOF'
feat(w-4): trafico - node_y_resuelta reemplaza edge_deck (contrato 7)

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: `traffic_manager.gd` — regla general del agente sobre `node_y_resuelta`

**Files:**
- Modify: `godot/scripts/traffic_manager.gd`

**Interfaces:**
- Consumes: `TrafficGraph.node_y_resuelta`, `TrafficGraph.node_elevated` (Task 3).

- [ ] **Step 1: Replace the deck branch in `_apply_pose`**

Replace the Y-computation block at the end of `_apply_pose` (current lines 954-970 — everything from the `# Fase W-2 (contrato 7...` comment through `ground_y = _sampler.height_at(pos2.x, pos2.y)`):

```gdscript
	# Fase W-4 (contrato 7, reemplaza el flag deck por arista de W-2): cada nodo del grafo
	# ya trae su y_resuelta (tablero, rampa o drapeado, calculado por TrafficGraph a partir
	# de la misma fórmula que road_builder.gd usa para la malla visual). Si CUALQUIERA de
	# los dos extremos de la arista está "elevado" (node_elevated, precomputado una vez
	# contra ELEVATED_EPS), se interpola la y entre las y_resuelta de los extremos por la
	# fracción recorrida; si no, se muestrea terreno cada frame como siempre (regla R).
	var from_node := _graph.edge_from[agent.edge]
	var to_node := _graph.edge_to[agent.edge]
	var ground_y: float
	if _graph.node_elevated[from_node] or _graph.node_elevated[to_node]:
		var y_res_from: float = _graph.node_y_resuelta[from_node]
		var y_res_to: float = _graph.node_y_resuelta[to_node]
		var y_entry := y_res_from if agent.dir == 1 else y_res_to
		var y_far := y_res_to if agent.dir == 1 else y_res_from
		var t := clampf(agent.s / len_e, 0.0, 1.0)
		ground_y = lerpf(y_entry, y_far, t)
	else:
		ground_y = _sampler.height_at(pos2.x, pos2.y)
	var basis := Basis(Vector3.UP, agent.yaw)
	agent.body.global_transform = Transform3D(basis, Vector3(pos2.x, ground_y, pos2.y))
```

`from_node`/`to_node` match the existing `_entry_node`/`_far_node` convention (`edge_from` is entry when `agent.dir==1`) — `y_entry`/`y_far` orientation mirrors that exactly, same as the W-2/W-3 code this replaces.

- [ ] **Step 2: Headless verification**

Run: `cd godot && "/c/Users/Brayhan/AppData/Local/Programs/Godot/Godot_v4.4-stable_win64_console.exe" --headless --path . --quit-after 5 2>&1 | grep -E "TrafficGraph|SCRIPT ERROR|Invalid get index"`

Expected: `[TrafficGraph]` lines identical to Task 3's (this task only changes how `traffic_manager.gd` *reads* the graph, not the graph itself). No `SCRIPT ERROR`. Traffic agent Y-tracking on elevated roads/ramps can't be verified headless — flagged for the human checklist (Task 6).

- [ ] **Step 3: Commit**

```bash
git add godot/scripts/traffic_manager.gd
git commit -m "$(cat <<'EOF'
feat(w-4): trafico - _apply_pose usa node_y_resuelta/node_elevated (contrato 7)

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Generar la zona de validación (Bogotá) y su tabla de conteos

**No files modified in the repo** — disposable pipeline artifact, same convention as W-3's Honda.

**Interfaces:**
- Consumes: `generate_map.py --lat --lon --size --name --stats --svg` (existing CLI, unchanged).
- Produces: `data_pipeline/output/map.json` (consumed by Task 6).

- [ ] **Step 1: Run the pipeline CLI**

```bash
cd data_pipeline && python generate_map.py --lat 4.753 --lon -74.045 --size M --name "Bogotá (Autopista Norte x Calle 170)" --stats --svg
```

Center verified live against Overpass on 2026-07-13 (query bbox `4.7405,-74.0575,4.7655,-74.0325`, larger than the M-sized zone this generates but confirming the surrounding area is rich in exactly what this phase needs): 60 `bridge=yes` ways (many "Avenida Calle 170"/"Avenida Calle 183" elevated avenues), 34 `*_link` ways (`trunk_link`/`primary_link` — genuine interchange ramps, the W-1 prerequisite this phase's ramp propagation specifically needs), and 111 ways carrying an explicit `layer` tag with values `{1: 81, -1: 22, 2: 6, 0: 1, 5: 1}` — the `layer=2` elements in particular confirm a genuine multi-level structure exists in this zone, and the presence of a `layer=5` outlier is a useful real-data test of the `_elev_capa` clamp `[1,3]`.

- [ ] **Step 2: Report the table verbatim**

Copy the complete printed output into the task report. Confirm: `puentes >= 1` and `ramales(*_link) >= 1` (both already verified live above) — the `*_link` count in particular matters more for this phase than for W-3, since ramps are exactly what W-4 validates and `*_link` roads are described by the master spec as "casi siempre estas rampas en los datos reales." If either is 0, STOP and report it before proceeding to Task 6.

- [ ] **Step 3: No commit** (disposable artifact; confirm `git status --short data_pipeline/output/` and `data_pipeline/cache/` are clean after — W-3's final review found this exact class of leftover, clean it immediately if present, do not defer to a later task).

---

## Task 6: Cargar Bogotá en Godot, verificación headless, checklist humano

**Files:**
- Temporarily overwrite (restored in Task 7, not this task): `godot/data/map.json`

- [ ] **Step 1: Back up Jordán, swap in Bogotá**

```bash
cd "C:\Users\Brayhan\Documents\RealDriving\ciudad-conducible"
cp godot/data/map.json /tmp/jordan_map_backup_w4.json
cp data_pipeline/output/map.json godot/data/map.json
```

- [ ] **Step 2: Headless run, capture diagnostics**

```bash
cd godot && "/c/Users/Brayhan/AppData/Local/Programs/Godot/Godot_v4.4-stable_win64_console.exe" --headless --path . --quit-after 5 2>&1
```

Expected: no `SCRIPT ERROR`, no `Invalid get index`. Report the actual printed values for `RoadBuilder` (vías elevadas por capa, rampas generadas, escalones residuales, m de colisión elevada — all should be meaningfully `> 0` given the verified real data), `WaterBuilder`, and `[TrafficGraph]` (in particular `nodos con y_resuelta != terreno`, which should be substantial given 81+ `layer=1` ways and 6 `layer=2` ways in the source data).

- [ ] **Step 3: Leave the swap in place, hand off the human checklist**

Do **not** restore Jordán in this task. Present this checklist to the human:

> **Checklist humano — Bogotá (nuevo):**
> - Abrir el proyecto en el editor de Godot y darle Play (el `map.json` activo ya es Bogotá).
> - El paso a desnivel se VE: una vía `layer=1` cruza notoriamente sobre la inferior, con caja opaca por debajo; si hay algo en `layer=2`, debe quedar claramente más alto que lo de `layer=1`.
> - Conducir el ciclo completo de un intercambiador: subir por una rampa (continua, sin escalones ni saltos), cruzar por arriba, bajar por otra — la colisión debe sostener el auto en TODO el recorrido.
> - Pasar por DEBAJO de un tramo elevado: caja opaca, sin ver a través.
> - Si hay tráfico cerca, observar que un auto de IA en una rampa/tablero no se hunde ni flota (seguirlo un momento).
> - Los escalones residuales impresos en la Tarea 2 (repetidos en esta corrida) deberían ser pocos; si alguno cae en un lugar prominente que veas manejando, anótalo.
>
> Cuando termines, avísame para restaurar Jordán y correr la regresión final (Tarea 7).

- [ ] **Step 4: No commit.**

---

## Task 7: Restaurar Jordán, regresión de Honda (W-3), regresión completa

**Files:**
- Restore: `godot/data/map.json` (via `git checkout`)

- [ ] **Step 1: Restore Jordán**

```bash
cd "C:\Users\Brayhan\Documents\RealDriving\ciudad-conducible"
git status --short godot/data/map.json
git checkout -- godot/data/map.json
git status --short godot/data/map.json
```

- [ ] **Step 2: Full headless regression boot on Jordán**

```bash
cd godot && "/c/Users/Brayhan/AppData/Local/Programs/Godot/Godot_v4.4-stable_win64_console.exe" --headless --path . --quit-after 5 2>&1
```

Expected, **all must match exactly** except where this phase intentionally changes elevated-road Y values (see Global Constraints):
- `WaterBuilder: 3 polígonos (0 descartados, 9 tris), 3 cintas de agua` — unchanged.
- `RoadBuilder: 527 vías, 6040 puntos insertados por subdivisión, 5 vías elevadas por capa, ...` — vías/puntos/elevated-count unchanged from Task 1/2's Jordán runs; `rampas generadas`/`escalones residuales`/`m de colisión elevada` should match Task 2's Jordán numbers exactly (same code, same data, deterministic).
- `RoadBuilder no-regresión: 47094 vértices / 15698 triángulos` — **must match exactly** (topology/tessellation never changes in this phase, only Y values).
- `BuildingBuilder: 4916 edificios, 0 descartados` — unchanged.
- `[TrafficGraph] nodos:1493 aristas:1809 intersecciones:619 terminales:152` and `intersecciones con capa mixta excluidas: 3` — **must match the W-3 baseline exactly** (W-4 never touches topology or the W-3 guard).
- No `SCRIPT ERROR`, no `Invalid get index`.

- [ ] **Step 3: Honda regression — the phase's explicit named regression check**

Regenerate Honda exactly as W-3 did:

```bash
cd data_pipeline && python generate_map.py --lat 5.2075 --lon -74.75 --size M --name "Honda, Tolima" --stats --svg
cd .. && cp data_pipeline/output/map.json godot/data/map.json
cd godot && "/c/Users/Brayhan/AppData/Local/Programs/Godot/Godot_v4.4-stable_win64_console.exe" --headless --path . --quit-after 5 2>&1
```

Expected: `puentes=2` (same as W-3's original Honda run), and critically — per the Global Constraints — **the built bridge's height at its midpoint must be unchanged from W-3's value** (the river crossing has real natural clearance, so `max()` must still pick the chord term, not the `capa*LAYER_CLEARANCE` term). Verify this explicitly: temporarily print (remove before commit — this is a one-off diagnostic, not a permanent addition) the resolved height at the built bridge's midpoint (road `id=71` from W-3's investigation, world `~(46, 589)`) and confirm it matches W-3's recorded value (`~86.33` chord height, `y_from=86.3292`/`y_to=86.3292` per the W-3 ledger) to within floating-point tolerance. If it changed, the `max()` formula is picking the wrong term for this case — STOP and report before proceeding, this is exactly the failure mode the Global Constraints call out by name.

Restore Jordán again immediately after this check:

```bash
cd "C:\Users\Brayhan\Documents\RealDriving\ciudad-conducible" && git checkout -- godot/data/map.json
```

- [ ] **Step 4: Hand off the final human regression checklist**

> **Checklist humano — regresión completa (en este orden):**
> - Honda: el puente sobre el Río Gualí se ve IGUAL que en la Tarea 5 de W-3 (misma altura, mismo aspecto) — si se ve más alto, hay un problema con la fórmula del contrato 6, repórtalo con los números impresos en el Paso 3 de esta tarea.
> - Jordán: conducción libre 3 minutos (calles, edificios, tráfico, props); contrarreloj completo con récords intactos; tráfico normal en las intersecciones de siempre; minimapa idéntico; ≥ 60 fps; carga < 20 s.
> - Exportar el proyecto (fuera del editor) y confirmar que corre — el contrato exige esto explícitamente para W-4 (no lo pidieron las fases anteriores).

- [ ] **Step 5: No commit** (Step 1/3's restores already leave the tracked file at its committed state).

---

## Self-Review Notes

1. **Spec coverage:** Contract 6's `max(cuerda, terreno+capa*LAYER_CLEARANCE)` formula → Task 1. Contract 6's ramp propagation (single-pass, `RAMP_LENGTH`, 15% grade cap, residual-step counting, no chaining beyond one road per endpoint, never sinks below terrain) → Task 2. Contract 6's uniform box/collision rule (`ELEVATED_EPS`, replaces "deck-only") → Task 1's `_add_elevated_strip` (used by both Task 1 and Task 2's call sites). Contract 7's `y_resuelta` per node + general agent rule, retiring the W-2 `deck` edge flag → Tasks 3-4. The phase's required diagnostic string → split across `RoadBuilder`'s print (Task 1/2) and `TrafficGraph`'s print (Task 3), matching this codebase's existing per-class-diagnostic convention rather than one combined string spanning two classes. "Una capital que el humano elige y confirma" → Task 5, human already chose Bogotá and the chosen center was verified live against Overpass before being baked into the plan. Both required regression checks (Honda's chord must stay unchanged; Jordán's full suite) → Task 7. Explicitly-out-of-scope items (tunnels, relations, water animation/collision, pedestrians, pillars, railings, >3 layers, curved ramps, iterative solvers) → none implemented, correctly.
2. **Placeholder scan:** none — every step has complete code or an exact command with an expected value; the genuinely unknown-ahead-of-time numbers (ramps built, residual steps, elevated collision meters, elevated node counts) are explicitly flagged "report the real number," consistent with W-2/W-3.
3. **Type consistency:** `_compute_elevated_heights`/`_compute_ramp_heights`'s `heights: Array[float]` return shape is consumed identically by `_add_elevated_strip` at both its call sites (elevated roads, Task 1; ramps, Task 2). `_compute_elevated_endpoint_heights`'s `Dictionary` (key `"%.2f|%.2f"` → `float`) is produced once in `road_builder.gd::build()` (Task 1) and consumed by `_compute_ramp_heights` (Task 2) in the same file, and independently re-derived (not shared) by `traffic_graph.gd::_resolve_node_heights` (Task 3) per the duplication convention. `TrafficGraph.node_y_resuelta`/`node_elevated`'s index space matches `node_pos` exactly (both `resize()`d to `node_pos.size()` before any indexed write, Task 3 Step 3). `traffic_manager.gd`'s new `_apply_pose` branch (Task 4) reads `node_elevated`/`node_y_resuelta` with the exact same `edge_from`/`edge_to`/`agent.dir` orientation convention the W-2/W-3 code it replaces already used (verified against `_entry_node`/`_far_node`).
4. **Duplication risk (flagged, not resolved by a new shared file per the master spec's exhaustive file-creation list):** `road_builder.gd` and `traffic_graph.gd` now each carry their own copy of the elevation+ramp math. Every duplicated constant in `traffic_graph.gd` is suffixed `_DUP` specifically so a future diff to `road_builder.gd`'s constants is easy to notice as needing a mirrored change — this is a deliberate, visible seam, not a coincidence to be cleaned up quietly.
