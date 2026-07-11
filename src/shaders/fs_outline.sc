$input v_texcoord0, v_color0

// Material effect `outline` (labelle-gfx#305, MaterialEffect.outline). An
// alpha-dilated silhouette: where the sprite's own texel is (near-)transparent
// but a NEIGHBOUR texel within `thickness` is opaque, the outline colour is
// drawn; the sprite's own opaque texels composite on top. Feathered by
// `softness`. Samples the sprite texel × vertex colour/tint (matching
// fs_sprite) for the interior.
//   u_material_color = outline rgba (MaterialUniforms.r,g,b,a)
//   u_material_params.x = thickness (MaterialUniforms.scalar0; px — see the
//                         texel-space approximation note below)
//   u_material_params.y = softness  (MaterialUniforms.scalar1; 0 = hard edge …
//                         1 = feathered)
//   u_material_texel = (1/tex_w, 1/tex_h, tex_w, tex_h) — the sprite texture's
//                      pixel size, so `thickness` px maps to a UV offset. Zig
//                      uploads it from the bound texture's dimensions.
//   u_material_rect  = (u0, v0, u1, v1) — the sprite's SOURCE FRAME in whole-
//                      atlas UV space ((0,0,1,1) for a standalone texture). A
//                      neighbour tap that lands OUTSIDE this rect is treated as
//                      transparent (see the atlas-bleed note below).
//
// thickness px: interpreted in SOURCE-TEXEL space (thickness * texel.xy), i.e.
// design px == source texel — exact when the sprite is drawn 1:1, an
// approximation when scaled. Documented tradeoff; keeping it in texel space
// avoids threading the dest/source scale into the material seam.
//
// Tap count: a fixed 8-tap single ring (N/S/E/W + 4 diagonals) at the thickness
// radius — the classic cheap dilation kernel. Documented approximation: a single
// ring (not a filled disc), so very large thicknesses read as a ring of samples
// rather than a solid dilation, which is fine for the selection/hover-highlight
// use case.
//
// Atlas bleed: labelle sprites are SUB-RECTS of a shared atlas, so a tap past
// the frame edge lands on a NEIGHBOURING frame, not empty space (UClamp only
// clamps at the whole-atlas border, not the frame border). Each tap is therefore
// gated by `u_material_rect`: a UV outside [rect.xy, rect.zw] contributes 0
// (out-of-frame = transparent), so the outline never dilates a neighbour's
// content into this sprite.
//
// LIMITATION (#4, documented — see texture.zig): the outline can only draw
// WITHIN the sprite's `dest` quad, so a tightly-cropped frame whose opaque
// pixels reach the frame edge has no room for the OUTWARD outline there (it is
// clipped at the frame boundary). A full outward outline needs quad expansion
// (draw into a dest enlarged by `thickness`) — a P3 follow-up, not v1.
#include <bgfx_shader.sh>

SAMPLER2D(s_tex, 0);
uniform vec4 u_material_color;
uniform vec4 u_material_params;
uniform vec4 u_material_texel;
uniform vec4 u_material_rect;

// Neighbour alpha at `uv`, gated to the source frame: a UV outside the frame
// rect (an adjacent atlas frame) contributes 0 so the outline can't bleed it.
#define OUTLINE_TAP(uv) \
	max(ring, step(u_material_rect.x, (uv).x) * step((uv).x, u_material_rect.z) * \
	          step(u_material_rect.y, (uv).y) * step((uv).y, u_material_rect.w) * \
	          texture2D(s_tex, (uv)).a)

void main()
{
	// INTRINSIC sprite texel (NO tint): the silhouette + ring math must key off
	// the sprite's own alpha, not the tinted alpha — otherwise a faded sprite
	// (tint.a < 1) has a sub-1 interior alpha and the outline colour leaks UNDER
	// the opaque body. `v_color0.rgb` still tints the interior COLOUR; the tint
	// FADE (`v_color0.a`) is applied ONCE to the final composite (see below).
	vec4 texel = texture2D(s_tex, v_texcoord0);
	float src_a = texel.a;                       // intrinsic silhouette alpha
	vec3 sprite_rgb = texel.rgb * v_color0.rgb;  // tinted interior colour

	vec2 px = u_material_texel.xy * u_material_params.x; // thickness in UV
	float diag = 0.70710678;                             // 1/sqrt(2)

	// Max in-frame neighbour alpha over the 8-tap ring (raw sprite alpha, so the
	// silhouette is tint-independent).
	float ring = 0.0;
	ring = OUTLINE_TAP(v_texcoord0 + vec2( px.x, 0.0));
	ring = OUTLINE_TAP(v_texcoord0 + vec2(-px.x, 0.0));
	ring = OUTLINE_TAP(v_texcoord0 + vec2(0.0,  px.y));
	ring = OUTLINE_TAP(v_texcoord0 + vec2(0.0, -px.y));
	ring = OUTLINE_TAP(v_texcoord0 + vec2( px.x * diag,  px.y * diag));
	ring = OUTLINE_TAP(v_texcoord0 + vec2(-px.x * diag,  px.y * diag));
	ring = OUTLINE_TAP(v_texcoord0 + vec2( px.x * diag, -px.y * diag));
	ring = OUTLINE_TAP(v_texcoord0 + vec2(-px.x * diag, -px.y * diag));

	// softness: 0 → hard (threshold at 0.5), 1 → feathered (linear ramp).
	float hard = step(0.5, ring);
	float soft = smoothstep(0.0, 1.0, ring);
	float coverage = mix(hard, soft, clamp(u_material_params.y, 0.0, 1.0));

	// The outline's effective contribution under the sprite, gated by the sprite's
	// INTRINSIC silhouette: its own alpha (colour alpha × coverage) times the
	// fraction the sprite leaves uncovered, i.e. Ao·(1−As) with As = intrinsic
	// alpha. So an opaque interior (src_a == 1) gets ZERO outline regardless of
	// tint. This ALREADY folds in the over-operator's (1−As) term.
	float outline_a = u_material_color.a * coverage * (1.0 - src_a);

	// Sprite OVER outline at INTRINSIC alpha (straight-alpha result for the
	// STATE_BLEND_ALPHA path). A-over-B: comp_a = As + Ao·(1−As); premultiplied
	// colour = As·Cs + Ao·(1−As)·Co. `outline_a` is ALREADY Ao·(1−As), so it is
	// used DIRECTLY (multiplying by (1−As) again would double-attenuate the
	// outline on anti-aliased edges, 0 < src_a < 1).
	float comp_a = src_a + outline_a;
	vec3 comp_pre = sprite_rgb * src_a + u_material_color.rgb * outline_a;
	vec3 comp_rgb = comp_a > 0.0 ? comp_pre / comp_a : vec3(0.0, 0.0, 0.0);

	// Apply the tint FADE ONCE to the whole composite, so the interior stays
	// sprite-coloured and the outline stays outline-coloured while BOTH fade
	// together (tint.a → 0 hides sprite AND outline; tint.a == 1 is unchanged).
	// For a no-outline pixel this reduces exactly to `texel * v_color0`.
	gl_FragColor = vec4(comp_rgb, comp_a * v_color0.a);
}
