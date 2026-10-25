#!/usr/bin/env python3
"""Derive deployment specs and ``PatchData/`` from the pinned master exact-page tables.

``master`` carries the user-space tables that the satellite replaced. This tool decodes them from the
pinned snapshot (``tools/pinned/master``), writes readable specs with exact 4 KiB page images under
``tools/specs/<build>/`` and generates the deployable ``PatchData/<build>/`` directory with
``tools/userpatch_data.py``.

Coverage is deliberately conservative; gaps are reported instead of invented:

* ``24H32`` (15.8.1, Darwin 24.6.0): kinds 1 GL, 2 Metal, 3 VDA/VA, 4 VDA/AppleGVA.
* ``25G241`` (26.7.1, Darwin 25.6.0): kinds 1, 2, 3, 4.
* ``23J631`` (14.8.9, Darwin 23.6.0): kinds 3 and 4 only. Master's Sonoma GL/Metal pages are a
  14.x-range table and are not pinned to an exact ``kern.osversion``, so they are listed as a gap
  rather than deployed under a guessed build.

Every page is master's stock byte array and every site is resolved from the table's verified
``find``/``replace``/``skip``/``count`` fields; the output is deterministic. Adding a build means
adding a source definition below plus a pinned source file, then regenerating.

Usage::

    python3 tools/convert_master_patchdata.py               # write tools/specs + PatchData
    python3 tools/convert_master_patchdata.py --check       # verify committed output is current
    python3 tools/convert_master_patchdata.py --report      # inventory and gaps only
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import master_source
import master_tables as tables
import userpatch_data as generator

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SPECS_DIR = Path(__file__).resolve().parent / "specs"
DEFAULT_PATCHDATA_DIR = ROOT / "PatchData"

KIND_NAMES = {1: "gl", 2: "metal", 3: "vda-va", 4: "vda-gva"}

# Page provenance for the GL/Metal arrays. Offsets are the file offsets recorded in master's comments
# ("file page at 0xE000", "File offset 0x8000"); the Metal control page is a shared-cache page without
# a recorded file offset.
GL_PAGE_NOTES: dict[str, tuple[str, int | None]] = {
    "kGLDriverHwInfoPage": ("exact 4 KiB AMDRadeonX5000GLDriver page at file offset 0xE000 "
                            "(master array kGLDriverHwInfoPage)", 0xE000),
    "kGLDriverDualQuadPage": ("exact 4 KiB AMDRadeonX5000GLDriver page at file offset 0x8000 "
                              "(master array kGLDriverDualQuadPage)", 0x8000),
    "kMTLControlPage": ("exact 4 KiB AMDRadeonX5000MTLDriver shared-cache page containing the "
                        "pipeline CB_COLOR_CONTROL computation (master array kMTLControlPage)", None),
    "kTahoeGLHwInfoPage": ("exact 4 KiB AMDRadeonX5000GLDriver page at file offset 0xE000 "
                           "(master array kTahoeGLHwInfoPage)", 0xE000),
    "kTahoeGLDualQuadPage": ("exact 4 KiB AMDRadeonX5000GLDriver page at file offset 0x8000 "
                             "(master array kTahoeGLDualQuadPage)", 0x8000),
    "kTahoeMTLControlPage": ("exact 4 KiB AMDRadeonX5000MTLDriver shared-cache page containing the "
                             "pipeline CB_COLOR_CONTROL computation (master array "
                             "kTahoeMTLControlPage)", None),
}


@dataclass(frozen=True)
class GlSource:
    """GL/Metal tables live in master's UserPatches.cpp (plus a page-data header)."""

    table: str
    files: tuple[str, ...]
    driver: str


@dataclass(frozen=True)
class HeaderSource:
    """VDA/AppleGVA tables are self-contained headers with a ``Patches[]`` array."""

    file: str
    table: str = "Patches"


@dataclass(frozen=True)
class BuildSpec:
    build: str
    darwin: tuple[int, int, int]
    apu_mask: int
    note: str
    gl: GlSource | None
    vda: HeaderSource
    gva: HeaderSource
    gaps: tuple[str, ...] = field(default_factory=tuple)


