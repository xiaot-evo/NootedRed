# NRPT Patch Profile Specification — v3

Status: **frozen v3** (2026-10-29). Normative contract for the profile-driven user-space patch
engine on branch `feature/profile-driven-userpatch`. **v3 replaces v1 and v2:** a v3 parser rejects
every other version (`E003`); there is no compatibility mode, no legacy offset matching and no
matchFlags encoding. The normative contract is this document plus
`NootedRedTool/Sources/NootedRedTool/ProfileCodec.swift`.

This document is normative for four implementations. They must agree byte for byte:

| Layer | Artifact |
| --- | --- |
| Host codec / pure functions / bundle model | `NootedRedTool/Sources/NootedRedTool/ProfileCodec.swift` |
| Host generator + evidence | NootedRedTool `PatchAnalyzer` (task-26) |
| Offline validator / injection tooling | `test/nrpt_validator.py`, `test/inject_profile.py` (task-27) |
| Kernel consumer | `NootedRedUserPatch` v3 engine, `NRedProfiles` array (task-25) |

The kext contains **no** patch data: every page hash, site offset, find/replace byte, image path and
mode comes from the profile. Profiles are injected as the `NRedProfiles` array property of the
`org.ChefKiss.NootedRedUserPatch` personality in the kext `Info.plist` (§8). A missing, mismatched or
malformed bundle/profile is a fail-closed `NoOp`; it is never partially accepted and never replaced by
a guessed fallback.

NRPT v3 goals: (1) profile-defined patch **modes** so each page states the validation route it
belongs to; (2) **multiple profiles coexist** in one bundle, selected by exact build/APU/device;
(3) minimal, deterministic metadata; (4) identity is **full-page content** (FNV-1a-64 + all site
finds), never a pager/file offset.

## 1. Conventions

- All multi-byte integers are **unsigned little-endian**. There is no implicit padding, alignment or
  structure padding anywhere; every field is at the offset given in this document.
- `u8`, `u16`, `u32`, `u64` mean exactly 1, 2, 4 and 8 bytes. `char[N]` means N raw bytes.
- MUST / MUST NOT / SHOULD / MAY are used in the RFC 2119 sense.
- "Profile" = one complete binary NRPT v3 file. "Bundle" = the `NRedProfiles` array of profile
  entries (§8). "Page" = one 4 KiB (4096-byte) chunk of a target driver image. "Site" = one explicit
  byte replacement inside a page. "Chunk base offset" = the kernel-reported base offset of a
  delivered 4 KiB chunk; it is **diagnostic only** in v3.
- Hashing uses standard FNV-1a exactly as specified in §1.1. The final u32/u64 is written
  little-endian like every other integer.

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

`pageHash` input is exactly the 4096 bytes of the clean page in ascending order.
`payloadChecksum` input is the profile payload from offset 64 to the end: page-table bytes, then
site-table bytes, then image-table bytes, in that order.

## 2. Overall layout

```
offset 0                     Header (64 bytes)
offset 64                    Page table   (pageCount × 32 bytes)
offset 64 + pageTableSize    Site table   (siteCount × 40 bytes)
offset 64 + pageTableSize + siteTableSize
                             Image table  (imageTableSize bytes, imageCount variable entries)
offset size                  end of profile
```

```
size = 64 + pageCount * 32 + siteCount * 40 + imageTableSize
```

| Constraint | Value |
| --- | --- |
| `headerSize` | exactly `64` |
| `pageTableSize` | exactly `pageCount * 32` |
| `siteTableSize` | exactly `siteCount * 40` |
| `imageTableSize` | exactly the sum of the image entries (§7) |
| actual byte length | exactly `64 + pageTableSize + siteTableSize + imageTableSize` |
| maximum profile size | `65536` bytes (64 KiB) |

A decoder MUST reject a profile whose table sizes, byte length or record counts do not satisfy these
equalities exactly. There is no version that owns trailing or leading bytes.

## 3. Header (64 bytes)

| Offset | Size | Type | Field | Required value / meaning |
| --- | --- | --- | --- | --- |
| 0 | 4 | char[4] | `magic` | ASCII `"NRPT"` (`4E 52 50 54`) |
| 4 | 2 | u16 | `version` | `3` (v1/v2 MUST be rejected, `E003`) |
| 6 | 2 | u16 | `headerSize` | `64` |
| 8 | 16 | char[16] | `build` | exact `kern.osversion`, NUL padded (§3.1) |
| 24 | 4 | u32 | `apuMask` | APU family bit mask, non-zero, subset of bits 0–5 (§3.2) |
| 28 | 4 | u32 | `deviceID` | `0` = no device gate; `1...0xFFFF` = exact PCI device ID gate (§3.3) |
| 32 | 2 | u16 | `pageCount` | number of page records, `1...256` |
| 34 | 2 | u16 | `siteCount` | total number of site records, `1...1024` |
| 36 | 4 | u32 | `pageTableSize` | `pageCount * 32` |
| 40 | 4 | u32 | `siteTableSize` | `siteCount * 40` |
| 44 | 4 | u32 | `payloadChecksum` | FNV-1a-32 over page+site+image tables (§1.1) |
| 48 | 4 | u32 | `reserved0` | MUST be `0` (v3 has no header flags; `E008` if non-zero) |
| 52 | 2 | u16 | `imageCount` | number of image-table entries, `1...16` |
| 54 | 4 | u32 | `imageTableSize` | exact sum of image entry sizes (§7) |
| 58 | 6 | u8[6] | `reserved1` | MUST be `0` (`E009` if non-zero) |

The header is **not** covered by `payloadChecksum`; every header field is validated independently
and the identity fields are also compared with the running system and with the bundle entry (§8).
A decoder MUST reject a header byte that violates a rule in this section before looking at any
table.

### 3.1 `build`

Fixed-width, NUL-padded ASCII string, not a C string by accident:

- holds `1...15` bytes from the alphabet `[0-9A-Za-z._-]`;
- the first byte after the string is `0x00`; every byte after that first NUL is `0x00`;
- MUST equal the running `kern.osversion` read by the consumer. The `NRedSystemBuild` property
  injected next to the bundle is an injection-time sanity hint only and never overrides the actual
  running build. Comparison is exact byte equality after NUL trimming: no prefix match, no "nearest
  build", no Darwin-major fallback.

