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
	vec4 base = texture2D(s_tex, v_texcoord0) * v_color0;

	vec2 px = u_material_texel.xy * u_material_params.x; // thickness in UV
	float diag = 0.70710678;                             // 1/sqrt(2)

	// Max in-frame neighbour alpha over the 8-tap ring.
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

	// The outline's effective contribution under the sprite: its own alpha
	// (colour alpha × coverage) times the fraction the sprite leaves uncovered,
	// i.e. Ao·(1−As). This ALREADY folds in the over-operator's (1−As) term.
	// The tint alpha (v_color0.a) scales it too, so fading the sprite out
	// (tint.a → 0) fades its outline with it (a hidden sprite hides its outline).
	float outline_a = u_material_color.a * v_color0.a * coverage * (1.0 - base.a);

	// Sprite OVER outline (straight-alpha result for the STATE_BLEND_ALPHA path).
	// A-over-B: result_a = As + Ao·(1−As); premultiplied colour = As·Cs +
	// Ao·(1−As)·Co. Since `outline_a` is ALREADY Ao·(1−As), it is used DIRECTLY
	// here — multiplying by (1−As) a second time would double-attenuate the
	// outline on semi-transparent / anti-aliased sprite edges (0 < base.a < 1).
	float a = base.a + outline_a;
	vec3 pre = base.rgb * base.a + u_material_color.rgb * outline_a;
	vec3 rgb = a > 0.0 ? pre / a : vec3(0.0, 0.0, 0.0);
	gl_FragColor = vec4(rgb, a);
}
