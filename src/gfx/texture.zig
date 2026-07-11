/// Texture handle pool, image decode (PNG / JPG / BMP / TGA / … via
/// stb_image), GPU upload, and the `drawTexturePro` primitive that
/// samples the stored bgfx handle. Owns the `texture_handles` /
/// `texture_pixel_data` arrays — `programs.shutdownPrograms` calls
/// `destroyAllTextures` here on teardown so the bgfx handles get released
/// in the same pass as the shader uniforms.
const std = @import("std");
const bgfx = @import("zbgfx").bgfx;
const core = @import("labelle-core");
const types = @import("types.zig");
const state = @import("state.zig");
const programs = @import("programs.zig");
const astc = @import("astc.zig");

const MaterialEffect = core.backend_contract.MaterialEffect;
const Material = core.backend_contract.Material;

// stb_image goes through a tiny shim that empties out clang's nullability
// qualifiers before include. Zig 0.16's translate-c rejects `_Nonnull` on
// array parameters in Bionic's stdlib.h on the Android NDK 27 sysroot —
// see Flying-Platform/flying-platform-labelle#450. Macro-replacing
// `_Nonnull` / `_Nullable` to nothing makes the preprocessor strip them
// before translate-c sees the declarations. This is the SAME shim the
// sokol backend uses (backends/sokol/src/stb_shim.h), minus the
// stb_truetype include — bgfx has its own bitmap font.
pub const stbi = @cImport({
    @cInclude("stb_shim.h");
});

const Texture = types.Texture;
const Color = types.Color;
const Rectangle = types.Rectangle;
const Vector2 = types.Vector2;
const PosTexColorVertex = programs.PosTexColorVertex;

// ── Texture handle storage ────────────────────────────────────────────

/// Texture handle storage: maps our Texture.id to bgfx TextureHandle.
const MAX_TEXTURES = 512;
var texture_handles: [MAX_TEXTURES]bgfx.TextureHandle = [_]bgfx.TextureHandle{.{ .idx = std.math.maxInt(u16) }} ** MAX_TEXTURES;
/// Pixel data backing each texture (decoded RGBA8 pixels, owned).
/// Stored so we can free on unload/shutdown. null means no decoded data.
var texture_pixel_data: [MAX_TEXTURES]?[]u8 = [_]?[]u8{null} ** MAX_TEXTURES;

/// Look up the raw bgfx handle backing a pool id (used by `gfx.drawMesh` to
/// bind a `Texture` returned by `uploadTexture`/`createTexture2D` — e.g. a Spine
/// atlas page — through the sprite pipeline). Returns an invalid handle for
/// out-of-range / unloaded ids so callers can skip the submit.
pub fn handleForId(id: u32) bgfx.TextureHandle {
    if (id >= MAX_TEXTURES) return .{ .idx = std.math.maxInt(u16) };
    return texture_handles[id];
}

/// Find a free texture slot by scanning for invalid handles (supports reuse after unload).
fn findFreeTextureSlot() ?u32 {
    // Start from 1 (slot 0 is reserved/unused)
    for (1..MAX_TEXTURES) |i| {
        if (texture_handles[i].idx == std.math.maxInt(u16)) {
            return @intCast(i);
        }
    }
    return null;
}

/// Walk every texture slot, destroy its bgfx handle, and free any
/// retained pixel data. Called from `programs.shutdownPrograms` on
/// backend teardown so the bgfx context can finish cleanly. Pre-split
/// this loop was inline in `shutdownPrograms`; moving it next to the
/// state it walks keeps the texture pool's invariants local to this
/// file.
pub fn destroyAllTextures() void {
    for (0..MAX_TEXTURES) |i| {
        if (texture_handles[i].idx != std.math.maxInt(u16)) {
            bgfx.destroyTexture(texture_handles[i]);
            texture_handles[i] = .{ .idx = std.math.maxInt(u16) };
        }
        if (texture_pixel_data[i]) |px| {
            std.heap.page_allocator.free(px);
            texture_pixel_data[i] = null;
        }
    }
}

