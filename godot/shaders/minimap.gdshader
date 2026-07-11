shader_type canvas_item;
// Minimapa (Fase M-4): traslada+rota la textura horneada (vías + ruta) para que
// ARRIBA = rumbo del vehículo, con máscara circular y borde fino en el mismo pase.
//
// Convención del proyecto (ver TrafficManager._right): +X = este, +Z = sur en el mundo.
// heading = vehicle.rotation.y, en la misma convención que el resto del proyecto
// (yaw = atan2(dx, dz), Basis(UP, yaw) para orientar; ver route_generator/traffic_manager).
//
// Para un offset de pantalla "local" (x=derecha, y=abajo, centrado, [-1,1]) se muestrea
// el mundo desplazado por N * local * view_uv_radius, con
//   N = [[cos(heading), sin(heading)], [-sin(heading), cos(heading)]]
// Historia de esta fórmula (ver también minimap.gd:_update_north_label): la versión
// original (arriba=adelante, derecha=lateral derecho real, giro derecha=antihorario) hacía
// que el mapa fluyera hacia ABAJO al avanzar; el humano pidió lo contrario (fluir hacia
// ARRIBA). La primera corrección (reflexión vertical) lo logró pero invirtió el sentido
// de giro (derecha pasaba a girar horario), que el humano reportó como "giro a la derecha
// y en el minimapa parece que giro a la izquierda". Esta versión (rotación propia de 180°
// sobre la original, N = -M_original) conserva arriba=adelante-invertido (fluye hacia
// arriba, como se pidió) Y el sentido de giro correcto (derecha=antihorario); el costo
// matemáticamente inevitable es que local=(1,0) (derecha en pantalla) ya NO es el lateral
// derecho real del vehículo sino el izquierdo — no hay forma de arreglar los tres ejes
// (arriba/abajo, izquierda/derecha, sentido de giro) a la vez con una sola rotación/reflexión.

uniform sampler2D map_tex : filter_linear;
uniform vec2 player_uv = vec2(0.5, 0.5);
uniform float heading = 0.0;
uniform float view_uv_radius = 0.15;

const vec4 BG_COLOR = vec4(0.13, 0.13, 0.16, 1.0);
const vec4 BORDER_COLOR = vec4(0.92, 0.92, 0.95, 1.0);
const float BORDER_WIDTH = 0.025;

void fragment() {
	vec2 local = (UV - vec2(0.5)) * 2.0;
	float r = length(local);
	if (r > 1.0) {
		discard;
	}

	float c = cos(heading);
	float s = sin(heading);
	vec2 offset = vec2(
		 c * local.x + s * local.y,
		-s * local.x + c * local.y
	) * view_uv_radius;
	vec2 sample_uv = player_uv + offset;

	vec4 map_color;
	if (sample_uv.x < 0.0 || sample_uv.x > 1.0 || sample_uv.y < 0.0 || sample_uv.y > 1.0) {
		map_color = BG_COLOR;
	} else {
		vec4 tex_color = texture(map_tex, sample_uv);
		map_color = mix(BG_COLOR, tex_color, tex_color.a);
	}

	float border = smoothstep(1.0 - BORDER_WIDTH, 1.0, r);
	COLOR = mix(map_color, BORDER_COLOR, border);
}
