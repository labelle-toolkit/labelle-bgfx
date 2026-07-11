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
// use case. The atlas is UClamp/VClamp, so taps past the sprite edge clamp to
// the border texel (no neighbouring-frame bleed on a tightly-cropped sprite).
#include <bgfx_shader.sh>

SAMPLER2D(s_tex, 0);
uniform vec4 u_material_color;
uniform vec4 u_material_params;
uniform vec4 u_material_texel;

void main()
{
	vec4 base = texture2D(s_tex, v_texcoord0) * v_color0;

	vec2 px = u_material_texel.xy * u_material_params.x; // thickness in UV
	float diag = 0.70710678;                             // 1/sqrt(2)

	// Max neighbour alpha over the 8-tap ring.
	float ring = 0.0;
	ring = max(ring, texture2D(s_tex, v_texcoord0 + vec2( px.x, 0.0)).a);
	ring = max(ring, texture2D(s_tex, v_texcoord0 + vec2(-px.x, 0.0)).a);
	ring = max(ring, texture2D(s_tex, v_texcoord0 + vec2(0.0,  px.y)).a);
	ring = max(ring, texture2D(s_tex, v_texcoord0 + vec2(0.0, -px.y)).a);
	ring = max(ring, texture2D(s_tex, v_texcoord0 + vec2( px.x * diag,  px.y * diag)).a);
	ring = max(ring, texture2D(s_tex, v_texcoord0 + vec2(-px.x * diag,  px.y * diag)).a);
	ring = max(ring, texture2D(s_tex, v_texcoord0 + vec2( px.x * diag, -px.y * diag)).a);
	ring = max(ring, texture2D(s_tex, v_texcoord0 + vec2(-px.x * diag, -px.y * diag)).a);

	// softness: 0 → hard (threshold at 0.5), 1 → feathered (linear ramp).
	float hard = step(0.5, ring);
	float soft = smoothstep(0.0, 1.0, ring);
	float coverage = mix(hard, soft, clamp(u_material_params.y, 0.0, 1.0));

	// Outline only where the sprite itself is not already opaque.
	float outline_a = u_material_color.a * coverage * (1.0 - base.a);

	// Composite the sprite OVER the outline (straight-alpha result for the
	// STATE_BLEND_ALPHA path): premultiply, add, then un-premultiply.
	float a = base.a + outline_a * (1.0 - base.a);
	vec3 pre = base.rgb * base.a + u_material_color.rgb * outline_a * (1.0 - base.a);
	vec3 rgb = a > 0.0 ? pre / a : vec3(0.0, 0.0, 0.0);
	gl_FragColor = vec4(rgb, a);
}
