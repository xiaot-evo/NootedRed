# NootedRed ![GitHub Workflow Status](https://img.shields.io/github/actions/workflow/status/ChefKissInc/NootedRed/main.yml?branch=master&logo=github&style=for-the-badge) [![Release Badge](https://img.shields.io/github/v/release/ChefKissInc/NootedRed?include_prereleases&style=for-the-badge&sort=semver&color=blue)](https://github.com/ChefKissInc/NootedRed/releases) [![Downloads Badge](https://img.shields.io/github/downloads/ChefKissInc/NootedRed/total?style=for-the-badge)](https://github.com/ChefKissInc/NootedRed/releases/latest) ![Written by humans, not AI](https://img.shields.io/badge/written_by_humans-not_ai-blue?style=for-the-badge)

> [!CAUTION]
> Please consider donating: donations help me stay alive and pay costs; if the Hackintosh projects don't receive funding, I will (have to) stop working on them.
>
> PayPal or credit/debit card: https://ko-fi.com/chefkiss
>
> BTC: `bc1qgu56kptepex2csuzl5nhzc4vxuj8c6ggjzhcem`
>
> SOL: `4PJU3iB5rimN9BNcpzduvmTnptJyedZiAd23so33SAdi`
>
> ETH: `0x038A25849c23Bc5A736484351a8B6Ad71bC46676`

The macOS kernel extension for GPU bug fixes, QoL improvements, and extended hardware support.

```
Copyright (C) 2022-2026  ChefKiss

Licensed under the ChefKiss Open Knowledge License version 1.

This work is licensed to you under the terms of the ChefKiss Open Knowledge
License, either version 1 of the License, or (at your option) any later
version published by ChefKiss.

This work may not be used to train or develop artificial intelligence,
and may not be used with artificial intelligence in any other way. See
the ChefKiss Open Knowledge License for details.

This work is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
ChefKiss Open Knowledge License for more details.

You should have received a copy of the ChefKiss Open Knowledge License
along with this work.  If not, see https://git.chefkiss.dev/ChefKiss/OpenKnowledge/raw/branch/master/LICENSE-v1.md.
```

> [!WARNING]
> This project is under active research and development; There will be crashes here and there, as the project is glue between the existing buggy AMD drivers.
>
> See repository issues and [our site](https://chefkiss.dev/applehax/nootedred) for more information.

## Documentation

- [Architecture](docs/ARCHITECTURE.md) — kernel plane vs root-patch plane, the research behind the
  redesign, data contracts, support policy and migration plan.
- [Compatibility matrix](docs/COMPATIBILITY.md) — per-build, per-APU status for GLFIX, VDA/VCN, and what
  macOS 26 does and does not support today.
- [Root patch pipeline](docs/ROOT-PATCH-PIPELINE.md) — design of the companion user-space patcher:
  versioned payloads, manifests, APFS snapshot install/revert, KDK/kmutil/cache handling and CI gates.
- [Build artifacts](docs/Build-Artifacts.md) — kext build layout and artifact locations.
- [Platform data index](docs/Platform-Data-Index.md) — collected platform data used to derive payloads.
- [Compatibility data collector](tools/README-collect-compat-data.md) — collect a target machine's
  drivers, kernel data, VDA data and capabilities for a new macOS/APU payload.
- [Archived documentation](docs/archive/README.md) — historical in-memory patching documents, kept for
  reference only.
- Research notes live in the local `analysis/` directory and are intentionally not tracked.

## Build artifacts

Use `tools/build-branch.sh -y` to put the kext and zip under
`build/branches/<branch>/...`. See [docs/Build-Artifacts.md](docs/Build-Artifacts.md).
