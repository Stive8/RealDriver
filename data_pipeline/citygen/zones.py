"""Identidad de zona: canonicalizacion de centro, zone_id, bbox derivado y
proyeccion lat/lon <-> metros. Unica fuente de verdad para "que zona es esta"
y "que sistema de coordenadas usa" (ver ESPEC_SESION_CIUDADES2, contrato 1).
"""
import math
from dataclasses import dataclass

SIZE_SIDES = {"S": 1500.0, "M": 2500.0, "L": 3500.0}
CENTER_QUANT = 0.002
PIPELINE_MAJOR = 1


def clamp(value: float, lo: float, hi: float) -> float:
    return max(lo, min(hi, value))


def project(lat: float, lon: float, origin: tuple) -> tuple:
    lat0, lon0 = origin
    x = (lon - lon0) * 111320.0 * math.cos(math.radians(lat0))
    z = -(lat - lat0) * 110540.0
    return round(x, 2), round(z, 2)


def deproject(x: float, z: float, origin: tuple) -> tuple:
    """Inversa exacta de project(): mundo (x, z) -> (lat, lon)."""
    lat0, lon0 = origin
    lon = lon0 + x / (111320.0 * math.cos(math.radians(lat0)))
    lat = lat0 - z / 110540.0
    return lat, lon


def canonicalize_center(lat: float, lon: float) -> tuple:
    lat_c = round(round(lat / CENTER_QUANT) * CENTER_QUANT, 4)
    lon_c = round(round(lon / CENTER_QUANT) * CENTER_QUANT, 4)
    return lat_c, lon_c


def derive_bbox(lat_c: float, lon_c: float, side: float) -> tuple:
    dlat = (side / 2.0) / 110540.0
    dlon = (side / 2.0) / (111320.0 * math.cos(math.radians(lat_c)))
    return (lat_c - dlat, lon_c - dlon, lat_c + dlat, lon_c + dlon)


def encode_coord(v: float) -> str:
    return f"{v:.4f}".replace("-", "m").replace(".", "_")


def make_zone_id(size: str, lat_c: float, lon_c: float) -> str:
    return f"z{PIPELINE_MAJOR}_{size}_{encode_coord(lat_c)}_{encode_coord(lon_c)}"


@dataclass
class ZoneSpec:
    name: str
    size: str  # "S" | "M" | "L" | "custom" (legado)
    lat: float = None
    lon: float = None
    bbox: tuple = None     # explicito: modo legado (Jordan)
    origin: tuple = None   # explicito: modo legado (Jordan)


@dataclass
class ResolvedZone:
    zone_id: str
    cache_key: str  # subcarpeta de cache/: zone_id normalmente, "legacy" para Jordan
    bbox: tuple
    origin: tuple
    size: str
    name: str


def resolve(spec: ZoneSpec) -> ResolvedZone:
    if spec.bbox is not None or spec.origin is not None:
        if spec.bbox is None or spec.origin is None:
            raise ValueError("ZoneSpec legado requiere bbox Y origin explicitos")
        lat_c, lon_c = canonicalize_center(*spec.origin)
        zone_id = make_zone_id(spec.size, lat_c, lon_c)
        return ResolvedZone(
            zone_id=zone_id, cache_key="legacy",
            bbox=spec.bbox, origin=spec.origin, size=spec.size, name=spec.name,
        )

    if spec.lat is None or spec.lon is None:
        raise ValueError("ZoneSpec normal requiere lat Y lon")
    if spec.size not in SIZE_SIDES:
        raise ValueError(f"size invalido: {spec.size!r} (debe ser S, M o L)")

    lat_c, lon_c = canonicalize_center(spec.lat, spec.lon)
    bbox = derive_bbox(lat_c, lon_c, SIZE_SIDES[spec.size])
    zone_id = make_zone_id(spec.size, lat_c, lon_c)
    return ResolvedZone(
        zone_id=zone_id, cache_key=zone_id,
        bbox=bbox, origin=(lat_c, lon_c), size=spec.size, name=spec.name,
    )
