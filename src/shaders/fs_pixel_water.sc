$input v_texcoord0, v_color0

// Material effect `pixel_water` (RFC-PIXEL-WATER, labelle-bgfx#100,
// MaterialEffect.pixel_water). The COND-07 condenser's reactive reservoir: a
// dark water body clipped to a silhouette mask AND the fill level, with a
// restrained periodic surface wave, up to eight bounded fading drop ripples, a
// limited surface highlight and a SUPPLIED (pre-authored) reflection texture.
//
// This is NOT a fluid simulation and the highlight is NOT simulated light. No
// scene capture, no full-screen pass, no render-target read-back: it shades the
// reservoir sprite's own quad, like every other material effect.
//
// ── Coordinate system ────────────────────────────────────────────────────────
// Local coordinates are NATIVE ART PIXELS with the origin at the reservoir
// rectangle's TOP-LEFT, +X right and +Y DOWN. `u_water_rect` remaps the sprite's
// atlas UV to that rectangle (the sprite may be an atlas sub-rect), and
// `logical_width`/`logical_height` scale it into art pixels.
//
// The fill `level` is the fraction filled from the reservoir's BOTTOM:
//     surface_y = logical_height * (1 - level)
// so level 0 puts the surface at the bottom edge and renders NO water at all
// (explicitly gated — a zero level is not "a zero-height column", it is off).
//
// ── The effect grid ──────────────────────────────────────────────────────────
// `grid_pixels` is the number of native art pixels per effect cell. EVERY
// texture/noise position is evaluated at the logical CELL CENTRE and every
// displacement is quantized to whole grid increments, so the water keeps a
// crisp, pixel-aligned look under integer enlargement. The reference scene's
// "6 screen pixels per cell" is integer ENLARGEMENT of the finished art — it is
// neither this value nor an engine constant.
//
// ── Samplers (FIXED slots; see programs.zig `submitPixelWaterTriangles`) ─────
//   unit 0  s_tex           the reservoir SPRITE's own texture (the authored
//                           static art, also the unsupported-renderer
//                           fallback). Sampled at the raw atlas UV exactly like
//                           fs_sprite, x v_color0 — same authored (sRGB-ish)
//                           colour space as every other sprite. The water
//                           composites OVER it, so the art still shows through
//                           above the surface and outside the mask.
//   unit 1  s_water_mask    the reservoir silhouette mask, a STANDALONE texture
//                           (not atlased) spanning exactly the logical
//                           rectangle. Coverage = alpha x max(rgb), so BOTH
//                           authoring conventions work: white-on-transparent
//                           and white-on-black. Nearest + clamped (the Zig side
//                           forces those sampler flags at bind time).
//   unit 2  s_water_reflect the SUPPLIED reflection, also standalone and
//                           reservoir-local. It is ALREADY the desired
//                           reflection: it is not flipped here and nothing is
//                           captured from the scene. Nearest + clamped.
//
// ── Uniform registers (16 vec4s, mirroring core's PixelWaterDraw) ────────────
//   u_water_rect         (u0, v0, u1, v1) the sprite's source frame in
//                        whole-atlas UV space; (0,0,1,1) for a standalone
//                        texture.
//   u_water_head[0]      (logical_width, logical_height, grid_pixels,
//                        ripple_count)   -- the u32 header, widened to float
//                        on the Zig side (ESSL has no cheap uint path here).
//   u_water_head[1]      (waves_enabled, has_mask, has_reflection, raw_flags)
//                        -- `flags` is DECODED in Zig so this shader never does
//                        bitwise arithmetic on a float.
//   u_water_color[0..2]  deep / surface / highlight, LINEAR 0..1 rgba. The
//                        engine already converted these out of the authored
//                        sRGB hex: do NOT gamma-convert again here.
//   u_water_params[0]    (level, time, wave_amplitude_px, wave_period_s)
//   u_water_params[1]    (distortion_px, reflection_opacity, ripple_duration_s,
//                        ripple_radius_px)
//   u_water_params[2]    (ripple_strength_px, _, _, _)
//   u_water_ripples[0..7] one live impact each: (x, start_time, strength, _).
//                        `time` is SIMULATION seconds, never a wall clock.
//
// ── Ripples ──────────────────────────────────────────────────────────────────
// The loop is a FIXED eight iterations (PIXEL_WATER_MAX_RIPPLES). That bound is
// a comptime constant on purpose: ESSL 3.00 / WebGL2 treat a dynamically-bounded
// loop as a portability hazard, so the trip count must not depend on a uniform.
// Entries at or past `ripple_count` are skipped (they are NOT guaranteed zeroed)
// and an age outside [0, ripple_duration_seconds) contributes exactly nothing.
// A ripple stores only its logical X: the SURFACE defines its y, so it stays
// attached to a rising surface as the reservoir fills.
#include <bgfx_shader.sh>

