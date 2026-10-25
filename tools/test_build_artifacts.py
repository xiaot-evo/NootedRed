#!/usr/bin/env python3
"""Guard the CI/build-branch artifact globs for both kext zips (review D9).

The main kext archive and the satellite archive live at different depths:

    build/branches/<branch>/<plat>/<arch>/<mode>/NootedRed-*.zip
    build/branches/<branch>/<plat>/<arch>/userpatch/<mode>/NootedRedUserPatch-*.zip

A single-depth glob misses the satellite zip. This test checks that the CI workflow, the per-branch
wrapper and the documentation all carry both patterns, and it exercises the extracted globs against a
synthetic artifact tree. It does not invoke xmake or GitHub Actions.
"""

from __future__ import annotations

import glob
import re
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "main.yml"
BUILD_BRANCH = ROOT / "tools" / "build-branch.sh"
BUILD_ARTIFACTS_DOC = ROOT / "docs" / "Build-Artifacts.md"

MAINLINE_GLOB = "build/branches/*/*/*/*/*.zip"
SATELLITE_GLOB = "build/branches/*/*/*/userpatch/*/*.zip"
MAINLINE_NAMED = "build/branches/*/*/*/*/NootedRed-*.zip"
SATELLITE_NAMED = "build/branches/*/*/*/userpatch/*/NootedRedUserPatch-*.zip"

GLOB_RE = re.compile(r"build/branches/[^\s'\"]*\.zip")

EXPECTED_FILES = {
    "build/branches/br/macosx/x86_64/debug/NootedRed-0.9.0-DEBUG.zip",
    "build/branches/br/macosx/x86_64/release/NootedRed-0.9.0-RELEASE.zip",
    "build/branches/br/macosx/x86_64/userpatch/debug/NootedRedUserPatch-0.9.0-DEBUG.zip",
    "build/branches/br/macosx/x86_64/userpatch/release/NootedRedUserPatch-0.9.0-RELEASE.zip",
}


def globs_in(text: str) -> set[str]:
    return {match.rstrip(".,;)") for match in GLOB_RE.findall(text)}


class BuildArtifactGlobTest(unittest.TestCase):
    def test_workflow_globs_cover_both_kexts(self) -> None:
        globs = globs_in(WORKFLOW.read_text(encoding="utf-8"))
        self.assertIn(MAINLINE_GLOB, globs)
        self.assertIn(SATELLITE_GLOB, globs)

    def test_build_branch_wrapper_globs_cover_both_kexts(self) -> None:
        text = BUILD_BRANCH.read_text(encoding="utf-8")
        normalized = text.replace('"$ROOT"/', "").replace('"$BRANCH"', "*")
        self.assertIn(MAINLINE_NAMED, normalized)
        self.assertIn(SATELLITE_NAMED, normalized)
        self.assertEqual(globs_in(normalized), {MAINLINE_NAMED, SATELLITE_NAMED})

    def test_globs_match_a_synthetic_artifact_tree(self) -> None:
        with tempfile.TemporaryDirectory(prefix="nred-artifacts-") as tmp:
            for relative in EXPECTED_FILES:
                path = Path(tmp) / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"zip")
            previous = Path.cwd()
            try:
                import os
                os.chdir(tmp)
                matched = set(glob.glob(MAINLINE_GLOB)) | set(glob.glob(SATELLITE_GLOB))
            finally:
                os.chdir(previous)
            self.assertEqual(matched, EXPECTED_FILES)

    def test_build_artifacts_doc_mentions_satellite_layout(self) -> None:
        text = BUILD_ARTIFACTS_DOC.read_text(encoding="utf-8")
        self.assertIn("userpatch/<mode>", text)
        self.assertIn("NootedRedUserPatch-0.9.0-RELEASE", text)


if __name__ == "__main__":
    unittest.main(verbosity=1)