BUILDS: tuple[BuildSpec, ...] = (
    BuildSpec(
        build="24H32",
        darwin=(24, 6, 0),
        apu_mask=0x3F,
        note=("Deployable macOS 15.8.1 set: GL/Metal exact pages plus the validated VDA/VA and "
              "VDA/AppleGVA tables. VDA kinds still require NRedVCNBridgeReady at runtime."),
        gl=GlSource("kGLDriverPatches", ("NootedRed/UserPatches.cpp",),
                    "AMDRadeonX5000GLDriver 7.0.25 / macOS 15.8.1 (24H32)"),
        vda=HeaderSource("NootedRed/VDAVAData.hpp"),
        gva=HeaderSource("NootedRed/VDAGVAData.hpp"),
    ),
    BuildSpec(
        build="23J631",
        darwin=(23, 6, 0),
        apu_mask=0x38,  # Renoir / RenoirE / GreenSardine: the VCN 2.2 families these VDA tables target
        note=("VDA-only macOS 14.8.9 set: master's VDA/VA and VDA/AppleGVA headers are pinned to "
              "23J631. GL/Metal are not deployed: master's Sonoma pages are a 14.x-range table, not an "
              "exact 23J631 build."),
        gl=None,
        vda=HeaderSource("NootedRed/VDAVADataSonoma.hpp"),
        gva=HeaderSource("NootedRed/VDAGVADataSonoma.hpp"),
        gaps=("GL/Metal: master has exact Sonoma pages for the Darwin 23.6 range (kGLDriverPatches_Sonoma) "
              "but does not pin them to an exact kern.osversion, so no 14.x PatchData directory is "
              "generated for kinds 1/2.",),
    ),
    BuildSpec(
        build="25G241",
        darwin=(25, 6, 0),
        apu_mask=0x3F,
        note=("Deployable macOS 26.7.1 set: GL/Metal exact pages plus VDA/VA and VDA/AppleGVA tables. "
              "VDA kinds still require NRedVCNBridgeReady at runtime; Metal is copied from master's "
              "known-good gate/allow form."),
        gl=GlSource("kTahoeGLDriverPatches", ("NootedRed/UserPatches.cpp", "NootedRed/TahoePatchData.hpp"),
                    "AMDRadeonX5000GLDriver 7.x / macOS 26.7.1 (25G241)"),
        vda=HeaderSource("NootedRed/VDAVADataTahoe.hpp"),
        gva=HeaderSource("NootedRed/VDAGVADataTahoe.hpp"),
    ),
)

GLOBAL_GAPS = (
    "No PatchData exists for other builds. Add a pinned source + BuildSpec entry; do not guess pages.",
    "VDA/AppleGVA data is hardware-validated only on Renoir 0x1638 (15.8.1). Format v1 has one "
    "apuMask per build, so other VCN 2.2 APUs rely on exact page equality and NRedVCNBridgeReady.",
    "Driver identity in format v1 is exact 4 KiB page equality; there is no driver-bundle hash field.",
)


class ConversionError(Exception):
    """The pinned master tables cannot be converted as configured."""


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise ConversionError(message)


# Master's VDA/AppleGVA tables are wired into the kext by NRed.cpp's registerVDAFix() calls. The
# converter verifies that mapping from the pinned NRed.cpp instead of assuming it.
VDA_NAMESPACES = {
    "NootedRed/VDAVAData.hpp": "VDAVAData",
    "NootedRed/VDAVADataSonoma.hpp": "VDAVADataSonoma",
    "NootedRed/VDAVADataTahoe.hpp": "VDAVADataTahoe",
    "NootedRed/VDAGVAData.hpp": "VDAGVAData",
    "NootedRed/VDAGVADataSonoma.hpp": "VDAGVADataSonoma",
    "NootedRed/VDAGVADataTahoe.hpp": "VDAGVADataTahoe",
}


def verify_vda_registration(source: "SourceTree", files_used: list[str]) -> dict[str, Any]:
    """Verify NRed.cpp registers each VDA/AppleGVA header as a VDA patch table."""

    text = source.text("NootedRed/NRed.cpp")
    verified = []
    for rel in files_used:
        namespace = VDA_NAMESPACES.get(rel)
        _require(namespace is not None, f"{rel}: no known VDA namespace mapping")
        pattern = rf"registerVDAFix\(\s*{re.escape(namespace)}::Patches"
        _require(re.search(pattern, text) is not None,
                 f"NRed.cpp does not register {namespace}::Patches as a VDA table")
        verified.append({"header": rel, "namespace": namespace})
    return {
        "api": "UserPatches::registerVDAFix",
        "verifiedIn": "NootedRed/NRed.cpp",
        "headers": verified,
    }


