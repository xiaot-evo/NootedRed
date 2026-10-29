# NRPT Patch Profile Specification — v2

Status: **frozen v2** (2026-10-29). Normative contract for the profile-driven user-space patch
engine on branch `feature/profile-driven-userpatch`. Revision v2 adds the target-image metadata
used by the hook-side vnode gate (the earlier direct-map consumer was removed for safety; the wire
format below is unchanged and remains frozen); §2.1, §4.1a, §3, §7, §11, §12 and §15 are extended by the
"NRPT v2 (normative)" section immediately below. The rest of this document (v1 matching, page/site
semantics, fail-closed rules) remains normative and is unchanged by v2; the kext consumer may also
keep accepting v1 profiles as hook-only.

This document is normative for four implementations. They must agree byte for byte:

| Layer | Artifact |
| --- | --- |
| Host codec / pure functions | `NootedRedTool/Sources/NootedRedTool/ProfileCodec.swift` |
| Host generator + evidence | NootedRedTool function parser / profile generator (task-7) |
| Offline validator | host simulator that applies a profile exactly like the kext (task-8) |
| Kernel consumer | generic parser + page matcher in `NootedRedUserPatch` (task-6) |

The kext contains **no** patch data: every page offset, page hash, site offset and find/replace byte
comes from the profile. A generated profile is injected as the `NRedOffsetProfile` `OSData` property
of the `org.ChefKiss.NootedRedUserPatch` personality in the kext `Info.plist`, together with the
expected build string `NRedSystemBuild`. A missing, mismatched or malformed profile is a fail-closed
`NoOp`; it is never partially accepted and never replaced by a guessed fallback.

NRPT is not `NRPD` (`docs/UserPatch-Data-Format.md`, embedded exact-page tables) and it replaces the
host-generated `NRPF`/NRP2/NRP3 experiments. It carries page identity and site records only; it does
**not** embed full 4 KiB page images.

## 0. NRPT v2 (normative); v1 sections below remain the matching contract

NRPT v2 keeps every v1 matching and fail-closed rule and adds **target-image metadata** so a
consumer can associate each page with its owning driver image/vnode without guessing addresses or
scanning for bytes. Version `2` replaces version `1`; a v2 parser MUST reject version `1` unless it
explicitly implements the documented v1 hook-only subset, and a v1 parser MUST reject version `2`.

### 0.1 Overall layout

```
offset 0                     Header (64 bytes)
offset 64                    Page table   (pageCount × 32 bytes)
offset 64 + pageTableSize    Site table   (siteCount × 40 bytes)
offset size - imageTableSize Image table  (imageTableSize bytes, imageCount variable entries)
```

```
size = 64 + pageCount * 32 + siteCount * 40 + imageTableSize
```

`pageTableSize` is exactly `pageCount * 32`; `siteTableSize` is exactly `siteCount * 40`;
`imageTableSize` is exactly the sum of the variable image-table entries (§0.4) and MUST equal the
value derived from the entries. The profile remains at most 65536 bytes and
`payloadChecksum = FNV-1a-32(bytes[64, size))` now covers the page table, the site table **and**
the image table, in that order.

### 0.2 Header changes (everything else from §3 is unchanged)

| Offset | Size | Type | Field | Required value |
| --- | --- | --- | --- | --- |
| 4 | 2 | u16 | `version` | `2` |
| 32 | 2 | u16 | `pageCount` | `1...256` |
| 34 | 2 | u16 | `siteCount` | `1...1024` |
| 36 | 4 | u32 | `pageTableSize` | `pageCount * 32` |
| 40 | 4 | u32 | `siteTableSize` | `siteCount * 40` |
| 44 | 4 | u32 | `payloadChecksum` | FNV-1a-32 over page+site+image tables |
| 48 | 4 | u32 | `flags` | v1 header flags (bit 0 only) |
| 52 | 2 | u16 | `imageCount` | `1...16` |
| 54 | 4 | u32 | `imageTableSize` | exact sum of §0.4 entry sizes |
| 58 | 6 | u8[6] | `reserved` | all zero |

All other header fields keep their v1 offsets and rules (`magic` @0, `headerSize` @6 = 64,
`build` @8, `apuMask` @24, `deviceID` @28).

### 0.3 Page record (32 bytes; replaces the v1 24-byte record)

| Offset | Size | Type | Field | Meaning |
| --- | --- | --- | --- | --- |
| 0 | 8 | u64 | `pageFileOffset` | unchanged v1 field, 4 KiB aligned |
| 8 | 8 | u64 | `pageHash` | unchanged v1 field |
| 16 | 4 | u32 | `firstSite` | unchanged v1 canonical ordering |
| 20 | 2 | u16 | `siteCount` | unchanged v1 |
| 22 | 2 | u16 | `matchFlags` | unchanged v1 (bits 1|2 mandatory) |
| 24 | 2 | u16 | `imageIndex` | index into the image table |
| 26 | 2 | u16 | `reserved` | MUST be 0 |
| 28 | 4 | u32 | `pageVmOffset` | 4 KiB aligned page offset from the image's unslid mach-header VM address |

`pageVmOffset` MUST equal `pageStartVMAddress - image.imageUnslidVmaddr` and MUST satisfy
`pageVmOffset & 0xFFF == 0` and `pageVmOffset + 4096 <= image.imageVmSize`; violations are `E040`.
The consumer computes the live page address as `dyldImageLoadAddress + pageVmOffset`, which works
identically for standalone file-backed dylibs and dyld-shared-cache images. Every page's
`imageIndex` MUST be `< imageCount` (`E038`).

### 0.4 Image table entries (`imageCount` variable-size entries, in generator order)

