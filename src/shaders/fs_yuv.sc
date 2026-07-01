$input v_texcoord0, v_color0

// GPU YUV->RGBA video fragment shader. Samples three single-channel R8 planes
// (Y full-res, U/V half-res) bound to s_texY/s_texU/s_texV at units 0/1/2 and
// does the BT.601 limited-range convert, matching yuv.zig's fixed-point path:
//   Y offset 16/255 = 0.0627451, UV offset 128/255 = 0.5019608
//   Y gain 298/256 = 1.1640625, V->R 409/256 = 1.5976562,
//   U->G 100/256 = 0.390625, V->G 208/256 = 0.8125, U->B 516/256 = 2.015625
#include <bgfx_shader.sh>

SAMPLER2D(s_texY, 0);
SAMPLER2D(s_texU, 1);
SAMPLER2D(s_texV, 2);

void main()
{
	float y = texture2D(s_texY, v_texcoord0).x - 0.0627451;
	float u = texture2D(s_texU, v_texcoord0).x - 0.5019608;
	float v = texture2D(s_texV, v_texcoord0).x - 0.5019608;

	vec4 rgba;
	rgba.x = clamp((y * 1.1640625) + (v * 1.5976562), 0.0, 1.0);
	rgba.y = clamp((y * 1.1640625) - (u * 0.390625) - (v * 0.8125), 0.0, 1.0);
	rgba.z = clamp((y * 1.1640625) + (u * 2.015625), 0.0, 1.0);
	rgba.w = 1.0;

	gl_FragColor = rgba * v_color0;
}
