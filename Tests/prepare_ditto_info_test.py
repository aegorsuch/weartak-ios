import importlib.util
import os
import plistlib
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

sys.dont_write_bytecode = True
script = Path(__file__).resolve().parents[1] / "scripts" / "prepare-ditto-info.py"
spec = importlib.util.spec_from_file_location("prepare_ditto_info", script)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class CommunityIdentityChecks(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.template = Path(self.directory.name) / "template.plist"
        self.output = Path(self.directory.name) / "prepared.plist"
        self.original = {"DITTO_COMMUNITY_PDL": "$(DITTO_COMMUNITY_PDL)", "Unrelated": ["preserved"]}
        self.template.write_bytes(plistlib.dumps(self.original))

    def test_missing_identity_is_empty_and_preserves_template(self):
        length, _ = module.prepare(self.template, self.output, "")
        self.assertEqual(length, 0)
        prepared = plistlib.loads(self.output.read_bytes())
        self.assertEqual(prepared["DITTO_COMMUNITY_PDL"], "")
        self.assertEqual(prepared["Unrelated"], ["preserved"])
        self.assertEqual(plistlib.loads(self.template.read_bytes()), self.original)

    def test_ci_identity_is_written_without_printing_value(self):
        value = "fake-test-only-encoded_PDL123=="
        result = subprocess.run([sys.executable, str(script), "--template", str(self.template),
                                 "--output", str(self.output)],
                                env={**os.environ, "DITTO_COMMUNITY_PDL": value},
                                text=True, capture_output=True, check=True)
        self.assertNotIn(value, result.stdout + result.stderr)
        self.assertIn(f"length={len(value)}", result.stdout)
        self.assertIn("SHA256=", result.stdout)
        self.assertEqual(plistlib.loads(self.output.read_bytes())["DITTO_COMMUNITY_PDL"], value)

    def test_invalid_identity_is_rejected_without_its_value(self):
        value = "not a PDL: sensitive-test-only"
        result = subprocess.run([sys.executable, str(script), "--template", str(self.template),
                                 "--output", str(self.output)],
                                env={**os.environ, "DITTO_COMMUNITY_PDL": value},
                                text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(value, result.stdout + result.stderr)
        self.assertFalse(self.output.exists())

    def test_export_verifies_only_iphone_identity_and_rejects_mismatch(self):
        value = "fake-test-only-encoded_PDL123=="
        expected = module.prepare(self.template, self.output, value)
        ipa = Path(self.directory.name) / "test.ipa"
        with zipfile.ZipFile(ipa, "w") as archive:
            archive.writestr("Payload/WearTAK.app/Info.plist",
                             plistlib.dumps({"DITTO_COMMUNITY_PDL": value}))
            archive.writestr("Payload/WearTAK.app/Watch/Watch.app/Info.plist", plistlib.dumps({}))
        self.assertEqual(module.verify(self.output, ipa), expected)
        with zipfile.ZipFile(ipa, "w") as archive:
            archive.writestr("Payload/WearTAK.app/Info.plist",
                             plistlib.dumps({"DITTO_COMMUNITY_PDL": ""}))
        with self.assertRaises(ValueError):
            module.verify(self.output, ipa)


if __name__ == "__main__":
    unittest.main()