```
ImageEntryHeader (20 bytes)
  0   u8   kind           0 = standalone file-backed dylib, 1 = dyld shared cache image
  1   u8   flags          bit 0 = match `path` by suffix; every other bit reserved (0)
  2   u16  pathLength     path byte count, 1...200 (NUL terminator is not counted)
  4   u64  imageUnslidVmaddr  unslid VM address of the image's mach header / __TEXT segment
  12  u32  imageVmSize    __TEXT vmsize: bound for pageVmOffset, > 0 and <= 0xFFFFF000
  16  u8   segmentCount   1...16
  17  u8   sectionCount   0...16
  18  u16  reserved       MUST be 0
then
  path bytes (exactly pathLength printable ASCII bytes, first byte '/'),
  zero padding to a 4-byte boundary (it must contain the NUL terminator and be all zero),
  segmentCount × 16-byte NUL-padded segment names,
  sectionCount × 16-byte NUL-padded section names.
```

Rules: entry size is `20 + roundUp4(pathLength + 1) + segmentCount*16 + sectionCount*16` and the
whole table is the exact sum of the entries (`E035`/`E036`). Paths are absolute canonical
installed paths derived from the parsed target image (compression to the same path on every host:
the generator strips fixture-root prefixes); duplicates of `(kind, path)` are rejected (`E039`).
Names are 1...15 printable ASCII bytes each, unique within their table, and are validated then
ignored by the runtime (evidence only). `kind = 1` requires `imageUnslidVmaddr != 0`; `kind = 0`
uses the path suffix and normally stores 0; invalid geometry is `E041`. The image table is
deterministic: entries appear in the generator's first-discovery order and identical inputs produce
byte-identical image tables.

### 0.5 New error codes (stable diagnostics; whole-profile rejection)

| Code | Name | Rule |
| --- | --- | --- |
| `E034` | `invalidImageCount` | `imageCount` outside `1...16`, or image table larger than the format bound |
| `E035` | `invalidImageEntry` | malformed entry header/counts/padding/name table |
| `E036` | `imageTableSizeMismatch` | `imageTableSize` differs from the size derived from the entries |
| `E037` | `invalidImagePath` | empty/too long/non-printable/non-absolute image path |
| `E038` | `invalidPageMetadata` | page `imageIndex` out of range or page record reserved bytes non-zero |
| `E039` | `duplicateImagePath` | two image entries share `(kind, path)` |
| `E040` | `invalidPageVmOffset` | `pageVmOffset` unaligned or page leaves the image extent |
| `E041` | `invalidImageGeometry` | invalid unslid address / `imageVmSize` / segment-section name tables |

### 0.6 v2 producer and validator obligations

- The generator derives `kind`, canonical `path`, `imageUnslidVmaddr`, `imageVmSize`, segment and
  section names, and each page's `pageVmOffset` exclusively from the parsed Mach-O / dyld-cache
  image; it fails generation if any page has no resolvable image/segment/section. No path, address
  or offset is hardcoded.
- The generator MUST run the offline validator on the clean fixture. The offline validator MUST
  re-resolve every page's `(imageIndex, pageVmOffset)` to the exact fixture page start, segment,
  section, page-file offset and page hash, and report that resolution in its evidence. The
  fixture used for generation MUST be a clean on-disk extraction (`F_NOCACHE` or equivalent when it
  was collected from a running system whose pages are already patched).
- v2 matching remains exactly v1 §8: offset (when required) + full-page FNV-1a-64 hash + every
  site `find`, with the first identity-matching record authoritative and no partial page writes.
  The image metadata is used only to associate the page with its owning image/vnode (hook-side
  vnode-name gate, offline tooling); it never replaces the page identity gates.
- Codec model delta (§15): `NRPTProfile` gains `images: [NRPTImage]`; `NRPTImage` has
  `kind`, `path`, `unslidVMAddress`, `vmSize`, `segmentNames`, `sectionNames`; `NRPTPage` replaces
  the v1 24-byte fields plus `imageIndex: UInt16, pageVmOffset: UInt32`; `NRPTFormat` gains the v2
  header/page/image constants and `encodedSize(pageCount:siteCount:imageTableSize:)`;
  `ProfileCodecError` gains `E034...E041`. Encode/decode remain all-or-nothing; the pure matching
  helpers (`pageHash`, `pageMatches`, `applySites`, `applyPage`, `fnv1a32/64`) are unchanged.

## 1. Conventions

- All multi-byte integers are **unsigned little-endian**. There is no implicit padding, alignment or
  structure padding anywhere; every field is at the offset given in this document.
- `u8`, `u16`, `u32`, `u64` mean exactly 1, 2, 4 and 8 bytes.
- `char[N]` means N raw bytes, not a C string unless stated.
- MUST / MUST NOT / SHOULD / MAY are used in the RFC 2119 sense.
- "Profile" = one complete binary NRPT v1 file as injected in the property. "Page" = one 4 KiB
  (4096-byte) chunk of a user-space driver image. "Site" = one explicit byte replacement inside a
  page. "Chunk base offset" = the kernel-reported base offset of the 4 KiB chunk currently being
  validated (see §9).
- Hashing uses standard FNV-1a, exactly as specified in §1.1 (no polynomial variants, no alternate
  offset basis, no endian conversion of the hash value: the final u32/u64 is written little-endian
  like every other integer).

### 1.1 Hash functions

`fnv1a32` (payload checksum):

```
hash = 0x811C9DC5
for each byte b in input, in order:
    hash = (hash XOR b) * 0x01000193 mod 2^32
```

`fnv1a64` (page identity hash):

```
hash = 0xCBF29CE484222325
for each byte b in input, in order:
    hash = (hash XOR b) * 0x100000001B3 mod 2^64
```

`pageHash` input is exactly the 4096 bytes of the page, in ascending byte order. `payloadChecksum`
input is the profile payload: the page table bytes followed by the site table bytes, i.e. every byte
of the profile from offset 64 to the end, in order. Neither hash is computed over a "patched" page or
over any transformed copy; both are computed from the exact bytes as stored/delivered.

## 2. Overall layout