class SourceTree:
    """Lazily parsed pinned master source files."""

    def __init__(self, root: Path) -> None:
        self.root = root
        self._texts: dict[str, str] = {}
        self._arrays: dict[str, dict[str, bytes]] = {}
        self._hashes: dict[str, str] = {}

    def text(self, rel: str) -> str:
        if rel not in self._texts:
            path = self.root / rel
            try:
                self._texts[rel] = path.read_text(encoding="utf-8")
            except OSError as error:
                raise ConversionError(f"{path}: cannot read pinned source: {error}") from error
            self._hashes[rel] = hashlib.sha256(self._texts[rel].encode("utf-8")).hexdigest()
        return self._texts[rel]

    def arrays(self, rel: str) -> dict[str, bytes]:
        if rel not in self._arrays:
            self._arrays[rel] = tables.parse_byte_arrays(self.text(rel), rel)
        return self._arrays[rel]

    def sha256(self, rel: str) -> str:
        self.text(rel)
        return self._hashes[rel]


def _table_file(source: SourceTree, files: tuple[str, ...],
                table_name: str) -> tuple[str, str, list[tables.PatchRow]]:
    for rel in files:
        text = source.text(rel)
        try:
            rows = tables.parse_patch_rows(text, table_name, rel)
        except tables.TableParseError:
            continue
        return rel, text, rows
    raise ConversionError(f"table {table_name}[] not found in {', '.join(files)}")


def _page_file_name(kind: int, index: int, page_name: str) -> str:
    return f"{KIND_NAMES[kind]}-{index:02d}-{tables.slugify(page_name)}.bin"


def _gl_tables(source: SourceTree, gl: GlSource) -> tuple[list[dict[str, Any]], dict[str, bytes]]:
    rel, text, rows = _table_file(source, gl.files, gl.table)
    arrays: dict[str, bytes] = {}
    for file_name in gl.files:
        arrays.update(source.arrays(file_name))

    # Master's GL table mixes GL and Metal page arrays; the page array name is the discriminator.
    rows_by_kind: dict[int, list[tables.PatchRow]] = {}
    for row in rows:
        kind = 2 if "MTL" in row.page else 1
        rows_by_kind.setdefault(kind, []).append(row)

    result: list[dict[str, Any]] = []
    page_files: dict[str, bytes] = {}
    for kind in sorted(rows_by_kind):
        grouped = tables.group_rows_by_page(rows_by_kind[kind])
        pages = []
        for index, (page_name, page_rows) in enumerate(grouped.items()):
            _require(page_name in arrays, f"{gl.table}: page array {page_name} not found")
            page = arrays[page_name]
            _require(len(page) == tables.PAGE_SIZE,
                     f"{page_name}: {len(page)} bytes, expected {tables.PAGE_SIZE}")
            sites = tables.derive_sites(page_rows, arrays, page_name)
            note, file_offset = GL_PAGE_NOTES.get(
                page_name, (f"exact 4 KiB page from master array {page_name}", None))
            file_name = _page_file_name(kind, index, page_name)
            page_spec: dict[str, Any] = {
                "source": f"pages/{file_name}",
                "sha256": tables.sha256_hex(page),
                "note": note,
                "sites": sites,
            }
            if file_offset is not None:
                page_spec["fileOffset"] = file_offset
            pages.append(page_spec)
            page_files[file_name] = page
        result.append({
            "kind": kind,
            "sourceFile": rel,
            "table": gl.table,
            "driver": gl.driver,
            "note": f"{KIND_NAMES[kind]}: {len(pages)} exact page(s) from master {rel}:{gl.table}",
            "pages": pages,
        })
    return result, page_files


def _header_table(source: SourceTree, header: HeaderSource,
                  kind: int) -> tuple[dict[str, Any], dict[str, bytes]]:
    text = source.text(header.file)
    arrays = source.arrays(header.file)
    rows = tables.parse_patch_rows(text, header.table, header.file)
    grouped = tables.group_rows_by_page(rows)
    pages = []
    page_files: dict[str, bytes] = {}
    for index, (page_name, page_rows) in enumerate(grouped.items()):
        _require(page_name in arrays, f"{header.file}: page array {page_name} not found")
        page = arrays[page_name]
        _require(len(page) == tables.PAGE_SIZE,
                 f"{page_name}: {len(page)} bytes, expected {tables.PAGE_SIZE}")
        provenance = tables.page_provenance(text, page_name)
        note = provenance["note"] or f"exact 4 KiB page from master array {page_name}"
        if provenance["recordedOffset"] is not None:
            note += f" [recorded image offset 0x{provenance['recordedOffset']:x}]"
        file_name = _page_file_name(kind, index, page_name)
        pages.append({
            "source": f"pages/{file_name}",
            "sha256": tables.sha256_hex(page),
            "note": note,
            "sites": tables.derive_sites(page_rows, arrays, page_name),
        })
        page_files[file_name] = page
    source_description = tables.parse_source_description(text)
    table: dict[str, Any] = {
        "kind": kind,
        "sourceFile": header.file,
        "table": header.table,
        "note": f"{KIND_NAMES[kind]}: {len(pages)} exact page(s) from master {header.file}:{header.table}",
        "pages": pages,
    }
    if source_description is not None:
        table["sourceDescription"] = source_description
    return table, page_files