SAMPLER2D(s_tex, 0);
SAMPLER2D(s_water_mask, 1);
SAMPLER2D(s_water_reflect, 2);

uniform vec4 u_water_rect;
uniform vec4 u_water_head[2];
uniform vec4 u_water_color[3];
uniform vec4 u_water_params[3];
uniform vec4 u_water_ripples[8];

// MUST match core's PIXEL_WATER_MAX_RIPPLES. Comptime trip count — see above.
#define WATER_MAX_RIPPLES 8
// Surface wavelength, in effect CELLS. The RFC fixes the amplitude (authored, in
// art pixels) but not the wavelength; a fixed cell-relative wavelength keeps the
// wave's look stable when the art grid changes.
#define WATER_WAVE_CELLS 16.0
// Wavelength (in cells) of the vertical reflection shimmer. Deliberately a
// different, non-harmonic count from WATER_WAVE_CELLS so surface and reflection
// motion do not visibly lock together.
#define WATER_REFLECT_CELLS 11.0
#define WATER_TAU 6.2831853

// Snap `v` to a whole multiple of the grid `g`. `floor(x + 0.5)` rather than
// round(), which GLSL 1.20 (the desktop `-p 120` variant) does not have.
float waterQuant(float v, float g)
{
	return floor(v / g + 0.5) * g;
}