```
offset 0                     Header (64 bytes)
offset 64                    Page table   (pageCount   records × 24 bytes)
offset 64 + pageTableSize    Site table   (siteCount   records × 40 bytes)
offset size                  end of profile
```

```
size = 64 + pageCount * 24 + siteCount * 40
```

| Constraint | Value |
| --- | --- |
| `headerSize` | exactly `64` |
| `pageTableSize` | exactly `pageCount * 24` |
| `siteTableSize` | exactly `siteCount * 40` |
| actual byte length | exactly `64 + pageTableSize + siteTableSize` |
| maximum profile size | `65536` bytes (64 KiB) |

A decoder MUST reject a profile whose table sizes, byte length or record counts do not satisfy these
equalities exactly. There is no version that owns trailing or leading bytes.

## 3. Header (64 bytes)

| Offset | Size | Type | Field | Required value / meaning |
| --- | --- | --- | --- | --- |
| 0 | 4 | char[4] | `magic` | ASCII `"NRPT"` (`4E 52 50 54`) |
| 4 | 2 | u16 | `version` | `1` |
| 6 | 2 | u16 | `headerSize` | `64` |
| 8 | 16 | char[16] | `build` | expected `kern.osversion`, NUL padded (§3.1) |
| 24 | 4 | u32 | `apuMask` | APU family bit mask, non-zero, subset of bits 0–5 (§3.2) |
| 28 | 4 | u32 | `deviceID` | PCI device ID gate, exact semantics in §3.3 |
| 32 | 2 | u16 | `pageCount` | number of page records, `1...256` |
| 34 | 2 | u16 | `siteCount` | total number of site records, `1...1024` |
| 36 | 4 | u32 | `pageTableSize` | `pageCount * 24` |
| 40 | 4 | u32 | `siteTableSize` | `siteCount * 40` |
| 44 | 4 | u32 | `payloadChecksum` | FNV-1a-32 over the profile payload (§1.1) |
| 48 | 4 | u32 | `flags` | header flags, only bit 0 defined (§3.3) |
| 52 | 12 | u8[12] | `reserved` | all bytes MUST be `0` |

The header is not covered by `payloadChecksum`; every header field is validated independently and
the identity fields are additionally compared against the running system (§3, §11). A decoder MUST
reject a header byte that violates a rule in this section, before looking at any page or site record.

### 3.1 `build`

The field is a fixed-width, NUL-padded ASCII string, not a C string by accident:

- it holds `1...15` bytes from the alphabet `[0-9A-Za-z._-]`;
- the first byte after the string is `0x00`;
- every byte after that first NUL is `0x00`;
- it MUST equal the running `kern.osversion` read by the consumer. The `NRedSystemBuild` property
  injected next to the profile is an injection-time sanity hint: when present it MUST equal the same
  build, but it never overrides the actual running build. The comparison is exact byte equality
  after NUL trimming: no prefix matching, no "nearest build", no Darwin-major fallback. The embedded
  build of a macOS update never matches an older profile.

A profile for `24H232` stores `32 34 48 32 33 32 00 00 ...` and is only usable on build `24H232`.

### 3.2 `apuMask`

One bit per APU family known to the mainline kext. The generator declares the union of the families
for which its discovered pages were validated; the consumer accepts the profile only when the mask
intersects the running APU family set (`(profile.apuMask & runningMask) != 0`). An empty mask is
invalid; an unknown higher bit is invalid in v1. An unknown running device that yields an empty
candidate mask never matches.

| Bit | Mask | Family |
| --- | --- | --- |
| 0 | `0x00000001` | Raven |
| 1 | `0x00000002` | Raven2 |
| 2 | `0x00000004` | Picasso |
| 3 | `0x00000008` | Renoir |
| 4 | `0x00000010` | RenoirE |
| 5 | `0x00000020` | Green Sardine |

Candidate mask derivation (runtime; same rule as mainline `selectPatchSet`):

| PCI device ID | Candidate family bits |
| --- | --- |
| `0x15DD` Raven | bit 0 |
| `0x15D8` Raven2/Picasso | bits 1 and 2 (STRAP0 may narrow to bit 2) |
| `0x1636`, `0x164C` Renoir/Cezanne | bits 3 and 4 (STRAP0/PCI revision may narrow) |
| `0x15E7`, `0x1638` Barcelo/Green Sardine | bits 3 and 5 |
| anything else | empty set → profile never matches (`NoOp`) |

The exact per-device narrowing rule is mainline behavior, not part of the binary format; v1 requires
the intersection test and requires that "cannot determine the running family" means "do not apply".

### 3.3 `deviceID` and header `flags`

Header `flags` bit 0 is defined; every other bit is reserved and MUST be `0`.

| Bit | Name | Meaning |
| --- | --- | --- |
| 0 | `NRPT_HEADER_FLAG_REQUIRE_DEVICE_ID` | `deviceID` is part of profile identity and MUST equal the running iGPU PCI device ID |

`deviceID` is the PCI device ID (`0x15DD`, `0x1638`, …) in its low 16 bits; bits 16–31 MUST be `0`.

- If bit 0 is set: `deviceID` MUST be in `1...0xFFFF`. The consumer accepts only when
  `deviceID == runningDeviceID`; it MUST NOT fall back when the running ID is unavailable.
- If bit 0 is clear: `deviceID` MUST be `0`. A non-zero `deviceID` with the flag clear is invalid,
  and a `0` device ID with the flag set is invalid. There is no "wildcard device" encoding: the
  absence of the gate is stated explicitly by clearing the flag.

`deviceID` and `apuMask` are independent gates; both configured gates must pass. Both are redundant
with the page identity for safety and exist to select the right profile deterministically, not as the
page-matching identity.

### 3.4 Counts and table sizes

`pageCount` MUST be `1...256`. `siteCount` MUST be `1...1024`. An empty profile (zero pages or zero
sites) is invalid: "no patches" is expressed by not injecting a profile, never by an empty one.
`pageTableSize`/`siteTableSize` MUST equal the exact products in §2. The decoder derives the record
counts from the tables and rejects a mismatch between the header counts and the size-derived counts.