def derive_spec(source: SourceTree, definition: BuildSpec,
                pinned_commit: str) -> dict[str, Any]:
    """Return ``{"spec": <json spec>, "pages": {file name: bytes}}`` for one build."""

    table_specs: list[dict[str, Any]] = []
    page_files: dict[str, bytes] = {}
    source_files_used: set[str] = set()

    if definition.gl is not None:
        gl_tables, gl_pages = _gl_tables(source, definition.gl)
        table_specs.extend(gl_tables)
        page_files.update(gl_pages)
        source_files_used.update(definition.gl.files)

    vda_table, vda_pages = _header_table(source, definition.vda, 3)
    gva_table, gva_pages = _header_table(source, definition.gva, 4)
    table_specs.extend((vda_table, gva_table))
    page_files.update(vda_pages)
    page_files.update(gva_pages)
    source_files_used.update((definition.vda.file, definition.gva.file, "NootedRed/NRed.cpp"))

    table_specs.sort(key=lambda table: table["kind"])
    expected_kinds = [1, 2, 3, 4] if definition.gl is not None else [3, 4]
    _require([table["kind"] for table in table_specs] == expected_kinds,
             f"{definition.build}: unexpected table kinds {[table['kind'] for table in table_specs]}")

    registration = verify_vda_registration(source, [definition.vda.file, definition.gva.file])
    spec: dict[str, Any] = {
        "schema": 1,
        "build": definition.build,
        "darwin": list(definition.darwin),
        "apuMask": definition.apu_mask,
        "note": definition.note,
        "provenance": {
            "kind": "derived-from-pinned-master-tables",
            "pinnedMasterCommit": pinned_commit,
            "sourceFiles": [
                {"path": rel, "sha256": source.sha256(rel)} for rel in sorted(source_files_used)
            ],
            "tables": [
                {
                    "kind": table["kind"],
                    "kindName": KIND_NAMES[table["kind"]],
                    "sourceFile": table["sourceFile"],
                    "patchTable": table["table"],
                    **({"sourceDescription": table["sourceDescription"]}
                       if "sourceDescription" in table else {}),
                    **({"driver": table["driver"]} if "driver" in table else {}),
                }
                for table in table_specs
            ],
            "registration": registration,
            "apuMaskNote": {
                0x3F: "union of master's gfx9 family masks; exact page equality is the final gate",
                0x38: "Renoir | RenoirE | GreenSardine, the VCN 2.2 families these VDA tables target",
            }.get(definition.apu_mask, f"0x{definition.apu_mask:02X}"),
            "gaps": list(definition.gaps) + list(GLOBAL_GAPS),
            "note": ("Pages are master's stock byte arrays; site offsets/occurrences are derived from "
                     "the PagePatch find/replace/skip/count fields. No driver bytes are invented. "
                     "Regenerate with tools/convert_master_patchdata.py."),
        },
        "tables": [
            {"kind": table["kind"], "note": table["note"], "pages": table["pages"]}
            for table in table_specs
        ],
    }
    return {"spec": spec, "pages": page_files}


def write_outputs(
    specs: dict[str, dict[str, Any]],
    specs_root: Path,
    patchdata_root: Path,
) -> list[Path]:
    """Write spec dirs (spec.json + pages/) and PatchData build dirs; return written paths."""

    written: list[Path] = []
    for build, payload in sorted(specs.items()):
        build_spec_dir = specs_root / build
        pages_dir = build_spec_dir / "pages"
        if build_spec_dir.exists():
            shutil.rmtree(build_spec_dir)
        pages_dir.mkdir(parents=True)
        for file_name, data in sorted(payload["pages"].items()):
            (pages_dir / file_name).write_bytes(data)
        spec_path = build_spec_dir / "spec.json"
        spec_path.write_text(json.dumps(payload["spec"], indent=2, ensure_ascii=True) + "\n",
                             encoding="utf-8")
        written.append(spec_path)
        patchdata_roots = patchdata_root
        patchdata_roots.mkdir(parents=True, exist_ok=True)
        # The generator owns the binary layout; it validates the spec again and is deterministic.
        generator.write_build(spec_path, patchdata_roots)
        written.extend(sorted((patchdata_roots / build).iterdir()))
    return written