A profile for `24H232` stores `32 34 48 32 33 32 00 00 ...` and is only usable on build `24H232`.

### 3.2 `apuMask`

One bit per APU family known to the mainline kext; non-zero and subset of bits 0–5 in v3. The
consumer accepts a profile only when `(profile.apuMask & runningApuMask) != 0`. The bundle entry
carries the same mask (§8); both must agree.

| Bit | Mask | Family |
| --- | --- | --- |
| 0 | `0x01` | Raven |
| 1 | `0x02` | Raven2 |
| 2 | `0x04` | Picasso |
| 3 | `0x08` | Renoir |
| 4 | `0x10` | RenoirE |
| 5 | `0x20` | Green Sardine |

Candidate mask derivation (runtime; same rule as mainline `selectPatchSet`):

| PCI device ID | Candidate family bits |
| --- | --- |
| `0x15DD` Raven | bit 0 |
| `0x15D8` Raven2/Picasso | bits 1 and 2 (STRAP0 may narrow to bit 2) |
| `0x1636`, `0x164C` Renoir/Cezanne | bits 3 and 4 (STRAP0/PCI revision may narrow) |
| `0x15E7`, `0x1638` Barcelo/Green Sardine | bits 3 and 5 |
| anything else | empty set → profile never matches (`NoOp`) |

The exact per-device narrowing rule is mainline behavior, not part of the binary format. "Cannot
determine the running family" means "do not apply".

### 3.3 `deviceID`

`deviceID` is the iGPU PCI device ID (`0x15DD`, `0x1638`, …) in its low 16 bits; bits 16–31 MUST be
`0` (`E007`).

- `0`: no device-ID gate. The profile may be selected on any device whose APU mask intersects.
- `1...0xFFFF`: exact gate. The consumer accepts only when `deviceID == runningDeviceID`; if the
  running ID is unavailable, no patch is applied.

v3 has no header `flags` field: the gate is expressed by the value itself, so there is no silent
wildcard. `deviceID` and `apuMask` are independent gates; both configured gates must pass. They are
selection/safety gates, not page identity (page identity is content, §5).

### 3.4 Counts and table sizes

`pageCount` MUST be `1...256`; `siteCount` MUST be `1...1024`; `imageCount` MUST be `1...16`.
An empty profile (zero pages, zero sites or zero images) is invalid: "no patches" is expressed by not
injecting a profile, never by an empty one. `pageTableSize`, `siteTableSize` and `imageTableSize`
MUST equal the exact derived values; a mismatch is a decode error (`E011`, `E012`, `E036`).

## 4. Page records (32 bytes each, page table order)

| Offset (record) | Size | Type | Field | Required value / meaning |
| --- | --- | --- | --- | --- |
| 0 | 8 | u64 | `pageFileOffset` | diagnostic pager/file offset, 4 KiB aligned; **not identity** |
| 8 | 8 | u64 | `pageHash` | FNV-1a-64 over the complete 4096-byte clean page (§1.1) |
| 16 | 4 | u32 | `firstSite` | index of this page's first site in the site table |
| 20 | 2 | u16 | `siteCount` | sites of this page, `1...64` |
| 22 | 1 | u8 | `mode` | patch mode (§4.2): `1` PAGE, `2` DYLD; `3` RESOLVER is reserved |
| 23 | 1 | u8 | `flags` | reserved in v3, MUST be `0` (`E038` if non-zero) |
| 24 | 2 | u16 | `imageIndex` | index into the image table, `< imageCount` |
| 26 | 2 | u16 | `reserved` | MUST be `0` (`E038` if non-zero) |
| 28 | 4 | u32 | `pageVmOffset` | diagnostic evidence: page start VA minus image `imageUnslidVmaddr`, 4 KiB aligned |

`pageFileOffset` and `pageVmOffset` are **diagnostic evidence only** and are never compared with any
runtime value. They are still canonical fields: the generator derives them from the parsed image and
a decoder validates their geometry so a malformed generator cannot record misleading evidence.

- `pageFileOffset` MUST be 4 KiB aligned (`E017`). `0` is a legal value (e.g. page 0 of a standalone
  image); it means "page at file offset 0", not "unknown".
- `pageVmOffset` MUST satisfy `pageVmOffset & 0xFFF == 0` and
  `pageVmOffset + 4096 <= image.imageVmSize` (`E040`). The consumer never uses it for matching.
- `pageHash` is any u64 value, including `0`; the only way to validate it is against page content.

### 4.1 Site range

`firstSite` and `siteCount` MUST describe a canonical contiguous slice of the site table: page `i`
starts where page `i-1` ended (`firstSite == sum of siteCount of pages 0...i-1`), and the pages
together account for exactly header `siteCount`. Pages and sites appear in generator order; there is
no interleaving or ordering freedom. Each site belongs to exactly one page.

### 4.2 Modes

| Mode | Value | Name | Route | Image kind |
| --- | --- | --- | --- | --- |
| `1` | `0x01` | PAGE | `_cs_validate_page` (standalone file-backed vnode) | `0` standalone-file |
| `2` | `0x02` | DYLD | `_cs_validate_range` (dyld shared cache) | `1` dyld-shared-cache |
| `3` | `0x03` | RESOLVER | reserved, not implemented in v3 | — |

Rules:

- Every v3 page record MUST have mode `1` or `2`; mode `3` and any other value are invalid (`E018`).
  Mode `3` is reserved for a future resolver path and MUST NOT be emitted by a v3 generator.
- `mode == PAGE` requires the referenced image to have `kind == standaloneFile (0)`;
  `mode == DYLD` requires `kind == dyldSharedCache (1)`. A mismatch is `E019`.
- Mode determines the **matching domain**: a PAGE record can only be applied from the page-validation
  hook, a DYLD record only from the range-validation hook (§6). The two domains are disjoint.
- Mode is metadata for routing/vnode gating only. It never weakens identity: every applied page
  still requires full-page hash equality plus all site `find` matches.

### 4.3 Identity (no offset requirement)

NRPT v3 page identity is exactly:

```
fnv1a64(entire 4096-byte delivered chunk) == pageHash
and, for every site of the record: memcmp(chunk + siteInPage, find, findSize) == 0
```

There is no offset comparison and no per-page match-flags word in v3. `pageFileOffset`,
`pageVmOffset`, `imageIndex` and `mode` do not participate in identity; they select the matching
domain, route and evidence. This mirrors the native backend behavior that a full 4 KiB page image
(here: its FNV-1a-64 hash plus every site) is the identity, not the pager offset.