## 4. Page records (24 bytes each, page table order)

| Offset (record) | Size | Type | Field | Required value / meaning |
| --- | --- | --- | --- | --- |
| 0 | 8 | u64 | `pageFileOffset` | page base offset in the target image namespace, 4096-aligned |
| 8 | 8 | u64 | `pageHash` | FNV-1a-64 over the complete 4096-byte clean page (§1.1) |
| 16 | 4 | u32 | `firstSite` | index of the first site of this page in the site table |
| 20 | 2 | u16 | `siteCount` | number of sites of this page, `1...64` |
| 22 | 2 | u16 | `matchFlags` | page identity rules (§4.2), reserved bits zero |

`pageFileOffset` MUST be 4 KiB aligned (low 12 bits zero). It is the offset of the page base inside
the exact pager-file namespace the generator used (see §4.3). `pageHash` is any u64 value: the hash
of the page content, with no special value reserved; in particular `0` is a legal hash value. The
only way to validate a hash is against actual page content.

### 4.1 Site range

`firstSite` and `siteCount` must describe a canonical contiguous slice of the site table: page `i`
starts where page `i-1` ended, i.e. `firstSite == sum of siteCount of pages 0...i-1`, and the pages
together account for exactly `siteCount` sites. Pages and sites appear in generator order; there is no
interleaving or ordering freedom. Each site belongs to exactly one page.

### 4.2 `matchFlags` and identity semantics

| Bit | Value | Name | Meaning |
| --- | --- | --- | --- |
| 0 | `0x0001` | `NRPT_MATCH_REQUIRE_OFFSET` | `pageFileOffset` MUST equal the chunk base offset |
| 1 | `0x0002` | `NRPT_MATCH_REQUIRE_HASH` | FNV-1a-64 of the 4096-byte chunk MUST equal `pageHash` |
| 2 | `0x0004` | `NRPT_MATCH_REQUIRE_SITES` | every site `find` MUST match before any write |
| 3–15 | `0x0008...0x8000` | reserved | MUST be `0` |

v1 constraints (any violation is a decode error):

- `REQUIRE_HASH` and `REQUIRE_SITES` MUST always be set. A page may never be identified by offset
  alone or written without re-verifying every `find` byte.
- `REQUIRE_OFFSET` is optional. It MAY be set only when the producer has proven that its stored
  `pageFileOffset` is in the same namespace as the runtime chunk base offset (§4.3).
- The default, and the encoding a generator emits when it has no reason to clear the flag, is
  `REQUIRE_OFFSET | REQUIRE_HASH | REQUIRE_SITES` = `0x0007`.
- Unknown bits are rejected, not ignored. There is no `OPTIONAL_PAGE` in v1: a page record that never
  matches any delivered page is not an error at runtime, it simply does nothing; it is not a claim
  about the file layout.

Full-page hash + all site finds are the actual safety identity. If `REQUIRE_OFFSET` is set, the offset
is an additional cheap prefilter and an exact gate; if it is clear, page content alone identifies the
page.

### 4.3 Offset namespace

`pageFileOffset` is **not** a global address. It is the offset inside the file/pager the kernel
reports for the validated chunk:

- for a standalone Mach-O file (a dylib or kext bundle page, e.g. the GL driver), the file offset of
  the page inside that file;
- for a split dyld shared cache, the offset inside the *subcache file* whose pager reported the page,
  not the offset in the concatenated/large cache view and not the VM address.

Producers MUST NOT guess this namespace and MUST NOT "fix" it by masking or rebasing at runtime. The
generator records `pageFileOffset` only when it has evidence for the exact namespace (the offline
fixture and, where available, a live-observation report); otherwise it MUST clear `REQUIRE_OFFSET`
and rely on the full-page hash, which is namespace-independent. The consumer compares exact u64
values and MUST NOT round, mask or slide offsets. A non-4 KiB-aligned delivered offset can therefore
never match a `REQUIRE_OFFSET` record; that is a normal skip, not an error.

## 5. Site records (40 bytes each, site table order)

| Offset (record) | Size | Type | Field | Required value / meaning |
| --- | --- | --- | --- | --- |
| 0 | 2 | u16 | `siteInPage` | byte offset from the page base, `0x0000...0x0FFF` |
| 2 | 1 | u8 | `findSize` | number of significant `find` bytes, `1...16` |
| 3 | 1 | u8 | `replaceSize` | number of significant `replace` bytes, `1...16`, MUST equal `findSize` |
| 4 | 16 | u8[16] | `find` | expected current bytes, zero-padded after `findSize` |
| 20 | 16 | u8[16] | `replace` | bytes to write, zero-padded after `replaceSize` |
| 36 | 4 | u32 | `flags` | reserved for v1, MUST be `0` |

Rules:

- `siteInPage + findSize <= 4096` and `siteInPage + replaceSize <= 4096` (with equal sizes these are
  the same bound). No site may straddle a page end.
- `findSize == replaceSize`. A patch replaces a byte sequence in place and must not shift any other
  instruction: the generator's semantic transform is required to preserve instruction length, with
  padding already included in `replace`. `findSize != replaceSize` is an invalid profile in v1.
- Unused bytes in `find[16]` after `findSize` and in `replace[16]` after `replaceSize` MUST be `0`.
  This is canonical form; a decoder rejects dirty padding.
- `find` must differ from `replace` (a no-op site is invalid) and the writer writes all
  `replaceSize` bytes unconditionally. The consumer verifies `find` at `siteInPage` and then writes
  `replace` at the same offset; `siteInPage` is authoritative and the consumer MUST NOT scan the page
  for the pattern and MUST NOT require in-page uniqueness.
- Two sites on the same page MUST NOT have overlapping write ranges
  `[siteInPage, siteInPage + replaceSize)`. Different pages may use the same `siteInPage`.
