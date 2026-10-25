#!/usr/bin/env python3
"""Pinned copy of the master-branch UserPatch table sources.

The satellite branch removes the user-space patching code (and its exact-page tables) from
``NootedRed/``. The host tools still need those exact bytes to derive the checked-in fixtures, the
deployable ``PatchData/`` sets and the conversion specs, so a byte-for-byte snapshot of the relevant
master files is kept under ``tools/pinned/master/`` with a SHA-256 manifest.

This module is the single place that resolves "where do the master table sources come from?":

* default: the pinned snapshot (works at HEAD, in a zip export and without git);
* ``--source-root DIR``: an explicit checkout/extract of master's tree;
* ``--source-git REV``: extract the needed files from git (``git show REV:<path>``) into a temp tree.

Usage::

    python3 tools/master_source.py --verify           # verify the pin manifest and file hashes
    python3 tools/master_source.py --refresh [--rev master]
    python3 tools/master_source.py --print-root

The pin manifest records the master commit and per-file hashes. Refresh it only after re-verifying
that the new master tables are what the checked-in data should be derived from; converter/test
``--check`` runs will then require regenerating docs/specs/PatchData deterministically.
"""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import json
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Iterator

ROOT = Path(__file__).resolve().parents[1]
PINNED_ROOT = Path(__file__).resolve().parent / "pinned" / "master"
PINNED_MANIFEST = PINNED_ROOT / "manifest.json"

# Relative to the source tree root (both live checkout and pinned snapshot use NootedRed/<file>).
REQUIRED_FILES = (
    "NootedRed/UserPatches.cpp",
    "NootedRed/UserPatches.hpp",
    "NootedRed/UserPatchesSonoma.inc",
    "NootedRed/TahoePatchData.hpp",
    "NootedRed/VDAVAData.hpp",
    "NootedRed/VDAVADataSonoma.hpp",
    "NootedRed/VDAVADataTahoe.hpp",
    "NootedRed/VDAGVAData.hpp",
    "NootedRed/VDAGVADataSonoma.hpp",
    "NootedRed/VDAGVADataTahoe.hpp",
    "NootedRed/NRed.cpp",
)


class MasterSourceError(Exception):
    """The master source tree is missing, incomplete or does not match its pinned hashes."""


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_pin(path: Path = PINNED_MANIFEST) -> dict[str, Any]:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except OSError as error:
        raise MasterSourceError(f"cannot read pinned source manifest {path}: {error}") from error
    except json.JSONDecodeError as error:
        raise MasterSourceError(f"invalid pinned source manifest {path}: {error}") from error


def verify_pin(root: Path = PINNED_ROOT) -> list[str]:
    """Return a list of problems; empty means the pinned snapshot is intact."""

    problems: list[str] = []
    manifest_path = root / "manifest.json"
    if not manifest_path.is_file():
        return [f"missing pin manifest {manifest_path}"]
    try:
        manifest = load_pin(manifest_path)
    except MasterSourceError as error:
        return [str(error)]

    if manifest.get("schema") != 1:
        problems.append(f"{manifest_path}: unsupported pin schema {manifest.get('schema')!r}")
    if not manifest.get("sourceCommit"):
        problems.append(f"{manifest_path}: missing sourceCommit")

    listed: dict[str, dict[str, Any]] = {}
    for entry in manifest.get("files", []):
        if not isinstance(entry, dict) or "path" not in entry:
            problems.append(f"{manifest_path}: malformed file entry {entry!r}")
            continue
        listed[entry["path"]] = entry
    missing = [name for name in REQUIRED_FILES if name not in listed]
    if missing:
        problems.append(f"pin manifest does not list required file(s): {', '.join(missing)}")

    for name, entry in sorted(listed.items()):
        path = root / name
        if not path.is_file():
            problems.append(f"missing pinned file {path}")
            continue
        data = path.read_bytes()
        if entry.get("size") != len(data):
            problems.append(f"{path}: size {len(data)}, pinned {entry.get('size')}")
        digest = hashlib.sha256(data).hexdigest()
        if entry.get("sha256") != digest:
            problems.append(f"{path}: sha256 {digest}, pinned {entry.get('sha256')}")

    for path in sorted(root.rglob("*")):
        if path.is_file() and path.name != "manifest.json" and path.name != "README.md":
            relative = str(path.relative_to(root))
            if relative not in listed:
                problems.append(f"unpinned extra file {path}")
    return problems


