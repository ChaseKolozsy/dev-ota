import base64
import io
import tempfile
import unittest
from pathlib import Path

from PIL import Image, ImageDraw

from image_templates import create_from_path, create_tap_template


class ImageTemplateTests(unittest.TestCase):
    def test_crops_click_region_and_preserves_normalized_click(self):
        screenshot = Image.new("RGB", (1080, 2400), "white")
        draw = ImageDraw.Draw(screenshot)
        draw.rounded_rectangle((340, 1000, 740, 1160), radius=24, fill="navy")
        draw.text((450, 1060), "INSTALL", fill="white")

        metadata, png = create_tap_template(
            screenshot,
            click_x=540,
            click_y=1080,
            bounds=(340, 1000, 740, 1160),
            padding=24,
        )

        self.assertEqual(metadata["format"], "devota-image-template")
        self.assertEqual(metadata["version"], 1)
        self.assertAlmostEqual(metadata["expectedCenterX"], 0.5, places=2)
        self.assertAlmostEqual(metadata["clickOffsetX"], 0.5, places=2)
        self.assertLessEqual(len(png), 384 * 1024)
        decoded = Image.open(io.BytesIO(base64.b64decode(metadata["pngBase64"])))
        self.assertEqual(decoded.size, (448, 208))

    def test_cli_helper_writes_private_template(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "screen.png"
            output = root / "tap.png"
            Image.new("RGB", (400, 800), "green").save(source)

            metadata = create_from_path(
                source,
                output_path=output,
                click_x=200,
                click_y=400,
                bounds=None,
                padding=24,
            )

            self.assertTrue(output.is_file())
            self.assertEqual(output.stat().st_mode & 0o777, 0o600)
            self.assertEqual(metadata["sourceWidth"], 400)
            self.assertEqual(metadata["sourceHeight"], 800)


if __name__ == "__main__":
    unittest.main()