- Site `flags` is reserved in v1: any non-zero value is invalid. It exists so a later format version
  can add site semantics without moving the record; using it requires a version bump.
- The site table is verified as a whole at runtime: if any site of the matched page does not match
  its `find`, the profile consumer performs **zero** writes for that page. Partial application of a
  page is forbidden.

## 6. Canonical layout and identity uniqueness

A v1 profile is canonical when all of the following hold; a decoder MUST reject all violations:

1. `size == 64 + 24 * pageCount + 40 * siteCount` and `size <= 65536`.
2. Page records appear in the page table in the order the generator emitted them; site records follow
   the page table and are grouped by page in the same order, contiguously (§4.1).
3. Every page has `siteCount >= 1` and `siteCount <= 64`; the sum of page site counts is the header
   `siteCount`.
4. Every page's `pageFileOffset` is 4 KiB aligned; every `siteInPage`/size pair is in page bounds.
5. No two page records describe the same identity:
   - identical `pageFileOffset` **and** identical `pageHash` is invalid (duplicate record);
   - identical `pageHash` is invalid unless both records set `REQUIRE_OFFSET` and their
     `pageFileOffset` values differ. A hash collision between records that are not offset-distinguished
     would make the first-matching-record rule ambiguous.
   - Different hashes with the same offset are legal: the same namespace offset can belong to
     different images, and the full-page hash distinguishes them.
6. There is no requirement that two pages have different content in general; only the identity pairs
   above must be unambiguous.

The generator must also ensure, from the target image it parsed, that no **additional** page of the
target image matches a record's identity. That condition cannot be checked from the binary profile
alone, so it is a producer obligation and an offline-validator obligation (§15, §16).

## 7. Limits (v1)

A decoder MUST reject a profile exceeding any limit; a generator MUST refuse to emit one.

| Item | Limit |
| --- | --- |
| profile size | `<= 65536` bytes |
| `pageCount` | `1...256` |
| `siteCount` | `1...1024` |
| sites per page | `1...64` |
| build string | `1...15` bytes |
| site patch size (`findSize == replaceSize`) | `1...16` bytes |
| page size for `pageHash` | exactly `4096` bytes |
| `apuMask` | non-zero, subset of `0x0000003F` |
| `deviceID` (when required) | `1...0xFFFF`; bits 16–31 zero |
| header `flags` | only bit 0; other bits zero |
| page `matchFlags` | bits 0–2 only; bits 1 and 2 always set |
| site `flags` | `0` |
| reserved header bytes | `0` |
| unused `find`/`replace` padding | `0` |

The maximum legal v1 profile (`256` pages, `1024` sites) is `64 + 6144 + 40960 = 47168` bytes, below
the 64 KiB ceiling. The ceiling is still checked first so a malformed size field cannot drive large
allocations.

## 8. Runtime matching algorithm

The consumer validates and copies the whole profile once, before any page-validation hook can run.
For every delivered 4 KiB chunk with base offset `chunkBase` and bytes `data[0..4096)` the consumer
MUST execute exactly:

```
for pageIndex in 0 ..< pageCount:                       // profile table order
    record = pages[pageIndex]

    if record.matchFlags has REQUIRE_OFFSET:
        if chunkBase is not 4 KiB aligned: continue
        if record.pageFileOffset != chunkBase: continue

    if record.matchFlags has REQUIRE_HASH:
        if fnv1a64(data, 4096) != record.pageHash: continue

    // Identity matched: this record is authoritative for this chunk.
    if the record's applied bit is set:
        stop: this record was already applied once this boot; write nothing,
              try no other record

    for each site of the record:
        if memcmp(data + site.siteInPage, site.find, site.findSize) != 0:
            count a find mismatch
            stop: write nothing for this chunk, try no other record

    if MachInfo::setKernelWriting(true, ...) fails:
        count a write-protection failure; stop; write nothing
    for each site of the record:
        memcpy(data + site.siteInPage, site.replace, site.replaceSize)
    restore kernel write protection
    set the record's applied bit
    count the applied page
    break out of the page-record loop
```

Properties of this algorithm that are part of the contract:

- Page-record order is significant only for determinism; the identity rules in §6 make at most one
  record match a given chunk.
- Once a record's enabled identity predicates match, the record is **authoritative**. A subsequent
  site check failure aborts the chunk with zero writes; the consumer MUST NOT fall through to another
  record, MUST NOT scan for another occurrence of `find`, and MUST NOT mask/skip offending sites.
- Writes happen only after all enabled identity checks (offset if required, hash, all site finds)
  pass. No write happens if the original validator did not accept the page (§9).
- A record is applied at most once per boot (bounded bitmap, one bit per page record). This prevents
  double writes if the same content is validated through another mapping.
- Counters and logs are bounded: `AppliedPages`, `FindMismatches`, `HashMismatches`/`MatchedPages`,
  route availability, and at most one log line per apply/failure class (rate-limited); no allocation,
  no VFS/IORegistry access and no sleeping in either hook.

## 9. Delivery contexts and chunking

- `_cs_validate_page`: the kernel provides one validated page's bytes (expected 4096). The chunk base
  is the kernel-reported `page_offset` converted to a u64; it is used only when `REQUIRE_OFFSET` is
  set. The page is patched only when the original validation result (`*validated != 0` on 24H232, see
  `analysis/xnu-lilu-page-validation.md`) says the page was accepted, and its return value is never
  modified by the patch attempt.
- `_cs_validate_range`: bytes are processed as consecutive 4 KiB chunks in ascending order; chunk `i`
  has base `rangeBase + i * 4096`. Only whole 4 KiB chunks are processed: a trailing partial chunk is
  ignored (never patch a partial page). The range hook's own boolean return value is likewise not
  affected by patch failures.
- Both hooks may run in memory-object/code-signing context: the profile MUST already be copied into
  plain static memory; hooks must not touch IOKit, VFS or the original `OSData` property bytes.