// Zig 0.16 removed `std.fs.cwd()` in favour of `std.Io.Dir.cwd()`, which
// requires an `Io` parameter threaded through the call site. This file
// is a demo/legacy convenience loader — production texture loading goes
// through `uploadTexture` + a caller-owned `decodeImage` (see the
// split-contract comment on `uploadTexture` below), which never touches
// the FS directly. Rather than thread `Io` through the backend for a
// one-shot loader, we use libc `fopen` / `fread` / `fclose` to keep the
// existing `(path) !Texture` signature. `link_libc = true` is set on
// the gfx module (see backends/bgfx/build.zig) — stb_image already pulls
// libc in for malloc/free/memcpy, so this loader's fopen/fread/fclose
// add no new link-time cost.
const SEEK_SET: c_int = 0;
const SEEK_END: c_int = 2;
extern "c" fn fseek(stream: *std.c.FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *std.c.FILE) c_long;

pub fn loadTexture(path: [:0]const u8) !Texture {
    // Read the file from disk via libc. See the rationale block above.
    const file = std.c.fopen(path.ptr, "rb") orelse return error.LoadFailed;
    defer _ = std.c.fclose(file);

    if (fseek(file, 0, SEEK_END) != 0) return error.LoadFailed;
    const file_size_signed = ftell(file);
    if (file_size_signed < 18) return error.LoadFailed; // Too small for any image header
    if (fseek(file, 0, SEEK_SET) != 0) return error.LoadFailed;
    const file_size: usize = @intCast(file_size_signed);

    const allocator = std.heap.page_allocator;
    const data = allocator.alloc(u8, file_size) catch return error.LoadFailed;
    defer allocator.free(data);

    const bytes_read = std.c.fread(data.ptr, 1, file_size, file);
    if (bytes_read != file_size) {
        // `fread` can return short on EOF mid-read without setting an error
        // flag, so we must compare against the full requested size — not
        // just the minimum image header — or we'd silently decode a truncated
        // file. See PR #227 (cursor[bot] review).
        std.log.warn("texture: short read on {s} ({d}/{d} bytes)", .{ path, bytes_read, file_size });
        return error.LoadFailed;
    }
    if (bytes_read < 18) return error.LoadFailed;

    // GPU-compressed (ASTC) blobs upload as-is — no CPU decode.
    if (astc.isAstc(data[0..bytes_read])) return uploadCompressed(data[0..bytes_read]);

    const decoded = try decodeImage("", data[0..bytes_read], allocator);
    defer allocator.free(decoded.pixels);
    return uploadTexture(decoded);
}

/// Pure CPU decode, safe from a worker thread. Decodes via stb_image,
/// which covers PNG / JPG / BMP / TGA / GIF / PSD / HDR / PIC / PNM —
/// forcing 4 output channels so the result is always RGBA8 to match
/// `DecodedImage` and `uploadTexture`'s `.RGBA8` format. stb gives a
/// top-left-origin buffer, the same orientation the upload path + sprite
/// shader expect.
///
/// stb allocates the decoded buffer with its OWN malloc, but the engine
/// frees `decoded.pixels` with the Zig `allocator`, so we MUST copy stb's
/// buffer into `allocator` and then `stbi_image_free` stb's original —
/// never hand stb's raw pointer to the Zig allocator. The caller owns the
/// returned `pixels` buffer and frees it on both the success and the
/// discard paths.
pub fn decodeImage(
    _: [:0]const u8,
    data: []const u8,
    allocator: std.mem.Allocator,
) !DecodedImage {
    var width: c_int = 0;
    var height: c_int = 0;
    var channels: c_int = 0;
    const raw = stbi.stbi_load_from_memory(
        @ptrCast(data.ptr),
        @intCast(data.len),
        &width,
        &height,
        &channels,
        4, // force RGBA8
    );
    if (raw == null) return error.LoadFailed;
    defer stbi.stbi_image_free(raw);

    if (width <= 0 or height <= 0) return error.LoadFailed;

    // Checked multiplication: a crafted/malformed image with huge dimensions
    // could overflow `w*h*4` (esp. on 32-bit Android), wrapping to a small
    // allocation that the caller then reads past with the original dims.
    const wh = std.math.mul(usize, @as(usize, @intCast(width)), @as(usize, @intCast(height))) catch return error.LoadFailed;
    const len = std.math.mul(usize, wh, 4) catch return error.LoadFailed;
    const owned = try allocator.alloc(u8, len);
    @memcpy(owned, @as([*]const u8, @ptrCast(raw))[0..len]);

    return .{
        .pixels = owned,
        .width = @intCast(width),
        .height = @intCast(height),
    };
}

