$input v_texcoord0, v_color0

// GPU YUV->RGBA video fragment shader. Samples three single-channel R8 planes
// (Y full-res, U/V half-res) bound to s_texY/s_texU/s_texV at units 0/1/2 and
// converts with the stream's matrix (labelle-bgfx#155), set per draw from
// `video/yuv_uniform.zig` (the same `yuv.Matrix` the CPU path uses):
//   u_yuvOffsetGain = (Y offset, Y gain, chroma offset, 0)
//   u_yuvCoeffs     = (V->R, U->G, V->G, U->B)
// Decoders without colour metadata get BT.601 limited range, i.e. the former
// hard-coded constants: (16/255, 298/256, 128/255) and 409/100/208/516 / 256.
#include <bgfx_shader.sh>

SAMPLER2D(s_texY, 0);
SAMPLER2D(s_texU, 1);
SAMPLER2D(s_texV, 2);

uniform vec4 u_yuvOffsetGain;
uniform vec4 u_yuvCoeffs;

void main()
{
	float y = (texture2D(s_texY, v_texcoord0).x - u_yuvOffsetGain.x) * u_yuvOffsetGain.y;
	float u = texture2D(s_texU, v_texcoord0).x - u_yuvOffsetGain.z;
	float v = texture2D(s_texV, v_texcoord0).x - u_yuvOffsetGain.z;

	vec4 rgba;
	rgba.x = clamp(y + (v * u_yuvCoeffs.x), 0.0, 1.0);
	rgba.y = clamp(y - (u * u_yuvCoeffs.y) - (v * u_yuvCoeffs.z), 0.0, 1.0);
	rgba.z = clamp(y + (u * u_yuvCoeffs.w), 0.0, 1.0);
	rgba.w = 1.0;

	gl_FragColor = rgba * v_color0;
}