The delivered page bytes are hashed exactly as delivered, in ascending order. The consumer MUST NOT
compare a "patched" page (a record already applied) against the stored hash again, because writing
`replace` changes the page by definition.

## 10. Fail-closed semantics

These rules are mandatory; "best effort" fallbacks are forbidden.

1. **Whole-profile rejection.** If any rule in §2–§7 fails, the consumer must reject the entire
   profile: do not keep partially parsed tables, do not install page matching, log one specific
   reason and stay `NoOp`. The profile is all-or-nothing.
2. **One profile only.** No fallback among profiles, builds, devices, families, data files, embedded
   tables, kext resources, boot arguments or heuristics. Build equality is exact; a newer/older
   macOS build is unsupported, not approximated.
3. **Unresolvable identity means no patch.** If the expected build, running APU family or (when
   required) running device ID cannot be established, the profile must not be applied. Bounded retry
   of identity discovery is allowed; guessing a family or a build is not.
4. **Page-level failure is local and silent to the system.** A hash mismatch, offset mismatch or site
   find mismatch means "this delivered page is not ours": write nothing, continue validating normally.
   It is not an error of the code-signing validator, never changes its result, and never panics.
5. **No partial page writes.** All sites of a page are applied together after all checks pass. A
   failure before the write loop means no site of that page is written.
6. **No re-matching after a failed identity.** Once a record's enabled identity gates match, a site
   mismatch ends processing for that chunk (no substitute record, no scan, no offset repair).
7. **Deterministic bytes.** A profile is a pure function of the generator inputs: no timestamps,
   paths, machine names or random values. Identical inputs produce byte-identical profiles
   (including `payloadChecksum`).

## 11. Validation errors

Decoders (host codec and kext parser) MUST report one of these stable codes with the indicated
context. A code is either a structural decode error (profile rejected in full) or a generator/model
error (encode refused in full); in both cases nothing is written or applied.

| Code | Name | Rule |
| --- | --- | --- |
| `E001` | `truncated` | profile shorter than the 64-byte header |
| `E002` | `badMagic` | bytes 0–3 are not `"NRPT"` |
| `E003` | `unsupportedVersion` | `version != 1` |
| `E004` | `invalidHeaderSize` | `headerSize != 64` |
| `E005` | `invalidBuild` | build is empty, >15 bytes, has a forbidden character, missing NUL padding, or non-zero bytes after the first NUL |
| `E006` | `invalidApuMask` | mask is zero or contains a bit outside 0–5 |
| `E007` | `invalidDeviceID` | `deviceID`/header-flag combination from §3.3 is invalid |
| `E008` | `unsupportedHeaderFlags` | a reserved header-flag bit is set |
| `E009` | `headerReservedNotZero` | any of header bytes 52–63 is non-zero |
| `E010` | `profileTooLarge` | computed or actual size exceeds 64 KiB |
| `E011` | `pageTableSizeMismatch` | `pageTableSize != pageCount * 24` |
| `E012` | `siteTableSizeMismatch` | `siteTableSize != siteCount * 40` |
| `E013` | `totalSizeMismatch` | actual length differs from `64 + pageTableSize + siteTableSize` |
| `E014` | `payloadChecksumMismatch` | FNV-1a-32 over bytes `[64, size)` differs from `payloadChecksum` |
| `E015` | `pageCountOutOfRange` | `pageCount > 256` (zero pages is `E032`) |
| `E016` | `siteCountOutOfRange` | `siteCount < 1` or `> 1024` |
| `E017` | `pageOffsetMisaligned` | a page `pageFileOffset` has non-zero low 12 bits |
| `E018` | `unsupportedPageMatchFlags` | page `matchFlags` has a bit outside 0–2 |
| `E019` | `requiredPageMatchFlagMissing` | page `matchFlags` does not set both `REQUIRE_HASH` and `REQUIRE_SITES` |
| `E020` | `pageSiteRangeInvalid` | a page's `firstSite + siteCount` overflows or exceeds header `siteCount` |
| `E021` | `nonCanonicalSiteRange` | a page's `firstSite` is not the running sum of preceding page site counts |
| `E022` | `siteCountSumMismatch` | sum of page site counts differs from header `siteCount` |
| `E023` | `sitesPerPageExceeded` | a page has `0` sites or more than 64 sites |
| `E024` | `invalidSitePatchSize` | `findSize` or `replaceSize` is `0` or `>16` |
| `E025` | `findReplaceSizeMismatch` | `findSize != replaceSize` |
| `E026` | `siteOutOfPageBounds` | `siteInPage + size > 4096` |
| `E027` | `sitePaddingNotZero` | a `find`/`replace` byte after the declared size is non-zero |
| `E028` | `noOpSite` | `find` and `replace` are byte-identical over `findSize` bytes |
| `E029` | `unsupportedSiteFlags` | site `flags != 0` |
| `E030` | `overlappingSiteWrites` | two sites on the same page have overlapping write ranges |
| `E031` | `duplicatePageIdentity` | two records have the same identity from §6 rule 5 |
| `E032` | `emptyProfile` | `pageCount == 0` (a profile with zero patches is invalid; do not inject one) |
| `E033` | `invalidPageSize` | `pageHash` helper input is not exactly 4096 bytes (codec precondition, not a wire-format rule) |

Error messages are part of diagnostics only, not of the wire format; the code names above are stable.

Runtime (non-fatal) counters, separate from profile validation: `AppliedPages`, `FindMismatches`,
`MatchedPages`/`HashMismatches`, `RangeHook`/`PageHook` availability. They never turn a valid
validator result into a failure.

## 12. Producer (generator) contract

The generator produces a profile only from a parsed target image; it MUST fail generation (emit no
profile) on any ambiguity. It must not contain hardcoded patch addresses, find/replace bytes or page
offsets, and must not fall back to byte scanning outside a parsed function.

For every discovered site it must have:

