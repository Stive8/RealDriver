shader_type spatial;
render_mode specular_disabled;

uniform vec3 shadow_tint : source_color = vec3(0.15, 0.18, 0.22);
uniform float light_boost = 1.0;

void fragment() {
	vec3 wheel_color = vec3(0.05, 0.05, 0.05);
	float is_wheel = step(0.5, UV.x);
	ALBEDO = mix(COLOR.rgb, wheel_color, is_wheel);
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
