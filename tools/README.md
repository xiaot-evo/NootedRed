# tools/ — offscreen OpenGL blending probe (NootedRed #158)

`gl_blend_probe` is a small, self-contained CGL/OpenGL 4.1-core harness used to
investigate **NootedRed issue #158**: Chromium/Electron hardware acceleration
corruption and GPU resets caused by the user-space `AMDRadeonX5000GLDriver`
using Vega dGPU values on an AMD iGPU.

It renders into an FBO, reads the pixels back and compares them with a CPU
reference. It never edits files, never injects code, never opens a window and
never takes over the display. **It is still a GPU test on a machine whose GPU is
currently misbehaving — read the safety section before running it.**

Related local documents: `analysis/repro-plan.md` (full evidence + repro plan),
`Chromium-OpenGL-Issue-Report.md` (prior analysis, repository root).

## Files

| File | Purpose |
| --- | --- |
| `gl_blend_probe.c` | the probe (inspect / link / render modes) |
| `build.sh` | compiles it to `build/tools/gl_blend_probe` with `xcrun clang` |
| `README.md` | this document |

## Safety (read first)

Verified on the target machine (macOS 15.8.1, Renoir `0x1638`, NootedRed 0.9.0
loaded), 2026-10-18:

- a minimal CGL/FBO program **SIGSEGV'd on its first `glClear()`** in
  `AMDRadeonX5000GLDriver` at
  `glrAMD_GFX9_UpdateHwExportBlockState ← glrAMD_GFX9_UpdateDrawBufferInfo ←
  glrATI_Hwl_DrawableChanged ← glrBindContextDrawFramebuffer ←
  gldUpdateDrawFramebuffer ← gleUpdateDrawFramebufferState ← glClear_Exec`
  (`~/Library/Logs/DiagnosticReports/glblend2-2026-10-18-211253.ips`,
  and `glblend4-2026-10-18-211622.ips` with the identical stack);
- around the same time the system logged **12+ WindowServer / Electron GPU
  resets** in `/Library/Logs/DiagnosticReports/Kernel_*.gpuRestart`
  (AMD Radeon RX Renoir Graphics, `DID=0x1638`, restart channel 13/23 GFX).

The earlier probes created a GL context but no drawable; the crash happens in
the draw-framebuffer update path while `glClear` touches the *default* (invalid)
drawable. `gl_blend_probe --render` therefore attaches a **PBuffer drawable**
before clearing/drawing. That is safer, but not proven safe.

Rules:

1. `--inspect` (default) is the only mode allowed without Lead approval:
   CGL context + `glGetString` only. It has been run here without a new
   GPU-reset report being logged.
2. `--link` compiles and links shaders but submits no draw calls. It was run
   here without a new reset, but it does exercise the driver's compiler/state
   path; treat it as low-risk, not zero-risk.
3. `--render` refuses to start unless `--yes` is passed. Do not pass `--yes`
   without the Lead's explicit approval, a fresh reboot and a recovery plan.
4. On any GPU reset (new `*.gpuRestart` file), a display corruption event, a
   freeze, or a watchdog/SIGSEGV message: **stop**. Do not immediately retry.
   Reboot to a known-good state before continuing.

## Build

```sh
./tools/build.sh
```

Requirements: Xcode command line tools (`xcrun clang`, SDK with
`OpenGL.framework`), no Homebrew packages. The build does not touch the GPU.
`build/` is git-ignored.

## Usage

```sh
build/tools/gl_blend_probe --inspect            # safe: context + GL strings/extensions
build/tools/gl_blend_probe --exts               # inspect + full extension list
build/tools/gl_blend_probe --link               # + compile/link shaders, no draw calls
build/tools/gl_blend_probe --render --yes       # RISKY: FBO clear/draw/readback + CPU compare
build/tools/gl_blend_probe --render --yes --timeout 30
```

