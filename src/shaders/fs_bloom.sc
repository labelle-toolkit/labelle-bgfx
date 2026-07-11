$input v_texcoord0, v_color0

// Post-fx pass `bloom` (labelle-gfx#305 P2, PostPassKind.bloom). A SINGLE-PASS
// approximation of the classic bright-pass + blur + composite: over a 5x5
// neighbourhood it bright-passes each tap (luma above `threshold`) and
// Gaussian-accumulates it, stepping by `radius` texels, then adds that blurred
// bright energy back over the base scene scaled by `intensity`. The backend owns
// this internal kernel (RFC §2.2); v1 deliberately keeps it to ONE pass (no
// separate downsample chain) so it stays a pure src→dst primitive the gfx
// ping-pong drives — a separable multi-tap downsample chain is a possible v2.
//   u_postfx_params.x = threshold   u_postfx_params.y = intensity
//   u_postfx_params.z = radius (texel step)   u_postfx_texel.xy = 1/size
#include <bgfx_shader.sh>

SAMPLER2D(s_tex, 0);
uniform vec4 u_postfx_params;
uniform vec4 u_postfx_texel;

void main()
{
	vec2 uv = v_texcoord0;
	vec3 base = texture2D(s_tex, uv).rgb;
	float threshold = u_postfx_params.x;
	vec2 step_uv = u_postfx_texel.xy * max(u_postfx_params.z, 0.0);
	vec3 sum = vec3(0.0, 0.0, 0.0);
	float wsum = 0.0;
	for (int y = -2; y <= 2; y++) {
		for (int x = -2; x <= 2; x++) {
			vec2 off = vec2(float(x), float(y)) * step_uv;
			vec3 c = texture2D(s_tex, uv + off).rgb;
			float luma = dot(c, vec3(0.299, 0.587, 0.114));
			float bright = max(luma - threshold, 0.0);
			float w = exp(-0.5 * float(x * x + y * y));
			sum += c * bright * w;
			wsum += w;
		}
	}
	vec3 bloom = sum / max(wsum, 0.0001);
	gl_FragColor = vec4(base + bloom * u_postfx_params.y, 1.0);
}