1. the parsed function extent (symbol/ObjC metadata + CFG validation) containing the instruction;
2. a decoded, semantically matched instruction or instruction sequence with exactly one match in that
   function (one unambiguous site), failing generation otherwise;
3. `siteInPage` = the exact byte offset of the instruction(s) inside the 4 KiB page;
4. `find` = the exact current instruction bytes in the clean page at that offset; `replace` = the
   transformed bytes, same length, differing from `find`;
5. the clean page bytes at a known `pageFileOffset` in the namespace the consumer will see
   (§4.3), and `pageHash = FNV-1a-64(pageBytes)` over the full 4096 bytes;
6. `matchFlags` explicitly: `0x0007` only when the offset namespace is proven, otherwise `0x0006`;
7. proof that no other page of the target image matches this record's identity (offset+hash gate), so
   generation is unambiguous;
8. the header identity: `build` = exact target `kern.osversion`, `apuMask` = union of validated
   families, optional strict `deviceID`, and the injected `NRedSystemBuild` equal to the same build.

The profile bytes must be produced by the canonical encoder (`ProfileCodec.encode` or an
independently implemented encoder that is byte-identical); the tool must keep a JSON evidence report
(parsed function, matched instruction, source page hash, flags decision, validation result) next to
the profile. Hand-editing profile bytes is forbidden.

After encoding, the generator must run the offline validator (§16) on the clean fixture; a profile
that does not reproduce every intended site, or that matches any unintended page, must not be
committed or deployed.

## 13. Offline validator contract

The offline validator applies a profile to a clean fixture using exactly the algorithm in §8 (same
flag semantics, same FNV-1a-64 over the full page, same first-matching-record rule, same no-partial-
page rule). It MUST report, per page and per site, at least:

- whether the record's identity matched (offset gate result, hash result);
- whether every site `find` matched;
- the bytes that would be written, and the resulting page hash;
- whether any fixture page other than the intended one matches a record identity (false-positive
  check);
- overall pass/fail and the profile checksum/identity fields.

A profile is deployable only when every intended page matches and applies and no unintended page
matches. The validator must not silently repair a profile (no flag rewriting, no offset patching, no
site masking).

## 14. Kernel consumer contract

- Parse and copy the profile into bounded static storage during plugin start, before any page
  validation can occur. The `OSData` bytes must not be referenced afterwards (the property is
  removed and may be freed). Bounded static arrays: at least the v1 limits of §7; no allocation.
- Validate every §2–§7 rule, including `payloadChecksum`, and the header identity against the
  expected build/APU/device. On any failure: keep the plugin loaded, report `NoOp`, log one specific
  reason (the `E0xx` code and a short field context), and never install/perform matching. No partial
  state may survive a rejected load.
- Hooks must follow the OS ABI (`_cs_validate_page`: 7-argument `void` with `int *validated`,
  `*tainted`, `*nx` on macOS 15; `_cs_validate_range`: 6-argument `boolean_t`); patch only after the
  original validator accepted the page. No allocation, no VFS, no IORegistry, no sleeps and no
  unbounded logging in the hooks.
- The binary must contain no page offsets, page hashes, find/replace constants, page tables or
  per-build data beyond the generic parser and matcher (the audit check from
  `analysis/lilu-dyld-shared-cache-profile-engine.md` §2.4 must pass).
- `MachInfo::setKernelWriting` is used only around the actual writes, and failures to enable/disable
  kernel writing are fail-closed (no write without protection handling).

## 15. Codec API (`ProfileCodec.swift`)

`ProfileCodec` is a pure Swift file (Foundation only, no I/O) and is the reference implementation of
this specification. The public surface is:

```swift
enum NRPTFormat { /* constants: magic, version, sizes, limits, default flags */ }

struct NRPTHeaderFlags: OptionSet { static let requireDeviceID }        // header flags u32
struct NRPTMatchFlags: OptionSet {
    static let requireOffset, requireHash, requireSites
    static let defaultV1                                                // 0x0007
}

struct NRPTSite  { var siteInPage: UInt16; var find: [UInt8]; var replace: [UInt8]; var flags: UInt32 }
struct NRPTPage  { var pageFileOffset: UInt64; var pageHash: UInt64;
                   var matchFlags: NRPTMatchFlags; var sites: [NRPTSite] }
struct NRPTHeader { var build: String; var apuMask: UInt32; var deviceID: UInt32;
                    var flags: NRPTHeaderFlags }
struct NRPTProfile { var header: NRPTHeader; var pages: [NRPTPage] }

enum ProfileCodecError: Error, Equatable { case ... }                  // stable E0xx codes via `code`

enum ProfileCodec {
    static func encode(_ profile: NRPTProfile) throws -> Data          // validate + canonical bytes
    static func decode(_ data: Data) throws -> NRPTProfile             // strict, all-or-nothing
    static func validate(_ profile: NRPTProfile) throws                // model-level rules

    static func fnv1a32(_ data: Data) -> UInt32                        // pure
    static func fnv1a64(_ data: Data) -> UInt64                        // pure
    static func pageHash(_ page: Data) throws -> UInt64                // requires exactly 4096 bytes
    static func payloadChecksum(pageTable: Data, siteTable: Data) -> UInt32

    // Pure simulation of the kext algorithm (offline validator / tests):
    static func pageMatches(_ page: NRPTPage, data: Data, pageOffset: UInt64?) -> Bool
    static func applySites(_ page: NRPTPage, to data: Data) -> Data
    static func applyPage(_ profile: NRPTProfile, data: Data,
                          pageOffset: UInt64?) -> NRPTPageApplication
}

enum NRPTPageApplication: Equatable {
    case noMatch
    case siteFindMismatch(pageIndex: Int, siteIndex: Int)
    case applied(pageIndex: Int, data: Data)                            // patched full page
}
```

