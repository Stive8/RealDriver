# Retrofit Agua — Fase W-3 (grafo por capas, validación en Honda, regresión) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. No GDScript/Python test framework exists in this project — verification is headless Godot runs (`godot --headless --path . --quit-after N`, checking printed diagnostics and absence of `SCRIPT ERROR`) plus the pipeline CLI's own printed stats, plus a human visual/driving checklist for anything 3D that the agent cannot observe.

**Goal:** Implement contract 7's W-3 slice of `ESPEC_SESION_RETROFIT_AGUA_V2.md`: add a `capa_efectiva` guard to `traffic_graph.gd` so that traffic never treats a layer-mismatched coincidence (e.g. a bridge crossing near/over an at-grade road) as a shared, ceding intersection; generate a real validation zone (Honda, Tolima) that has an actual OSM bridge and a river mapped as a way; verify the guard's diagnostics against it; and re-run the full regression suite against the already-accepted Jordán map to prove zero behavioral change there.

**Architecture:** One additive change to `traffic_graph.gd` only (new `edge_capa` parallel array + a classification-time guard) — no other file is touched, no pipeline/citygen code changes (W-3 does not modify `roads[].layer`/`.deck` extraction, which W-1 already ships). Honda's `map.json` is generated as a disposable validation artifact via the existing `generate_map.py` CLI (the same "Cualquier ciudad" pipeline code path the backend uses) — it is never committed to the repo or packaged; it's temporarily swapped into `godot/data/map.json` for headless diagnostics and then discarded, with Jordán restored via `git checkout` immediately after.

**Tech Stack:** Godot 4.4 stable GDScript (static typing where reasonable), Python 3 stdlib + `requests` (citygen), no autoloads, snake_case, one script = one responsibility (existing project conventions).

## Global Constraints