/// Main/GL-thread GPU upload. bgfx copies the pixel buffer into its own
/// command queue via `bgfx.copy`, so we do NOT free `decoded.pixels` —
/// the caller owns it and frees it on both the success and the discard
/// paths. The backend retains its own copy via bgfx.copy's memcpy.
pub fn uploadTexture(decoded: DecodedImage) !Texture {
    if (decoded.width == 0 or decoded.height == 0) return error.LoadFailed;
    const id = findFreeTextureSlot() orelse return error.LoadFailed;

    const w: u16 = std.math.cast(u16, decoded.width) orelse return error.LoadFailed;
    const h: u16 = std.math.cast(u16, decoded.height) orelse return error.LoadFailed;

    const mem = bgfx.copy(decoded.pixels.ptr, @intCast(decoded.pixels.len));
    const handle = bgfx.createTexture2D(
        w,
        h,
        false,
        1,
        .RGBA8,
        bgfx.SamplerFlags_UClamp | bgfx.SamplerFlags_VClamp,
        mem,
        0,
    );
    if (handle.idx == std.math.maxInt(u16)) return error.LoadFailed;

    texture_handles[id] = handle;
    // The old loadTexture path cached the decoded bytes in
    // texture_pixel_data[id] so it could free them on unload; with the
    // new split contract the caller owns the bytes and bgfx.copy has
    // already taken its own copy, so we leave the slot null here.
    texture_pixel_data[id] = null;

    return .{ .id = id, .width = @intCast(decoded.width), .height = @intCast(decoded.height) };
}

// ── Dynamic textures (runtime-updated pixels) ───────────────────────────────
// Path A "display half" (Flying-Platform/flying-platform-labelle#549): a blank
// RGBA8 texture created once, then re-uploaded every frame via `updateTexture`.
// This is the sink a video player feeds decoded+converted RGBA frames into —
// bgfx then draws it like any other texture (`drawTexturePro`). bgfx only
// allows updates on a MUTABLE texture, i.e. one created with `null` initial
// memory (an immutable texture is one created WITH data — that's the normal
// `uploadTexture` path). `bgfx.copy` takes its own copy of the pixels on every
// update, so the caller may overwrite/reuse its frame buffer immediately
// (double-buffer safe), exactly as the upload path does.

/// Create a blank, updatable RGBA8 texture of `width`x`height`. Passes `null`
/// memory so the texture is mutable and can be re-uploaded with `updateTexture`
/// each frame (unlike `uploadTexture`, which bakes data in at create time).
pub fn createDynamicTexture(width: u32, height: u32) !Texture {
    const id = findFreeTextureSlot() orelse return error.LoadFailed;
    const w: u16 = std.math.cast(u16, width) orelse return error.LoadFailed;
    const h: u16 = std.math.cast(u16, height) orelse return error.LoadFailed;

    const handle = bgfx.createTexture2D(
        w,
        h,
        false,
        1,
        .RGBA8,
        bgfx.SamplerFlags_UClamp | bgfx.SamplerFlags_VClamp,
        null, // mutable: no initial data, updatable via updateTexture2D
        0,
    );
    if (handle.idx == std.math.maxInt(u16)) return error.LoadFailed;

    texture_handles[id] = handle;
    texture_pixel_data[id] = null;
    return .{ .id = id, .width = @intCast(width), .height = @intCast(height) };
}

