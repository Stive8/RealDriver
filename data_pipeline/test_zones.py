#!/usr/bin/env python3
"""Tests para citygen.zones (canonicalizacion, zone_id, proyeccion)."""
import math
import unittest

from citygen import zones


class TestClamp(unittest.TestCase):
    def test_clamps_within_range(self):
        self.assertEqual(zones.clamp(5.0, 0.0, 10.0), 5.0)
        self.assertEqual(zones.clamp(-1.0, 0.0, 10.0), 0.0)
        self.assertEqual(zones.clamp(11.0, 0.0, 10.0), 10.0)


class TestProjectDeproject(unittest.TestCase):
    def test_deproject_is_inverse_of_project(self):
        origin = (4.4380, -75.2019)
        lat, lon = 4.4380 + 0.003, -75.2019 - 0.004
        x, z = zones.project(lat, lon, origin)
        lat2, lon2 = zones.deproject(x, z, origin)
        self.assertAlmostEqual(lat, lat2, places=4)
        self.assertAlmostEqual(lon, lon2, places=4)

    def test_deproject_origin_is_zero_zero(self):
        origin = (4.4380, -75.2019)
        lat, lon = zones.deproject(0.0, 0.0, origin)
        self.assertAlmostEqual(lat, origin[0], places=6)
        self.assertAlmostEqual(lon, origin[1], places=6)


class TestCanonicalizeCenter(unittest.TestCase):
    def test_rounds_to_nearest_quantum(self):
        lat_c, lon_c = zones.canonicalize_center(4.4380, -75.2019)
        self.assertAlmostEqual(lat_c, 4.438, places=6)
        self.assertAlmostEqual(lon_c, -75.202, places=6)

    def test_points_within_200m_share_canonical_center(self):
        # ~0.0009 deg de latitud ~= 100 m; bien por debajo de medio paso de 0.002.
        lat_c1, lon_c1 = zones.canonicalize_center(4.50000, -74.60000)
        lat_c2, lon_c2 = zones.canonicalize_center(4.50090, -74.60090)
        self.assertEqual((lat_c1, lon_c1), (lat_c2, lon_c2))


class TestEncodeCoord(unittest.TestCase):
    def test_positive_value(self):
        self.assertEqual(zones.encode_coord(4.4380), "4_4380")

    def test_negative_value(self):
        self.assertEqual(zones.encode_coord(-75.2020), "m75_2020")


class TestDeriveBbox(unittest.TestCase):
    def test_bbox_span_matches_side(self):
        lat_c, lon_c = 4.438, -75.202
        bbox = zones.derive_bbox(lat_c, lon_c, side=2500.0)
        lat_s, lon_o, lat_n, lon_e = bbox
        dlat_m = (lat_n - lat_s) * 110540.0
        dlon_m = (lon_e - lon_o) * 111320.0 * math.cos(math.radians(lat_c))
        self.assertAlmostEqual(dlat_m, 2500.0, delta=0.5)
        self.assertAlmostEqual(dlon_m, 2500.0, delta=0.5)


class TestMakeZoneId(unittest.TestCase):
    def test_matches_worked_example(self):
        # Ejemplo del contrato: centro canonico de Jordan, tamano M.
        zone_id = zones.make_zone_id("M", 4.438, -75.202)
        self.assertEqual(zone_id, "z1_M_4_4380_m75_2020")


class TestResolve(unittest.TestCase):
    def test_normal_mode_derives_bbox_and_zone_id(self):
        spec = zones.ZoneSpec(name="Test City", size="M", lat=4.4380, lon=-75.2019)
        resolved = zones.resolve(spec)
        self.assertEqual(resolved.zone_id, "z1_M_4_4380_m75_2020")
        self.assertEqual(resolved.cache_key, resolved.zone_id)
        self.assertEqual(resolved.size, "M")
        self.assertEqual(resolved.origin, (4.438, -75.202))
        lat_s, lon_o, lat_n, lon_e = resolved.bbox
        self.assertLess(lat_s, resolved.origin[0])
        self.assertGreater(lat_n, resolved.origin[0])

    def test_two_nearby_points_produce_same_zone_id(self):
        spec1 = zones.ZoneSpec(name="A", size="S", lat=4.50000, lon=-74.60000)
        spec2 = zones.ZoneSpec(name="B", size="S", lat=4.50090, lon=-74.60090)
        self.assertEqual(zones.resolve(spec1).zone_id, zones.resolve(spec2).zone_id)

    def test_legacy_mode_uses_explicit_bbox_and_origin(self):
        bbox = (4.433220, -75.210321, 4.442772, -75.193563)
        origin = (4.4380, -75.2019)
        spec = zones.ZoneSpec(name="Jordán, Ibagué", size="custom", bbox=bbox, origin=origin)
        resolved = zones.resolve(spec)
        self.assertEqual(resolved.bbox, bbox)
        self.assertEqual(resolved.origin, origin)
        self.assertEqual(resolved.size, "custom")
        self.assertEqual(resolved.cache_key, "legacy")
        self.assertTrue(resolved.zone_id.startswith("z1_custom_"))


if __name__ == "__main__":
    unittest.main()