## 5. Site records (40 bytes each, site table order)

| Offset (record) | Size | Type | Field | Required value / meaning |
| --- | --- | --- | --- | --- |
| 0 | 2 | u16 | `siteInPage` | byte offset from the page base, `0x0000...0x0FFF` |
| 2 | 1 | u8 | `findSize` | number of significant `find` bytes, `1...16` |
| 3 | 1 | u8 | `replaceSize` | number of significant `replace` bytes, `1...16`, MUST equal `findSize` |
| 4 | 16 | u8[16] | `find` | expected current bytes, zero-padded after `findSize` |
| 20 | 16 | u8[16] | `replace` | bytes to write, zero-padded after `replaceSize` |
| 36 | 4 | u32 | `flags` | reserved, MUST be `0` |

Rules (identical to the frozen site contract, unchanged in v3):

- `siteInPage + findSize <= 4096` (and with equal sizes the same bound for `replace`). No site may
  straddle a page end.
- `findSize == replaceSize` (`E025` if different). A patch replaces a byte sequence in place; the
  generator's semantic transform preserves instruction length and includes padding in `replace`.
- Unused bytes in `find[16]` after `findSize`, and in `replace[16]` after `replaceSize`, MUST be `0`
  (`E027`).
- `find != replace`; a no-op site is invalid (`E028`).
- `siteInPage` is authoritative: the consumer verifies `find` at exactly that offset and then writes
  `replace` there. It MUST NOT scan the page for the pattern and MUST NOT require uniqueness.
- Two sites on the same page MUST NOT have overlapping write ranges
  `[siteInPage, siteInPage + replaceSize)` (`E030`). Different pages may share offsets.
- Site `flags` MUST be `0` (`E029`).
- The site table is verified as a whole: if any site of the identity-matching record does not match
  its `find`, the consumer performs **zero** writes for that page; partial application is forbidden.

## 6. Canonical layout, limits and uniqueness

### 6.1 Layout

1. `size == 64 + 32 * pageCount + 40 * siteCount + imageTableSize` and `size <= 65536`.
2. Page records are in generator order; site records follow the page table, grouped contiguously by
   page in the same order.
3. The image table follows the site table; entries are concatenated in generator order with no gaps.
4. Every deterministic input produces byte-identical output (no timestamps, paths relative to the
   machine, random values or map ordering).

### 6.2 Limits

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
| `deviceID` | `0` or `1...0xFFFF`; bits 16–31 zero |
| `imageCount` | `1...16` |
| image path length | `1...200` printable ASCII bytes, first byte `/` |
| `imageTableSize` | `<= 3520` bytes (`16 * (16 + 204)`) |
| image `vmSize` | `1...0xFFFFF000` |
| bundle entries | `1...16` profiles |
| page mode | `1` or `2` (any other value rejected) |
| page `flags`, page `reserved` | `0` |
| image entry `reserved` byte | `0` |
| header bytes 48–51 and 58–63 | `0` |
| site `flags`, unused `find`/`replace` padding | `0` |

The maximum legal v3 profile is `64 + 256*32 + 1024*40 + 3520 = 52736` bytes, below the 64 KiB
ceiling. The ceiling is checked before any table parsing so a malformed size field cannot drive large
allocations.

### 6.3 Uniqueness

- **Duplicate page identity** (`E031`): two page records MUST NOT have the same `pageHash` in the
  same `mode`. A content-identical page cannot be patched by two different records of one matching
  domain; the generator must merge or fail.
- The same `pageHash` in **different** modes is allowed: PAGE and DYLD are disjoint matching
  domains, so the two records can never both match the same delivered chunk.
- Different hashes may share `pageFileOffset`/`pageVmOffset`/`imageIndex`; those are evidence only.
- **Duplicate image path** (`E039`): two image entries MUST NOT share `(kind, path)`.
- The generator must additionally ensure, from the target it parsed, that no unintended page of the
  target matches a record's identity; that is a producer/offline-validator obligation (§9, §10).

## 7. Image table entries (variable size, in generator order)

```
ImageEntryHeader (16 bytes)
  0   u8   kind               0 = standalone file-backed dylib, 1 = dyld shared cache image
  1   u8   reserved           MUST be 0
  2   u16  pathLength         path byte count, 1...200 (NUL terminator not counted)
  4   u64  imageUnslidVmaddr  evidence: unslid VM address of the image's mach header (__TEXT vmaddr)
  12  u32  imageVmSize        __TEXT vmsize: bound for pageVmOffset; 1...0xFFFFF000
then
  path bytes (exactly pathLength printable ASCII bytes, first byte '/'),
  NUL terminator followed by zero padding to a 4-byte boundary.
```

```
entrySize = 16 + roundUp4(pathLength + 1)
imageTableSize = sum(entrySize for every image)
roundUp4(n) = (n + 3) & ~3
```

- `kind` MUST be `0` or `1`; `reserved` MUST be `0`; `pathLength` MUST be `1...200`; all entry
  header violations are `E035`.
- Paths are absolute canonical installed paths derived from the parsed target image (the generator
  strips fixture-root prefixes so the bytes are identical on every host). Empty, longer-than-200,
  non-printable or non-absolute paths are `E037`.
- `kind == 1` (dyld shared cache) requires `imageUnslidVmaddr != 0`; `kind == 0` (standalone)
  normally stores `0` and the consumer locates it by path basename. `imageVmSize` MUST be
  `1...0xFFFFF000`. Invalid geometry is `E041`.
- Segment and section name tables are **not** part of v3: they were v2 evidence only. The image
  table is `kind` + `path` + `imageUnslidVmaddr` + `imageVmSize`; the generator keeps deeper evidence
  in its JSON report.
- The image table is deterministic: entries appear in the generator's first-discovery order and
  identical inputs produce a byte-identical table.
- The consumer uses `kind` and `path` for the mode/vnode gate (§6 runtime) and `imageVmSize` to bound
  the diagnostic `pageVmOffset`; it never uses `imageUnslidVmaddr` for matching.

## 8. `NRedProfiles` bundle (Info.plist property)

Multiple profiles coexist in one injected property. The property is the **`NRedProfiles` array**
(OSArray) of dictionaries (OSDictionary) on the `org.ChefKiss.NootedRedUserPatch` personality of
`NootedRedUserPatch.kext`:

```
NRedProfiles = [
    {
        "Build"    : <String>          # exact kern.osversion, e.g. "24H232"
        "APUMask"  : <Integer>         # non-zero, subset of 0x3F
        "DeviceID" : <Integer>         # 0 = no device gate, 1...0xFFFF = exact gate
        "Profile"  : <Data>            # complete NRPT v3 profile bytes (this document)
    },
    ...
]
```

Rules:

- The property MUST contain `1...16` entries (`E050`). Every entry MUST contain exactly these four
  keys (`E053`); unknown keys are invalid (`E053`), so a typo cannot silently disable a gate.
- `Build` MUST be a valid build string (§3.1) and MUST be **unique** across entries (`E051`). Build
  is the bundle's primary key: multiple builds coexist; a build selects at most one profile.
- `APUMask` MUST be a 32-bit unsigned integer that is non-zero and a subset of `0x3F`; `DeviceID`
  MUST be a 32-bit unsigned integer `0...0xFFFF`.
- `Profile` MUST be a valid NRPT v3 profile (`E001...E041`). Its header identity MUST equal the entry
  metadata: `profile.header.build == Build`, `profile.header.apuMask == APUMask`,
  `profile.header.deviceID == DeviceID` (`E052`).
- Profiles in different entries may share pages/sites; only the selected profile is ever used.
- The property is bounded: at most 16 entries and each profile at most 64 KiB. The consumer copies
  only the selected, validated profile into static storage.

### 8.1 Exact selector semantics

The consumer resolves the running identity (actual running `kern.osversion`, running APU family mask,
running PCI device ID; bounded retry allowed, guessing forbidden), validates the bundle, and selects
exactly one entry:

```
for entry in bundle:
    if entry.Build is not byte-equal to the running build: continue    # exact, no prefix
    if (entry.APUMask & runningApuMask) == 0: continue                 # intersection required
    if entry.DeviceID != 0 and entry.DeviceID != runningDeviceID: continue
    select entry

if no entry remains:
    NoOp (unsupported build / family / device); never fall back to another entry or profile
```

Because `Build` is unique, at most one entry can pass the build test; there is therefore **no
first-match, priority or ambiguity rule**. If that entry's APU/device gates fail, the bundle is a
`NoOp` for this machine even if another entry would have matched the APU mask — there is no
cross-build or cross-device fallback.

### 8.2 Provisional selection before the build is readable

`kern.osversion` may not be readable at the time the plugin loads (it is published by userspace
later in boot). A consumer MAY begin matching provisionally only under all of these constraints;
otherwise it MUST wait and apply nothing:

1. the bundle is structurally valid (§8) and the consumer has a concrete running APU family mask and
   (when any entry requires it) device ID;
2. **exactly one** bundle entry passes the APU-intersection and device gates when the build test is
   ignored; zero candidates or more than one candidate means wait — never pick one by order,
   priority or nearest build;
3. matching uses the normal mandatory identity (full-page FNV-1a-64 hash + every site `find`) and the
   normal mode/route rules, so a page of a different build cannot be written unless its complete
   4 KiB content is byte-identical, in which case the patch semantics are valid for that content;
4. the provisional state is surfaced in diagnostics (`IdentityProvisional = 1`, selected build and
   the fact that it is unconfirmed);
5. when the actual running build becomes readable, the consumer re-runs the exact selector (§8.1):
   - actual build == provisionally selected entry's `Build`: confirm the profile, clear
     provisional state, continue normally;
   - actual build differs: enter a hard error state, publish both builds and the mismatch, **stop
     all further matching and writes** (pages already applied stay applied; no rollback, because
     they matched byte-exact content), and never fall back to another entry;
6. if no actual build becomes readable within the consumer's bounded retry window, the plugin ends
   as fail-closed `NoOp`/`BuildUnavailable` (no new writes).

Provisional selection never overrides a header/bundle identity check: it only allows content
matching to start before the build string is available. The final state is always determined by the
actual running build.

After selection the consumer MUST:

1. reject the whole bundle if the selected entry fails any structural rule (`E001...E041`, `E050,
   E051, E052, E053`) or if any other entry fails structurally (the bundle is validated as a whole);
2. verify the running identity against the selected profile header again (§3.1–§3.3);
3. only then enable page matching.

`NRedSystemBuild` remains an injection-time hint: it MUST be ignored for acceptance, may only be
used as a diagnostic/sanity check, and a mismatch with the running build is logged, not patched
around. There is no `NRedOffsetProfile` single-profile property in v3.

## 9. Runtime matching algorithm

The consumer validates the bundle and copies the selected profile before any validation hook can
run. Hooks are hook-only: no threads, no workers, no direct `vm_map_*` patching.

For every delivered 4 KiB chunk `data[0..4096)` with base offset `chunkBase` (diagnostic only):

```
eligibleModes = page-validation hook ? {PAGE} : range-validation hook ? {DYLD} : {}

for pageIndex in 0 ..< pageCount:                       // profile table order
    record = pages[pageIndex]
    if record.mode not in eligibleModes: continue

    // Optional vnode gate (defense in depth, never identity):
    if consumer has a vnode name for this chunk and mode/image gate is enabled:
        if not mode_image_gate_accepts(record, vnodeName): continue

    if fnv1a64(data, 4096) != record.pageHash: continue

    // Identity matched: this record is authoritative for this chunk.
    if record's applied bit is set: stop (already applied once this boot; no write)
    for each site: if memcmp(data + siteInPage, find, findSize) != 0:
        FindMismatches++; stop (zero writes; no other record, no scan)

    if MachInfo::setKernelWriting(true) fails: WriteFailures++; stop
    for each site: memcpy(data + siteInPage, replace, replaceSize)
    restore kernel write protection
    set the applied bit; AppliedPages++
    break

// No original-page identity matched: detect an already-patched delivery.
for pageIndex in 0 ..< pageCount:
    record = pages[pageIndex]
    if record.mode not in eligibleModes: continue
    // optional vnode gate as above
    if every site's replace bytes are already present at siteInPage:
        set the applied bit; AlreadyPatched++; stop (never write)
```

Contract properties:

- **No offset comparison anywhere.** `pageFileOffset`, `pageVmOffset` and `chunkBase` are never used
  for acceptance or rejection.
