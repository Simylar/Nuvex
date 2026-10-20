import base64
import importlib.util
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "verificar_appcast", ROOT / "Nuvex/scripts/verificar_appcast.py"
)
assert SPEC and SPEC.loader
MODULO = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULO)


class AppcastTests(unittest.TestCase):
    def setUp(self):
        self.temporal = tempfile.TemporaryDirectory()
        self.ruta = Path(self.temporal.name) / "appcast.xml"

    def tearDown(self):
        self.temporal.cleanup()

    def escribir(
        self,
        *,
        url="https://example.invalid/Nuvex-3.2.0.zip",
        firma=None,
        canal="",
        tamano=123,
        extra="",
        deltas="",
    ):
        if firma is None:
            firma = base64.b64encode(bytes(64)).decode("ascii")
        canal_xml = f"<sparkle:channel>{canal}</sparkle:channel>" if canal else ""
        self.ruta.write_text(
            f'''<?xml version="1.0"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
<sparkle:version>131</sparkle:version>
<sparkle:shortVersionString>3.2.0</sparkle:shortVersionString>
{canal_xml}
<enclosure url="{url}" length="{tamano}" sparkle:edSignature="{firma}" />
{deltas}
</item>{extra}</channel></rss>''',
            encoding="utf-8",
        )

    def test_acepta_version_estable_firmada(self):
        self.escribir()
        MODULO.verificar(self.ruta, "3.2.0", "131")

    def test_exige_canal_esperado(self):
        self.escribir(canal="beta")
        with self.assertRaisesRegex(ValueError, "canal incorrecto"):
            MODULO.verificar(self.ruta, "3.2.0", "131")
        MODULO.verificar(self.ruta, "3.2.0", "131", "beta")

    def test_rechaza_descarga_insegura_o_sin_firma(self):
        self.escribir(url="http://example.invalid/Nuvex-3.2.0.zip")
        with self.assertRaisesRegex(ValueError, "HTTPS"):
            MODULO.verificar(self.ruta, "3.2.0", "131")
        self.escribir(firma="")
        with self.assertRaisesRegex(ValueError, "firma EdDSA"):
            MODULO.verificar(self.ruta, "3.2.0", "131")

    def test_exige_url_tamano_y_formato_de_firma_exactos(self):
        paquete = Path(self.temporal.name) / "Nuvex-3.2.0.zip"
        paquete.write_bytes(b"paquete")
        self.escribir(tamano=paquete.stat().st_size)
        url = "https://example.invalid/Nuvex-3.2.0.zip"
        MODULO.verificar(self.ruta, "3.2.0", "131", direccion_esperada=url, archivo=paquete)
        with self.assertRaisesRegex(ValueError, "archivo esperado"):
            MODULO.verificar(self.ruta, "3.2.0", "131", direccion_esperada=url + ".otro")
        self.escribir(tamano=paquete.stat().st_size + 1)
        with self.assertRaisesRegex(ValueError, "tamaño declarado"):
            MODULO.verificar(self.ruta, "3.2.0", "131", archivo=paquete)
        self.escribir(firma=base64.b64encode(b"corta").decode("ascii"))
        with self.assertRaisesRegex(ValueError, "longitud Ed25519"):
            MODULO.verificar(self.ruta, "3.2.0", "131")

    def test_rechaza_colisiones_de_version_o_compilacion(self):
        duplicado_build = """
<item><sparkle:version>131</sparkle:version>
<sparkle:shortVersionString>3.1.9</sparkle:shortVersionString></item>
"""
        self.escribir(extra=duplicado_build)
        with self.assertRaisesRegex(ValueError, "compilación 131"):
            MODULO.verificar(self.ruta, "3.2.0", "131")

        duplicado_version = """
<item><sparkle:version>130</sparkle:version>
<sparkle:shortVersionString>3.2.0</sparkle:shortVersionString></item>
"""
        self.escribir(extra=duplicado_version)
        with self.assertRaisesRegex(ValueError, "versión 3.2.0"):
            MODULO.verificar(self.ruta, "3.2.0", "131")

    def test_valida_firma_url_y_archivo_de_cada_delta(self):
        firma = base64.b64encode(bytes(64)).decode("ascii")
        delta = Path(self.temporal.name) / "Nuvex131-130.delta"
        delta.write_bytes(b"delta firmado")
        deltas = f"""
<sparkle:deltas><enclosure
  url="https://example.invalid/Nuvex131-130.delta"
  length="{delta.stat().st_size}"
  sparkle:edSignature="{firma}"
  sparkle:deltaFrom="130" />
</sparkle:deltas>
"""
        self.escribir(deltas=deltas)
        MODULO.verificar(
            self.ruta,
            "3.2.0",
            "131",
            directorio_archivos=Path(self.temporal.name),
        )

        self.escribir(deltas=deltas.replace('sparkle:edSignature="' + firma + '"', 'sparkle:edSignature=""'))
        with self.assertRaisesRegex(ValueError, "delta.*firma EdDSA"):
            MODULO.verificar(self.ruta, "3.2.0", "131")

        self.escribir(deltas=deltas.replace("https://", "http://"))
        with self.assertRaisesRegex(ValueError, "delta.*HTTPS"):
            MODULO.verificar(self.ruta, "3.2.0", "131")

    def test_rechaza_delta_ajeno_o_no_referenciado(self):
        firma = base64.b64encode(bytes(64)).decode("ascii")
        delta = Path(self.temporal.name) / "Nuvex131-130.delta"
        delta.write_bytes(b"delta")
        deltas = f"""
<sparkle:deltas><enclosure
  url="https://otro.invalid/Nuvex131-130.delta"
  length="{delta.stat().st_size}"
  sparkle:edSignature="{firma}"
  sparkle:deltaFrom="130" />
</sparkle:deltas>
"""
        self.escribir(deltas=deltas)
        with self.assertRaisesRegex(ValueError, "publicación actual"):
            MODULO.verificar(
                self.ruta,
                "3.2.0",
                "131",
                directorio_archivos=Path(self.temporal.name),
            )

        self.escribir()
        with self.assertRaisesRegex(ValueError, "no referencia"):
            MODULO.verificar(
                self.ruta,
                "3.2.0",
                "131",
                directorio_archivos=Path(self.temporal.name),
            )

    def test_rechaza_delta_cuyo_nombre_no_corresponde_a_la_compilacion(self):
        firma = base64.b64encode(bytes(64)).decode("ascii")
        delta = Path(self.temporal.name) / "Nuvex999-130.delta"
        delta.write_bytes(b"delta")
        deltas = f"""
<sparkle:deltas><enclosure
  url="https://example.invalid/{delta.name}"
  length="{delta.stat().st_size}"
  sparkle:edSignature="{firma}"
  sparkle:deltaFrom="130" />
</sparkle:deltas>
"""
        self.escribir(deltas=deltas)
        with self.assertRaisesRegex(ValueError, "compilación nueva"):
            MODULO.verificar(
                self.ruta,
                "3.2.0",
                "131",
                directorio_archivos=Path(self.temporal.name),
            )

    def test_zip_local_debe_estar_referenciado_y_conservar_notas(self):
        paquete = Path(self.temporal.name) / "Nuvex-3.2.0.zip"
        paquete.write_bytes(b"paquete")
        self.escribir(tamano=paquete.stat().st_size)
        with self.assertRaisesRegex(ValueError, "notas de versión"):
            MODULO.verificar(
                self.ruta,
                "3.2.0",
                "131",
                directorio_archivos=Path(self.temporal.name),
            )

        contenido = self.ruta.read_text(encoding="utf-8")
        self.ruta.write_text(
            contenido.replace("<enclosure", "<description>Notas</description><enclosure", 1),
            encoding="utf-8",
        )
        MODULO.verificar(
            self.ruta,
            "3.2.0",
            "131",
            directorio_archivos=Path(self.temporal.name),
        )

    def test_cada_zip_local_debe_conservar_version_y_canal(self):
        firma = base64.b64encode(bytes(64)).decode("ascii")
        beta = Path(self.temporal.name) / "Nuvex-3.2.0-beta.1.zip"
        beta.write_bytes(b"beta")
        entrada_beta = f"""
<item>
<sparkle:version>130</sparkle:version>
<sparkle:shortVersionString>3.2.0-beta.1</sparkle:shortVersionString>
<description>Notas beta</description>
<enclosure url="https://example.invalid/{beta.name}" length="{beta.stat().st_size}"
 sparkle:edSignature="{firma}" />
</item>
"""
        self.escribir(extra=entrada_beta)
        with self.assertRaisesRegex(ValueError, "canal estable.*esperaba beta"):
            MODULO.verificar(
                self.ruta,
                "3.2.0",
                "131",
                directorio_archivos=Path(self.temporal.name),
            )

        self.escribir(
            extra=entrada_beta.replace(
                "<description>", "<sparkle:channel>beta</sparkle:channel><description>", 1
            )
        )
        MODULO.verificar(
            self.ruta,
            "3.2.0",
            "131",
            directorio_archivos=Path(self.temporal.name),
        )

        beta.rename(Path(self.temporal.name) / "Nuvex-3.2.0-beta.2.zip")
        with self.assertRaisesRegex(ValueError, "debe aparecer exactamente una vez"):
            MODULO.verificar(
                self.ruta,
                "3.2.0",
                "131",
                directorio_archivos=Path(self.temporal.name),
            )


if __name__ == "__main__":
    unittest.main()
