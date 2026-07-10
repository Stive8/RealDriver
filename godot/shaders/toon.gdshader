shader_type spatial;

uniform bool use_vertex_color = false;
uniform vec4 albedo_color : source_color = vec4(1.0);

void fragment() {
	vec4 base = use_vertex_color ? COLOR : albedo_color;
	ALBEDO = base.rgb;
}

void light() {
	float NdotL = dot(NORMAL, LIGHT);
	float step_val = 0.25;
	if (NdotL > 0.15) {
		step_val = 0.6;
	}
	if (NdotL > 0.35) {
		step_val = 1.0;
	}
	DIFFUSE_LIGHT = vec3(step_val);
}