def load_specs(source_root: Path | None) -> tuple[str, dict[str, dict[str, Any]]]:
    root = master_source.resolve_root(source_root)
    source = SourceTree(root)
    pinned = master_source.load_pin()
    commit = str(pinned.get("sourceCommit", ""))
    _require(bool(commit), "pinned source manifest has no sourceCommit")
    specs = {definition.build: derive_spec(source, definition, commit) for definition in BUILDS}
    return commit, specs


def compare_tree(expected: Path, actual: Path, allowed_extra: frozenset[str] = frozenset()) -> list[str]:
    problems: list[str] = []
    if not actual.exists():
        return [f"missing committed directory {actual}"]
    expected_files = {path.relative_to(expected) for path in expected.rglob("*") if path.is_file()}
    actual_files = {path.relative_to(actual) for path in actual.rglob("*") if path.is_file()}
    for missing in sorted(expected_files - actual_files):
        problems.append(f"missing {actual / missing}")
    for extra in sorted(actual_files - expected_files):
        if str(extra) in allowed_extra:
            continue
        problems.append(f"unexpected committed file {actual / extra}")
    for relative in sorted(expected_files & actual_files):
        expected_bytes = (expected / relative).read_bytes()
        actual_bytes = (actual / relative).read_bytes()
        if expected_bytes != actual_bytes:
            problems.append(f"{actual / relative}: differs from regenerated output "
                            f"(sha256 {hashlib.sha256(actual_bytes).hexdigest()} -> "
                            f"{hashlib.sha256(expected_bytes).hexdigest()})")
    return problems


def check(source_root: Path | None, specs_root: Path, patchdata_root: Path) -> list[str]:
    _commit, specs = load_specs(source_root)
    with tempfile.TemporaryDirectory(prefix="userpatch-convert-check-") as tmp:
        tmp_root = Path(tmp)
        write_outputs(specs, tmp_root / "specs", tmp_root / "PatchData")
        problems = compare_tree(tmp_root / "specs", specs_root)
        problems += compare_tree(tmp_root / "PatchData", patchdata_root,
                                 allowed_extra=frozenset({"README.md"}))
    return problems


def report(source_root: Path | None) -> int:
    commit, specs = load_specs(source_root)
    print(f"pinned master commit: {commit}")
    for definition in BUILDS:
        spec = specs[definition.build]["spec"]
        kinds = [table["kind"] for table in spec["tables"]]
        pages = sum(len(table["pages"]) for table in spec["tables"])
        sites = sum(len(page["sites"]) for table in spec["tables"] for page in table["pages"])
        kind_text = ", ".join(f"{kind}:{KIND_NAMES[kind]}" for kind in kinds)
        print(f"{definition.build} (Darwin {'.'.join(map(str, definition.darwin))}, "
              f"apuMask 0x{definition.apu_mask:02X}): {pages} page(s), {sites} site(s), kinds [{kind_text}]")
        for gap in definition.gaps:
            print(f"  gap: {gap}")
    print("gaps affecting all builds:")
    for gap in GLOBAL_GAPS:
        print(f"  - {gap}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Derive tools/specs and PatchData from the pinned master exact-page tables.",
    )
    parser.add_argument("--source-root", type=Path, default=None,
                        help="master source tree (default: pinned tools/pinned/master)")
    parser.add_argument("--source-git", default=None,
                        help="extract the required master files from a git revision instead")
    parser.add_argument("--specs", type=Path, default=DEFAULT_SPECS_DIR, help="spec output directory")
    parser.add_argument("--out", type=Path, default=DEFAULT_PATCHDATA_DIR, help="PatchData root")
    parser.add_argument("--check", action="store_true", help="verify committed output instead of writing")
    parser.add_argument("--report", action="store_true", help="print inventory/gaps only")
    args = parser.parse_args(argv)
    if args.source_root is not None and args.source_git is not None:
        print("error: --source-root and --source-git are mutually exclusive", file=sys.stderr)
        return 1
    try:
        if args.source_git is not None:
            with master_source.source_root_from_git(args.source_git) as root:
                return _run(args, root)
        return _run(args, args.source_root)
    except (ConversionError, master_source.MasterSourceError, generator.SpecError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


def _run(args: argparse.Namespace, source_root: Path | None) -> int:
    if args.report:
        return report(source_root)
    if args.check:
        problems = check(source_root, args.specs, args.out)
        if problems:
            for problem in problems:
                print(f"error: {problem}", file=sys.stderr)
            return 1
        print(f"ok: {args.specs} and {args.out} match the pinned master derivation")
        return 0
    commit, specs = load_specs(source_root)
    written = write_outputs(specs, args.specs, args.out)
    print(f"wrote {len(written)} file(s) from pinned master commit {commit}")
    for path in written:
        print(f"  {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
