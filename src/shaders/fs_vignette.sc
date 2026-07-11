$input v_texcoord0, v_color0

// Post-fx pass `vignette` (labelle-gfx#305 P2, PostPassKind.vignette). Darken the
// frame toward its edges, fading toward a tint colour. `radius` is where the
// darkening begins (0 = centre … 1 = corner), `softness` its falloff width, and
// `intensity` how far the edge is pushed toward `tint`.
//   u_postfx_params.x = intensity   .y = radius   .z = softness
//   u_postfx_color.rgb = tint (linear 0..1)
#include <bgfx_shader.sh>

SAMPLER2D(s_tex, 0);
uniform vec4 u_postfx_params;
uniform vec4 u_postfx_color;

void main()
{
	vec3 base = texture2D(s_tex, v_texcoord0).rgb;
	vec2 d = v_texcoord0 - vec2(0.5, 0.5);
	float dist = length(d) * 1.41421356; // 0 at centre … ~1 at the corner
	float edge = smoothstep(u_postfx_params.y, u_postfx_params.y + max(u_postfx_params.z, 0.0001), dist);
	vec3 col = mix(base, u_postfx_color.rgb, edge * clamp(u_postfx_params.x, 0.0, 1.0));
	gl_FragColor = vec4(col, 1.0);
}