Exit codes: `0` success/all PASS (or only SKIPs), `1` no CGL pixel format/context,
`2` shader compile/link failure, `3` FBO incomplete, `10` rendered pixel mismatch,
`11` PBuffer drawable unavailable (no draw was attempted), `12` render refused
without `--yes`, `124` watchdog, `128+N` killed by signal N.

## Tests and expected values

Blue `(0,0,1,1)` is the FBO clear colour; a full-screen triangle is drawn.

| Case | Blend state | Fragment output | Expected pixel (RGBA8) |
| --- | --- | --- | --- |
| solid, no blend | blending off | `(1,0,0,1)` | `(255,0,0,255)` |
| classic alpha | `SRC_ALPHA / 1-SRC_ALPHA` | `(1,0,0,0.5)` | `(128,0,128,255)` |
| dual-source `SRC1_COLOR` | `SRC1_COLOR / 1-SRC1_COLOR` | `c0=(1,0,0,1)`, `c1=(0.25,0.5,0.75,1)` | `(64,0,64,255)` |
| dual-source `SRC1_ALPHA` | `SRC1_ALPHA / 1-SRC1_ALPHA` | `c0=(0.5,0.25,0.75,1)`, `c1=(0.25,0.5,0.75,0.5)` | `(64,32,223,255)` |

Tolerance is ±2 per channel. The dual-source cases are skipped when the driver
does not advertise `GL_ARB/EXT_blend_func_extended` or reports
`GL_MAX_DUAL_SOURCE_DRAW_BUFFERS == 0`.

A **dual-source mismatch** on the target machine is a strong repro signal: a
driver that silently ignores the index-1 output blends with `c0.a` instead
(for the `SRC1_ALPHA` case that yields `(128,64,191)` instead of `(64,32,223)`).

## Baseline on the target machine (2026-10-18, inspect + link only)

```
GL_VENDOR   = ATI Technologies Inc.
GL_RENDERER = AMD Radeon RX Renoir Graphics OpenGL Engine
GL_VERSION  = 4.1 ATI-7.0.25
GLSL        = 4.10
GL_ARB_blend_func_extended = present
GL_EXT_blend_func_extended = MISSING
GL_MAX_DRAW_BUFFERS = 8, GL_MAX_DUAL_SOURCE_DRAW_BUFFERS = 1, GL_MAX_COLOR_ATTACHMENTS = 8
extension count = 46
c1 bound to frag data index 1: yes
dual-source shaded linked: SRC1_COLOR ok, SRC1_ALPHA ok
```

Notes:

- `GL_ARB_blend_func_extended` present but `GL_EXT_blend_func_extended` missing
  independently reproduces the GLEW observation recorded in issue #158
  (2023-12-10 comment): the ARB entry points exist, the EXT alias does not.
- 46 extensions is tiny for a GL 4.1 driver; GLEngine filters what the AMD
  driver reports.
- **A PASS does not exonerate the driver.** This probe submits a simple
  single-draw sequence; Chromium reaches the same driver through ANGLE
  (`libGLESv2`/`libEGL`) with a very different pipeline/command pattern.
  A FAIL (crash, reset, or pixel mismatch) is much more informative than a PASS.

## What this harness does not do

- It does not run Chromium/ANGLE; use a real Electron/Chromium app for that
  (see the local `analysis/repro-plan.md` §4.8 for the app-level ladder).
- It does not patch or validate any candidate fix. Patch validation is
  approval-gated and should start with the user-space interposer described in
  local `analysis/repro-plan.md` §4.7.
- It does not read or write system files, kexts or the dyld shared cache.

## Recovery notes

If a run hangs, the shell may stay blocked inside the GL driver. Use another
terminal (or ssh) to kill it; if the display is corrupted, force-restart
WindowServer by logging out, or reboot with the power button as a last resort.
The GPU-reset reports in `/Library/Logs/DiagnosticReports` are the first thing to
collect after an incident (`*.gpuRestart`, `gl_blend_probe*.ips`).
