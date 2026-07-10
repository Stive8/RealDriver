shader_type spatial;
render_mode specular_disabled;

uniform bool use_vertex_color = false;
uniform vec4 albedo_color : source_color = vec4(1.0);
uniform vec3 shadow_tint : source_color = vec3(0.15, 0.18, 0.22);
uniform float light_boost = 1.0;

uniform vec4 window_color : source_color = vec4(0.1, 0.15, 0.22, 0.7);
uniform float frame_ratio = 0.15;
uniform float floor_height = 3.2;
uniform float window_spacing = 2.5;

void fragment() {
	vec3 base_albedo = (use_vertex_color ? COLOR : albedo_color).rgb;

	float cell_u = mod(UV.x, window_spacing) / window_spacing;
	float cell_v = mod(UV.y, floor_height) / floor_height;

	float in_window = step(frame_ratio, cell_u) * step(cell_u, 1.0 - frame_ratio)
	                * step(frame_ratio, cell_v) * step(cell_v, 1.0 - frame_ratio);

	ALBEDO = mix(base_albedo, window_color.rgb, in_window * window_color.a);
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
