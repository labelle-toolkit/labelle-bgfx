$input v_texcoord0, v_color0

// Material effect `dissolve` (labelle-gfx#305, MaterialEffect.dissolve). A
// burn-away transition: a per-texel noise value gates the sprite — texels whose
// noise falls BELOW the threshold vanish (alpha 0), and the surviving texels
// just past the threshold get a hot burn-edge glow. Samples the sprite texel ×
// vertex colour/tint (matching fs_sprite) and preserves the source alpha for
// the survivors (dissolved texels → alpha 0, so alpha-blend leaves the
// background showing through).
//   u_material_color.rgb  = edge_rgb  (MaterialUniforms.r,g,b — burn-edge glow;
//                           .a ignored per the contract)
//   u_material_params.x   = threshold (MaterialUniforms.scalar0; 0 = solid …
//                           1 = fully gone)
//   u_material_params.y   = edge_width (MaterialUniforms.scalar1; px band of the
//                           burn edge — see the fwidth() note below)
//   u_material_params.w   = use_noise_tex flag (Zig sets 1.0 when a noise
//                           texture is bound at s_lut, else 0.0 → procedural)
//   s_lut                 = optional noise texture (MaterialUniforms.aux_texture;
//                           0 = use the built-in procedural noise below). Bound
//                           at sampler unit 1, SHARED with palette_swap's ramp
//                           sampler (bgfx keys uniforms by name globally). Zig
//                           always binds a VALID texture here (the sprite's own
//                           texture as a dummy on the procedural path), so this
//                           is never an unbound-sampler read.
//
// Built-in noise (aux_texture == 0): a cheap value-noise built from a
// sin-dot-fract hash, sampled at v_texcoord0 * NOISE_SCALE (NOISE_SCALE cells
// across the sprite's 0..1 UV span). Smooth (Hermite-interpolated) so the burn
// front reads as an organic edge rather than per-pixel static. Documented
// approximation — not a Perlin/simplex; good enough for the 2D-juice case.
//
// edge_width px: converted from screen pixels to noise-value units with the
// fragment derivative fwidth(n) — the change in the noise value per screen
// pixel — so `edge_width` is a genuine screen-space width of the glow band.
// Derivatives are core in GLSL 120 / ESSL 300 / Metal / SPIR-V (all four
// targets), so no extension pragma is needed.
#include <bgfx_shader.sh>

SAMPLER2D(s_tex, 0);
SAMPLER2D(s_lut, 1);
uniform vec4 u_material_color;
uniform vec4 u_material_params;

#define NOISE_SCALE 9.0

float dissolveHash(vec2 p)
{
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
}

// Smooth value noise: bilinear-interpolate the 4 lattice-corner hashes with a
// Hermite (smoothstep) fade for a continuous, differentiable field.
float dissolveNoise(vec2 p)
{
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = dissolveHash(i);
	float b = dissolveHash(i + vec2(1.0, 0.0));
	float c = dissolveHash(i + vec2(0.0, 1.0));
	float d = dissolveHash(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

void main()
{
	vec4 texel = texture2D(s_tex, v_texcoord0) * v_color0;

	float n = mix(
		dissolveNoise(v_texcoord0 * NOISE_SCALE),
		texture2D(s_lut, v_texcoord0).r,
		step(0.5, u_material_params.w));

	float threshold = u_material_params.x;
	float reveal = n - threshold;                       // < 0 → dissolved away
	float band = max(fwidth(n) * u_material_params.y, 1e-4);
	float alive = step(0.0, reveal);                    // 1 = kept, 0 = gone
	float edge = 1.0 - smoothstep(0.0, band, max(reveal, 0.0)); // 1 at the front

	vec3 rgb = mix(texel.rgb, u_material_color.rgb, edge);
	gl_FragColor = vec4(rgb, texel.a * alive);
}
