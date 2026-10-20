import importlib.util
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "comparar_versiones", ROOT / "Nuvex/scripts/comparar_versiones.py"
)
assert SPEC and SPEC.loader
MODULO = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULO
SPEC.loader.exec_module(MODULO)


class VersionesSemVerTests(unittest.TestCase):
    def test_ordena_prereleases_segun_semver(self):
        analizar = MODULO.Version.analizar
        orden = [
            "1.0.0-alpha",
            "1.0.0-alpha.1",
            "1.0.0-alpha.beta",
            "1.0.0-beta",
            "1.0.0-beta.2",
            "1.0.0-beta.11",
            "1.0.0-rc.1",
            "1.0.0",
        ]
        self.assertEqual(sorted(orden, key=analizar), orden)

    def test_estable_es_mayor_que_beta_de_la_misma_version(self):
        analizar = MODULO.Version.analizar
        self.assertGreater(analizar("3.2.0"), analizar("3.2.0-beta.1"))

    def test_build_metadata_no_cambia_la_precedencia(self):
        analizar = MODULO.Version.analizar
        self.assertEqual(analizar("3.2.0+uno"), analizar("3.2.0+dos"))

    def test_rechaza_ceros_iniciales_y_formatos_incompletos(self):
        analizar = MODULO.Version.analizar
        for version in ("03.2.0", "3.02.0", "3.2", "3.2.0-beta.01"):
            with self.subTest(version=version), self.assertRaises(ValueError):
                analizar(version)


if __name__ == "__main__":
    unittest.main()