void main()
{
	// The sprite's own art, straight-alpha and tinted, exactly as fs_sprite
	// produces it. This is the BASE the water composites over, so the authored
	// reservoir art remains visible above the surface line and outside the mask
	// (and a level of 0 reduces this shader to a plain sprite draw).
	vec4 base = texture2D(s_tex, v_texcoord0) * v_color0;

	// Atlas UV -> sprite-local 0..1 -> logical art pixels (+Y down).
	vec2 span = max(u_water_rect.zw - u_water_rect.xy, vec2(1e-6, 1e-6));
	vec2 local_uv = (v_texcoord0 - u_water_rect.xy) / span;

	vec2 logical = max(u_water_head[0].xy, vec2(1.0, 1.0));
	float grid = max(u_water_head[0].z, 1.0);
	float ripple_count = u_water_head[0].w;
	float waves_on = u_water_head[1].x;
	float has_mask = u_water_head[1].y;
	float has_reflect = u_water_head[1].z;

	float level = clamp(u_water_params[0].x, 0.0, 1.0);
	float time = u_water_params[0].y;
	float amplitude = max(u_water_params[0].z, 0.0);
	float period = max(u_water_params[0].w, 1e-4);
	float distortion = max(u_water_params[1].x, 0.0);
	float reflect_opacity = clamp(u_water_params[1].y, 0.0, 1.0);
	float ripple_duration = max(u_water_params[1].z, 1e-4);
	float ripple_radius = max(u_water_params[1].w, 1e-4);
	float ripple_strength = u_water_params[2].x;

	vec2 local_px = local_uv * logical;
	// The logical CELL CENTRE this fragment belongs to. Every sample position and
	// every displacement below is computed from `cell`, never from `local_px`, so
	// a whole cell moves as one block and the output stays on the art grid.
	vec2 cell = (floor(local_px / grid) + vec2(0.5, 0.5)) * grid;

	float surface_y = logical.y * (1.0 - level);

	// Restrained periodic surface wave, gated by PIXEL_WATER_FLAG_WAVES. Gating
	// with the flag (rather than zeroing the amplitude) is what lets a game
	// toggle waves without destroying the authored amplitude.
	float wave = 0.0;
	if (waves_on > 0.5)
	{
		wave = amplitude * sin(WATER_TAU * (time / period + cell.x / (WATER_WAVE_CELLS * grid)));
	}

	// Bounded fading impacts: local falloff in X around the impact, linear fade
	// over the impact's lifetime, and an outward-travelling oscillation so the
	// disturbance reads as a ripple rather than a bump.
	float ripple = 0.0;
	for (int i = 0; i < WATER_MAX_RIPPLES; ++i)
	{
		if (float(i) >= ripple_count) continue;   // past the live entries
		vec4 r = u_water_ripples[i];
		float age = time - r.y;
		// Outside [0, duration) contributes NOTHING — not a clamped tail.
		if (age < 0.0 || age >= ripple_duration) continue;
		float dist = abs(cell.x - r.x);
		float falloff = max(0.0, 1.0 - dist / ripple_radius);   // local falloff
		float fade = 1.0 - age / ripple_duration;               // time-based fade
		ripple += ripple_strength * r.z * falloff * fade *
			sin(WATER_TAU * (dist / ripple_radius - age / ripple_duration));
	}

	// One quantization for the whole surface displacement, so wave + ripples
	// together land on a whole number of grid increments.
	float offset = waterQuant(wave + ripple, grid);
	float surface = surface_y + offset;

	// Silhouette mask, sampled at the cell centre in reservoir-local UV.
	// Coverage = alpha x max(rgb) so a white-on-transparent mask and a
	// white-on-black mask both read as "interior".
	vec2 cell_uv = clamp(cell / logical, vec2(0.0, 0.0), vec2(1.0, 1.0));
	vec4 mask_texel = texture2D(s_water_mask, cell_uv);
	float mask_a = mix(1.0, mask_texel.a * max(mask_texel.r, max(mask_texel.g, mask_texel.b)), has_mask);

	// Clip to BOTH the mask and the fill level. `step(1e-6, level)` is the
	// explicit "level 0 renders no water" gate.
	float below = step(surface, cell.y);
	float coverage = mask_a * below * step(1e-6, level);

	// Water body: surface colour at the top of the column, deep colour at the
	// reservoir floor. Both are LINEAR already — no gamma conversion here.
	float depth_span = max(logical.y - surface, 1e-4);
	float depth = clamp((cell.y - surface) / depth_span, 0.0, 1.0);
	vec3 body_rgb = mix(u_water_color[1].rgb, u_water_color[0].rgb, depth);
	float body_a = mix(u_water_color[1].a, u_water_color[0].a, depth);

	// Supplied reflection, displaced horizontally by at most `distortion_px`
	// (authored as at most ONE logical pixel) and quantized to the grid. The
	// texture is used as authored: no flip, no scene capture.
	float shift = waterQuant(
		distortion * sin(WATER_TAU * (time / period + cell.y / (WATER_REFLECT_CELLS * grid))),
		grid);
	vec2 reflect_uv = clamp(
		vec2((cell.x + shift) / logical.x, cell.y / logical.y),
		vec2(0.0, 0.0), vec2(1.0, 1.0));
	vec4 reflect_texel = texture2D(s_water_reflect, reflect_uv);
	float reflect_mix = reflect_opacity * has_reflect * reflect_texel.a;
	vec3 water_rgb = mix(body_rgb, reflect_texel.rgb, reflect_mix);

	// LIMITED highlight: the topmost cell row of the water column only, its
	// strength tracking the surface's own displacement so crests read brighter.
	// This is a stylistic rim, not simulated light.
	float crest_scale = max(amplitude + abs(ripple_strength), 1e-4);
	float crest = clamp(0.5 + 0.5 * (offset / crest_scale), 0.0, 1.0);
	float highlight = u_water_color[2].a * (1.0 - step(grid, cell.y - surface)) * crest;
	water_rgb = mix(water_rgb, u_water_color[2].rgb, highlight);

	// WATER OVER SPRITE ART, straight-alpha (the STATE_BLEND_ALPHA path, same
	// over-operator shape as fs_outline). The water is the FOREGROUND layer here:
	// the reservoir art is usually opaque, so compositing the other way round
	// would multiply the water by (1 - 1) and render nothing at all.
	//     comp_a   = Aw + Ab*(1-Aw)
	//     comp_pre = Cw*Aw + Cb*Ab*(1-Aw)
	// The tint fade applies to the water too, so tint.a = 0 hides art and water
	// together, and a level of 0 (coverage 0) reduces exactly to `base`.
	float water_a = coverage * body_a * v_color0.a;
	float comp_a = water_a + base.a * (1.0 - water_a);
	vec3 comp_pre = water_rgb * water_a + base.rgb * base.a * (1.0 - water_a);
	vec3 comp_rgb = comp_a > 0.0 ? comp_pre / comp_a : vec3(0.0, 0.0, 0.0);

	gl_FragColor = vec4(comp_rgb, comp_a);
}
