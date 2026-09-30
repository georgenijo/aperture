import json
from pathlib import Path
import sys
import tempfile
import unittest

import numpy as np
from PIL import Image, ImageCms

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from measure import load
from retarget import main


class MeasurementTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)

    def test_untagged_srgb_values_are_preserved(self):
        path = self.root / 'source.png'
        Image.new('RGB', (20, 20), (180, 120, 90)).save(path)
        np.testing.assert_array_equal(load(path)[0, 0], [180, 120, 90])

    def test_display_p3_is_converted_before_measurement(self):
        profile_path = Path('/System/Library/ColorSync/Profiles/Display P3.icc')
        if not profile_path.exists():
            self.skipTest('requires the macOS Display P3 profile')
        profile = ImageCms.getOpenProfile(str(profile_path))
        image = Image.new('RGB', (20, 20), (180, 120, 90))
        path = self.root / 'p3.png'
        image.save(path, icc_profile=profile.tobytes())
        expected = ImageCms.profileToProfile(
            image, profile, ImageCms.createProfile('sRGB'), outputMode='RGB')
        measured = load(path)[0, 0]
        np.testing.assert_array_equal(measured, expected.getpixel((0, 0)))
        self.assertFalse(np.array_equal(measured, image.getpixel((0, 0))))

    def test_invalid_profile_is_rejected(self):
        path = self.root / 'invalid.png'
        Image.new('RGB', (20, 20)).save(path, icc_profile=b'not an ICC profile')
        with self.assertRaisesRegex(ValueError, 'cannot convert embedded colour profile'):
            load(path)

    def test_grayscale_sources_report_validation_error(self):
        Image.new('RGB', (100, 100), (128, 128, 128)).save(self.root / 'grey.png')
        self.assert_fit_rejected(0.3, 'source photos have no measurable saturation')

    def test_grayscale_targets_report_validation_error(self):
        Image.new('RGB', (100, 100), (90, 140, 210)).save(self.root / 'colour.png')
        self.assert_fit_rejected(0, 'target photos have no measurable saturation')

    def assert_fit_rejected(self, saturation, message):
        targets = self.root / 'targets.json'
        targets.write_text(json.dumps({
            'neutralBands': [], 'saturation': saturation, 'blueHueDegrees': 270,
        }))
        base = Path(__file__).resolve().parents[3] / 'ApertureTests/Fixtures/film-response-probes.json'
        output = self.root / 'fit.json'
        with self.assertRaisesRegex(SystemExit, message):
            main(str(targets), str(base), str(self.root), str(output))
        self.assertFalse(output.exists())


if __name__ == '__main__':
    unittest.main()
