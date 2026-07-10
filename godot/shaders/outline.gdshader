shader_type spatial;
render_mode cull_front, specular_disabled;

uniform float outline_width = 0.03;

void vertex() {
	VERTEX += NORMAL * outline_width;
}

void fragment() {
	ALBEDO = vec3(0.0);
}
