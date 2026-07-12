"""Validaciones estructurales del pipeline (contrato 3, ESPEC_SESION_CIUDADES2).
Fallar con causa exacta, nunca degradar en silencio. Union-find espeja
godot/scripts/traffic_graph.gd (FUSE_FMT "%.2f|%.2f", sin epsilon) para que la
conectividad medida aqui coincida con el grafo que Godot construira en runtime.
"""
import math

MIN_ROAD_KM = 3.0
MIN_LARGEST_COMPONENT_PCT = 60.0
MAX_BUILDINGS = 25000
MAX_FILE_BYTES = 12 * 1024 * 1024
SPARSE_BUILDINGS_THRESHOLD = 200
STEEP_SLOPE_THRESHOLD_PCT = 15.0

FUSE_FMT = "%.2f|%.2f"


class _DSU:
    def __init__(self):
        self.parent = {}
        self.size = {}

    def add(self, key):
        if key not in self.parent:
            self.parent[key] = key
            self.size[key] = 1

    def find(self, key):
        while self.parent[key] != key:
            self.parent[key] = self.parent[self.parent[key]]
            key = self.parent[key]
        return key

    def union(self, a, b):
        ra, rb = self.find(a), self.find(b)
        if ra == rb:
            return
        if self.size[ra] < self.size[rb]:
            ra, rb = rb, ra
        self.parent[rb] = ra
        self.size[ra] += self.size[rb]


def compute_connectivity(roads) -> tuple:
    dsu = _DSU()
    edges = []
    for road in roads:
        points = road["points"]
        for i in range(len(points) - 1):
            x0, z0 = points[i]
            x1, z1 = points[i + 1]
            ka = FUSE_FMT % (x0, z0)
            kb = FUSE_FMT % (x1, z1)
            dsu.add(ka)
            dsu.add(kb)
            length = math.hypot(x1 - x0, z1 - z0)
            edges.append((ka, kb, length))
            dsu.union(ka, kb)

    total_length = sum(e[2] for e in edges)
    if total_length <= 0.0:
        return 0.0, 0.0

    component_length = {}
    for ka, _kb, length in edges:
        root = dsu.find(ka)
        component_length[root] = component_length.get(root, 0.0) + length

    largest = max(component_length.values())
    return total_length / 1000.0, 100.0 * largest / total_length


def check_road_data(road_km: float):
    return None if road_km >= MIN_ROAD_KM else "insufficient_road_data"


def check_connectivity(largest_component_pct: float):
    return None if largest_component_pct >= MIN_LARGEST_COMPONENT_PCT else "fragmented_road_graph"


def check_building_cap(n_buildings: int):
    return None if n_buildings <= MAX_BUILDINGS else "zone_too_dense"


def check_file_size(size_bytes: int):
    return None if size_bytes <= MAX_FILE_BYTES else "zone_too_dense"


def compute_flags(n_buildings: int, max_road_slope_pct: float) -> list:
    flags = []
    if n_buildings < SPARSE_BUILDINGS_THRESHOLD:
        flags.append("sparse_buildings")
    if max_road_slope_pct > STEEP_SLOPE_THRESHOLD_PCT:
        flags.append("steep")
    return flags
