class_name ModeContext
extends RefCounted
var vehicle: VehicleBody3D
var graph: TrafficGraph
var map_meta: Dictionary
var hud_layer: CanvasLayer   # capa "ModeHud": el modo añade/quita ahí su HUD propio
var minimap: Node            # null hasta M-4 o si está deshabilitado: comprobar siempre