`encode` derives the header counts, table sizes and `payloadChecksum` from the arrays; a model can
therefore never serialize inconsistent sizes. `decode` re-derives and cross-checks them. All API
functions are sample-free: they never contain, embed or require checked-in driver bytes; callers
construct `NRPTProfile` values programmatically or pass real bytes read from a fixture.

## 16. Self-test expectations

The codec and the kext parser are expected to pass at least the following tests. Host codec tests
must be pure/offline; no Apple driver binary needs to be committed.

1. `fnv1a32("") == 0x811C9DC5`, `fnv1a32("a") == 0xE40C292C`, `fnv1a32("foobar") == 0xBF9CF968`.
2. `fnv1a64("") == 0xCBF29CE484222325`, `fnv1a64("a") == 0xAF63DC4C8601EC8C`,
   `fnv1a64("foobar") == 0x85944171F73967E8` (standard FNV-1a reference vectors).
3. `pageHash` accepts exactly 4096-byte input and rejects 4095/4097-byte input.
4. Encode→decode round trip preserves header build/APU/device/flags, page order, page offsets,
   page hashes, match flags, site order, `siteInPage`, `find`, `replace`, and site flags; encoded
   bytes are deterministic across repeated encodes.
5. Encoded size equals `64 + 24 * pages + 40 * sites`; a hand-built 13-page/18-site profile encodes
   to `64 + 312 + 720 = 1096` bytes.
6. Every wire-format rule `E001...E032` has at least one crafted-byte test that decodes a valid profile, mutates
   exactly the bytes that break that rule, and asserts the specific code. Mutations include: magic
   byte, version, header size, build padding/chars, APU mask zero and bit 6, device ID with/without
   the header flag, header flag bit 1, reserved byte, truncation at every `0...63`, trailing byte,
   count/size fields, checksum byte, unaligned page offset, page match flag bit 3, missing
   `REQUIRE_HASH`, non-contiguous `firstSite`, zero/too-many sites per page, size 0/17, unequal
   find/replace sizes, out-of-bounds `siteInPage`, dirty padding, find == replace, site flag 1,
   overlapping sites, duplicate identity, zero pages.
7. `encode` refuses (same codes) a model that violates any §7 limit, including `257` pages, `1025`
   sites, `65` sites on one page, a 16-byte build string, an unknown match flag bit and an empty
   profile.
8. `applyPage`/`applySites`: (a) matched page applies all `replace` bytes and only they change;
   (b) a hash mismatch returns `noMatch` with zero writes; (c) one wrong `find` byte returns
   `siteFindMismatch` and leaves **all** bytes unchanged (atomic page); (d) `REQUIRE_OFFSET` cleared
   matches regardless of the supplied offset but never wrong content, `REQUIRE_OFFSET` set rejects a
   different offset even with matching content; (e) the first fully matching record is authoritative
   when two records are valid (§6); (f) a non-4096-byte data input is rejected/no-op.
9. The kext parser rejects the same crafted profiles and accepts exactly the codec's encodings
   (cross-implementation test with a golden encoding produced by `ProfileCodec.encode`).
10. A profile with a page that never matches any delivered page loads and simply produces
    `AppliedPages = 0` for that page; malformed profiles produce `NoOp` and no writes at all.

## 17. Versioning

- `version` is `1` for this layout. Any change to field meaning, field order, offsets, sizes, flags,
  checksum algorithm, limits, canonical layout or matching semantics requires a new version number.
  A parser MUST reject versions it does not know; forward compatibility is not implied.
- `headerSize` exists so a future version can grow the header, but a v1 parser requires exactly 64
  and a v1 encoder always writes 64.
- Every currently reserved byte/bit (header bytes 52–63, header flag bits 1–31, page `matchFlags`
  bits 3–15, site `flags`, `find`/`replace` padding) MUST be zero in v1. A future version may only
  use them after a version bump, with a matching spec, codec, generator, validator and kext update.
- `payloadChecksum` covers only the payload; if a future version needs to protect header identity
  bytes cryptographically or against corruption, that is a new version with a new checksum
  definition.

## 18. Security considerations and non-goals

- FNV-1a is a non-cryptographic checksum/hash. It is used here as a fast content-identity and
  accidental-corruption gate for pages discovered from a clean fixture, not as a security boundary.
  The trust boundary is the EFI partition / kext `Info.plist`: an attacker who can modify the
  injected profile can already modify the kext. The format is nevertheless fully bounds-checked and
  fail-closed so corrupted or mis-generated data can never cause an out-of-bounds write in kernel
  context.
- The page hash is not a code-signing hash and does not replace the kernel's own signature
  validation. The plugin patches only after the original validator accepted the page.
- Non-goals for v1: per-family page tables for one build (the `apuMask` is a union), a driver image
  hash/signature field, site masks/wildcards, variable-length `find`/`replace` (they are equal and at
  most 16 bytes), more than 4096-byte pages, kernel-kext patch descriptors, or runtime scanning of
  any kind. A profile is immutable for the boot; the format has no timestamp or generator version
  field by design (determinism), so provenance lives in the generator's JSON evidence.

## 19. References

- `analysis/lilu-dyld-shared-cache-profile-engine.md` — target architecture, NRPT v1 field draft,
  page-identity rationale and kext safety constraints.
- `docs/UserPatch-Data-Format.md` — the separate embedded `NRPD` exact-page format (not used by
  NRPT; kept as historical/reference contract for the v1 satellite path).
- `analysis/xnu-lilu-page-validation.md` — macOS 15 `_cs_validate_page` / `_cs_validate_range` ABI,
  `page_offset` semantics and the 7-argument hook. (File preserved in the working tree under
  `build/revert-backup/` if it is not present at `analysis/`.)
- Apple TN3126, *Inside Code Signing: Hashes* — code-directory page hashes and 4 KiB page slots.
- FNV reference: Fowler–Noll–Vo hash function, FNV-1a 32/64 variants (offset basis `0x811C9DC5` /
  `0xCBF29CE484222325`, prime `0x01000193` / `0x100000001B3`).
