import importlib.util
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "ajustar_appcast", ROOT / "Nuvex/scripts/ajustar_appcast.py"
)
assert SPEC and SPEC.loader
MODULO = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULO)


class AjustarAppcastTests(unittest.TestCase):
    def test_corrige_solo_los_zip_historicos_y_preserva_el_documento(self):
        with tempfile.TemporaryDirectory() as temporal:
            ruta = Path(temporal) / "appcast.xml"
            original = '''<?xml version="1.0"?>
<!-- comentario que no debe perderse -->
<rss><channel>
<description><![CDATA[<p>Notas históricas</p>]]></description>
<enclosure url="https://github.com/Simylar/Nuvex/releases/download/v3.2.0/Nuvex-3.2.0.zip" />
<enclosure url="https://github.com/Simylar/Nuvex/releases/download/v3.2.0/Nuvex-3.1.2.zip" />
<enclosure url="https://github.com/Simylar/Nuvex/releases/download/v3.2.0/Nuvex131-130.delta" />
</channel></rss>
'''
            ruta.write_text(original, encoding="utf-8")

            self.assertEqual(MODULO.ajustar(ruta, "Simylar/Nuvex", "3.2.0"), 1)
            resultado = ruta.read_text(encoding="utf-8")

            self.assertIn("<!-- comentario que no debe perderse -->", resultado)
            self.assertIn("<![CDATA[<p>Notas históricas</p>]]>", resultado)
            self.assertIn("/v3.2.0/Nuvex-3.2.0.zip", resultado)
            self.assertIn("/v3.1.2/Nuvex-3.1.2.zip", resultado)
            self.assertIn("/v3.2.0/Nuvex131-130.delta", resultado)

    def test_rechaza_repositorio_o_version_invalidos(self):
        with tempfile.TemporaryDirectory() as temporal:
            ruta = Path(temporal) / "appcast.xml"
            ruta.write_text("<rss />", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "repositorio"):
                MODULO.ajustar(ruta, "repositorio", "3.2.0")
            with self.assertRaisesRegex(ValueError, "SemVer"):
                MODULO.ajustar(ruta, "Simylar/Nuvex", "3.2")


if __name__ == "__main__":
    unittest.main()
