class_name MazeBuilder
extends Node2D

# WALL_THICKNESS agrega un pequeno margen extra a lo largo de cada segmento de pared
# (no solo en su espesor) para que las esquinas donde se cruzan una pared horizontal
# y una vertical no dejen un huequito diagonal sin colision.
const WALL_THICKNESS := 4.0
const WALL_COLOR := Color(0.25, 0.25, 0.25)

@onready var generator: MazeGenerator = $MazeGenerator

var maze: Array[Array] = []
var start_cell_pos: Vector2i = Vector2i.ZERO

var _h_wall_shape: RectangleShape2D
var _v_wall_shape: RectangleShape2D


# Punto de entrada: dado un seed, (re)genera el laberinto logico y su geometria fisica.
# Se puede llamar varias veces (ej. al reconectar) porque limpia las paredes previas.
func build(seed_value: int) -> void:
	_clear_previous_walls()
	maze = generator.generate_maze(seed_value)
	start_cell_pos = _find_cell_with_content(MazeCell.Content.START)
	_build_walls()


# Posicion en el mundo (pixeles) del centro de la celda START, usada como spawn point.
func get_start_world_position() -> Vector2:
	var cs := float(generator.cell_size)
	return Vector2(start_cell_pos) * cs + Vector2(cs, cs) / 2.0


func _clear_previous_walls() -> void:
	for child in get_children():
		if child.name.begins_with("Wall_"):
			child.queue_free()


func _find_cell_with_content(content: MazeCell.Content) -> Vector2i:
	for y in range(generator.maze_height):
		for x in range(generator.maze_width):
			if maze[y][x].content == content:
				return Vector2i(x, y)
	return Vector2i(generator.maze_width / 2, generator.maze_height / 2)


# Cada celda solo dibuja su pared norte y oeste; asi cada pared interna del grid se
# dibuja una sola vez (remove_wall() en maze_generator.gd siempre limpia el par de
# flags a la vez, wall_north/wall_west de todas las celdas ya cubren todo el interior).
# Los bordes sur y este del grid completo se agregan aparte porque ninguna celda
# vecina los "reclama" como su norte/oeste.
func _build_walls() -> void:
	var cs := float(generator.cell_size)
	# Un solo RectangleShape2D compartido por orientacion (reutilizado por referencia
	# en cada CollisionShape2D) en vez de crear un recurso nuevo por pared.
	_h_wall_shape = RectangleShape2D.new()
	_h_wall_shape.size = Vector2(cs + WALL_THICKNESS, WALL_THICKNESS)
	_v_wall_shape = RectangleShape2D.new()
	_v_wall_shape.size = Vector2(WALL_THICKNESS, cs + WALL_THICKNESS)

	for y in range(generator.maze_height):
		for x in range(generator.maze_width):
			var cell: MazeCell = maze[y][x]
			if cell.wall_north:
				_add_wall(Vector2(x * cs + cs / 2.0, y * cs), _h_wall_shape)
			if cell.wall_west:
				_add_wall(Vector2(x * cs, y * cs + cs / 2.0), _v_wall_shape)
			if y == generator.maze_height - 1 and cell.wall_south:
				_add_wall(Vector2(x * cs + cs / 2.0, (y + 1) * cs), _h_wall_shape)
			if x == generator.maze_width - 1 and cell.wall_east:
				_add_wall(Vector2((x + 1) * cs, y * cs + cs / 2.0), _v_wall_shape)


func _add_wall(world_pos: Vector2, shape: RectangleShape2D) -> void:
	var wall := StaticBody2D.new()
	wall.name = "Wall_%d_%d" % [int(world_pos.x), int(world_pos.y)]
	wall.position = world_pos
	wall.collision_layer = 2 # layer_2 = "Wall" (ver project.godot)
	wall.collision_mask = 0 # estatico, no necesita detectar nada

	var collision := CollisionShape2D.new()
	collision.shape = shape
	wall.add_child(collision)

	var visual := ColorRect.new()
	visual.color = WALL_COLOR
	visual.size = shape.size
	visual.position = -shape.size / 2.0
	visual.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wall.add_child(visual)

	add_child(wall)