/// Re-upload a full RGBA8 frame to a dynamic texture created by
/// `createDynamicTexture`. `pixels` must be exactly width*height*4 bytes
/// (tightly packed, top-left origin — same orientation as the decode path).
/// No-ops on a bad id/handle or a size mismatch so a malformed frame can't
/// scribble past the texture.
pub fn updateTexture(texture: Texture, pixels: []const u8) void {
    if (texture.id >= MAX_TEXTURES) return;
    const handle = texture_handles[texture.id];
    if (handle.idx == std.math.maxInt(u16)) return;

    const w: u16 = std.math.cast(u16, texture.width) orelse return;
    const h: u16 = std.math.cast(u16, texture.height) orelse return;
    const expected = @as(usize, @intCast(texture.width)) * @as(usize, @intCast(texture.height)) * 4;
    if (pixels.len != expected) return;

    const mem = bgfx.copy(pixels.ptr, @intCast(pixels.len));
    // pitch = max(u16) → bgfx treats the row stride as tightly packed (w*bpp).
    bgfx.updateTexture2D(handle, 0, 0, 0, 0, w, h, mem, std.math.maxInt(u16));
}

// ── GPU-compressed textures (ASTC) ──────────────────────────────────────────
// The engine's `loadTextureFromMemory` seam (labelle-gfx) dispatches here when
// the backend exposes `isCompressed`/`uploadCompressed` and the blob is
// compressed, skipping the CPU decode entirely. bgfx has no PNG decoder, so for
// a 4K atlas this is also the only zero-cost upload path (labelle-gfx#269/#341).

/// Map an ASTC block size to the matching bgfx `TextureFormat`, or null if bgfx
/// has no enum for it. Covers the full ASTC LDR block-size set bgfx exposes.
fn astcFormat(block_x: u8, block_y: u8) ?bgfx.TextureFormat {
    return switch ((@as(u16, block_x) << 8) | block_y) {
        0x0404 => .ASTC4x4,
        0x0504 => .ASTC5x4,
        0x0505 => .ASTC5x5,
        0x0605 => .ASTC6x5,
        0x0606 => .ASTC6x6,
        0x0805 => .ASTC8x5,
        0x0806 => .ASTC8x6,
        0x0808 => .ASTC8x8,
        0x0a05 => .ASTC10x5,
        0x0a06 => .ASTC10x6,
        0x0a08 => .ASTC10x8,
        0x0a0a => .ASTC10x10,
        0x0c0a => .ASTC12x10,
        0x0c0c => .ASTC12x12,
        else => null,
    };
}

/// Everything needed to upload a validated 2D ASTC blob.
const AstcUpload = struct { fmt: bgfx.TextureFormat, width: u16, height: u16, blocks: []const u8 };

/// Validate an ASTC blob for a 2D bgfx upload, or null if we can't take it
/// as-is: not ASTC, malformed/truncated, 3D, an unsupported block size, or
/// dimensions past `u16`. `isCompressed`/`uploadCompressed` share this so the
/// "can upload as-is" probe and the actual upload never disagree.
fn validateAstc(data: []const u8) ?AstcUpload {
    const hdr = astc.parse(data) orelse return null;
    if (hdr.depth != 1 or hdr.block_z != 1) return null; // bgfx createTexture2D is 2D only
    const fmt = astcFormat(hdr.block_x, hdr.block_y) orelse return null;
    const w = std.math.cast(u16, hdr.width) orelse return null;
    const h = std.math.cast(u16, hdr.height) orelse return null;
    return .{ .fmt = fmt, .width = w, .height = h, .blocks = hdr.blocks };
}

/// True if `data` is a GPU-compressed blob this backend can upload as-is.
pub fn isCompressed(data: []const u8) bool {
    return validateAstc(data) != null;
}

/// Image dimensions of a compressed blob, read from the ASTC header without
/// decoding — lets the async asset-catalog adapter set a correct DecodedImage
/// width/height before upload. Null if not an ASTC blob we accept.
pub fn compressedDims(data: []const u8) ?struct { width: u32, height: u32 } {
    const info = validateAstc(data) orelse return null;
    return .{ .width = @intCast(info.width), .height = @intCast(info.height) };
}

