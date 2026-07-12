#!/usr/bin/env python3
import os
import tempfile
import unittest

from citygen import svg_preview


class TestGenerateSvg(unittest.TestCase):
    def test_writes_svg_with_expected_elements(self):
        roads = [{"points": [[0.0, 0.0], [10.0, 0.0]], "width": 6.0}]
        buildings = [{"footprint": [[0.0, 0.0], [5.0, 0.0], [5.0, 5.0], [0.0, 5.0]]}]
        terrain = {"cell_size": 10.0, "nx": 2, "nz": 2, "origin_x": 0.0, "origin_z": 0.0,
                   "heights": [0.0, 1.0, 1.0, 2.0]}
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "preview.svg")
            svg_preview.generate_svg(roads, buildings, terrain, path)
            with open(path, "r", encoding="utf-8") as f:
                content = f.read()
        self.assertIn("<svg", content)
        self.assertIn("<polyline", content)
        self.assertIn("<polygon", content)

    def test_empty_scene_does_not_raise(self):
        terrain = {"cell_size": 10.0, "nx": 2, "nz": 2, "origin_x": 0.0, "origin_z": 0.0,
                   "heights": [0.0, 0.0, 0.0, 0.0]}
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "preview.svg")
            svg_preview.generate_svg([], [], terrain, path)
            self.assertTrue(os.path.isfile(path))


if __name__ == "__main__":
    unittest.main()
