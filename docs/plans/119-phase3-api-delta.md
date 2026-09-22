# Phase 3: the API delta that matters (#119)

Found 2026-09-22 while validating the API 161 vendor against this backend.
Phases 1, 2 and the Phase 4 shader probe are recorded in their own documents.

## Status after the vendor bump

| Stage | Result |
| --- | --- |
| shaderc builds on the new set | yes — `1.19.161` |
| all 44 shader blobs regenerated | yes — reproducible, uniformly bgfx binary v12 |
| native video decoder | compiled OUT — no new framework dependency (§1) |
| backend test suite | **203/207 tests, 3 steps failing** (baseline: 247/247, 46/46) |

The remaining gap is TWO things, both understood:

* `window.zig:1365` and `:1496` — the `bgfx_reset` swap-chain port (§2).
* 4 × `shader_material_tests` — shader reflection reading the regenerated
  v12 blobs. Expected given the format bump; needs its own look, and is not
  video- or swap-chain-related.

## 1. RESOLVED: bgfx's native video decoder is compiled OUT

bgfx gained a native video decoder (API 146, "Added video decoder support"),
and `3rdparty/h264` is now included unconditionally by `src/video.h`. On Apple
platforms it drives **VideoToolbox** over **CoreMedia** sample buffers.

Without those frameworks the link fails on 13 symbols —
`VTDecompressionSession*`, `VTIsHardwareDecodeSupported`, `VTSessionSetProperty`,
`CMBlockBufferCreateWithMemoryBlock`, `CMSampleBufferCreate`, `CMTimeMake`,
`CMVideoFormatDescriptionCreateFrom{H264,HEVC}ParameterSets`, `kCMTimeInvalid`,
`kVTDecompressionPropertyKey_RealTime`.

### Decision: do not adopt it, compile it out

Adopting upstream's decoder was considered and rejected on evidence. It has
backends for exactly four renderers:

```
video_d3d11.cpp   video_d3d12.cpp   video_mtl.cpp   video_vk.cpp
```

**No OpenGL/GLES backend, and none for wasm.** This backend's renderer
mapping puts the two platforms where our video work actually lives on GLES:

| Platform | Renderer | Upstream decoder |
| --- | --- | --- |
| macOS | Metal | yes |
| Windows | D3D11/12 | yes |
| Linux | Vulkan (OpenGL fallback) | yes / no |
| **Android** | **OpenGLES** | **none** |
| **wasm / WebGL2** | **OpenGLES** | **none** |

Our `src/video/` is overwhelmingly Android and web — `android.zig`,
`android_audio.zig`, the ImageReader route, `web.zig`, `web_backend.zig`,
`web_video.c`, plus the shared `yuv.zig` GPU path. `desktop.zig` is one file
of thirteen. Adopting upstream would replace the one platform group already
working, leave Android and web on our code regardless, and leave us
maintaining both stacks.

So: `BGFX_CONFIG_VIDEO=0` via a new `-Dvideo` option in zbgfx (default off),
with VideoToolbox/CoreMedia linked only when it is on. `src/config.h` gates
all four backends on that one define, so it compiles out cleanly — verified,
zero `VT*`/`CM*` symbols remain.

Net effect: the API 161 bump adds **no** new framework dependency. The option
exists for a project targeting only Vulkan/D3D/Metal that does want it.

Revisit if upstream ever ships a GLES backend; that is an upstream request,
not work on our side.

## 2. STRUCTURAL: `bgfx_reset` lost width and height

```c
// API 142 (current pin)
void bgfx_reset(uint32_t _width, uint32_t _height, uint32_t _flags, bgfx_texture_format_t _format);

// API 161 (target)
void bgfx_reset(uint32_t _flags, const bgfx_swap_chain_t* _swapChain);
```

Upstream added an explicit swap-chain object (API 160, "Added swap-chain.
(#3959)"). Size now lives on the swap chain:

```c
typedef struct bgfx_swap_chain_s {
    void*  nwh;  void*  ndt;
    uint32_t width, height, flags;
    bgfx_texture_format_t formatColor, formatDepthStencil;
    bgfx_texture_handle_t depth;
    uint8_t numBackBuffers, maxFrameLatency;
} bgfx_swap_chain_t;
```

with companions `bgfx_create_frame_buffer_from_swap_chain` and
`bgfx_update_swap_chain`.

### Why this is a port, not a signature fix

`src/window.zig` calls `bgfx.reset(w, h, flags, .Count)` at three sites
(311, 1365, 1496), and resizing the backbuffer by calling `reset` with a new
width/height **is the mechanism** behind:

* `ensureSurface` — polls the LIVE framebuffer every frame and resets the
  swapchain when it moves. This is bgfx#82, the fix for a stale backbuffer
  being scaled by the compositor after an in-place Android rotation.
* the browser-window resize path on wasm (#895 downstream), which relies on
  the same per-frame poll.
* the fullscreen/windowed transition on desktop.

All of that has to be re-expressed against `bgfx_update_swap_chain` (or a
recreated swap chain). The decision — update in place vs recreate, who owns
the `bgfx_swap_chain_t`, and how `nwh`/`ndt` are threaded through the Android
surface-loss path — is real design work, and it is the single largest item
remaining in this upgrade.

It also means **`bgfx_reset` is not the only casualty**: anything keying off
the old "reset resizes the backbuffer" model needs review, including the
surface-loss/restore sequence and the headless/surfaceless probes.

## 3. What the numbers already tell us

203/207 with only the reset sites failing to compile is a good sign: the
renderer core, the material/post-fx stack and the shader pipeline are broadly
intact on API 161. The remaining work is concentrated, not diffuse.

## Recommended sequencing from here

1. Port `window.zig`'s three reset sites to the swap-chain API. Treat it as a
   design change with its own review, not a compile fix.
2. Re-run the full host matrix and compare against the Phase 1 baseline
   (14/14 exit 0, 247/247 tests) — that baseline exists precisely for this.
3. Only then the goldens and the device pass. Per the Phase 4 probe, blob
   diffing is meaningless now (v11 -> v12), so rendered output is the gate.
4. Decide the video-path overlap (§1) separately from this upgrade.