/// Upload an ASTC blob straight to the GPU — no CPU decode. The compressed
/// blocks are copied into bgfx's command queue (`bgfx.copy`), so the caller's
/// buffer can be freed immediately after this returns.
pub fn uploadCompressed(data: []const u8) !Texture {
    const info = validateAstc(data) orelse return error.LoadFailed;
    const id = findFreeTextureSlot() orelse return error.LoadFailed;

    const mem = bgfx.copy(info.blocks.ptr, @intCast(info.blocks.len));
    const handle = bgfx.createTexture2D(
        info.width,
        info.height,
        false,
        1,
        info.fmt,
        bgfx.SamplerFlags_UClamp | bgfx.SamplerFlags_VClamp,
        mem,
        0,
    );
    if (handle.idx == std.math.maxInt(u16)) return error.LoadFailed;
    texture_handles[id] = handle;
    texture_pixel_data[id] = null;
    return .{ .id = id, .width = @intCast(info.width), .height = @intCast(info.height) };
}

pub fn unloadTexture(texture: Texture) void {
    if (texture.id < MAX_TEXTURES) {
        const handle = texture_handles[texture.id];
        if (handle.idx != std.math.maxInt(u16)) {
            bgfx.destroyTexture(handle);
            texture_handles[texture.id] = .{ .idx = std.math.maxInt(u16) };
        }
        if (texture_pixel_data[texture.id]) |px| {
            std.heap.page_allocator.free(px);
            texture_pixel_data[texture.id] = null;
        }
    }
}

fn makeTexVertex(px: f32, py: f32, u: f32, v: f32, abgr: u32) PosTexColorVertex {
    return .{
        .x = state.toNdcX(px),
        .y = state.toNdcY(py),
        .u = u,
        .v = v,
        .abgr = abgr,
    };
}

/// Build the 6 vertices (2 triangles) for a textured quad: maps `source` (in
/// texture pixels, with the labelle-gfx negative-dim flip convention) to `dest`
/// (screen/world space), applying origin + rotation + camera zoom. `tex_w`/`tex_h`
/// are the texture's pixel dimensions used to normalize the source rect to UVs.
/// Shared by `drawTexturePro` (single RGBA texture) and `drawPlanesPro` (three
/// YUV plane textures): the geometry + UVs are identical, only the submit /
/// sampler binding differs. For the YUV path the same normalized UVs sample the
/// full-res Y and the half-res U/V correctly (0..1 spans each plane's extent).
fn buildQuadVertices(tex_w: u32, tex_h: u32, source: Rectangle, dest: Rectangle, origin: Vector2, rotation: f32, abgr: u32) [6]PosTexColorVertex {
    const tw: f32 = @floatFromInt(tex_w);
    const th: f32 = @floatFromInt(tex_h);

    // Source rect → UVs. Negative source.width/height are the labelle-gfx
    // convention for flip_x/flip_y (the renderer negates the rect dims when a
    // sprite is flipped). See drawTexturePro's original comment for the
    // absolute-extent + swap rationale (avoids sampling a neighboring frame).
    const sw_abs = @abs(source.width);
    const sh_abs = @abs(source.height);
    const flip_x = source.width < 0;
    const flip_y = source.height < 0;
    const u_left = source.x / tw;
    const u_right = (source.x + sw_abs) / tw;
    const v_top = source.y / th;
    const v_bottom = (source.y + sh_abs) / th;
    const uv0 = if (flip_x) u_right else u_left;
    const uv1 = if (flip_x) u_left else u_right;
    const tv0 = if (flip_y) v_bottom else v_top;
    const tv1 = if (flip_y) v_top else v_bottom;

    const zoom = state.cameraZoom();
    const scaled_ox = origin.x * zoom;
    const scaled_oy = origin.y * zoom;
    const dx = state.transformX(dest.x) - scaled_ox;
    const dy = state.transformY(dest.y) - scaled_oy;
    const dw = dest.width * zoom;
    const dh = dest.height * zoom;

    if (rotation == 0.0) {
        return .{
            makeTexVertex(dx, dy, uv0, tv0, abgr),
            makeTexVertex(dx + dw, dy, uv1, tv0, abgr),
            makeTexVertex(dx + dw, dy + dh, uv1, tv1, abgr),
            makeTexVertex(dx, dy, uv0, tv0, abgr),
            makeTexVertex(dx + dw, dy + dh, uv1, tv1, abgr),
            makeTexVertex(dx, dy + dh, uv0, tv1, abgr),
        };
    }

    const rad = rotation * (std.math.pi / 180.0);
    const cos_r = @cos(rad);
    const sin_r = @sin(rad);
    const ox = scaled_ox;
    const oy = scaled_oy;

    const corners = [4][2]f32{ .{ 0, 0 }, .{ dw, 0 }, .{ dw, dh }, .{ 0, dh } };
    var rotated: [4][2]f32 = undefined;
    for (corners, 0..) |corner, i| {
        const cx = corner[0] - ox;
        const cy = corner[1] - oy;
        rotated[i] = .{
            dx + ox + cx * cos_r - cy * sin_r,
            dy + oy + cx * sin_r + cy * cos_r,
        };
    }
    const uvs = [4][2]f32{ .{ uv0, tv0 }, .{ uv1, tv0 }, .{ uv1, tv1 }, .{ uv0, tv1 } };
    return .{
        makeTexVertex(rotated[0][0], rotated[0][1], uvs[0][0], uvs[0][1], abgr),
        makeTexVertex(rotated[1][0], rotated[1][1], uvs[1][0], uvs[1][1], abgr),
        makeTexVertex(rotated[2][0], rotated[2][1], uvs[2][0], uvs[2][1], abgr),
        makeTexVertex(rotated[0][0], rotated[0][1], uvs[0][0], uvs[0][1], abgr),
        makeTexVertex(rotated[2][0], rotated[2][1], uvs[2][0], uvs[2][1], abgr),
        makeTexVertex(rotated[3][0], rotated[3][1], uvs[3][0], uvs[3][1], abgr),
    };
}

