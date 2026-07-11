$input v_texcoord0, v_color0

// Post-fx pass `crt` (labelle-gfx#305 P2, PostPassKind.crt). The retro CRT tube:
// barrel distortion + chromatic aberration + scanlines + a soft RGB shadow mask.
//   u_postfx_params.x = curvature   .y = scanline   .z = mask   .w = aberration
//   u_postfx_texel.zw = (width, height) in pixels
#include <bgfx_shader.sh>

SAMPLER2D(s_tex, 0);
uniform vec4 u_postfx_params;
uniform vec4 u_postfx_texel;

void main()
{
	// Barrel-distort the sample coord around the centre by `curvature`.
	vec2 uv = v_texcoord0;
	vec2 cc = uv - vec2(0.5, 0.5);
	float r2 = dot(cc, cc);
	vec2 warp = uv + cc * r2 * u_postfx_params.x;

	// Chromatic aberration: split R/B along x by `aberration`.
	float ab = u_postfx_params.w;
	vec3 col;
	col.r = texture2D(s_tex, warp + vec2(ab, 0.0)).r;
	col.g = texture2D(s_tex, warp).g;
	col.b = texture2D(s_tex, warp - vec2(ab, 0.0)).b;
	// Carry the source alpha (from the primary/green tap) so transparent regions
	// stay transparent rather than being forced opaque.
	float srcA = texture2D(s_tex, warp).a;

	// Outside the warped image → black (the tube bezel).
	float inside = step(0.0, warp.x) * step(warp.x, 1.0) * step(0.0, warp.y) * step(warp.y, 1.0);
	col *= inside;

	// Scanlines: darken alternate rows by `scanline`.
	float lines = 0.5 + 0.5 * abs(sin(warp.y * u_postfx_texel.w * 3.14159265));
	float scan = mix(1.0, lines, clamp(u_postfx_params.y, 0.0, 1.0));

	// Shadow mask: a soft 3-pixel RGB column stripe by `mask`.
	float stripe = 0.6 + 0.4 * step(0.5, fract(warp.x * u_postfx_texel.z / 3.0));
	float m = mix(1.0, stripe, clamp(u_postfx_params.z, 0.0, 1.0));

	gl_FragColor = vec4(col * scan * m, srcA);
}