- The first record whose `(mode in eligibleModes, pageHash)` matches is authoritative. A site find
  failure aborts that chunk with zero writes; no fall-through, no scanning for another occurrence,
  no site masking.
- All sites of a page are written together after all checks pass; partial page writes are forbidden.
- A record is applied at most once per boot (bounded bitmap, one bit per page record). The
  already-patched pass never writes; it only marks the record and increments a counter.
- Writes happen only after the original validator accepted the page (§10); the hook return value is
  never modified by a patch attempt. Counters/logging are bounded; hooks do no allocation, VFS,
  IORegistry or sleeping.
- Mode-domain filtering is mandatory: a PAGE record is never considered by the range hook and a
  DYLD record is never considered by the page hook.

### 9.1 Delivery contexts and vnode gate

- `_cs_validate_page`: one validated page (4096 bytes expected), page-validation hook; contributes
  the `PAGE` matching domain. Patch only when the original result says the page was accepted
  (`*validated != 0` on macOS 15; see `analysis/xnu-lilu-page-validation.md`).
- `_cs_validate_range`: bytes are processed as consecutive 4 KiB chunks in ascending order, range
  hook; contributes the `DYLD` matching domain. Only whole chunks are processed; a trailing partial
  chunk is ignored.
- The vnode name gate is **defense in depth**, not identity: when the consumer can resolve the hook's
  vnode name, it MUST enforce mode-consistent acceptance — a PAGE record's image must be a
  standalone image whose path basename appears in the vnode name; a DYLD record's vnode must be a
  dyld-shared-cache vnode (name contains `dyld_shared_cache` or `dyld`). When the resolver is not
  available, matching proceeds with the mandatory hash+site identity and the consumer reports
  `VnodeGate = 0`; absence of the gate never weakens the content check.
- Both hooks may run in memory-object/code-signing context: the profile MUST already be copied into
  static memory; no hook may touch the original injected `OSData` bytes.

## 10. Fail-closed semantics

1. **Whole-bundle rejection.** If any rule in this document fails, the consumer MUST reject the whole
   bundle: no partially parsed entry, no partially parsed profile, no hook matching. Log one specific
   reason (`E0xx` + short field context) and stay `NoOp`.
2. **One profile only.** Exactly one bundle entry may be selected; no fallback to another profile,
   build, device, family, embedded data, boot argument or heuristic. A newer/older macOS build is
   unsupported, not approximated.
3. **Unresolvable identity means no patch.** If the running build, APU family or (when configured)
   device ID cannot be established, nothing is applied. Bounded retry is allowed; guessing is not.
   The only exception is the explicitly bounded provisional mode of §8.2, which requires a unique
   APU/device candidate, keeps the full content identity, and is revoked on a final build mismatch.
4. **Page-level failure is local.** A hash mismatch or site find mismatch means "not ours": zero
   writes, normal validation continues, the code-signing result is unchanged, nothing panics.
5. **No partial page writes.** All checks precede all writes; any failure before the write loop means
   no site of that page is written.
6. **No re-matching after a failed identity.** Once a record's hash matches, a site mismatch ends
   processing for that chunk (no substitute record, no scan, no repair).
7. **Deterministic bytes.** Profiles and bundle plist output are pure functions of their inputs.

## 11. Validation errors

Decoders (host codec and kext parser) MUST report one of these stable codes with context. A code is
either a structural decode error (whole profile/bundle rejected) or a generator/model error (encode
refused in full); in both cases nothing is written or applied.

| Code | Name | Rule |
| --- | --- | --- |
| `E001` | `truncated` | profile shorter than the 64-byte header |
| `E002` | `badMagic` | bytes 0–3 are not `"NRPT"` |
| `E003` | `unsupportedVersion` | `version != 3` (v1/v2 rejected) |
| `E004` | `invalidHeaderSize` | `headerSize != 64` |
| `E005` | `invalidBuild` | build empty, >15 bytes, forbidden character, missing NUL padding, or non-zero after the first NUL |
| `E006` | `invalidApuMask` | mask zero or with a bit outside 0–5 |
| `E007` | `invalidDeviceID` | `deviceID > 0xFFFF` (bits 16–31 non-zero) |
| `E008` | `reservedHeaderFieldNotZero` | header bytes 48–51 non-zero (v3 has no header flags) |
| `E009` | `reservedHeaderBytesNotZero` | header bytes 58–63 non-zero |
| `E010` | `profileTooLarge` | computed or actual size exceeds 64 KiB |
| `E011` | `pageTableSizeMismatch` | `pageTableSize != pageCount * 32` |
| `E012` | `siteTableSizeMismatch` | `siteTableSize != siteCount * 40` |
| `E013` | `totalSizeMismatch` | actual length differs from `64 + pageTableSize + siteTableSize + imageTableSize` |
| `E014` | `payloadChecksumMismatch` | FNV-1a-32 over bytes `[64, size)` differs from `payloadChecksum` |
| `E015` | `pageCountOutOfRange` | `pageCount > 256` (zero pages is `E032`) |
| `E016` | `siteCountOutOfRange` | `siteCount < 1` or `> 1024` |
| `E017` | `pageFileOffsetMisaligned` | a diagnostic `pageFileOffset` has non-zero low 12 bits |
| `E018` | `unsupportedPageMode` | page `mode` is not `1` or `2` (mode `3` RESOLVER is reserved) |
| `E019` | `pageModeImageKindMismatch` | PAGE mode without a standalone image kind, or DYLD mode without a shared-cache image kind |
| `E020` | `pageSiteRangeInvalid` | a page's `firstSite + siteCount` overflows or exceeds header `siteCount` |
| `E021` | `nonCanonicalSiteRange` | a page's `firstSite` is not the running sum of preceding page site counts |
| `E022` | `siteCountSumMismatch` | sum of page site counts differs from header `siteCount` |
| `E023` | `sitesPerPageExceeded` | a page has `0` sites or more than `64` sites |
| `E024` | `invalidSitePatchSize` | `findSize` or `replaceSize` is `0` or `>16` |
| `E025` | `findReplaceSizeMismatch` | `findSize != replaceSize` |
| `E026` | `siteOutOfPageBounds` | `siteInPage + size > 4096` |
| `E027` | `sitePaddingNotZero` | a `find`/`replace` byte after the declared size is non-zero |
| `E028` | `noOpSite` | `find` and `replace` are byte-identical over `findSize` bytes |
| `E029` | `unsupportedSiteFlags` | site `flags != 0` |
| `E030` | `overlappingSiteWrites` | two sites on one page have overlapping write ranges |
| `E031` | `duplicatePageIdentity` | two records share `pageHash` in the same `mode` |
| `E032` | `emptyProfile` | `pageCount == 0` |
| `E033` | `invalidPageSize` | `pageHash` helper input is not exactly 4096 bytes (codec precondition) |
| `E034` | `invalidImageCount` | `imageCount < 1` or `> 16`, or `imageTableSize` outside the format bound |
| `E035` | `invalidImageEntry` | malformed entry header: reserved non-zero, pathLength out of range, bad NUL/padding |
| `E036` | `imageTableSizeMismatch` | `imageTableSize` differs from the sum of parsed entries |
| `E037` | `invalidImagePath` | empty, >200, non-printable or non-absolute image path |
| `E038` | `invalidPageMetadata` | page `flags`/`reserved` non-zero, or `imageIndex >= imageCount` |
| `E039` | `duplicateImagePath` | two image entries share `(kind, path)` |
| `E040` | `invalidPageVmOffset` | `pageVmOffset` unaligned or `pageVmOffset + 4096 > imageVmSize` |
| `E041` | `invalidImageGeometry` | image `kind` outside 0–1, `vmSize` out of range, or shared-cache unslid address zero |
| `E050` | `bundleCountOutOfRange` | bundle entry count outside `1...16` |
| `E051` | `duplicateBundleBuild` | two bundle entries share the same `Build` |
| `E052` | `bundleEntryProfileMismatch` | entry `Build`/`APUMask`/`DeviceID` differ from the embedded profile header |
| `E053` | `invalidBundleEntry` | missing/unknown/wrong-typed `NRedProfiles` dictionary key or value |

