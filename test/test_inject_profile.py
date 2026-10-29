#!/usr/bin/env python3
# Unit tests for test/inject_profile.py (NRPT v3 NRedProfiles bundle injection tool).

import hashlib
import json
import os
import plistlib
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)
import inject_profile as I  # noqa: E402
import nrpt_validator as V  # noqa: E402


def make_profile(build: str, apu_mask: int = 0x28, device_id: int = 0x1638) -> bytes:
    images = [V.Image(V.IMAGE_KIND_STANDALONE, "/System/Library/Extensions/AMDTestGLDriver.bundle/Contents/MacOS/AMDTestGLDriver", 0, 0x4000)]
    pages = [
        V.Page(
            page_file_offset=0x1000,
            page_hash=0x1111222233334444,
            mode=V.MODE_PAGE,
            image_index=0,
            page_vm_offset=0x1000,
            sites=[V.Site(0x100, b"\x11\x22\x33", b"\x11\x22\x44")],
        )
    ]
    return V.encode(V.Profile(header=V.Header(build=build, apu_mask=apu_mask, device_id=device_id),
                              images=images, pages=pages))


class InjectProfileTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmpdir = tempfile.TemporaryDirectory(prefix="nrpt-v3-inject-")
        self.root = self._tmpdir.name
        self.profile0 = os.path.join(self.root, "p24H232.nrpt")
        self.profile1 = os.path.join(self.root, "p25A999.nrpt")
        with open(self.profile0, "wb") as handle:
            handle.write(make_profile("24H232"))
        with open(self.profile1, "wb") as handle:
            handle.write(make_profile("25A999", device_id=0))
        self.plist_path = os.path.join(self.root, "Info.plist")
        self.original = {
            "CFBundleIdentifier": "org.ChefKiss.NootedRedUserPatch",
            "IOKitPersonalities": {
                I.PERSONALITY_KEY: {
                    "IOClass": "NootedRedUserPatch",
                    "NRedOffsetProfile": b"legacy-bytes",
                    "NRedSystemBuild": "24H232",
                }
            },
        }
        with open(self.plist_path, "wb") as handle:
            plistlib.dump(self.original, handle, fmt=plistlib.FMT_XML)

    def tearDown(self) -> None:
        self._tmpdir.cleanup()

    def inject(self) -> str:
        output = os.path.join(self.root, "Injected.plist")
        rc = I.main(
            [
                "--info-plist", self.plist_path,
                "--profile", self.profile0, "--build", "24H232",
                "--profile", self.profile1, "--build", "25A999",
                "--output", output,
                "--quiet",
            ]
        )
        self.assertEqual(rc, 0)
        return output

    def test_inject_check_extract_round_trip(self) -> None:
        output = self.inject()
        with open(output, "rb") as handle:
            plist = plistlib.load(handle)
        personality = plist["IOKitPersonalities"][I.PERSONALITY_KEY]
        self.assertEqual(plist["CFBundleIdentifier"], "org.ChefKiss.NootedRedUserPatch")
        self.assertEqual(personality["IOClass"], "NootedRedUserPatch")
        self.assertNotIn("NRedOffsetProfile", personality)
        self.assertNotIn("NRedSystemBuild", personality)
        entries = personality["NRedProfiles"]
        self.assertEqual(len(entries), 2)
        self.assertEqual(set(entries[0].keys()), {"Build", "APUMask", "DeviceID", "Profile"})
        self.assertEqual(entries[0]["Build"], "24H232")
        self.assertEqual(entries[0]["APUMask"], 0x28)
        self.assertEqual(entries[0]["DeviceID"], 0x1638)
        self.assertEqual(entries[1]["Build"], "25A999")
        self.assertEqual(entries[1]["DeviceID"], 0)
        self.assertEqual(entries[0]["Profile"], make_profile("24H232"))

        self.assertEqual(I.main(["--info-plist", output, "--check", "--quiet"]), 0)
        extracted = os.path.join(self.root, "extracted")
        self.assertEqual(I.main(["--info-plist", output, "--extract", extracted, "--quiet"]), 0)
        with open(os.path.join(extracted, "manifest.json"), encoding="utf-8") as handle:
            manifest = json.load(handle)
        self.assertEqual(manifest["profileCount"], 2)
        self.assertEqual(manifest["entries"][0]["build"], "24H232")
        self.assertEqual(
            manifest["entries"][0]["sha256"], hashlib.sha256(make_profile("24H232")).hexdigest()
        )
        with open(os.path.join(extracted, "00-24H232.nrpt"), "rb") as handle:
            self.assertEqual(handle.read(), make_profile("24H232"))

    def test_injection_is_deterministic(self) -> None:
        first = self.inject()
        with open(first, "rb") as handle:
            first_bytes = handle.read()
        second = self.inject()
        with open(second, "rb") as handle:
            second_bytes = handle.read()
        self.assertEqual(first_bytes, second_bytes)

    def test_check_rejects_legacy_single_profile(self) -> None:
        self.assertEqual(I.main(["--info-plist", self.plist_path, "--check", "--quiet"]), 1)

    def test_inject_rejects_metadata_mismatch(self) -> None:
        with self.assertRaises(SystemExit):
            I.main(
                [
                    "--info-plist", self.plist_path,
                    "--profile", self.profile0, "--build", "26C000",
                    "--output", os.path.join(self.root, "bad.plist"),
                ]
            )

    def test_inject_rejects_missing_profile(self) -> None:
        with self.assertRaises(SystemExit):
            I.main(
                [
                    "--info-plist", self.plist_path,
                    "--profile", os.path.join(self.root, "missing.nrpt"), "--build", "24H232",
                    "--output", os.path.join(self.root, "bad.plist"),
                ]
            )

    def test_manifest_mode(self) -> None:
        manifest_path = os.path.join(self.root, "entries.json")
        with open(manifest_path, "w", encoding="utf-8") as handle:
            json.dump(
                {
                    "schema": 1,
                    "entries": [{"profile": self.profile0}],
                },
                handle,
            )
        output = os.path.join(self.root, "Manifest.plist")
        rc = I.main(["--info-plist", self.plist_path, "--manifest", manifest_path,
                     "--output", output, "--quiet"])
        self.assertEqual(rc, 0)
        with open(output, "rb") as handle:
            plist = plistlib.load(handle)
        self.assertEqual(plist["IOKitPersonalities"][I.PERSONALITY_KEY]["NRedProfiles"][0]["Build"], "24H232")

    def test_check_rejects_unknown_keys(self) -> None:
        output = self.inject()
        with open(output, "rb") as handle:
            plist = plistlib.load(handle)
        entries = plist["IOKitPersonalities"][I.PERSONALITY_KEY]["NRedProfiles"]
        entries[0]["Unexpected"] = 1
        with open(output, "wb") as handle:
            plistlib.dump(plist, handle)
        self.assertEqual(I.main(["--info-plist", output, "--check", "--quiet"]), 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