pub fn drawTexturePro(texture: Texture, source: Rectangle, dest: Rectangle, origin: Vector2, rotation: f32, tint: Color) void {
    if (texture.id >= MAX_TEXTURES) return;
    const handle = texture_handles[texture.id];
    if (handle.idx == std.math.maxInt(u16)) return;

    const vertices = buildQuadVertices(@intCast(texture.width), @intCast(texture.height), source, dest, origin, rotation, tint.toAbgr());
    programs.submitTexturedTriangles(&vertices, handle);
}

/// Which curated material effects this bgfx backend implements (labelle-gfx#305
/// Slice B). The fine-grained gate `core.Backend(Impl).drawTextureProMaterial`
/// consults before dispatching: `flash` + `palette_swap` are implemented;
/// `dissolve`/`outline` (and `none`) are not, so they degrade to a plain sprite.
/// Kept in sync with `programs.submitMaterialTriangles`'s effect switch.
pub fn materialSupported(effect: MaterialEffect) bool {
    return switch (effect) {
        .flash, .palette_swap => true,
        .dissolve, .outline, .none => false,
    };
}

/// Material-aware sprite draw — the bgfx impl of labelle-core's optional
/// `drawTextureProMaterial` contract (labelle-gfx#305). Same quad-build as
/// `drawTexturePro`, but routes through the effect's material program with the
/// `MaterialUniforms` uploaded (see `programs.submitMaterialTriangles`). The
/// core wrapper only calls this for a supported, non-`none` effect, so the switch
/// here handles just `flash` + `palette_swap`; anything else falls back to the
/// plain sprite so a stray call can never leave the sprite undrawn.
///
/// `palette_swap` degrades to a PLAIN sprite when `aux_texture == 0` (no LUT
/// bound) or the LUT handle is dead — never a crash, never a black quad (RFC §3).
pub fn drawTextureProMaterial(
    texture: Texture,
    source: Rectangle,
    dest: Rectangle,
    origin: Vector2,
    rotation: f32,
    tint: Color,
    material: Material,
) void {
    if (texture.id >= MAX_TEXTURES) return;
    const handle = texture_handles[texture.id];
    if (handle.idx == std.math.maxInt(u16)) return;

    // Resolve the LUT ramp for palette_swap from the flat `aux_texture` handle
    // (a plain texture-pool id, per the contract). A zero/dead handle degrades.
    var lut_handle = bgfx.TextureHandle{ .idx = std.math.maxInt(u16) };
    if (material.effect == .palette_swap) {
        const lut_id = material.uniforms.aux_texture;
        if (lut_id == 0 or lut_id >= MAX_TEXTURES) {
            drawTexturePro(texture, source, dest, origin, rotation, tint);
            return;
        }
        lut_handle = texture_handles[lut_id];
        if (lut_handle.idx == std.math.maxInt(u16)) {
            drawTexturePro(texture, source, dest, origin, rotation, tint);
            return;
        }
    }

    const vertices = buildQuadVertices(@intCast(texture.width), @intCast(texture.height), source, dest, origin, rotation, tint.toAbgr());
    switch (material.effect) {
        .flash, .palette_swap => programs.submitMaterialTriangles(&vertices, handle, material.effect, material.uniforms, lut_handle),
        else => programs.submitTexturedTriangles(&vertices, handle),
    }
}