Error messages are diagnostics only; the code names are stable.

Runtime (non-fatal) counters, separate from validation: `AppliedPages`, `AlreadyPatched`,
`FindMismatches`, `HashMismatches`/`MatchedPages`, `VnodeGate`, `PageHook`/`RangeHook`,
`SelectedProfileBuild`, `ProfileCount`, `ModePageCount`/`ModeDyldCount`. They never turn a valid
validator result into a failure.

## 12. Producer (generator) contract

The generator produces a profile only from a parsed target image; it MUST fail generation (emit no
profile) on any ambiguity. It must not contain hardcoded addresses, find/replace bytes or page
offsets, and must not fall back to byte scanning outside a parsed function.

For every discovered site it must have:

1. the parsed function extent (symbol/ObjC metadata + CFG validation) containing the instruction;
2. a decoded, semantically matched instruction or instruction sequence with exactly one match in that
   function (one unambiguous site), failing generation otherwise;
3. `siteInPage` = the exact byte offset of the instruction(s) inside the 4 KiB page;
4. `find` = exact current instruction bytes in the clean page at that offset; `replace` = transformed
   bytes, equal length, differing from `find`;
5. the clean page bytes from the parsed image and `pageHash = FNV-1a-64(pageBytes)` over all 4096
   bytes;
6. `mode`: `PAGE` for a page of a standalone file-backed image, `DYLD` for a page of a dyld
   shared-cache image (derived from `kind`, never guessed);
7. `imageIndex`, `imageUnslidVmaddr`, `imageVmSize`, `path` derived exclusively from the parsed
   image; `pageVmOffset = pageStartVA - imageUnslidVmaddr` (4 KiB aligned, within `imageVmSize`);
   `pageFileOffset` = the best available pager/file offset evidence (4 KiB aligned, diagnostic only);
8. header identity: `build` = exact target `kern.osversion`, `apuMask` = union of validated
   families, `deviceID` = `0` or the exact target device ID;
9. proof that no unintended page of the target image matches the record's identity, so generation is
   unambiguous.

The profile bytes MUST come from the canonical encoder (`ProfileCodec.encode` or a byte-identical
implementation). The generator keeps a JSON evidence report (parsed function, matched instruction,
mode, target kind/path, page hash, pageVmOffset, validation result). Hand-editing profile bytes is
forbidden.

Bundle generation (multi-build coexistence): each generated profile becomes one `NRedProfiles`
entry with its Build/APUMask/DeviceID metadata equal to its header, encoded by
`ProfileCodec.encodeBundlePlist` (or `nredProfilesArray` when injecting into an existing
`Info.plist`). Builds MUST be unique; a generator that would emit two entries for one build must fail
instead. Output must be deterministic and re-decoded/validated before injection.

After encoding, the generator MUST run the offline validator (§13) on the clean fixture; a profile
that does not reproduce every intended site, or that matches any unintended page, must not be
committed or deployed.

## 13. Offline validator contract

The offline validator applies a profile to a clean fixture using the pure codec simulation:
`applyPage(profile, data:, mode: .page/.dyld)`, `pageMatches`, `applySites`, and the same
first-identity-match/atomic-page rule and already-patched pass as §9. It MUST report, per page and
per site:

- the page `mode`, `imageIndex`, target image kind/path, `pageVmOffset` and `pageHash`;
- whether full-page hash identity matched and whether every site `find` matched;
- the bytes that would be written and the resulting page hash;
- whether any fixture page other than the intended one matches a record identity in its mode
  (false-positive check, including the duplicate-content subcache cases);
- header identity and bundle selector result for the target (build/APU/device);
- overall PASS/FAIL.

A profile is deployable only when every intended page matches/applies in its own mode and no
unintended fixture page matches. The validator must not repair a profile (no flag rewriting, no
offset patching, no site masking, no mode rewriting).

## 14. Kernel consumer contract

- Read the `NRedProfiles` array from the injected personality property during plugin start, before
  any page-validation hook can run. Validate the whole bundle and select exactly one profile,
  applying §8 and §3.1–§3.3 identity gates. Copy the selected profile into bounded static storage
  (≤64 KiB, static arrays within the §6.2 limits); do not reference the `OSData` afterwards.
- Remove/ignore the injected property after copying. No file I/O, no IOKit reads inside hooks; all
  profile parsing happens in sleepable start/retry contexts.
- Parse and validate every §2–§7 rule, including `payloadChecksum`, image table sizes and mode/image
  consistency. On any failure: keep the plugin loaded, report `NoOp` with the specific `E0xx` code,
  and never match or write. No partial state may survive a rejected bundle.
