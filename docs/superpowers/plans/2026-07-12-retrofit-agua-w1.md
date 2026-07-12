# Retrofit Agua — Fase W-1 (pipeline: ramales, agua, excavación) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the `citygen` Python pipeline (schema `1.3` → `1.4`) to fetch `*_link` road classes and OSM water features (`natural=water`, `waterway=river|stream|canal`), emit `roads[].layer`/`roads[].deck`, new `water_areas`/`water_ways` sections, excavate the terrain grid under water, and make the raw-OSM cache auto-invalidate when the Overpass query changes — all without touching the `terrain` schema, `TerrainSampler`, any Godot script, or the backend. This is the pipeline-only slice (W-1) of a 4-phase retrofit (W-1..W-4); Godot-side consumption (tableros, `WaterBuilder`, traffic layers) is out of scope here.

**Architecture:** Additive changes to four existing `citygen` modules (`fetch_osm.py`, `fetch_elevation.py`, `build.py`, `svg_preview.py`) plus the dev CLI (`generate_map.py`). No new files. Every new field is optional in the output JSON (present only when the corresponding OSM tag exists), so zones/roads without bridges/tunnels/layers/water serialize byte-identically to today except for the `schema_version` bump and two new top-level (empty) array sections.

**Tech Stack:** Python 3, stdlib + `requests` only (existing `citygen` constraint — no new dependencies). `unittest` (existing test framework, `python -m unittest discover -p "test_*.py"` from `data_pipeline/`).

## Global Constraints