/// Draw an externally-owned bgfx texture — one NOT in this module's pool —
/// through the sprite pipeline, reusing the exact `drawTexturePro` quad math
/// (camera transform, rotation, source-rect flip via negative dims, tint). This
/// is how `render_target` composites an offscreen pass (a transport mirror) into
/// the current view: the caller owns the handle's lifetime (it belongs to a
/// framebuffer), so — unlike `drawTexturePro` — nothing here touches the pool or
/// frees the handle. `tex_w/tex_h` are the source texture's dimensions (used to
/// normalise `source` into UVs).
pub fn drawExternalTexture(
    handle: bgfx.TextureHandle,
    tex_w: u32,
    tex_h: u32,
    source: Rectangle,
    dest: Rectangle,
    origin: Vector2,
    rotation: f32,
    tint: Color,
) void {
    if (handle.idx == std.math.maxInt(u16)) return;
    const vertices = buildQuadVertices(tex_w, tex_h, source, dest, origin, rotation, tint.toAbgr());
    programs.submitTexturedTriangles(&vertices, handle);
}

// ── YUV plane textures (GPU-side video colour conversion) ──────────────────
// perf/gpu-yuv-video: the in-engine video path uploads raw Y/U/V planes to
// three single-channel R8 textures (Y full-res, U/V half-res) and converts
// them to RGB in the `fs_yuv` fragment shader during the draw — replacing the
// CPU YUV→RGBA convert + 8.3 MB RGBA upload with a ~3 MB plane upload and no CPU
// convert. The textures are MUTABLE (null initial memory) and re-uploaded each
// frame via `updatePlaneTextures`, exactly like `createDynamicTexture` /
// `updateTexture`. R8 is the single-channel 8-bit unorm format bgfx samples as
// (value, 0, 0, 1); the shader reads `.x`.

/// Three mutable R8 plane textures backing one video frame, plus the video's
/// luma dimensions (used as the "texture size" when building the draw quad's
/// UVs — see `buildQuadVertices`). `width`/`height` are the full (luma) frame
/// size; the U/V textures are half-res but sample with the same normalized UVs.
pub const PlaneTextures = struct {
    y: Texture,
    u: Texture,
    v: Texture,
    width: u32,
    height: u32,
};

/// True when the GPU-YUV shader program can be created/submitted on this
/// renderer. The player calls this once when choosing the video path: if it
/// returns false (e.g. `fs_yuv` won't link), the player permanently uses the
/// CPU RGBA fallback instead of submitting draws that would no-op (black).
/// Wraps `programs.ensureYuvProgram` so `player.zig` need not import `programs`.
pub fn yuvProgramReady() bool {
    return programs.ensureYuvProgram();
}

/// Allocate a fresh R8 plane texture of `w`×`h` (mutable, updatable per frame).
/// Bilinear + clamp sampling like the RGBA dynamic texture. Returns the pool id.
fn createPlaneR8(w: u32, h: u32) !Texture {
    const id = findFreeTextureSlot() orelse return error.LoadFailed;
    const cw: u16 = std.math.cast(u16, w) orelse return error.LoadFailed;
    const ch: u16 = std.math.cast(u16, h) orelse return error.LoadFailed;
    const handle = bgfx.createTexture2D(
        cw,
        ch,
        false,
        1,
        .R8,
        bgfx.SamplerFlags_UClamp | bgfx.SamplerFlags_VClamp,
        null, // mutable
        0,
    );
    if (handle.idx == std.math.maxInt(u16)) return error.LoadFailed;
    texture_handles[id] = handle;
    texture_pixel_data[id] = null;
    return .{ .id = id, .width = @intCast(w), .height = @intCast(h) };
}

