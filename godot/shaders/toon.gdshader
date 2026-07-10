shader_type spatial;
render_mode specular_disabled;

uniform bool use_vertex_color = false;
uniform vec4 albedo_color : source_color = vec4(1.0);
uniform vec3 shadow_tint : source_color = vec3(0.15, 0.18, 0.22);
uniform float light_boost = 1.0;

void fragment() {
	ALBEDO = (use_vertex_color ? COLOR : albedo_color).rgb;
}

void light() {
	float NdotL = dot(NORMAL, LIGHT);
	float step_val;
	if (NdotL > 0.35)
		step_val = 1.0;
	else if (NdotL > 0.15)
		step_val = smoothstep(0.15, 0.35, NdotL);
	else
		step_val = 0.0;

	DIFFUSE_LIGHT = LIGHT_COLOR * light_boost * mix(shadow_tint, vec3(1.0), step_val);
}
