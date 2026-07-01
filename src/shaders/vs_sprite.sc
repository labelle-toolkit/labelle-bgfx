$input a_position, a_texcoord0, a_color0
$output v_texcoord0, v_color0

// 2D sprite vertex shader: transforms the 2D position by u_viewProj and passes
// the texcoord + vertex colour through. Position arrives as vec2 (NDC computed
// in Zig; u_viewProj is set to identity), so it is expanded to vec4(xy, 0, 1).
#include <bgfx_shader.sh>

void main()
{
	gl_Position = mul(u_viewProj, vec4(a_position, 0.0, 1.0));
	v_texcoord0 = a_texcoord0;
	v_color0 = a_color0;
}
