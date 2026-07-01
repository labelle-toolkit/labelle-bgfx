$input v_texcoord0, v_color0

// 2D sprite fragment shader: samples the bound texture and multiplies by the
// vertex colour. Flat-colour draws bind a 1x1 white texture so tex*color=color.
#include <bgfx_shader.sh>

SAMPLER2D(s_tex, 0);

void main()
{
	gl_FragColor = texture2D(s_tex, v_texcoord0) * v_color0;
}
