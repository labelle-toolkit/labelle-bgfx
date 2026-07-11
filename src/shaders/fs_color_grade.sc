$input v_texcoord0, v_color0

// Post-fx pass `color_grade` (labelle-gfx#305 P2, PostPassKind.color_grade).
// Applies a colour LUT stored as a 2D UNROLLED STRIP (RFC §9 Q3 — portable
// across every backend's loader surface; a true 3D texture isn't). Convention: a
// 16x16x16 cube unrolled HORIZONTALLY into a 256x16 texture — 16 slices of 16x16
// laid left→right; BLUE selects the slice, RED the x within a slice, GREEN the y.
// Blue is linearly interpolated between the two neighbouring slices so banding
// stays low. `strength` cross-fades the graded result over the input
// (0 = original … 1 = full LUT). A zero/absent LUT never reaches this shader —
// Zig blits src→dst straight through instead (degrade, RFC §3).
//   u_postfx_params.x = strength   s_lut = the 256x16 strip
#include <bgfx_shader.sh>

SAMPLER2D(s_tex, 0);
SAMPLER2D(s_lut, 1);
uniform vec4 u_postfx_params;

void main()
{
	vec3 c = clamp(texture2D(s_tex, v_texcoord0).rgb, 0.0, 1.0);
	float N = 16.0;
	float blue = c.b * (N - 1.0);
	float slice0 = floor(blue);
	float f = blue - slice0;
	// x within a slice (red) and y (green), each nudged half a texel to the
	// entry centre; the slice offset (slice/N) advances one tile of width 1/N.
	float xr = c.r * (N - 1.0) / (N * N) + 0.5 / (N * N);
	float yg = c.g * (N - 1.0) / N + 0.5 / N;
	vec3 g0 = texture2D(s_lut, vec2(slice0 / N + xr, yg)).rgb;
	vec3 g1 = texture2D(s_lut, vec2((slice0 + 1.0) / N + xr, yg)).rgb;
	vec3 graded = mix(g0, g1, f);
	gl_FragColor = vec4(mix(c, graded, clamp(u_postfx_params.x, 0.0, 1.0)), 1.0);
}
