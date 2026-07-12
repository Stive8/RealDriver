"""citygen: generacion de map.json para cualquier zona (fase C-1).

API publica:
    citygen.generate(zone, cache_dir, out_path, progress_cb=None) -> GenResult
    citygen.ZoneSpec(name, size, lat=None, lon=None, bbox=None, origin=None)
"""
from .build import GenResult, generate
from .zones import ZoneSpec

__all__ = ["ZoneSpec", "GenResult", "generate"]
