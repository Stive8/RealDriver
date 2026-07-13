class_name RibbonUtil
extends RefCounted
## Matematica de cintas (perpendiculares + bisectriz-miter), extraida de road_builder.gd
## (Fase W-2, contrato 5): parametrizada por ancho, SIN muestreo de altura -- reusada por
## road_builder.gd (vias normales y tableros) y water_builder.gd (vias de agua, seccion
## transversal plana muestreada en el eje, no por vertice de cinta).

## Tope de cos(theta/2) en el miter join; evita puntas en giros cerrados.
const MITER_COS_CLAMP := 0.35


## Calcula los dos bordes de una cinta 2D de semiancho `half_width` sobre la polilinea
## `points` (Array de pares [x, z]). Retorna {"a": Array[Vector2], "b": Array[Vector2]},
## mismo tamano que `points`, uno por vertice de la polilinea de entrada.
static func compute_offsets(points: Array, half_width: float) -> Dictionary:
	var n := points.size()
	var offsets_a: Array[Vector2] = []
	var offsets_b: Array[Vector2] = []

	for i in range(n):
		var center := Vector2(points[i][0], points[i][1])
		var offset_vec: Vector2

		if i == 0:
			var dir := (Vector2(points[1][0], points[1][1]) - center).normalized()
			offset_vec = Vector2(dir.y, -dir.x) * half_width
		elif i == n - 1:
			var prev := Vector2(points[i - 1][0], points[i - 1][1])
			var dir := (center - prev).normalized()
			offset_vec = Vector2(dir.y, -dir.x) * half_width
		else:
			# DECISION_PENDIENTE (heredado de road_builder.gd, fase previa a W-2): el espec
			# dice "bisectriz de las direcciones adyacentes"; se interpreta como bisectriz
			# de las NORMALES de esas direcciones (miter join estandar), ya que la bisectriz
			# de las direcciones de viaje no produce un offset perpendicular a la via.
			var prev := Vector2(points[i - 1][0], points[i - 1][1])
			var next := Vector2(points[i + 1][0], points[i + 1][1])
			var dir_in := (center - prev).normalized()
			var dir_out := (next - center).normalized()
			var normal_in := Vector2(dir_in.y, -dir_in.x)
			var normal_out := Vector2(dir_out.y, -dir_out.x)
			var bisector_sum := normal_in + normal_out
			if bisector_sum.length() < 0.001:
				# Giro de ~180 grados: la bisectriz colapsa, usar la normal de entrada.
				offset_vec = normal_in * half_width
			else:
				var bisector := bisector_sum.normalized()
				var cos_half := sqrt(maxf(0.0, (1.0 + dir_in.dot(dir_out)) * 0.5))
				var miter_len := half_width / maxf(MITER_COS_CLAMP, cos_half)
				offset_vec = bisector * miter_len

		offsets_a.append(center + offset_vec)
		offsets_b.append(center - offset_vec)

	return {"a": offsets_a, "b": offsets_b}