- Register both hooks (`_cs_validate_page`: 7-argument `void` with `int *validated/*tainted/*nx` on
  macOS 15; `_cs_validate_range`: 6-argument `boolean_t`) and enforce the mode-domain split. Patch
  only after the original validator accepted the page.
- Enforce full-page FNV-1a-64 + all site finds; no offset comparison and no match-flags logic. No
  allocation, VFS, IORegistry, sleeping or unbounded logging in either hook. Use
  `MachInfo::setKernelWriting` only around the actual writes; a failure to enable/restore kernel
  writing is fail-closed (no write / stop further writes).
- Implement the already-patched pass from §9 (mark applied, never write) for idempotence across
  shared page cache deliveries.
- The binary must contain no page offsets, page hashes, find/replace constants, page tables or
  per-build data beyond the generic parser/matcher (v1 audit check from
  `analysis/lilu-dyld-shared-cache-profile-engine.md` §2.4).
- Diagnostics are bounded: `SelectedProfileBuild`, `ProfileCount`, mode counts, `VnodeGate`,
  `AppliedPages`, `AlreadyPatched`, `FindMismatches`, `WriteFailures`, hook availability and
  per-page applied bits.

## 15. Codec API (`ProfileCodec.swift`)

`ProfileCodec` is a pure Swift file (Foundation only, no I/O) and is the reference implementation of
this specification. The public surface is:

```swift
enum NRPTFormat { /* magic, version 3, sizes, limits, header/page/image offsets, bundle constants */ }

enum NRPTPageMode: UInt8 { case page = 1; case dyld = 2; case resolver = 3 }   // resolver reserved
enum NRPTImageKind: UInt8 { case standaloneFile = 0; case dyldSharedCache = 1 }

struct NRPTSite  { var siteInPage: UInt16; var find: [UInt8]; var replace: [UInt8]; var flags: UInt32 }
struct NRPTImage { var kind: NRPTImageKind; var path: String;
                   var unslidVMAddress: UInt64; var vmSize: UInt32 }
struct NRPTPage  { var pageFileOffset: UInt64; var pageHash: UInt64; var mode: NRPTPageMode;
                   var imageIndex: UInt16; var pageVmOffset: UInt32; var sites: [NRPTSite] }
struct NRPTHeader { var build: String; var apuMask: UInt32; var deviceID: UInt32 }
struct NRPTProfile { var header: NRPTHeader; var images: [NRPTImage]; var pages: [NRPTPage] }

struct NRedProfilesEntry  { var build: String; var apuMask: UInt32; var deviceID: UInt32;
                            var profile: NRPTProfile }
struct NRedProfilesBundle { var entries: [NRedProfilesEntry] }
enum NRedProfilesSelection: Equatable {
    case selected(index: Int, profile: NRPTProfile)
    case unsupportedBuild
    case apuMismatch
    case deviceMismatch
}

enum ProfileCodecError: Error, Equatable { case ... }      // stable E001...E053 via `code`

enum ProfileCodec {
    static func encode(_ profile: NRPTProfile) throws -> Data
    static func decode(_ data: Data) throws -> NRPTProfile
    static func validate(_ profile: NRPTProfile) throws

    static func validateBundle(_ bundle: NRedProfilesBundle) throws
    static func select(from bundle: NRedProfilesBundle, build: String,
                       runningApuMask: UInt32,
                       runningDeviceID: UInt16) throws -> NRedProfilesSelection
    static func provisionalCandidate(from bundle: NRedProfilesBundle, runningApuMask: UInt32,
                                     runningDeviceID: UInt16) throws -> NRedProfilesSelection?
    static func encodeBundlePlist(_ bundle: NRedProfilesBundle) throws -> Data
    static func decodeBundlePlist(_ data: Data) throws -> NRedProfilesBundle
    static func nredProfilesArray(_ bundle: NRedProfilesBundle) throws -> [[String: Any]]
    static func bundle(fromNRedProfilesArray: [[String: Any]]) throws -> NRedProfilesBundle

    static func fnv1a32(_ data: Data) -> UInt32
    static func fnv1a64(_ data: Data) -> UInt64
    static func pageHash(_ page: Data) throws -> UInt64
    static func payloadChecksum(pageTable: Data, siteTable: Data, imageTable: Data) -> UInt32

    static func pageMatches(_ page: NRPTPage, data: Data) -> Bool
    static func contentMatches(_ page: NRPTPage, data: Data) -> Bool   // hash-only evidence
    static func applySites(_ page: NRPTPage, to data: Data) -> Data
    static func applyPage(_ profile: NRPTProfile, data: Data,
                          mode: NRPTPageMode) -> NRPTPageApplication
}

enum NRPTPageApplication: Equatable {
    case noMatch
    case siteFindMismatch(pageIndex: Int, siteIndex: Int)
    case applied(pageIndex: Int, data: Data)
    case alreadyPatched(pageIndex: Int)
}
```

`encode` derives the header counts, table sizes and `payloadChecksum` from the arrays; a model can
never serialize inconsistent sizes. `decode` re-derives and cross-checks them. `encodeBundlePlist`
emits XML property-list bytes with the deterministic dictionary key order and the exact keys of §8;
`nredProfilesArray`/`bundle(fromNRedProfilesArray:)` convert between the model and the plist array so
tools can inject/extract the property in an existing `Info.plist`. All functions are sample-free:
they never require checked-in driver bytes.

## 16. Self-test expectations

The codec and the kext parser are expected to pass at least these tests (pure/offline; no Apple
driver binary needs to be committed):

1. FNV reference vectors: empty `0x811C9DC5` / `0xCBF29CE484222325`; `"a"` `0xE40C292C` /
   `0xAF63DC4C8601EC8C`; `"foobar"` `0xBF9CF968` / `0x85944171F73967E8`.
2. `pageHash` accepts exactly 4096 bytes and rejects 4095/4097 (`E033`).
3. Round trip: a multi-image profile (≥2 images, ≥2 pages, PAGE and DYLD modes) encode → decode is
   equal; repeated encodes are byte-identical; header/table bytes match the documented offsets
   (magic @0, version 3 @4, headerSize 64 @6, build @8, counts @32/34, checksum @44, imageCount @52,
   imageTableSize @54).
