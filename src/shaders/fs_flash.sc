$input v_texcoord0, v_color0

// Material effect `flash` (labelle-gfx#305, MaterialEffect.flash). The GPU
// hit-flash: samples the sprite texel (× vertex colour/tint, matching fs_sprite)
// and mixes its RGB toward the flash colour by `amount`, preserving the sprite's
// alpha so the silhouette is unchanged.
//   u_material_color = flash rgba  (MaterialUniforms.r,g,b,a — .a currently
//                      unused by the mix, reserved for a future additive term)
//   u_material_params.x = amount   (MaterialUniforms.scalar0; 0 = sprite … 1 =
//                      fully flashed)
// Shares the uniform names with fs_palette so bgfx creates each uniform once.
#include <bgfx_shader.sh>

SAMPLER2D(s_tex, 0);
uniform vec4 u_material_color;
uniform vec4 u_material_params;

void main()
{
	vec4 texel = texture2D(s_tex, v_texcoord0) * v_color0;
	float amount = clamp(u_material_params.x, 0.0, 1.0);
	vec3 rgb = mix(texel.rgb, u_material_color.rgb, amount);
	gl_FragColor = vec4(rgb, texel.a);
}