def resolve_root(source_root: Path | str | None = None) -> Path:
    """Return a directory containing ``NootedRed/<files>``; defaults to the pinned snapshot."""

    if source_root is None:
        problems = verify_pin()
        if problems:
            raise MasterSourceError("pinned master source is invalid: " + "; ".join(problems))
        return PINNED_ROOT
    root = Path(source_root)
    missing = [name for name in REQUIRED_FILES if not (root / name).is_file()]
    if missing:
        raise MasterSourceError(f"{root}: missing required master source file(s): {', '.join(missing)}")
    return root


@contextlib.contextmanager
def source_root_from_git(rev: str = "master") -> Iterator[Path]:
    """Extract the required files from ``git show <rev>:<path>`` into a temporary source tree."""

    with tempfile.TemporaryDirectory(prefix="nootedred-master-src-") as tmp:
        root = Path(tmp)
        for name in REQUIRED_FILES:
            try:
                data = subprocess.check_output(["git", "-C", str(ROOT), "show", f"{rev}:{name}"],
                                               stderr=subprocess.PIPE)
            except subprocess.CalledProcessError as error:
                message = error.stderr.decode("utf-8", "replace").strip()
                raise MasterSourceError(f"git show {rev}:{name} failed: {message}") from error
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        yield root


def refresh(rev: str = "master") -> dict[str, Any]:
    """Rewrite the pinned snapshot from ``rev`` and regenerate its manifest."""

    files = []
    for name in REQUIRED_FILES:
        try:
            data = subprocess.check_output(["git", "-C", str(ROOT), "show", f"{rev}:{name}"],
                                           stderr=subprocess.PIPE)
        except subprocess.CalledProcessError as error:
            message = error.stderr.decode("utf-8", "replace").strip()
            raise MasterSourceError(f"git show {rev}:{name} failed: {message}") from error
        path = PINNED_ROOT / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        files.append({"path": name, "size": len(data), "sha256": hashlib.sha256(data).hexdigest()})

    try:
        commit = subprocess.check_output(["git", "-C", str(ROOT), "rev-parse", rev], text=True).strip()
        subject = subprocess.check_output(["git", "-C", str(ROOT), "show", "-s", "--format=%s", rev],
                                           text=True).strip()
    except subprocess.CalledProcessError as error:
        raise MasterSourceError(f"cannot resolve git revision {rev}: {error}") from error

    manifest = {
        "schema": 1,
        "description": ("Pinned copy of the master-branch UserPatch table sources. These exact bytes are "
                        "the provenance for the checked-in fixtures, specs and PatchData; do not edit "
                        "them by hand."),
        "sourceRepositoryTree": rev,
        "sourceCommit": commit,
        "sourceCommitSubject": subject,
        "extraction": "git show <rev>:<path> > tools/pinned/master/<path>",
        "refreshCommand": "python3 tools/master_source.py --refresh",
        "files": files,
    }
    PINNED_ROOT.mkdir(parents=True, exist_ok=True)
    PINNED_MANIFEST.write_text(json.dumps(manifest, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")
    return manifest


def pin_commit() -> str:
    return str(load_pin().get("sourceCommit", ""))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Verify or refresh the pinned master table sources.")
    parser.add_argument("--verify", action="store_true", help="verify pinned file hashes (default)")
    parser.add_argument("--refresh", action="store_true", help="rewrite the pin from git")
    parser.add_argument("--rev", default="master", help="git revision to pin/refresh (default: master)")
    parser.add_argument("--print-root", action="store_true", help="print the resolved source root")
    args = parser.parse_args(argv)

    try:
        if args.refresh:
            manifest = refresh(args.rev)
            print(f"pinned {len(manifest['files'])} file(s) from {args.rev} ({manifest['sourceCommit']})")
            return 0
        problems = verify_pin()
        if problems:
            for problem in problems:
                print(f"error: {problem}", file=sys.stderr)
            return 1
        manifest = load_pin()
        print(f"ok: pinned master sources verified ({len(manifest['files'])} file(s), "
              f"commit {manifest['sourceCommit']})")
        if args.print_root:
            print(resolve_root())
        return 0
    except MasterSourceError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