4. Size formula: `size == 64 + 32*pageCount + 40*siteCount + imageTableSize`; a 13-page/18-site
   profile with a known image table encodes to `64 + 416 + 720 + imageTableSize`.
5. Image table: entries encode as `kind, reserved 0, pathLength, unslid, vmSize, path, NUL+pad`;
   `imageTableSize` is the exact sum; a path of length 1/200 and the max 16 images encode; image
   table mismatch/reorder/duplicate path tests (`E034`, `E035`, `E036`, `E037`, `E039`, `E041`).
6. Modes: `PAGE` and `DYLD` round-trip; mode `3` and mode/image-kind mismatches are rejected
   (`E018`, `E019`); no offset field participates in matching: `applyPage` matches by content with no
   offset argument, and a wrong offset-evidence value changes nothing.
7. Identity/no-writes: `pageMatches` false on hash mismatch; one wrong `find` → `siteFindMismatch`
   and the returned page is unchanged (atomic); `applyPage` filters by mode; all-replace-bytes page
   returns `alreadyPatched` and never writes.
8. Every wire-rule code `E001...E041` has at least one crafted-byte mutation test of a valid profile
   asserting the specific code (bad magic/version/header size/build/padding, APU, device ID,
   reserved header fields, truncation/trailing data, table sizes, checksum, counts, page offset,
   mode, image kind, image metadata, image path/padding/geometry, duplicated images/identity, site
   size/bounds/padding/no-op/flags/overlap/site ranges, empty profile).
9. `encode` refuses invalid models with the same codes (257 pages, 1025 sites, 65 sites/page, 16-byte
   build, 17 images, 201-byte path, duplicate identity, mode 3, empty pages/images).
10. Bundle: `encodeBundlePlist`/`decodeBundlePlist` round trip is equal and deterministic; the
    emitted XML contains exactly `NRedProfiles` with dictionaries `Build`/`APUMask`/`DeviceID`/
    `Profile`; max 16 entries (`E050`); duplicate build (`E051`); metadata/header mismatch (`E052`);
    unknown/missing/wrong-typed keys (`E053`); `select` returns `.selected` for the exact matching
    build with intersecting APU mask and device gate, and `.unsupportedBuild`/`.apuMismatch`/
    `.deviceMismatch` fail-closed otherwise (a same-APU profile for another build is never selected).
11. The kext parser accepts exactly the codec's encodings (golden cross-implementation test) and
    rejects the same crafted profiles and malformed bundles; a malformed bundle produces `NoOp` with
    no writes.
12. A page that never matches any delivered page loads and simply contributes no applied page;
    malformed pools never write.

## 17. Versioning

- `version` is `3` for this layout. Any change to field meaning, order, offsets, sizes, flags,
  checksum algorithm, limits, canonical layout, modes, bundle schema or matching semantics requires a
  new version number.
- A v3 parser MUST reject every other version (`E003`); v1/v2 compatibility is explicitly dropped.
  `headerSize` exists so a future version can grow the header, but a v3 parser requires exactly 64.
- Every currently reserved byte/bit (header bytes 48–51 and 58–63, page `flags`/`reserved`, image
  entry `reserved`, site `flags`, `find`/`replace` padding) MUST be zero in v3. A future version may
  use them only after a version bump with a matching spec, codec, generator, validator, bundle tooling
  and kext update.
- `payloadChecksum` covers only the payload (page+site+image tables). Header identity bytes are
  validated field-by-field against the bundle entry and the running system.

## 18. Security considerations and non-goals

- FNV-1a is a non-cryptographic checksum/hash: a fast content-identity and accidental-corruption
  gate, not a security boundary. The trust boundary is the EFI partition / kext `Info.plist`: an
  attacker who can modify the injected bundle can already modify the kext. The format is nevertheless
  fully bounds-checked and fail-closed so corrupted or mis-generated data can never cause an
  out-of-bounds write or a wrong-image patch in kernel context.
- Page identity is full 4 KiB content (FNV-1a-64) plus every site `find`; the vnode gate is defense in
  depth only. The page hash is not a code-signing hash and does not replace the kernel's own
  validation; the plugin patches only after the original validator accepted the page.
- Mode separation means the page hook can never apply a DYLD record and the range hook can never
  apply a PAGE record; this is a routing invariant, not a weaker identity.
- Non-goals for v3: v1/v2 compatibility, offset-based identity or per-page match flags, direct-map /
  thread / worker patching (v3 is hook-only), the RESOLVER mode implementation, per-family page
  tables inside one profile (a bundle carries one profile per build; if one build ever needs
  per-device page tables that requires a new version), a driver image hash/signature field, site
  masks/wildcards, variable-length patches, pages larger than 4 KiB, or kernel-kext descriptors. A
  profile is immutable for the boot; there is no timestamp/generator-version field by design
  (determinism), so provenance lives in the generator's JSON evidence.

## 19. References

- `analysis/lilu-dyld-shared-cache-profile-engine.md` — target architecture, page-identity rationale
  and kext safety constraints.
- `analysis/xnu-lilu-page-validation.md` — macOS 15 `_cs_validate_page` / `_cs_validate_range` ABI
  and the 7-argument hook (kept in the working tree under `build/revert-backup/` if absent from
  `analysis/`).
- `docs/Profile-Engine-Validation.md` — offline validation report of the current profile.
- Apple TN3126, *Inside Code Signing: Hashes* — code-directory page hashes and 4 KiB page slots.
- FNV reference: Fowler–Noll–Vo hash function, FNV-1a 32/64 variants (offset basis `0x811C9DC5` /
  `0xCBF29CE484222325`, prime `0x01000193` / `0x100000001B3`).


## Consumer note (final hook-only NootedRedUserPatch)

The released consumer of this specification is hook-only: it enforces the strict mode-domain routing
of §9 (PAGE records only from `_cs_validate_page`, DYLD records only from `_cs_validate_range`) and the
full-page hash + all-site-finds identity of §4.3, and it does **not** implement the §9.1 vnode-name
gate or any pager-offset identity.  Pages whose workload never reaches their validator in a boot are
reported as *deferred* (`NRedUserPatchCoverage=workload-deferred`, `AppliedPageList`/`DeferredPageList`)
while the consumer remains `Loaded`/`Reason=None`; deferred pages are a normal workload state, not a
profile or identity failure, and the hooks stay armed for later validation.  A profile/bundle that
violates any structural rule is still rejected as a whole (NoOp, no writes).