- `citygen/` only stdlib + `requests` — no new dependencies. [ESPEC rule 4]
- Determinism: no randomness in any new function (the existing `building_height` RNG is untouched). [ESPEC rule 4]
- Do **not** change the `terrain` JSON schema, `TerrainSampler`, `terrain_builder.gd`, the vehicle, traffic decision logic, or the backend. Excavation changes terrain **values** inside the pipeline only. [ESPEC rule 1, 3]
- `*_link` production width: **5.0 m**, overridden by a numeric `width` tag clamped to **[3, 20]** (reuse the existing clamp). [Contract 1]
- Water query additions (verbatim): `way["natural"="water"]({bbox});` and `way["waterway"~"^(river|stream|canal)$"]({bbox});`. `bridge`/`tunnel`/`layer` need no new query — they're tags on already-fetched `highway` ways. [Contract 1]
- Raw-OSM cache must store the query alongside the response and auto-invalidate (re-fetch, printing why) on any mismatch — including the current on-disk cache, which predates this change and has no `query` key at all. [Contract 1]
- `schema_version` → `"1.4"` (aditive only — absent fields/sections in older JSON must keep loading with today's exact behavior). `PIPELINE_MAJOR` (zone_id versioning, `zones.py`) does **not** change. [Contract 2]
- `roads[]` optional fields: `"layer": int` (only when the OSM `layer` tag parses to a non-zero integer — "ausente=0" means a zero/absent tag omits the key entirely) and `"deck": "bridge"|"tunnel"` (only when `bridge=*`/`tunnel=*` is anything other than absent/`"no"`). [Contract 2]
- New sections `water_areas[]` (`{"id", "footprint"}`, same 4-step shape validation as buildings: closed ring → ≥2 points → in-bbox → ≥3 effective vertices) and `water_ways[]` (`{"id", "kind", "width", "points"}`; width = numeric `width` tag clamped **[2, 40]**, else synthetic default river=12.0/canal=6.0/stream=3.0). [Contract 2]
- `meta.stats` gains `n_bridges`, `n_tunnels`, `n_layered`, `n_links`, `n_water_areas`, `n_water_ways`. [Contract 2]
- Water excavation: `WATER_DEPRESS = 1.5` m inside a `water_areas` polygon or within `width/2` of a `water_ways` axis; linear gradient from 1.5 to 0 between `width/2` and `width/2 + cell_size`. One deterministic pass, bounded by each element's own bbox (never a full-grid scan per element). Runs **after smoothing, before `raw_min`/`base_elevation` are computed** so an excavated low point is absorbed as the new floor like any natural minimum. Must print nodes-excavated and max-delta-outside-the-excavated-zone (must be `0.0`). [Contract 3]

---

## Task 1: Diagnóstico previo (con caché existente, sin cambios de código)

**Files:** None modified — this is a read-only measurement against the *current* code and the *current* `data_pipeline/cache/legacy/overpass_raw.json`, run before any other task in this plan.

**Interfaces:** None (standalone script run via `python -`, not committed).

- [ ] **Step 1: Count `bridge`/`tunnel`/`layer` tags already present in Jordán's cached raw Overpass response**

The current cache only queried today's `highway` classes (no `*_link`) and no water — but ordinary roads can still carry `bridge`/`tunnel`/`layer` tags today. Run this from `data_pipeline/`:

```bash
cd data_pipeline && python - <<'EOF'
import json
with open("cache/legacy/overpass_raw.json", encoding="utf-8") as f:
    raw = json.load(f)
ways = [el for el in raw.get("elements", []) if el.get("type") == "way"]
n_bridge = sum(1 for w in ways if str(w.get("tags", {}).get("bridge", "no")).lower() not in ("", "no"))
n_tunnel = sum(1 for w in ways if str(w.get("tags", {}).get("tunnel", "no")).lower() not in ("", "no"))
n_layer = sum(1 for w in ways if w.get("tags", {}).get("layer") is not None)
print(f"vias con bridge: {n_bridge}")
print(f"vias con tunnel: {n_tunnel}")
print(f"vias con layer: {n_layer}")
print("*_link, natural=water, waterway: 0 (no incluidos en la query actual del cache; se miden en Tarea 7 tras el contrato 1)")
EOF
```

Expected: three real counts printed (likely 0 or very low for Jordán — a mid-size Colombian city grid rarely has tagged bridges/tunnels/layers on ordinary streets) plus the fixed water/`*_link` line. **Report this table verbatim to the human** — it's the empirical baseline referenced by the phase's "Checklist humano — nuevo" (if puentes=0 y agua=0, the visual validation for those features happens later in W-3/W-4, not in Jordán).

---

## Task 2: `fetch_osm.py` — query de `*_link`/agua + anchos + caché auto-invalidante (Contrato 1)

**Files:**
- Modify: `data_pipeline/citygen/fetch_osm.py`
- Test: `data_pipeline/test_fetch_osm.py`

**Interfaces:**
- Produces: `fetch_osm.build_query(bbox) -> str` (now includes `*_link` + water clauses), `fetch_osm.load_osm_cache(path, query) -> dict|None`, `fetch_osm.save_osm_cache(path, query, data) -> None`, `ROAD_WIDTHS` gains 5 new keys.
- Consumes: `zones.clamp` (existing).

- [ ] **Step 1: Extend `ROAD_WIDTHS` and `build_query()`**

In `data_pipeline/citygen/fetch_osm.py`, replace the `ROAD_WIDTHS` dict (lines 15-25):

```python
ROAD_WIDTHS = {
    "motorway": 14.0,
    "trunk": 14.0,
    "primary": 12.0,
    "secondary": 9.0,
    "tertiary": 8.0,
    "residential": 6.0,
    "unclassified": 6.0,
    "living_street": 5.0,
    "service": 4.0,
    "motorway_link": 5.0,
    "trunk_link": 5.0,
    "primary_link": 5.0,
    "secondary_link": 5.0,
    "tertiary_link": 5.0,
}
```

Replace `build_query()` (lines 38-49):

```python
def build_query(bbox: tuple) -> str:
    lat_s, lon_o, lat_n, lon_e = bbox
    bbox_str = f"{lat_s:.6f},{lon_o:.6f},{lat_n:.6f},{lon_e:.6f}"
    return f"""[out:json][timeout:90];
(
  way["highway"~"^(motorway|trunk|primary|secondary|tertiary|residential|unclassified|service|living_street|motorway_link|trunk_link|primary_link|secondary_link|tertiary_link)$"]({bbox_str});
  way["building"]({bbox_str});
  way["natural"="water"]({bbox_str});
  way["waterway"~"^(river|stream|canal)$"]({bbox_str});
);
out body;
>;
out body qt;
"""
```

`road_width()` (lines 109-116) needs **no changes** — its `width` tag override + `WIDTH_CLAMP` logic already applies to any `highway` value, including the new `*_link` keys just added to `ROAD_WIDTHS`.

- [ ] **Step 2: Cache auto-invalidation — `load_osm_cache`/`save_osm_cache` + rewritten `fetch()`**

Replace `fetch()` (lines 52-77) and add the two new helper functions right after it:

```python
def fetch(bbox: tuple, cache_dir: str, refresh: bool) -> dict:
    cache_path = os.path.join(cache_dir, "overpass_raw.json")
    query = build_query(bbox)
    if not refresh:
        cached = load_osm_cache(cache_path, query)
        if cached is not None:
            print(f"Usando cache: {cache_path}")
            return cached

    os.makedirs(cache_dir, exist_ok=True)
    headers = {"User-Agent": USER_AGENT}
    last_error = None
    for url in (OVERPASS_URL, OVERPASS_FALLBACK_URL):
        try:
            print(f"Consultando Overpass: {url}")
            t0 = time.time()
            resp = requests.post(url, data={"data": query}, headers=headers, timeout=120)
            resp.raise_for_status()
            data = resp.json()
            print(f"  respuesta en {time.time() - t0:.1f}s, {len(resp.content)} bytes")
            save_osm_cache(cache_path, query, data)
            return data
        except Exception as exc:
            last_error = exc
            print(f"  fallo ({url}): {exc}")
    raise RuntimeError(f"No se pudo consultar Overpass en ningun endpoint: {last_error}")


def load_osm_cache(path: str, query: str):
    """Retorna la respuesta cacheada si la query coincide con la guardada; si no, None
    (imprime el motivo -- cache ausente, corrupta, formato viejo sin query registrada, o
    query distinta -- para nunca generar en silencio con datos de una query vieja)."""
    if not os.path.isfile(path):
        return None
    try:
        with open(path, "r", encoding="utf-8") as f:
            cache = json.load(f)
    except (json.JSONDecodeError, OSError) as exc:
        print(f"  cache invalida ({exc}): re-consultando")
        return None
    if not isinstance(cache, dict) or "query" not in cache or "response" not in cache:
        print("  cache en formato viejo (sin query registrada): re-consultando")
        return None
    if cache["query"] != query:
        print("  cache invalidada: la query cambio respecto a la guardada; re-consultando")
        return None
    return cache["response"]


def save_osm_cache(path: str, query: str, data: dict) -> None:
    with open(path, "w", encoding="utf-8") as f:
        json.dump({"query": query, "response": data}, f)
```

- [ ] **Step 3: Tests**

Add these imports to the top of `data_pipeline/test_fetch_osm.py` (alongside the existing `import unittest`):

```python
import json
import os
import tempfile
import unittest
from unittest.mock import patch, MagicMock

from citygen import fetch_osm
```

Append these test classes:

```python
class TestBuildQuery(unittest.TestCase):
    def test_includes_link_classes(self):
        query = fetch_osm.build_query((4.0, -75.0, 5.0, -74.0))
        for cls in ("motorway_link", "trunk_link", "primary_link", "secondary_link", "tertiary_link"):
            self.assertIn(cls, query)

    def test_includes_water_queries(self):
        query = fetch_osm.build_query((4.0, -75.0, 5.0, -74.0))
        self.assertIn('natural"="water"', query)
        self.assertIn('waterway"~"^(river|stream|canal)$"', query)


class TestRoadWidthLinks(unittest.TestCase):
    def test_link_defaults_to_5m(self):
        self.assertAlmostEqual(fetch_osm.road_width({"highway": "primary_link"}), 5.0)

    def test_link_width_tag_overrides_and_clamps(self):
        self.assertAlmostEqual(fetch_osm.road_width({"highway": "primary_link", "width": "2"}), 3.0)


class TestOsmCache(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.path = os.path.join(self.tmpdir, "overpass_raw.json")
        self.query = "QUERY_A"

    def test_missing_cache_returns_none(self):
        self.assertIsNone(fetch_osm.load_osm_cache(self.path, self.query))

    def test_save_then_load_roundtrip(self):
        fetch_osm.save_osm_cache(self.path, self.query, {"elements": [1, 2]})
        self.assertEqual(fetch_osm.load_osm_cache(self.path, self.query), {"elements": [1, 2]})

    def test_query_mismatch_invalidates_cache(self):
        fetch_osm.save_osm_cache(self.path, self.query, {"elements": [1, 2]})
        self.assertIsNone(fetch_osm.load_osm_cache(self.path, "QUERY_B"))

    def test_old_format_cache_without_query_is_invalid(self):
        with open(self.path, "w", encoding="utf-8") as f:
            json.dump({"elements": [1, 2]}, f)
        self.assertIsNone(fetch_osm.load_osm_cache(self.path, self.query))


class TestFetch(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.bbox = (4.0, -75.0, 5.0, -74.0)

    def test_uses_cache_when_query_matches(self):
        query = fetch_osm.build_query(self.bbox)
        cache_path = os.path.join(self.tmpdir, "overpass_raw.json")
        fetch_osm.save_osm_cache(cache_path, query, {"elements": ["cached"]})
        with patch("citygen.fetch_osm.requests.post") as mock_post:
            data = fetch_osm.fetch(self.bbox, self.tmpdir, refresh=False)
        mock_post.assert_not_called()
        self.assertEqual(data, {"elements": ["cached"]})

    def test_refetches_when_cache_has_old_format(self):
        cache_path = os.path.join(self.tmpdir, "overpass_raw.json")
        with open(cache_path, "w", encoding="utf-8") as f:
            json.dump({"elements": ["old"]}, f)
        mock_resp = MagicMock()
        mock_resp.json.return_value = {"elements": ["fresh"]}
        mock_resp.content = b"x"
        mock_resp.raise_for_status.return_value = None
        with patch("citygen.fetch_osm.requests.post", return_value=mock_resp) as mock_post:
            data = fetch_osm.fetch(self.bbox, self.tmpdir, refresh=False)
        mock_post.assert_called_once()
        self.assertEqual(data, {"elements": ["fresh"]})
        with open(cache_path, "r", encoding="utf-8") as f:
            saved = json.load(f)
        self.assertEqual(saved["query"], fetch_osm.build_query(self.bbox))
```

- [ ] **Step 4: Run tests**

Run: `cd data_pipeline && python -m unittest test_fetch_osm -v`
Expected: all tests pass (existing `TestRoadWidth`/`TestRoadOneway`/`TestBuildingHeight`/`TestInBbox`/`TestBuildRoads` unchanged + new classes above), `OK`.

- [ ] **Step 5: Commit**

```bash
git add data_pipeline/citygen/fetch_osm.py data_pipeline/test_fetch_osm.py
git commit -m "feat(w-1): pipeline - query *_link/agua + cache OSM auto-invalidante"
```

---

## Task 3: `fetch_osm.py` — `layer`/`deck` en vías + `water_areas`/`water_ways` (Contrato 2, lado fetch)

**Files:**
- Modify: `data_pipeline/citygen/fetch_osm.py`
- Test: `data_pipeline/test_fetch_osm.py`

**Interfaces:**
- Consumes: `zones.project`, `zones.clamp` (existing), `way_points`, `any_point_in_bbox` (existing, this file).
- Produces: `road_layer(tags) -> int|None`, `road_deck(tags) -> str|None`, `waterway_width(tags, kind) -> float`, `build_water_areas(ways, nodes, bbox, origin, stats) -> list`, `build_water_ways(ways, nodes, bbox, origin, stats) -> list`. Road entries from `build_roads()` gain optional `"layer"`/`"deck"` keys. Both consumed by `build.py` in Task 5 (exact same `stats` dict passed to `build_roads`/`build_buildings`/`build_controls`).

- [ ] **Step 1: `road_layer` / `road_deck` + wire into `build_roads()`**

Add these two functions right after `road_oneway()` (after line 131) in `data_pipeline/citygen/fetch_osm.py`:

```python
def road_layer(tags: dict):
    """Entero del tag `layer`, o None si esta ausente o no es numerico."""
    layer_tag = tags.get("layer")
    if layer_tag is None:
        return None
    try:
        return int(float(str(layer_tag).split()[0]))
    except (ValueError, TypeError):
        return None


def road_deck(tags: dict):
    """"bridge"|"tunnel"|None segun tags bridge=*/tunnel=* (cualquier valor no-'no' activa;
    si ambos estan presentes se prioriza bridge, caso extremadamente raro en OSM real)."""
    if str(tags.get("bridge", "no")).strip().lower() not in ("", "no"):
        return "bridge"
    if str(tags.get("tunnel", "no")).strip().lower() not in ("", "no"):
        return "tunnel"
    return None
```

Replace `build_roads()` (lines 154-181):

```python
def build_roads(ways, nodes, bbox, origin, stats):
    roads = []
    next_id = 0
    for way in ways:
        tags = way.get("tags", {})
        highway = tags.get("highway")
        if not highway:
            continue
        points = way_points(way, nodes)
        if len(points) < 2:
            stats["roads_discarded_few_points"] += 1
            continue
        if not any_point_in_bbox(points, bbox):
            stats["roads_discarded_outside_bbox"] += 1
            continue
        projected = [zones.project(lat, lon, origin) for lat, lon in points]
        oneway = road_oneway(tags)
        road = {
            "id": next_id,
            "highway": highway,
            "width": road_width(tags),
            "oneway": oneway,
            "points": [[x, z] for x, z in projected],
        }
        layer = road_layer(tags)
        if layer is not None and layer != 0:
            road["layer"] = layer
            stats["n_layered"] += 1
        deck = road_deck(tags)
        if deck is not None:
            road["deck"] = deck
            if deck == "bridge":
                stats["n_bridges"] += 1
            else:
                stats["n_tunnels"] += 1
        if highway.endswith("_link"):
            stats["n_links"] += 1
        roads.append(road)
        stats["roads_by_type"][highway] = stats["roads_by_type"].get(highway, 0) + 1
        stats["roads_oneway_by_value"][oneway] += 1
        next_id += 1
    return roads
```

- [ ] **Step 2: `build_water_areas()` and `build_water_ways()`**

Add at the end of `data_pipeline/citygen/fetch_osm.py` (after `build_buildings()`):

```python
WATERWAY_WIDTHS = {"river": 12.0, "stream": 3.0, "canal": 6.0}
WATERWAY_WIDTH_CLAMP = (2.0, 40.0)


def waterway_width(tags: dict, kind: str) -> float:
    width_tag = tags.get("width")
    if width_tag is not None:
        try:
            return zones.clamp(float(str(width_tag).split()[0]), *WATERWAY_WIDTH_CLAMP)
        except (ValueError, TypeError):
            pass
    return WATERWAY_WIDTHS[kind]


def build_water_areas(ways, nodes, bbox, origin, stats):
    """natural=water cerrados; mismas 4 reglas de forma que build_buildings()."""
    water_areas = []
    next_id = 0
    for way in ways:
        tags = way.get("tags", {})
        if tags.get("natural") != "water":
            continue
        node_ids = way.get("nodes", [])
        if len(node_ids) < 2 or node_ids[0] != node_ids[-1]:
            stats["water_areas_discarded_not_closed"] += 1
            continue
        points = way_points(way, nodes)
        if len(points) < 2:
            stats["water_areas_discarded_few_points"] += 1
            continue
        if not any_point_in_bbox(points, bbox):
            stats["water_areas_discarded_outside_bbox"] += 1
            continue
        effective_vertices = len(points) - 1
        if effective_vertices < 3:
            stats["water_areas_discarded_few_vertices"] += 1
            continue
        projected = [zones.project(lat, lon, origin) for lat, lon in points]
        water_areas.append({
            "id": next_id,
            "footprint": [[x, z] for x, z in projected],
        })
        next_id += 1
    return water_areas


def build_water_ways(ways, nodes, bbox, origin, stats):
    """waterway in {river, stream, canal}: eje + ancho (tag width clamp [2,40] o sintetico)."""
    water_ways = []
    next_id = 0
    for way in ways:
        tags = way.get("tags", {})
        kind = tags.get("waterway")
        if kind not in WATERWAY_WIDTHS:
            continue
        points = way_points(way, nodes)
        if len(points) < 2:
            stats["water_ways_discarded_few_points"] += 1
            continue
        if not any_point_in_bbox(points, bbox):
            stats["water_ways_discarded_outside_bbox"] += 1
            continue
        projected = [zones.project(lat, lon, origin) for lat, lon in points]
        water_ways.append({
            "id": next_id,
            "kind": kind,
            "width": waterway_width(tags, kind),
            "points": [[x, z] for x, z in projected],
        })
        next_id += 1
    return water_ways
```

- [ ] **Step 3: Tests**

Append to `data_pipeline/test_fetch_osm.py`:

```python
class TestRoadLayerAndDeck(unittest.TestCase):
    def test_layer_absent_is_none(self):
        self.assertIsNone(fetch_osm.road_layer({}))

    def test_layer_present_is_parsed(self):
        self.assertEqual(fetch_osm.road_layer({"layer": "2"}), 2)

    def test_layer_zero_is_still_parsed_as_zero(self):
        self.assertEqual(fetch_osm.road_layer({"layer": "0"}), 0)

    def test_layer_non_numeric_is_none(self):
        self.assertIsNone(fetch_osm.road_layer({"layer": "bogus"}))

    def test_deck_absent_is_none(self):
        self.assertIsNone(fetch_osm.road_deck({}))

    def test_deck_bridge(self):
        self.assertEqual(fetch_osm.road_deck({"bridge": "yes"}), "bridge")

    def test_deck_tunnel(self):
        self.assertEqual(fetch_osm.road_deck({"tunnel": "yes"}), "tunnel")

    def test_deck_bridge_no_is_none(self):
        self.assertIsNone(fetch_osm.road_deck({"bridge": "no"}))

    def test_deck_prioritizes_bridge_when_both_present(self):
        self.assertEqual(fetch_osm.road_deck({"bridge": "yes", "tunnel": "yes"}), "bridge")


class TestBuildRoadsLayerDeck(unittest.TestCase):
    def _stats(self):
        return {"roads_by_type": {}, "roads_oneway_by_value": {0: 0, 1: 0, -1: 0},
                "roads_discarded_few_points": 0, "roads_discarded_outside_bbox": 0,
                "n_bridges": 0, "n_tunnels": 0, "n_layered": 0, "n_links": 0}

    def test_bridge_road_gets_deck_field_and_stat(self):
        origin = (4.5, -74.5)
        bbox = (4.0, -75.0, 5.0, -74.0)
        nodes = {1: (4.5, -74.5), 2: (4.501, -74.501)}
        ways = [{"tags": {"highway": "primary", "bridge": "yes"}, "nodes": [1, 2]}]
        stats = self._stats()
        roads = fetch_osm.build_roads(ways, nodes, bbox, origin, stats)
        self.assertEqual(roads[0]["deck"], "bridge")
        self.assertEqual(stats["n_bridges"], 1)

    def test_normal_road_has_no_deck_or_layer_key(self):
        origin = (4.5, -74.5)
        bbox = (4.0, -75.0, 5.0, -74.0)
        nodes = {1: (4.5, -74.5), 2: (4.501, -74.501)}
        ways = [{"tags": {"highway": "residential"}, "nodes": [1, 2]}]
        stats = self._stats()
        roads = fetch_osm.build_roads(ways, nodes, bbox, origin, stats)
        self.assertNotIn("deck", roads[0])
        self.assertNotIn("layer", roads[0])

    def test_link_class_counted_and_defaults_to_5m(self):
        origin = (4.5, -74.5)
        bbox = (4.0, -75.0, 5.0, -74.0)
        nodes = {1: (4.5, -74.5), 2: (4.501, -74.501)}
        ways = [{"tags": {"highway": "primary_link"}, "nodes": [1, 2]}]
        stats = self._stats()
        roads = fetch_osm.build_roads(ways, nodes, bbox, origin, stats)
        self.assertAlmostEqual(roads[0]["width"], 5.0)
        self.assertEqual(stats["n_links"], 1)

    def test_layer_tag_gets_layer_field_and_stat(self):
        origin = (4.5, -74.5)
        bbox = (4.0, -75.0, 5.0, -74.0)
        nodes = {1: (4.5, -74.5), 2: (4.501, -74.501)}
        ways = [{"tags": {"highway": "primary", "layer": "1"}, "nodes": [1, 2]}]
        stats = self._stats()
        roads = fetch_osm.build_roads(ways, nodes, bbox, origin, stats)
        self.assertEqual(roads[0]["layer"], 1)
        self.assertEqual(stats["n_layered"], 1)


class TestBuildWaterAreas(unittest.TestCase):
    def _stats(self):
        return {"water_areas_discarded_not_closed": 0, "water_areas_discarded_few_points": 0,
                "water_areas_discarded_few_vertices": 0, "water_areas_discarded_outside_bbox": 0}

    def test_discards_ways_without_natural_water_tag(self):
        origin = (4.5, -74.5)
        bbox = (4.0, -75.0, 5.0, -74.0)
        nodes = {1: (4.5, -74.5), 2: (4.501, -74.5), 3: (4.501, -74.501), 4: (4.5, -74.501)}
        ways = [{"tags": {"building": "yes"}, "nodes": [1, 2, 3, 4, 1]}]
        areas = fetch_osm.build_water_areas(ways, nodes, bbox, origin, self._stats())
        self.assertEqual(areas, [])

    def test_builds_closed_water_polygon(self):
        origin = (4.5, -74.5)
        bbox = (4.0, -75.0, 5.0, -74.0)
        nodes = {1: (4.5, -74.5), 2: (4.501, -74.5), 3: (4.501, -74.501), 4: (4.5, -74.501)}
        ways = [{"tags": {"natural": "water"}, "nodes": [1, 2, 3, 4, 1]}]
        areas = fetch_osm.build_water_areas(ways, nodes, bbox, origin, self._stats())
        self.assertEqual(len(areas), 1)
        self.assertEqual(len(areas[0]["footprint"]), 5)

    def test_open_ring_is_discarded(self):
        origin = (4.5, -74.5)
        bbox = (4.0, -75.0, 5.0, -74.0)
        nodes = {1: (4.5, -74.5), 2: (4.501, -74.5), 3: (4.501, -74.501)}
        ways = [{"tags": {"natural": "water"}, "nodes": [1, 2, 3]}]
        stats = self._stats()
        areas = fetch_osm.build_water_areas(ways, nodes, bbox, origin, stats)
        self.assertEqual(areas, [])
        self.assertEqual(stats["water_areas_discarded_not_closed"], 1)


class TestWaterwayWidth(unittest.TestCase):
    def test_synthetic_defaults(self):
        self.assertAlmostEqual(fetch_osm.waterway_width({}, "river"), 12.0)
        self.assertAlmostEqual(fetch_osm.waterway_width({}, "stream"), 3.0)
        self.assertAlmostEqual(fetch_osm.waterway_width({}, "canal"), 6.0)

    def test_width_tag_overrides_and_clamps(self):
        self.assertAlmostEqual(fetch_osm.waterway_width({"width": "1"}, "river"), 2.0)
        self.assertAlmostEqual(fetch_osm.waterway_width({"width": "100"}, "river"), 40.0)


class TestBuildWaterWays(unittest.TestCase):
    def _stats(self):
        return {"water_ways_discarded_few_points": 0, "water_ways_discarded_outside_bbox": 0}

    def test_builds_river_with_synthetic_width(self):
        origin = (4.5, -74.5)
        bbox = (4.0, -75.0, 5.0, -74.0)
        nodes = {1: (4.5, -74.5), 2: (4.501, -74.501)}
        ways = [{"tags": {"waterway": "river"}, "nodes": [1, 2]}]
        water_ways = fetch_osm.build_water_ways(ways, nodes, bbox, origin, self._stats())
        self.assertEqual(len(water_ways), 1)
        self.assertEqual(water_ways[0]["kind"], "river")
        self.assertAlmostEqual(water_ways[0]["width"], 12.0)

    def test_ignores_unlisted_waterway_kinds(self):
        origin = (4.5, -74.5)
        bbox = (4.0, -75.0, 5.0, -74.0)
        nodes = {1: (4.5, -74.5), 2: (4.501, -74.501)}
        ways = [{"tags": {"waterway": "ditch"}, "nodes": [1, 2]}]
        water_ways = fetch_osm.build_water_ways(ways, nodes, bbox, origin, self._stats())
        self.assertEqual(water_ways, [])
```

Existing `TestBuildRoads` tests (lines 59-81 of the original file) use minimal `stats` dicts without the new `n_bridges`/`n_tunnels`/`n_layered`/`n_links` keys — **do not modify them**. Their fixtures have no `bridge`/`tunnel`/`layer`/`*_link` tags, so `build_roads()` never touches those keys for those inputs; they keep passing unchanged.

- [ ] **Step 4: Run tests**

Run: `cd data_pipeline && python -m unittest test_fetch_osm -v`
Expected: `OK`, all classes pass (old + new).

- [ ] **Step 5: Commit**

```bash
git add data_pipeline/citygen/fetch_osm.py data_pipeline/test_fetch_osm.py
git commit -m "feat(w-1): pipeline - layer/deck en vias + water_areas/water_ways"
```

---

## Task 4: `fetch_elevation.py` — excavación de agua (Contrato 3)

**Files:**
- Modify: `data_pipeline/citygen/fetch_elevation.py`
- Test: `data_pipeline/test_fetch_elevation.py`

**Interfaces:**
- Consumes: `zones.clamp` (existing). Reads `water_areas`/`water_ways` in the exact shape produced by Task 3 (`{"footprint": [[x,z],...]}`, `{"width": float, "points": [[x,z],...]}`).
- Produces: `excavate_water(heights, nx, nz, cell_size, origin_x, origin_z, water_areas, water_ways) -> (heights, n_excavated, delta_outside)`. `build_terrain()` gains keyword params `water_areas=()`, `water_ways=()` and `terrain_stats` gains `water_excavated_nodes`/`water_excavated_delta_outside`. Consumed by `build.py` in Task 5.

- [ ] **Step 1: `excavate_water()` and its geometry helpers**

Add near the top of `data_pipeline/citygen/fetch_elevation.py`, after the module constants (after line 26, before `compute_grid_params`):

```python
WATER_DEPRESS = 1.5  # m; profundidad de excavacion sobre agua (contrato 3, ESPEC_SESION_RETROFIT_AGUA_V2)


def _point_in_polygon(x: float, z: float, poly) -> bool:
    """Ray casting estandar sobre poly = lista de (x, z) SIN el punto de cierre duplicado."""
    inside = False
    n = len(poly)
    j = n - 1
    for i in range(n):
        xi, zi = poly[i]
        xj, zj = poly[j]
        if (zi > z) != (zj > z):
            x_intersect = (xj - xi) * (z - zi) / (zj - zi) + xi
            if x < x_intersect:
                inside = not inside
        j = i
    return inside


def _dist_point_to_segment(x, z, x0, z0, x1, z1) -> float:
    dx, dz = x1 - x0, z1 - z0
    seg_len2 = dx * dx + dz * dz
    if seg_len2 <= 1e-9:
        t = 0.0
    else:
        t = zones.clamp(((x - x0) * dx + (z - z0) * dz) / seg_len2, 0.0, 1.0)
    px, pz = x0 + dx * t, z0 + dz * t
    return math.hypot(x - px, z - pz)


def _dist_to_polyline(x: float, z: float, points) -> float:
    best = math.inf
    for k in range(len(points) - 1):
        x0, z0 = points[k]
        x1, z1 = points[k + 1]
        d = _dist_point_to_segment(x, z, x0, z0, x1, z1)
        if d < best:
            best = d
    return best


def _bbox_of_points(points, margin: float):
    xs = [p[0] for p in points]
    zs = [p[1] for p in points]
    return (min(xs) - margin, min(zs) - margin, max(xs) + margin, max(zs) + margin)


def _grid_index_bounds(world_bbox, nx, nz, cell_size, origin_x, origin_z):
    xmin, zmin, xmax, zmax = world_bbox
    i0 = max(0, int(math.floor((xmin - origin_x) / cell_size)))
    i1 = min(nx - 1, int(math.ceil((xmax - origin_x) / cell_size)))
    j0 = max(0, int(math.floor((zmin - origin_z) / cell_size)))
    j1 = min(nz - 1, int(math.ceil((zmax - origin_z) / cell_size)))
    return i0, i1, j0, j1


def excavate_water(heights, nx, nz, cell_size, origin_x, origin_z, water_areas, water_ways):
    """Deprime la grilla de terreno en zonas de agua (contrato 3): WATER_DEPRESS m dentro
    de un water_area o a <= ancho/2 del eje de un water_way, degradado lineal hasta
    ancho/2 + cell_size. Determinista, una pasada; acota el recorrido al bbox de cada
    elemento (nunca escanea la grilla completa por elemento).

    Retorna (heights_excavados, num_nodos_excavados, delta_max_fuera_de_la_zona_excavada);
    el ultimo valor es la prueba de "cirugia limpia": es 0.0 siempre, por construccion
    (solo se escriben indices dentro de depress_of).
    """
    result = list(heights)
    depress_of = {}

    for area in water_areas:
        footprint = area["footprint"]
        ring = footprint[:-1] if len(footprint) > 1 and footprint[0] == footprint[-1] else footprint
        if len(ring) < 3:
            continue
        i0, i1, j0, j1 = _grid_index_bounds(
            _bbox_of_points(ring, cell_size), nx, nz, cell_size, origin_x, origin_z)
        for j in range(j0, j1 + 1):
            for i in range(i0, i1 + 1):
                x = origin_x + i * cell_size
                z = origin_z + j * cell_size
                if _point_in_polygon(x, z, ring):
                    idx = j * nx + i
                    depress_of[idx] = max(depress_of.get(idx, 0.0), WATER_DEPRESS)

    for way in water_ways:
        half_width = way["width"] / 2.0
        points = way["points"]
        if len(points) < 2:
            continue
        i0, i1, j0, j1 = _grid_index_bounds(
            _bbox_of_points(points, half_width + cell_size), nx, nz, cell_size, origin_x, origin_z)
        for j in range(j0, j1 + 1):
            for i in range(i0, i1 + 1):
                x = origin_x + i * cell_size
                z = origin_z + j * cell_size
                d = _dist_to_polyline(x, z, points)
                if d <= half_width:
                    depress = WATER_DEPRESS
                elif d <= half_width + cell_size:
                    depress = WATER_DEPRESS * (1.0 - (d - half_width) / cell_size)
                else:
                    continue
                idx = j * nx + i
                depress_of[idx] = max(depress_of.get(idx, 0.0), depress)

    for idx, depress in depress_of.items():
        result[idx] -= depress

    delta_outside = 0.0
    for idx in range(len(result)):
        if idx not in depress_of:
            d = abs(result[idx] - heights[idx])
            if d > delta_outside:
                delta_outside = d

    return result, len(depress_of), delta_outside
```

- [ ] **Step 2: Wire into `build_terrain()`**

Change the signature (line 307):

```python
def build_terrain(bbox, origin, cache_dir: str, refresh_elevation: bool, water_areas=(), water_ways=()):
```

Insert the excavation call between the smoothing/grade block and `raw_min = min(smoothed)` (i.e. right after the existing `max_grade_after_smooth = max_adjacent_grade(smoothed, nx, nz, cell_size)` line, before the existing `raw_min = min(smoothed)` line):

```python
    # Excavacion de agua (contrato 3, ESPEC_SESION_RETROFIT_AGUA_V2): despues de suavizar,
    # antes de calcular raw_min/base_elevation, para que un punto excavado que resulte ser
    # el minimo global de la grilla se absorba igual que cualquier otro minimo natural.
    smoothed, water_excavated_nodes, water_excavated_delta_outside = excavate_water(
        smoothed, nx, nz, cell_size, origin_x, origin_z, water_areas, water_ways)
    print(f"agua: {water_excavated_nodes} nodos excavados, delta max fuera de zona = {water_excavated_delta_outside:.4f} m")
```

Add the two new fields to the `terrain_stats` dict (existing lines 348-361, insert before the closing `}`):

```python
        "water_excavated_nodes": water_excavated_nodes,
        "water_excavated_delta_outside": water_excavated_delta_outside,
```

- [ ] **Step 3: Tests**

Append to `data_pipeline/test_fetch_elevation.py`:

```python
class TestExcavateWater(unittest.TestCase):
    def setUp(self):
        self.nx, self.nz, self.cell = 5, 5, 10.0
        self.origin_x, self.origin_z = 0.0, 0.0
        self.heights = [100.0] * (self.nx * self.nz)

    def test_area_depresses_only_interior_node(self):
        water_areas = [{"id": 0, "footprint": [[15.0, 15.0], [25.0, 15.0], [25.0, 25.0], [15.0, 25.0], [15.0, 15.0]]}]
        result, n_excavated, delta_outside = fe.excavate_water(
            self.heights, self.nx, self.nz, self.cell, self.origin_x, self.origin_z, water_areas, [])
        idx = 2 * self.nx + 2  # nodo (20, 20)
        self.assertAlmostEqual(result[idx], 100.0 - fe.WATER_DEPRESS)
        self.assertEqual(n_excavated, 1)
        self.assertEqual(delta_outside, 0.0)

    def test_way_depresses_nodes_within_half_width_and_gradient(self):
        water_ways = [{"id": 0, "kind": "river", "width": 6.0, "points": [[0.0, 40.0], [40.0, 40.0]]}]
        result, n_excavated, delta_outside = fe.excavate_water(
            self.heights, self.nx, self.nz, self.cell, self.origin_x, self.origin_z, [], water_ways)
        row_on_axis = [result[4 * self.nx + i] for i in range(self.nx)]  # z=40 -> j=4, dist=0
        self.assertTrue(all(abs(h - (100.0 - fe.WATER_DEPRESS)) < 1e-9 for h in row_on_axis))
        # fila z=30 (dist=10, dentro del degradado half_width..half_width+cell_size) tambien se toca.
        self.assertEqual(n_excavated, 10)
        self.assertEqual(delta_outside, 0.0)

    def test_way_gradient_zone_partial_depression(self):
        water_ways = [{"id": 0, "kind": "river", "width": 6.0, "points": [[0.0, 40.0], [40.0, 40.0]]}]
        result, _, _ = fe.excavate_water(
            self.heights, self.nx, self.nz, self.cell, self.origin_x, self.origin_z, [], water_ways)
        idx = 3 * self.nx + 2  # nodo (20, 30): distancia 10 a la via, half_width=3
        expected_depress = fe.WATER_DEPRESS * (1.0 - (10.0 - 3.0) / self.cell)
        self.assertAlmostEqual(result[idx], 100.0 - expected_depress, places=4)

    def test_no_water_leaves_grid_unchanged(self):
        result, n_excavated, delta_outside = fe.excavate_water(
            self.heights, self.nx, self.nz, self.cell, self.origin_x, self.origin_z, [], [])
        self.assertEqual(result, self.heights)
        self.assertEqual(n_excavated, 0)
        self.assertEqual(delta_outside, 0.0)
```

- [ ] **Step 4: Run tests**

Run: `cd data_pipeline && python -m unittest test_fetch_elevation -v`
Expected: `OK`, existing 20 tests + new `TestExcavateWater` (4 tests) pass.

- [ ] **Step 5: Commit**

```bash
git add data_pipeline/citygen/fetch_elevation.py data_pipeline/test_fetch_elevation.py
git commit -m "feat(w-1): pipeline - excavacion de terreno bajo agua"
```

---

## Task 5: `build.py` — integración: schema 1.4, stats, `map_data`, wiring (Contrato 2)

**Files:**
- Modify: `data_pipeline/citygen/build.py`
- Test: `data_pipeline/test_build.py`

**Interfaces:**
- Consumes: `fetch_osm.build_water_areas`/`build_water_ways` (Task 3), `fetch_elevation.build_terrain(..., water_areas=, water_ways=)` (Task 4), `svg_preview.generate_svg` (new signature, Task 6 — this task updates the call site; Task 6 updates the function itself).
- Produces: `SCHEMA_VERSION = "1.4"`; `GenResult.stats` gains `n_bridges`/`n_tunnels`/`n_layered`/`n_links`/`n_water_areas`/`n_water_ways`; written `map.json` gains top-level `water_areas`/`water_ways` sections.

- [ ] **Step 1: Bump `SCHEMA_VERSION`**

In `data_pipeline/citygen/build.py`, change line 11:

```python
SCHEMA_VERSION = "1.4"
```

- [ ] **Step 2: Extend `osm_stats`, call the new builders, wire water into terrain, extend `stats`/`map_data`, update the `svg_preview` call**

Replace the body of `generate()` from the `osm_stats = {...}` block through the `return GenResult(ok=True, ...)` line (existing lines 70-133) with:

```python
    osm_stats = {
        "roads_by_type": {}, "roads_oneway_by_value": {0: 0, 1: 0, -1: 0}, "controls_by_type": {},
        "roads_discarded_few_points": 0, "roads_discarded_outside_bbox": 0,
        "buildings_discarded_not_closed": 0, "buildings_discarded_few_points": 0,
        "buildings_discarded_few_vertices": 0, "buildings_discarded_outside_bbox": 0,
        "n_bridges": 0, "n_tunnels": 0, "n_layered": 0, "n_links": 0,
        "water_areas_discarded_not_closed": 0, "water_areas_discarded_few_points": 0,
        "water_areas_discarded_few_vertices": 0, "water_areas_discarded_outside_bbox": 0,
        "water_ways_discarded_few_points": 0, "water_ways_discarded_outside_bbox": 0,
    }
    roads = fetch_osm.build_roads(ways, nodes, resolved.bbox, resolved.origin, osm_stats)
    buildings = fetch_osm.build_buildings(ways, nodes, resolved.bbox, resolved.origin, osm_stats)
    controls = fetch_osm.build_controls(raw, resolved.bbox, resolved.origin, osm_stats)
    water_areas = fetch_osm.build_water_areas(ways, nodes, resolved.bbox, resolved.origin, osm_stats)
    water_ways = fetch_osm.build_water_ways(ways, nodes, resolved.bbox, resolved.origin, osm_stats)

    road_km, largest_component_pct = validate.compute_connectivity(roads)

    reason = validate.check_road_data(road_km) or validate.check_connectivity(largest_component_pct)
    if reason is not None:
        return GenResult(ok=False, reason=reason, stats=None, zone_id=resolved.zone_id)

    reason = validate.check_building_cap(len(buildings))
    if reason is not None:
        return GenResult(ok=False, reason=reason, stats=None, zone_id=resolved.zone_id)

    report("elevation")
    terrain, terrain_stats = fetch_elevation.build_terrain(
        resolved.bbox, resolved.origin, zone_cache_dir, refresh_elevation,
        water_areas=water_areas, water_ways=water_ways,
    )

    report("build")
    max_road_slope_pct = 0.0
    for road in roads:
        slope = fetch_elevation.road_slope_stats(road["points"], terrain)
        if slope > max_road_slope_pct:
            max_road_slope_pct = slope

    extent, span_x, span_z = _extent_and_span(resolved.bbox, resolved.origin)
    flags = validate.compute_flags(len(buildings), max_road_slope_pct)
    stats = {
        "span_x": round(span_x, 1), "span_z": round(span_z, 1),
        "extent_m": [round(v, 1) for v in extent],
        "road_km": round(road_km, 1), "n_buildings": len(buildings),
        "largest_component_pct": round(largest_component_pct, 1),
        "max_road_slope_pct": round(max_road_slope_pct, 1), "flags": flags,
        "n_bridges": osm_stats["n_bridges"], "n_tunnels": osm_stats["n_tunnels"],
        "n_layered": osm_stats["n_layered"], "n_links": osm_stats["n_links"],
        "n_water_areas": len(water_areas), "n_water_ways": len(water_ways),
    }

    meta = build_meta(resolved, stats)
    map_data = {
        "meta": meta, "roads": roads, "buildings": buildings, "controls": controls,
        "water_areas": water_areas, "water_ways": water_ways, "terrain": terrain,
    }
    serialized = json.dumps(map_data, ensure_ascii=False, separators=(",", ":"))
    size_bytes = len(serialized.encode("utf-8"))

    reason = validate.check_file_size(size_bytes)
    if reason is not None:
        return GenResult(ok=False, reason=reason, stats=stats, zone_id=resolved.zone_id)

    report("package")
    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(serialized)

    if svg_path is not None:
        svg_preview.generate_svg(roads, buildings, water_areas, water_ways, terrain, svg_path)

    diagnostics = {
        "osm_stats": osm_stats, "terrain_stats": terrain_stats,
        "size_bytes": size_bytes, "n_roads": len(roads), "n_controls": len(controls),
    }
    return GenResult(ok=True, reason=None, stats=stats, zone_id=resolved.zone_id, diagnostics=diagnostics)
```

- [ ] **Step 3: Update existing schema-version assertions + `_flat_terrain()` fixture, add water tests**

In `data_pipeline/test_build.py`:
- Line 71 (`self.assertEqual(data["meta"]["schema_version"], "1.3")`) → change `"1.3"` to `"1.4"`, and rename the test method `test_successful_generation_writes_v1_3_meta` → `test_successful_generation_writes_v1_4_meta`.
- Line 89-99 (`TestBuildMeta.test_schema_version_1_3_with_stats`) → change the literal `"1.3"` on the `self.assertEqual(meta["schema_version"], "1.3")` line to `"1.4"`, and rename the method to `test_schema_version_1_4_with_stats`.
- `_flat_terrain()` (lines 12-21) needs no change — it's fully mocked via `patch(..., return_value=_flat_terrain())`, so the new `water_areas=`/`water_ways=` kwargs `build_terrain()` now receives are simply ignored by the mock.

Append these to the end of `data_pipeline/test_build.py` (before the `if __name__ == "__main__":` line):

```python
def _dense_grid_raw_with_water():
    raw = _dense_grid_raw()
    elements = raw["elements"]
    water_nodes = [
        {"type": "node", "id": 9001, "lat": 4.4390, "lon": -75.2019},
        {"type": "node", "id": 9002, "lat": 4.4390, "lon": -75.2018},
        {"type": "node", "id": 9003, "lat": 4.4391, "lon": -75.2018},
        {"type": "node", "id": 9004, "lat": 4.4391, "lon": -75.2019},
    ]
    elements.extend(water_nodes)
    elements.append(_grid_way(9101, [9001, 9002, 9003, 9004, 9001], {"natural": "water"}))
    river_nodes = [
        {"type": "node", "id": 9201, "lat": 4.4395, "lon": -75.2019},
        {"type": "node", "id": 9202, "lat": 4.4395, "lon": -75.2010},
    ]
    elements.extend(river_nodes)
    elements.append(_grid_way(9102, [9201, 9202], {"waterway": "river"}))
    return {"elements": elements}


class TestWaterIntegration(unittest.TestCase):
    def test_water_sections_and_stats_present(self):
        raw = _dense_grid_raw_with_water()
        zone = ZoneSpec(name="Test City", size="M", lat=4.4380, lon=-75.2019)
        with tempfile.TemporaryDirectory() as tmp:
            out_path = os.path.join(tmp, "map.json")
            with patch("citygen.build.fetch_osm.fetch", return_value=raw), \
                 patch("citygen.build.fetch_elevation.build_terrain", return_value=_flat_terrain()):
                result = build.generate(zone, tmp, out_path)
            self.assertTrue(result.ok, result.reason)
            with open(out_path, "r", encoding="utf-8") as f:
                data = json.load(f)
        self.assertEqual(len(data["water_areas"]), 1)
        self.assertEqual(len(data["water_ways"]), 1)
        self.assertEqual(data["meta"]["stats"]["n_water_areas"], 1)
        self.assertEqual(data["meta"]["stats"]["n_water_ways"], 1)
        self.assertEqual(data["water_ways"][0]["kind"], "river")

    def test_build_terrain_receives_water_features(self):
        raw = _dense_grid_raw_with_water()
        zone = ZoneSpec(name="Test City", size="M", lat=4.4380, lon=-75.2019)
        with tempfile.TemporaryDirectory() as tmp:
            with patch("citygen.build.fetch_osm.fetch", return_value=raw), \
                 patch("citygen.build.fetch_elevation.build_terrain", return_value=_flat_terrain()) as mock_terrain:
                build.generate(zone, tmp, os.path.join(tmp, "map.json"))
            _, kwargs = mock_terrain.call_args
            self.assertEqual(len(kwargs["water_areas"]), 1)
            self.assertEqual(len(kwargs["water_ways"]), 1)
```

- [ ] **Step 4: Run tests**

Run: `cd data_pipeline && python -m unittest test_build -v`
Expected: `OK`, all tests pass (4 existing, renamed, + 2 new `TestWaterIntegration`).

- [ ] **Step 5: Commit**

```bash
git add data_pipeline/citygen/build.py data_pipeline/test_build.py
git commit -m "feat(w-1): pipeline - schema 1.4, stats de agua/puentes, wiring completo"
```

---

## Task 6: `svg_preview.py` — agua en azul + tablero distintivo (Contrato 1, herramienta de dev)

**Files:**
- Modify: `data_pipeline/citygen/svg_preview.py`
- Test: `data_pipeline/test_svg_preview.py`

**Interfaces:**
- Consumes: `water_areas`/`water_ways` in the shape from Task 3; `road.get("deck")` from Task 3.
- Produces: `generate_svg(roads, buildings, water_areas, water_ways, terrain, path)` — new signature (water params inserted before `terrain`). Consumed by `build.py` (already updated in Task 5).

- [ ] **Step 1: Rewrite `generate_svg()`**

Replace the full `generate_svg()` function (lines 28-80) in `data_pipeline/citygen/svg_preview.py`:

```python
def generate_svg(roads, buildings, water_areas, water_ways, terrain, path):
    all_x = []
    all_z = []
    for road in roads:
        for x, z in road["points"]:
            all_x.append(x)
            all_z.append(z)
    for b in buildings:
        for x, z in b["footprint"]:
            all_x.append(x)
            all_z.append(z)
    for w in water_areas:
        for x, z in w["footprint"]:
            all_x.append(x)
            all_z.append(z)
    for w in water_ways:
        for x, z in w["points"]:
            all_x.append(x)
            all_z.append(z)
    # Incluir la extension de la grilla de terreno para que el hillshade no se recorte.
    all_x.append(terrain["origin_x"])
    all_x.append(terrain["origin_x"] + (terrain["nx"] - 1) * terrain["cell_size"])
    all_z.append(terrain["origin_z"])
    all_z.append(terrain["origin_z"] + (terrain["nz"] - 1) * terrain["cell_size"])

    if not all_x:
        print("Sin datos para preview.svg")
        return

    margin = 10.0
    min_x, max_x = min(all_x) - margin, max(all_x) + margin
    min_z, max_z = min(all_z) - margin, max(all_z) + margin
    width = max_x - min_x
    height = max_z - min_z

    # La formula de proyeccion ya deja z negativo hacia el norte, asi que
    # usar z directamente como coordenada svg-y coloca el norte arriba.
    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{min_x:.2f} {min_z:.2f} {width:.2f} {height:.2f}">',
        f'<rect x="{min_x:.2f}" y="{min_z:.2f}" width="{width:.2f}" height="{height:.2f}" fill="#f0f0f0" />',
    ]

    _append_hillshade(parts, terrain)

    for w in water_areas:
        pts = " ".join(f"{x:.2f},{z:.2f}" for x, z in w["footprint"])
        parts.append(f'<polygon points="{pts}" fill="#4a7d94" stroke="none" />')

    for w in water_ways:
        pts = " ".join(f"{x:.2f},{z:.2f}" for x, z in w["points"])
        parts.append(
            f'<polyline points="{pts}" fill="none" stroke="#4a7d94" '
            f'stroke-width="{max(w["width"], 1.0):.2f}" stroke-linecap="round" stroke-linejoin="round" />'
        )

    for b in buildings:
        pts = " ".join(f"{x:.2f},{z:.2f}" for x, z in b["footprint"])
        parts.append(f'<polygon points="{pts}" fill="#999999" stroke="none" />')

    for road in roads:
        pts = " ".join(f"{x:.2f},{z:.2f}" for x, z in road["points"])
        stroke_width = max(road["width"] * 0.5, 0.5)
        parts.append(
            f'<polyline points="{pts}" fill="none" stroke="#000000" '
            f'stroke-width="{stroke_width:.2f}" stroke-linecap="round" stroke-linejoin="round" />'
        )
        if road.get("deck") == "bridge":
            parts.append(
                f'<polyline points="{pts}" fill="none" stroke="#ffffff" '
                f'stroke-width="{max(stroke_width * 0.4, 0.3):.2f}" stroke-dasharray="4,4" '
                f'stroke-linecap="round" stroke-linejoin="round" />'
            )

    parts.append("</svg>")

    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(parts))
    print(f"preview.svg escrito: {path}")
```

- [ ] **Step 2: Update tests**

Replace `data_pipeline/test_svg_preview.py` entirely:

```python
#!/usr/bin/env python3
import os
import tempfile
import unittest

from citygen import svg_preview


class TestGenerateSvg(unittest.TestCase):
    def test_writes_svg_with_expected_elements(self):
        roads = [{"points": [[0.0, 0.0], [10.0, 0.0]], "width": 6.0}]
        buildings = [{"footprint": [[0.0, 0.0], [5.0, 0.0], [5.0, 5.0], [0.0, 5.0]]}]
        water_areas = [{"footprint": [[20.0, 0.0], [25.0, 0.0], [25.0, 5.0], [20.0, 5.0]]}]
        water_ways = [{"width": 6.0, "points": [[0.0, 10.0], [10.0, 10.0]]}]
        terrain = {"cell_size": 10.0, "nx": 2, "nz": 2, "origin_x": 0.0, "origin_z": 0.0,
                   "heights": [0.0, 1.0, 1.0, 2.0]}
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "preview.svg")
            svg_preview.generate_svg(roads, buildings, water_areas, water_ways, terrain, path)
            with open(path, "r", encoding="utf-8") as f:
                content = f.read()
        self.assertIn("<svg", content)
        self.assertIn("<polyline", content)
        self.assertIn("<polygon", content)
        self.assertIn("#4a7d94", content)

    def test_bridge_road_gets_distinct_stroke(self):
        roads = [{"points": [[0.0, 0.0], [10.0, 0.0]], "width": 6.0, "deck": "bridge"}]
        terrain = {"cell_size": 10.0, "nx": 2, "nz": 2, "origin_x": 0.0, "origin_z": 0.0,
                   "heights": [0.0, 0.0, 0.0, 0.0]}
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "preview.svg")
            svg_preview.generate_svg(roads, [], [], [], terrain, path)
            with open(path, "r", encoding="utf-8") as f:
                content = f.read()
        self.assertIn("stroke-dasharray", content)

    def test_empty_scene_does_not_raise(self):
        terrain = {"cell_size": 10.0, "nx": 2, "nz": 2, "origin_x": 0.0, "origin_z": 0.0,
                   "heights": [0.0, 0.0, 0.0, 0.0]}
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "preview.svg")
            svg_preview.generate_svg([], [], [], [], terrain, path)
            self.assertTrue(os.path.isfile(path))


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 3: Run tests**

Run: `cd data_pipeline && python -m unittest test_svg_preview -v`
Expected: `OK`, 3 tests pass.

- [ ] **Step 4: Commit**

```bash
git add data_pipeline/citygen/svg_preview.py data_pipeline/test_svg_preview.py
git commit -m "feat(w-1): pipeline - preview SVG con agua y tableros distintivos"
```

---

## Task 7: `generate_map.py` + regeneración de Jordán + diagnóstico final + regresión

**Files:**
- Modify: `data_pipeline/generate_map.py`
- No test file (CLI script; behavior verified by running it against real data below).

**Interfaces:** Consumes `result.stats`/`result.diagnostics` exactly as returned by `build.generate()` (Task 5).

- [ ] **Step 1: Extend the `--stats` printing block**

In `data_pipeline/generate_map.py`, replace the `if args.stats:` block (existing lines 85-98) with:

```python
    if args.stats:
        ts = result.diagnostics["terrain_stats"]
        os_ = result.diagnostics["osm_stats"]
        print("--- stats ---")
        print(f"tamano map.json: {result.diagnostics['size_bytes']} bytes")
        print(f"elevacion: {ts['elevation_min_abs']:.1f}-{ts['elevation_max_abs']:.1f} msnm")
        print(f"pendiente celdas adyacentes: {ts['max_grade_before_smooth']:.1f}% -> {ts['max_grade_after_smooth']:.1f}%")
        print(f"descartes vias: pocos_puntos={os_['roads_discarded_few_points']} fuera_bbox={os_['roads_discarded_outside_bbox']}")
        print(
            f"descartes edificios: no_cerrado={os_['buildings_discarded_not_closed']} "
            f"pocos_puntos={os_['buildings_discarded_few_points']} "
            f"pocos_vertices={os_['buildings_discarded_few_vertices']} "
            f"fuera_bbox={os_['buildings_discarded_outside_bbox']}"
        )
        print(
            f"agua: areas={result.stats['n_water_areas']} vias={result.stats['n_water_ways']} "
            f"nodos_excavados={ts['water_excavated_nodes']} "
            f"delta_max_fuera_de_zona={ts['water_excavated_delta_outside']:.4f}m"
        )
        print(
            f"descartes agua: areas(no_cerrado={os_['water_areas_discarded_not_closed']} "
            f"pocos_puntos={os_['water_areas_discarded_few_points']} "
            f"pocos_vertices={os_['water_areas_discarded_few_vertices']} "
            f"fuera_bbox={os_['water_areas_discarded_outside_bbox']}) "
            f"vias(pocos_puntos={os_['water_ways_discarded_few_points']} "
            f"fuera_bbox={os_['water_ways_discarded_outside_bbox']})"
        )
        print(
            f"puentes={result.stats['n_bridges']} tuneles={result.stats['n_tunnels']} "
            f"con_layer={result.stats['n_layered']} ramales(*_link)={result.stats['n_links']}"
        )
```

- [ ] **Step 2: Full pipeline test suite**

Run: `cd data_pipeline && python -m unittest discover -p "test_*.py"`
Expected: `OK`, test count = 67 (baseline) + tests added in Tasks 2-6 (11 + 4 + 4 + 2 + 1 = 22 new) = 89 total.

- [ ] **Step 3: Regenerate the packaged Jordán map**

Run: `cd data_pipeline && python generate_map.py --legacy-jordan --stats --svg`

No `--refresh` needed: the existing `cache/legacy/overpass_raw.json` predates the `query` key (Task 2), so `load_osm_cache()` will print `cache en formato viejo (sin query registrada): re-consultando` and fetch fresh data automatically — this is the auto-invalidation contract proving itself on real data. Elevation cache (`cache/legacy/elevation_raw.json`) stays valid (same bbox/grid), so no elevation re-fetch is needed.

Expected output includes:
- `Consultando Overpass: ...` (proves the auto-invalidation triggered a real re-fetch)
- `agua: N nodos excavados, delta max fuera de zona = 0.0000 m` (the "cirugía limpia" proof — must be exactly `0.0000`)
- `map.json escrito en ...s: zone_id=z1_custom_4_4380_m75_2020` (same zone_id as before — bbox/origin unchanged)
- The `--stats` block from Step 1, including the new `agua:`/`descartes agua:`/`puentes=...` lines
- `Copiado a .../godot/data/map.json`

**Report the full printed table to the human verbatim** — this is the "tras la query nueva" half of the Task-1 diagnostic (previous line count for roads should grow by exactly the number of new `*_link` ways found, per the `roads_by_type` breakdown; building count must stay at exactly 4916 — unaffected by the highway/water query additions).

- [ ] **Step 4: Regression — pipeline schema check**

Run:
```bash
cd data_pipeline && python -c "
import json
with open('output/map.json', encoding='utf-8') as f:
    data = json.load(f)
print('schema_version:', data['meta']['schema_version'])
print('n_roads:', len(data['roads']))
print('n_buildings:', len(data['buildings']))
print('n_water_areas:', len(data['water_areas']))
print('n_water_ways:', len(data['water_ways']))
print('stats:', data['meta']['stats'])
"
```
Expected: `schema_version: 1.4`, `n_buildings: 4916` (unchanged from the pre-W-1 baseline), `n_roads` ≥ 526 (526 + any real `*_link` ways in Jordán's OSM data), `stats` dict contains `n_bridges`/`n_tunnels`/`n_layered`/`n_links`/`n_water_areas`/`n_water_ways`.

- [ ] **Step 5: Regression — Godot boots unchanged with the 1.4 JSON**

Run: `cd godot && "/c/Users/Brayhan/AppData/Local/Programs/Godot/Godot_v4.4-stable_win64_console.exe" --headless --path . --quit-after 3`
Expected: identical clean boot to before this phase — no `SCRIPT ERROR`, no `Invalid get index`. The unmodified `map_loader.gd` reads `roads`/`buildings`/`controls`/`terrain` and ignores the two new top-level `water_areas`/`water_ways` keys entirely (Godot's `JSON.parse_string` tolerates unknown dictionary keys), so this must boot exactly as it did before W-1. Terrain values near any excavated water cells will differ from the pre-W-1 baseline (expected, per the phase's own regression checklist — those depressions are the intended new behavior, not a bug); every other terrain node must be byte-identical (guaranteed by Task 4's `delta_outside == 0.0` proof).

- [ ] **Step 6: Commit**

```bash
git add data_pipeline/generate_map.py data_pipeline/output/map.json data_pipeline/output/preview.svg godot/data/map.json
git commit -m "feat(w-1): pipeline - stats de agua en CLI + regenera Jordan (schema 1.4)"
```

## Self-Review Notes

1. **Spec coverage:** Contract 1 (query `*_link`/agua, ancho 5.0m clamp[3,20], caché auto-invalidante) → Task 2. Contract 2 (schema 1.4, `roads[].layer`/`.deck`, `water_areas`/`water_ways`, `meta.stats` nuevas 6 llaves, compatibilidad aditiva) → Tasks 3, 5. Contract 3 (excavación, `WATER_DEPRESS=1.5`, degradado 1 celda, una pasada acotada por bbox, delta-fuera=0.0) → Task 4. SVG preview (agua azul, tablero distintivo) → Task 6. "PRIMER diagnóstico" (empírico, con caché existente) → Task 1. Regeneración de Jordán + regresión completa (Godot sin tocar, delta 0.0 impreso, conteos idénticos salvo `*_link`) → Task 7.
2. **Placeholder scan:** none — every step has complete code or an exact runnable command with a concrete expected signal (some outputs are genuinely data-dependent, e.g. "*_link ways found in Jordán's real OSM data" or "N nodos excavados", and are explicitly framed as measurements to report rather than fixed pass/fail assertions).
3. **Type consistency:** `water_areas`/`water_ways` entry shapes are identical everywhere they're produced (Task 3: `fetch_osm.build_water_areas`/`build_water_ways`) and consumed (Task 4: `excavate_water`; Task 5: `build.py` map_data/stats; Task 6: `svg_preview.generate_svg`). `road_layer`/`road_deck` return types (`int|None`, `str|None`) match their single call site in `build_roads()` (Task 3). `build_terrain()`'s new `water_areas=`/`water_ways=` kwargs (Task 4) match the keyword names used at its only call site in `build.py` (Task 5). `generate_svg()`'s new positional param order (Task 6) matches its only call site in `build.py` (Task 5, already written with the new signature). `osm_stats` keys referenced by `build_roads()`/`build_water_areas()`/`build_water_ways()` (Task 3) are all present in the dict built in `build.py` (Task 5) and read back into `stats`/printed in `generate_map.py` (Task 7).