- **Do not touch:** `terrain_sampler.gd`, `terrain_builder.gd` (or its collision), `vehicle.gd`, camera, minimap, any shader file, the backend, `road_builder.gd`, `water_builder.gd`, `ribbon_util.gd`, or any `citygen/`/pipeline file. W-3 touches **only** `godot/scripts/traffic_graph.gd`. Traffic decision-logic (yielding priority math, corner-blending Bézier, replanning, signal timing) is untouched — this phase only changes which nodes get *classified* as an intersection in the first place.
- **No new files.**
- **Inspección obligatoria — already done as part of writing this plan, documented here so the implementer does not need to redo it:** intersections in `traffic_graph.gd` form **solely** by coordinate-based node fusion in `_get_or_add_node` (key `FUSE_FMT = "%.2f|%.2f"`, called from `_build_nodes_and_edges`). The file's only 2D geometric crossing detector, `_count_unconnected_crossings`, is diagnostic-only — its result (`unconnected_crossings`) is read only by `print_diagnostics()`/`unconnected_crossings_pct()`, never by `_classify_nodes`, `_assign_controllers`, or anything in `traffic_manager.gd`/`intersection_controller.gd` that decides yielding. **Contract 7's rule (i) applies** (not rule (ii), not the emergency rule).
- **`capa_efectiva(vía)` (contract 7):** `road["layer"]` if the road dict `has("layer")`, cast to `int`; else `+1` if `road.get("deck","") == "bridge"`; else `-1` if `== "tunnel"`; else `0`. Compute once per road in `_build_nodes_and_edges` (mirrors how `deck`/`chord_y` are already computed once per road there), store as a new `edge_capa: PackedInt32Array` parallel array (same index space as `edge_from`/`edge_to`/`edge_deck`/etc.).
- **`# DECISION_PENDIENTE` — guard placement (human-confirmed 2026-07-13, do not re-litigate):** the contract's literal text ("dos endpoints con capa_efectiva distinta NO se fusionan") is a guard **in the fusion step**. Implementing it literally there would also sever the legitimate, already-validated splice between a `deck=bridge` road's endpoint and its at-grade approach road — in real OSM data (and in Jordán's own committed `map.json`) that splice is an *intentional* shared coordinate between two different `capa_efectiva` values (OSM splits a way exactly where `bridge=yes` starts/ends), and W-2's own broken-splice mechanism (`_has_broken_splice`) depends on that shared coordinate existing. Severing it would disconnect all 5 of Jordán's bridges from the traffic graph — a direct regression against W-2's already-accepted checklist ("ver a un auto de tráfico cruzar el puente"), which the spec's own prime directive #9 forbids. Resolution: node fusion (`_get_or_add_node`) is **unchanged** — full connectivity is preserved exactly as W-2 built it. The guard instead applies at **classification time** (`_classify_nodes`): a node of degree ≥ 3 is only added to `intersections` (and therefore only gets a shared `IntersectionController`) if **all** its incident edges share the same `edge_capa` value; a mixed-capa degree-≥3 node is excluded from both `intersections` and `terminals` (counted, printed, gets no controller — matches "no cede el paso ni interactúa"). Degree-2 nodes (the ordinary deck↔approach splice) are never affected by this check at all, since `_classify_nodes` only inspects degree ≥ 3.
- **Honda, Tolima validation zone:** center `lat=5.2075, lon=-74.75` (midpoint of the spec's bbox `5.200,-74.760,5.215,-74.740`), `--size M`. Verified live against Overpass on 2026-07-13: 1 real `highway=trunk` road tagged `bridge=yes, layer=1` ("Vía Mariquita - Honda"), the Río Gualí mapped as a `way` (not a relation — avoids the "río solo-relación" emergency case), and 4 `natural=water` polygons including the Magdalena. Human-confirmed to proceed with this bbox as-is despite only 1 real road bridge (not "abundant" as the spec's aspirational text hoped) — adjust the human checklist wording accordingly (singular, not "2-3 puentes").
- Diagnostics required: `mixed_capa_intersections` count (new); full pre-existing `[TrafficGraph]` diagnostic line unchanged in format; Honda's own stats table from `generate_map.py --stats`.
- ≥ 60 fps and load time < 20 s remain human-verified acceptance criteria (not agent-verifiable).

---

## Task 1: `capa_efectiva` guard in `traffic_graph.gd` (contract 7, W-3)

**Files:**
- Modify: `godot/scripts/traffic_graph.gd`

**Interfaces:**
- Produces: `TrafficGraph.edge_capa: PackedInt32Array` (new parallel array, same index space as `edge_from`), `TrafficGraph.mixed_capa_intersections: int` (new diagnostic counter). Consumed only within this file (`_classify_nodes`, `print_diagnostics`) — no other script reads `edge_capa` in this phase (W-4 will, per the spec, but that's out of scope here).
- Consumes: `road.get("layer")` / `road.get("deck", "")` (already present in the JSON since W-1; `deck` already read at `traffic_graph.gd:113`, `layer` not previously read anywhere in this file).

- [ ] **Step 1: Add the new fields**

In the `--- Datos del grafo ---` block, right after the existing `edge_deck_y_to` declaration (current line 40):

```gdscript
var edge_capa: PackedInt32Array = PackedInt32Array()  ## capa_efectiva por arista (layer si existe; si no, bridge=+1/tunnel=-1/normal=0). Contrato 7, W-3.
```

In the `--- Diagnóstico ---` block, right after `var build_ms: int = 0` (current line 52):

```gdscript
var mixed_capa_intersections: int = 0  ## nodos grado>=3 excluidos de `intersections` por capa_efectiva mixta entre sus aristas (contrato 7, W-3; ver DECISION_PENDIENTE en _classify_nodes)
```

- [ ] **Step 2: Compute `capa_efectiva` per road and thread it through `_add_edge`**

Replace the road-processing block inside `_build_nodes_and_edges` (current lines 104-115) — insert the `capa` computation right after `raw_deck`/`is_built_deck`/`deck` are computed, before the `chord_y` block:

```gdscript
		var rid := int(road.get("id", -1))
		var hw := String(road.get("highway", ""))
		var w := float(road.get("width", 6.0))
		# v1.1 retrocompatible: oneway ausente = 0 (bidireccional).
		var ow := int(road.get("oneway", 0))
		# Fase W-2 (contrato 7): deck ausente = "" (vía normal, sin interpolación de y).
		# edge_deck sólo debe valer "bridge" cuando road_builder.gd REALMENTE construye esta
		# vía como tablero (bridge Y sin empalme roto) -- no basta con que el JSON diga "bridge"
		# (ver road_builder.gd:39, misma regla de emergencia de empalme roto).
		var raw_deck := String(road.get("deck", ""))
		var is_built_deck := raw_deck == "bridge" and not _has_broken_splice(pts, endpoint_counts)
		var deck := "bridge" if is_built_deck else ""

		# Fase W-3 (contrato 7): capa_efectiva de la vía completa -- layer del tag OSM si existe,
		# si no bridge/tunnel/normal. Nota: usa raw_deck (el campo JSON), no `deck` (que ya pasó
		# por la regla de empalme roto) -- capa_efectiva es una propiedad de la vía tal como OSM
		# la etiquetó, independiente de si road_builder.gd terminó construyéndola como tablero.
		var capa: int
		if road.has("layer"):
			capa = int(road["layer"])
		elif raw_deck == "bridge":
			capa = 1
		elif raw_deck == "tunnel":
			capa = -1
		else:
			capa = 0
```

Then update the edge-adding loop (current lines 136-145) to pass `capa` through:

```gdscript
		var prev_node := _get_or_add_node(pts[0])
		for i in range(1, pts.size()):
			var cur_node := _get_or_add_node(pts[i])
			if cur_node == prev_node:
				# Puntos consecutivos idénticos tras redondeo: no hay segmento.
				continue
			var y_from: float = chord_y[i - 1] if is_built_deck else 0.0
			var y_to: float = chord_y[i] if is_built_deck else 0.0
			_add_edge(prev_node, cur_node, rid, hw, w, ow, deck, y_from, y_to, capa)
			prev_node = cur_node
```

Update `_add_edge`'s signature and body (current lines 161-174):

```gdscript
func _add_edge(a: int, b: int, rid: int, hw: String, w: float, ow: int, deck: String, y_from: float, y_to: float, capa: int) -> void:
	var eidx := edge_from.size()
	edge_from.append(a)
	edge_to.append(b)
	edge_road_id.append(rid)
	edge_highway.append(hw)
	edge_width.append(w)
	edge_oneway.append(ow)
	edge_length.append(node_pos[a].distance_to(node_pos[b]))
	edge_deck.append(deck)
	edge_deck_y_from.append(y_from)
	edge_deck_y_to.append(y_to)
	edge_capa.append(capa)
	node_edges[a].append(eidx)
	node_edges[b].append(eidx)
```

`_get_or_add_node` (current lines 148-158) is **not touched** — this is the crux of the DECISION_PENDIENTE above: fusion stays coordinate-only.

- [ ] **Step 3: Guard at classification time, not at fusion**

Replace `_classify_nodes` (current lines 180-186):

```gdscript
func _classify_nodes() -> void:
	for i in range(node_pos.size()):
		var deg: int = node_edges[i].size()
		if deg >= 3:
			if _same_capa(node_edges[i]):
				intersections.append(i)
			else:
				mixed_capa_intersections += 1
		elif deg == 1:
			terminals.append(i)


## Contrato 7 (W-3): las intersecciones de este grafo se forman SOLO por fusión de nodos por
## coordenada (_get_or_add_node) -- inspección obligatoria confirmó que no hay detección 2D de
## cruces alimentando la lógica de paso (_count_unconnected_crossings es solo diagnóstico, leído
## únicamente por print_diagnostics/unconnected_crossings_pct). Aplica la regla (i) del contrato.
##
## DECISION_PENDIENTE (humano confirmó 2026-07-13, ver docs/superpowers/plans/2026-07-13-retrofit-agua-w3.md):
## el contrato pide "guarda en la fusión: dos endpoints de capa distinta NO se fusionan", pero
## aplicado ahí de forma literal e incondicional rompería los empalmes deck<->vía de aproximación
## que W-2 ya construye y el humano ya validó (el extremo de una vía deck=bridge SIEMPRE comparte
## coordenada exacta con la vía vecina a nivel que continúa, por cómo OSM parte una vía en el
## punto donde empieza/termina el puente) -- desconectar esos nodos aislaría los 5 tableros de
## Jordán del grafo de tráfico, una regresión directa contra el checklist ya aceptado de W-2.
## Los nodos de grado 2 (el caso de un empalme simple) NUNCA reciben controlador (solo grado>=3
## se clasifica como intersección, ver arriba), así que fusionarlos sin importar la capa es
## inofensivo para la lógica de paso. El guarda se aplica entonces en la CLASIFICACIÓN: un nodo
## de grado>=3 solo se vuelve intersección (con IntersectionController compartido) si TODAS sus
## aristas incidentes tienen la misma capa_efectiva; si son mixtas, se excluye de intersections Y
## de terminals (no recibe controlador) y se cuenta en mixed_capa_intersections -- así un puente
## que por coincidencia de redondeo comparte nodo con una vía inferior nunca comparte
## ceda-el-paso con ella, sin tocar la conectividad real de ningún empalme legítimo.
func _same_capa(edges: Array) -> bool:
	if edges.is_empty():
		return true
	var first: int = edge_capa[edges[0]]
	for e in edges:
		if edge_capa[e] != first:
			return false
	return true
```

- [ ] **Step 4: Diagnostic print**

In `print_diagnostics` (current lines 300-310), add one line after the existing `cruces no conectados` line:

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
	print("[TrafficGraph] construccion: %d ms" % build_ms)
```

- [ ] **Step 5: Headless non-regression verification on Jordán**

Run:
```bash
cd godot && "/c/Users/Brayhan/AppData/Local/Programs/Godot/Godot_v4.4-stable_win64_console.exe" --headless --path . --quit-after 5 2>&1
```

Expected — **every one of these must match exactly** (this is the phase's regression proof for the change, checked now rather than deferred to Task 5, since this is the only task that touches code):
- `[TrafficGraph] nodos:1493  aristas:1809  intersecciones:622  terminales:152` (topology is untouched — this task only adds data to existing edges and adds a classification filter; report the real number if it differs even by one, do not adjust the plan's expected value to match a wrong run).
- New line `[TrafficGraph] intersecciones con capa mixta excluidas: N` present, no crash computing it. Report the real `N` (Jordán's 5 bridges are simple 2-endpoint splices per W-2's "0 empalmes rotos" diagnostic, so `N` is expected to be low or 0, but this is empirical — report what actually prints).
- `RoadBuilder: 527 vías, ... 5 tableros (5 con colisión), 0 empalmes rotos, ... ms` and `RoadBuilder no-regresión: 47094 vértices / 15698 triángulos` unchanged (road_builder.gd is untouched by this task).
- `WaterBuilder: 3 polígonos (0 descartados, 9 tris), 3 cintas de agua` unchanged.
- No `SCRIPT ERROR`, no `Invalid get index`, no stack traces.

- [ ] **Step 6: Commit**

```bash
git add godot/scripts/traffic_graph.gd
git commit -m "$(cat <<'EOF'
feat(w-3): trafico - guarda de capa_efectiva en clasificacion de intersecciones

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Generar la zona de validación (Honda, Tolima) y su tabla de conteos

**No files modified in the repo** — this task runs the existing `generate_map.py` CLI against a new bbox; its output (`data_pipeline/output/map.json`, `data_pipeline/output/preview.svg`) is a disposable local artifact, not committed.

**Interfaces:**
- Consumes: `generate_map.py --lat --lon --size --name --stats --svg` (existing CLI, unchanged by this phase).
- Produces: `data_pipeline/output/map.json` (Honda's generated zone, schema 1.4, consumed by Task 3) and a printed stats table (the phase's required "tabla de conteos" deliverable).

- [ ] **Step 1: Run the pipeline CLI**

```bash
cd data_pipeline && python generate_map.py --lat 5.2075 --lon -74.75 --size M --name "Honda, Tolima" --stats --svg
```

Expected: exits 0, prints `map.json escrito en <N>s: zone_id=...` followed by the `vias=... edificios=... controles=... road_km=... componente_mayor=...% pendiente_max=...% flags=...` line, then the full `--stats` block (elevación, pendiente, descartes, agua, `puentes=... tuneles=... con_layer=... ramales(*_link)=...`).

- [ ] **Step 2: Report the table verbatim**

Copy the complete printed output (both the summary line and the full `--stats` block) into the task report unmodified — this is the phase's required empirical deliverable ("presentar su tabla de conteos"), analogous to what W-1's Task 1 did for Jordán. In particular confirm: `puentes >= 1` (the "Vía Mariquita - Honda" `bridge=yes` way verified live against Overpass on 2026-07-13) and `agua: areas=... vias=...` both `> 0` (Río Gualí + the Magdalena polygon, same verification). If either is 0, STOP and report it — it would mean the live Overpass data changed since verification or the pipeline discarded something; do not proceed to Task 3 on a zone with no bridge or no water, the whole point of Honda is to exercise both.

- [ ] **Step 3: No commit** (generated artifact only; `data_pipeline/output/` is not meant to be version-controlled — confirm it isn't already tracked with `git status --short data_pipeline/output/` before moving on, and do not `git add` anything from this step).

---

## Task 3: Cargar Honda en Godot, verificación headless de los diagnósticos del guardia

**Files:**
- Temporarily overwrite (and then restore in Task 5, not this task): `godot/data/map.json`

**Interfaces:**
- Consumes: `data_pipeline/output/map.json` (Task 2's output).
- Produces: headless diagnostic output proving the W-3 guard fires correctly against real elevated-road data, and (left in place for the human) a running project that boots into Honda for the manual checklist.

- [ ] **Step 1: Back up Jordán, swap in Honda**

```bash
cd "C:\Users\Brayhan\Documents\RealDriving\ciudad-conducible"
cp godot/data/map.json /tmp/jordan_map_backup.json
cp data_pipeline/output/map.json godot/data/map.json
```

(The `/tmp` copy is just a local safety net — Task 5 restores via `git checkout`, which is the authoritative source of truth, not this backup.)

- [ ] **Step 2: Headless run, capture diagnostics**

```bash
cd godot && "/c/Users/Brayhan/AppData/Local/Programs/Godot/Godot_v4.4-stable_win64_console.exe" --headless --path . --quit-after 5 2>&1
```

Expected: no `SCRIPT ERROR`, no `Invalid get index`. Report the actual printed values for: `RoadBuilder` (vías/tableros/empalmes rotos count — Honda's real road count is unknown ahead of time, unlike Jordán; just confirm `tableros >= 1` matching Task 2's `puentes` count from the stats table), `WaterBuilder` (polígonos/cintas — confirm both `> 0`, matching Task 2's water counts), and the full `[TrafficGraph]` block including the new `intersecciones con capa mixta excluidas: N` line. This `N` is the direct evidence the guard does something on real elevated-road data (unlike Jordán where it may be 0) — report it whatever it is; a 0 here is also a valid, reportable outcome (it would mean Honda's specific bridge geometry never coincides with an unrelated intersection within the `%.2f` rounding), not a failure.

- [ ] **Step 3: Leave the swap in place, hand off the human checklist**

Do **not** restore Jordán in this task — the human needs `godot/data/map.json` to still be Honda to open the project in the Godot editor and drive it. Present this checklist to the human (adapted from the spec's W-3 checklist to the real, verified data — singular bridge, not "2-3 distintos"):

> **Checklist humano — Honda (nuevo):**
> - Abrir el proyecto en el editor de Godot y darle Play (el `map.json` activo ya es Honda).
> - El puente ("Vía Mariquita - Honda") cruza agua real con claro visible debajo (la cuerda pasa recta, el cauce excavado se hunde) — el Río Gualí debe verse como cauce azul bajo el tablero.
> - Conducir sobre el puente sin caer (colisión del tablero) y también por debajo de él si el ángulo lo permite.
> - Pararse cerca de donde el puente cruza sobre otra vía (si la hay en esta zona) y observar el tráfico: los autos de la vía inferior NO deben ceder el paso al tráfico del puente ni interactuar con él — el diagnóstico `intersecciones con capa mixta excluidas: N` de la Tarea 3 es la evidencia impresa de que el grafo ya los trata como no-relacionados.
> - Confirmar visualmente el `flags` que imprimió la Tarea 2 (p. ej. `steep` si aparece) tiene sentido para el terreno que se ve.
>
> Cuando termines, avísame para restaurar Jordán y correr la regresión final (Tarea 5).

- [ ] **Step 4: No commit** (no repo files are meant to stay changed after this task — `godot/data/map.json` is intentionally left Honda for the human's own manual session and gets restored in Task 5, not committed here).

---

## Task 4: Esperar confirmación humana del checklist de Honda

**No files.** This task is a checkpoint, not code — do not proceed to Task 5 until the human confirms they finished (or explicitly skips) the Task 3 checklist. If the human reports a problem (e.g. traffic on the lower road DOES yield to the bridge, meaning `mixed_capa_intersections` should have been nonzero but wasn't, or vice versa), that is a real finding — return to Task 1 and re-open it rather than silently patching around it in a later task.

---

## Task 5: Restaurar Jordán, regresión completa, checklist humano de regresión

**Files:**
- Restore: `godot/data/map.json` (via `git checkout`, undoing Task 3's temporary swap)

**Interfaces:**
- Consumes: nothing new.
- Produces: final proof that Jordán (the packaged, human-accepted city) is byte-identical in behavior to before this phase, plus the phase's closing human regression checklist.

- [ ] **Step 1: Restore Jordán**

```bash
cd "C:\Users\Brayhan\Documents\RealDriving\ciudad-conducible"
git status --short godot/data/map.json
git checkout -- godot/data/map.json
git status --short godot/data/map.json
```

Expected: the first `git status` shows `M godot/data/map.json` (Honda still swapped in from Task 3); the second shows nothing (clean — Jordán restored exactly as committed).

- [ ] **Step 2: Full headless regression boot**

```bash
cd godot && "/c/Users/Brayhan/AppData/Local/Programs/Godot/Godot_v4.4-stable_win64_console.exe" --headless --path . --quit-after 5 2>&1
```

Expected, **all must match exactly** (same baseline as Task 1 Step 5, confirming the swap-and-restore round-trip left nothing behind):
- `WaterBuilder: 3 polígonos (0 descartados, 9 tris), 3 cintas de agua`
- `RoadBuilder: 527 vías, 6040 puntos insertados por subdivisión, 5 tableros (5 con colisión), 0 empalmes rotos`
- `RoadBuilder no-regresión: 47094 vértices / 15698 triángulos`
- `BuildingBuilder: 4916 edificios, 0 descartados`
- `[TrafficGraph] nodos:1493  aristas:1809  intersecciones:622  terminales:152`
- `[TrafficGraph] intersecciones con capa mixta excluidas: N` — must equal the **same** N Task 1 Step 5 reported for Jordán (this task changes zero code, so this number cannot have changed; if it differs, something is wrong with the restore, not the feature).
- No `SCRIPT ERROR`, no `Invalid get index`.

- [ ] **Step 3: Hand off the human regression checklist**

> **Checklist humano — regresión (Jordán, completa):**
> - Conducción libre 3 minutos por Jordán: calles, edificios, tráfico y props como siempre.
> - Contrarreloj completo con récords intactos.
> - Tráfico normal en las intersecciones de siempre — el guarda de capas NO debe cambiar ninguna intersección real: si alguna esquina conocida deja de ceder el paso, repórtalo junto con el `intersecciones con capa mixta excluidas: N` impreso (evidencia para diagnosticar si el guarda excluyó algo que no debía).
> - Minimapa idéntico.
> - ≥ 60 fps.
> - Carga < 20 s.

- [ ] **Step 4: No commit** (Step 1 already restored the tracked file to its committed state; there is nothing new to commit in this task — Task 1's commit is the only code change of this phase).

---

## Self-Review Notes

1. **Spec coverage:** Contract 7's "Inspección obligatoria" → done during plan-writing, documented as a Global Constraint and re-stated in Task 1 so the implementer doesn't redo it blind. Contract 7's `capa_efectiva` + guard rule (i) → Task 1. Phase step 2 ("Generar la zona de validación... presentar su tabla de conteos") → Task 2. Phase step 2's checklist ("puentes cruzan agua real...") → Task 3. Phase step 3 ("Suite de regresión final sobre Jordán regenerado" — Jordán needs no pipeline regeneration since W-3 touches no pipeline code; "regenerado" here means the already-W-1-regenerated Jordán already on `main`) → Task 5. The emergency rule (ii)/fallback is explicitly not needed (rule (i) applies, confirmed by inspection) — no task implements it, correctly.
2. **Placeholder scan:** none — every step has complete code or an exact command with a concrete expected value; the one genuinely unknown-ahead-of-time number (`mixed_capa_intersections` for both Jordán and Honda) is explicitly flagged as "report the real number" rather than asserted, consistent with how W-1/W-2 handled empirically-discovered counts.
3. **Type consistency:** `edge_capa: PackedInt32Array` — `int` per entry, matches `_add_edge`'s new `capa: int` parameter and `_same_capa`'s `Array` (of edge indices, `int`) parameter reading `edge_capa[e]`. `_add_edge`'s full new signature (`a, b, rid, hw, w, ow, deck, y_from, y_to, capa`) matches its only call site in `_build_nodes_and_edges` exactly (positional order: `prev_node, cur_node, rid, hw, w, ow, deck, y_from, y_to, capa`).
4. **Human-confirmed decisions baked into this plan (not to be re-asked during execution):** the capa-guard placement (classification, not fusion) — approved 2026-07-13; the Honda bbox — approved 2026-07-13 despite only 1 real road bridge.
