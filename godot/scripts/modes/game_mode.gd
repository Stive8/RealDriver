class_name GameMode
extends Node
## Contrato de modo de juego. Un modo es un subárbol autocontenido:
## recibe el mundo por ModeContext, crea lo suyo como hijos propios,
## y stop_mode() deja el mundo exactamente como estaba.

signal finished(result: Dictionary)  # claves: success: bool, stats: Array (pares [etiqueta, valor] para Resultados), record: bool (opcional)
signal aborted
signal route_changed                 # el minimapa re-hornea su capa de ruta al recibirla

func get_mode_id() -> String: push_error("no implementado"); return ""       # estable, snake_case; entra en claves de guardado
func get_display_name() -> String: push_error("no implementado"); return ""  # texto del botón del menú
func configure(_ctx: ModeContext) -> void: push_error("no implementado")     # inyección de dependencias; guardar ctx; una sola vez
func start_mode() -> void: push_error("no implementado")                     # posicionar vehículo, crear objetos propios, arrancar
func stop_mode() -> void: push_error("no implementado")                      # limpieza TOTAL (también si la carrera no terminó)
func set_paused(_p: bool) -> void: pass                                      # default no-op; contrarreloj congela su reloj
func get_route_overlay() -> Dictionary: return {}                            # {} = sin ruta; si hay: {"polyline": PackedVector2Array (x,z mundo), "markers": Array[Dictionary{"pos": Vector2, "kind": String}]} — kinds: "start", "checkpoint"
