# Archived documentation

These documents describe the **previous** in-memory user-space patching architecture and the related
research/plans. They are kept for history and debugging context only. They are **not** current
implementation guidance.

The current architecture is:

- [Architecture](../ARCHITECTURE.md)
- [Root patch pipeline](../ROOT-PATCH-PIPELINE.md)

Why the old documents were archived:

- `Compatibility-Architecture.md`, `Patch-Architecture.md`, `Device-Profile.md`,
  `CONTRIBUTING-USERPATCHES.md` — describe the `_cs_validate_page` in-memory page-cache patcher, exact-page
  snapshots, resolver/semantic fallbacks and multi-version page tables that are being replaced by the
  kernel + root-patch architecture.
- `VDA-Implementation-Plan.md`, `VDA-Deployment.md` — in-memory VDA user-space flow; the kernel VCN bridge
  part remains relevant and is described in the current architecture.
- `Chromium-Fix-Usage.md` — end-user boot args for the in-memory GLFIX path; the new user-space payload flow
  will have its own usage instructions.
- `IGPU-HwInfo-Research-Plan.md`, `TESTER-GUIDE.md`, `Tahoe-26.7.1-Support.md` — historical research and
  test handoff notes.

The analyses under [`../../analysis/`](../../analysis/) are also historical research records. Some of them
describe data derivation that is still useful for payload generation, but their runtime patching
recommendations are superseded by the current architecture.
