#!/usr/bin/env python3
import os
import tempfile
import unittest
from unittest.mock import patch

import seed_catalog
import store


class TestParseSeedFile(unittest.TestCase):
    def test_parses_valid_lines(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "seed.txt")
            with open(path, "w", encoding="utf-8") as f:
                f.write("Girardot;4.3057;-74.8087;S\nCartagena;10.3910;-75.4794;M\n")
            entries = seed_catalog.parse_seed_file(path)
        self.assertEqual(entries, [
            {"name": "Girardot", "lat": 4.3057, "lon": -74.8087, "size": "S"},
            {"name": "Cartagena", "lat": 10.3910, "lon": -75.4794, "size": "M"},
        ])

    def test_skips_blank_lines_and_comments(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "seed.txt")
            with open(path, "w", encoding="utf-8") as f:
                f.write("# comentario\n\nGirardot;4.3057;-74.8087;S\n   \n")
            entries = seed_catalog.parse_seed_file(path)
        self.assertEqual(len(entries), 1)

    def test_malformed_line_raises_with_line_number(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "seed.txt")
            with open(path, "w", encoding="utf-8") as f:
                f.write("Girardot;4.3057;-74.8087;S\nMalformada;solo_dos_campos\n")
            with self.assertRaises(ValueError) as ctx:
                seed_catalog.parse_seed_file(path)
        self.assertIn(":2:", str(ctx.exception))


class TestSeedResilientToNetworkFailure(unittest.TestCase):
    """Regresion: un 504/timeout de Overpass en UNA ciudad (visto en vivo con Annecy)
    no debe tumbar el resto del lote -- antes generate() se llamaba sin try/except y
    la excepcion se propagaba fuera de seed(), dejando las ciudades restantes sin intentar."""

    def test_exception_on_one_city_does_not_abort_the_batch(self):
        with tempfile.TemporaryDirectory() as tmp:
            seed_file = os.path.join(tmp, "seed.txt")
            with open(seed_file, "w", encoding="utf-8") as f:
                f.write("Ciudad A;1.0;1.0;S\nCiudad B;2.0;2.0;S\n")

            original_storage = (seed_catalog.STORAGE_DIR, seed_catalog.DB_PATH,
                                 seed_catalog.CACHE_DIR, seed_catalog.ZONES_DIR)
            seed_catalog.STORAGE_DIR = tmp
            seed_catalog.DB_PATH = os.path.join(tmp, "app.db")
            seed_catalog.CACHE_DIR = os.path.join(tmp, "cache")
            seed_catalog.ZONES_DIR = os.path.join(tmp, "zones")
            try:
                with patch("seed_catalog.generate", side_effect=RuntimeError("Overpass 504")):
                    result = seed_catalog.seed(seed_file)
            finally:
                (seed_catalog.STORAGE_DIR, seed_catalog.DB_PATH,
                 seed_catalog.CACHE_DIR, seed_catalog.ZONES_DIR) = original_storage

        self.assertEqual(result["sown"], 0)
        self.assertEqual(len(result["failed"]), 2)
        self.assertEqual(result["failed"][0][1], "osm_unavailable")
        self.assertEqual(result["failed"][1][1], "osm_unavailable")


if __name__ == "__main__":
    unittest.main()