/// Create the Y (full-res) + U/V (half-res) R8 plane textures for a `width`×
/// `height` video. On any sub-allocation failure, frees whatever was created so
/// the caller can cleanly fall back to the CPU RGBA path. Half-res dims round up
/// (matches `planes.chromaWidth`/`chromaHeight`) so odd frames keep a full edge.
pub fn createPlaneTextures(width: u32, height: u32) !PlaneTextures {
    const cw = (width + 1) / 2;
    const ch = (height + 1) / 2;
    const y = try createPlaneR8(width, height);
    errdefer unloadTexture(y);
    const u = try createPlaneR8(cw, ch);
    errdefer unloadTexture(u);
    const v = try createPlaneR8(cw, ch);
    return .{ .y = y, .u = u, .v = v, .width = width, .height = height };
}

/// Re-upload tight Y/U/V plane buffers to their textures. Each buffer must be
/// exactly `plane.width*plane.height` bytes (tightly packed, top-left origin).
/// No-ops a plane on a size mismatch / dead handle so a malformed frame can't
/// scribble past a texture (matching `updateTexture`).
pub fn updatePlaneTextures(pt: PlaneTextures, y_pixels: []const u8, u_pixels: []const u8, v_pixels: []const u8) void {
    updatePlaneR8(pt.y, y_pixels);
    updatePlaneR8(pt.u, u_pixels);
    updatePlaneR8(pt.v, v_pixels);
}

fn updatePlaneR8(t: Texture, pixels: []const u8) void {
    if (t.id >= MAX_TEXTURES) return;
    const handle = texture_handles[t.id];
    if (handle.idx == std.math.maxInt(u16)) return;
    const w: u16 = std.math.cast(u16, t.width) orelse return;
    const h: u16 = std.math.cast(u16, t.height) orelse return;
    const expected = @as(usize, @intCast(t.width)) * @as(usize, @intCast(t.height));
    if (pixels.len != expected) return;
    const mem = bgfx.copy(pixels.ptr, @intCast(pixels.len));
    bgfx.updateTexture2D(handle, 0, 0, 0, 0, w, h, mem, std.math.maxInt(u16));
}

/// Destroy the three plane textures (frees their pool slots).
pub fn unloadPlaneTextures(pt: PlaneTextures) void {
    unloadTexture(pt.y);
    unloadTexture(pt.u);
    unloadTexture(pt.v);
}

/// Draw the YUV video frame: same quad geometry as `drawTexturePro`, but binds
/// the three plane textures to the `s_texY/U/V` samplers and submits with the
/// `yuv_program` (GPU YUV→RGB). `source` is in luma (full-res) pixels.
pub fn drawPlanesPro(pt: PlaneTextures, source: Rectangle, dest: Rectangle, origin: Vector2, rotation: f32, tint: Color) void {
    if (pt.y.id >= MAX_TEXTURES or pt.u.id >= MAX_TEXTURES or pt.v.id >= MAX_TEXTURES) return;
    const yh = texture_handles[pt.y.id];
    const uh = texture_handles[pt.u.id];
    const vh = texture_handles[pt.v.id];
    if (yh.idx == std.math.maxInt(u16) or uh.idx == std.math.maxInt(u16) or vh.idx == std.math.maxInt(u16)) return;

    const vertices = buildQuadVertices(pt.width, pt.height, source, dest, origin, rotation, tint.toAbgr());
    programs.submitYuvTriangles(&vertices, yh, uh, vh);
}

// ── Image decoding helpers ─────────────────────────────────────────────

/// CPU-decoded image owned by the caller's allocator. See sokol's
/// `DecodedImage` doc-comment for why this is defined per-backend
/// instead of imported from labelle-gfx — same reasoning applies.
pub const DecodedImage = struct {
    pixels: []u8,
    width: u32,
    height: u32,
};

// BMP and TGA loaders removed — stb_image (compiled in via
// stb_image_impl.c) handles PNG/JPG/BMP/TGA and more. See `decodeImage`.
