$input v_texcoord0, v_color0

// Material effect `palette_swap` (labelle-gfx#305, MaterialEffect.palette_swap).
// Recolours a shared atlas per team/faction by treating the sampled texel's RED
// channel as a palette INDEX and looking it up in a small LUT ramp (a 1×N / N×1
// texture bound at sampler unit 1). The sprite's alpha is preserved (a
// transparent atlas pixel stays transparent). Vertex colour/tint is applied to
// the LUT result, matching fs_sprite's tint semantics.
//   s_lut               = LUT ramp                 (MaterialUniforms.aux_texture)
//   u_material_params.z  = active ramp entry count  (MaterialUniforms.aux_count)
// Index → LUT texel: k = round(raw.r * 255); u = (k + 0.5) / aux_count. The LUT
// is point-sampled (nearest), so index k lands on ramp entry k exactly. Zig
// draws plain (no material program) when aux_texture == 0, so s_lut is always a
// real texture here (never a degrade-crash).
#include <bgfx_shader.sh>

SAMPLER2D(s_tex, 0);
SAMPLER2D(s_lut, 1);
uniform vec4 u_material_color;
uniform vec4 u_material_params;

void main()
{
	vec4 raw = texture2D(s_tex, v_texcoord0);
	float count = max(u_material_params.z, 1.0);
	float k = floor(raw.r * 255.0 + 0.5);
	float u = (k + 0.5) / count;
	vec4 lut = texture2D(s_lut, vec2(u, 0.5));
	gl_FragColor = vec4(lut.rgb, raw.a) * v_color0;
}
