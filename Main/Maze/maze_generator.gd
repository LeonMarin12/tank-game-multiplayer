class_name MazeGenerator
extends Node

@export var maze_width :int = 20 #maze width in cells
@export var maze_height :int = 20 #maze height in cells
@export var alternative_path_probability :float = 0.15 #probability of creating alternative paths (loops)
@export var cell_size :int = 32 #size of each cell in pixels for visualization

# Content spawn probabilities
@export_range(0.0, 1.0) var chest_spawn_probability :float = 0.7 #probability to spawn chest in dead-ends (3 walls)
@export_range(0.0, 1.0) var enemy_spawn_probability :float = 0.2 #probability to spawn enemy in corners (2 walls)


var maze :Array[Array] = [] #2D array of MazeCell resources
var rng :RandomNumberGenerator = RandomNumberGenerator.new()

#region MazeGeneration

# seed_value hace que el laberinto sea una funcion pura (mismo seed -> mismo laberinto).
# Esto es lo que permite que cada peer en la red genere el mismo laberinto de forma
# local sin tener que transmitir el array completo: el host manda solo el seed (un int)
# y cada cliente llama a generate_maze(seed) por su cuenta.
func generate_maze(seed_value: int) -> Array[Array]:
	rng.seed = seed_value

	# Initialize the maze grid
	maze = []
	for y in range(maze_height):
		var row :Array = []
		for x in range(maze_width):
			var cell = MazeCell.new()
			cell.position = Vector2i(x, y)
			cell.visited = false
			cell.wall_north = true
			cell.wall_south = true
			cell.wall_east = true
			cell.wall_west = true
			row.append(cell)
		maze.append(row)
	
	# Generate maze using Recursive Backtracker algorithm
	var stack :Array[Vector2i] = []
	var start_pos = Vector2i(0, 0)
	var current_cell = maze[start_pos.y][start_pos.x]
	current_cell.visited = true
	stack.append(start_pos)
	
	while stack.size() > 0:
		var current_pos = stack[-1] #peek at the top of the stack
		var unvisited_neighbors = get_unvisited_neighbors(current_pos)
		
		if unvisited_neighbors.size() > 0:
			# Choose a random unvisited neighbor
			var next_pos = unvisited_neighbors[rng.randi() % unvisited_neighbors.size()]
			
			# Remove wall between current and next cell
			remove_wall(current_pos, next_pos)
			
			# Mark next cell as visited and push to stack
			maze[next_pos.y][next_pos.x].visited = true
			stack.append(next_pos)
		else:
			# No unvisited neighbors, backtrack
			stack.pop_back()
		
		# Create alternative paths (loops) with some probability
		if rng.randf() < alternative_path_probability:
			var visited_neighbors = get_visited_neighbors(current_pos)
			if visited_neighbors.size() > 0:
				var random_neighbor = visited_neighbors[rng.randi() % visited_neighbors.size()]
				# Only remove wall if there's currently a wall (to avoid redundant connections)
				if has_wall_between(current_pos, random_neighbor):
					remove_wall(current_pos, random_neighbor)
	
	# Assign content to cells based on wall count
	assign_cell_content()
	
	print("Maze generation complete: ", maze_width, "x", maze_height)
	return maze

func get_unvisited_neighbors(pos :Vector2i) -> Array[Vector2i]:
	var neighbors :Array[Vector2i] = []
	var directions = [
		Vector2i(0, -1), # North
		Vector2i(0, 1),  # South
		Vector2i(1, 0),  # East
		Vector2i(-1, 0)  # West
	]
	
	for dir in directions:
		var new_pos = pos + dir
		if is_valid_position(new_pos) and not maze[new_pos.y][new_pos.x].visited:
			neighbors.append(new_pos)
	
	return neighbors

func get_visited_neighbors(pos :Vector2i) -> Array[Vector2i]:
	var neighbors :Array[Vector2i] = []
	var directions = [
		Vector2i(0, -1), # North
		Vector2i(0, 1),  # South
		Vector2i(1, 0),  # East
		Vector2i(-1, 0)  # West
	]
	
	for dir in directions:
		var new_pos = pos + dir
		if is_valid_position(new_pos) and maze[new_pos.y][new_pos.x].visited:
			neighbors.append(new_pos)
	
	return neighbors

func is_valid_position(pos :Vector2i) -> bool:
	return pos.x >= 0 and pos.x < maze_width and pos.y >= 0 and pos.y < maze_height

func remove_wall(pos1 :Vector2i, pos2 :Vector2i):
	var cell1 = maze[pos1.y][pos1.x]
	var cell2 = maze[pos2.y][pos2.x]
	
	# Determine direction and remove appropriate walls
	if pos2.y < pos1.y: # North
		cell1.wall_north = false
		cell2.wall_south = false
	elif pos2.y > pos1.y: # South
		cell1.wall_south = false
		cell2.wall_north = false
	elif pos2.x > pos1.x: # East
		cell1.wall_east = false
		cell2.wall_west = false
	elif pos2.x < pos1.x: # West
		cell1.wall_west = false
		cell2.wall_east = false

func has_wall_between(pos1 :Vector2i, pos2 :Vector2i) -> bool:
	var cell1 = maze[pos1.y][pos1.x]
	
	# Check if there's a wall in the direction of pos2
	if pos2.y < pos1.y: # North
		return cell1.wall_north
	elif pos2.y > pos1.y: # South
		return cell1.wall_south
	elif pos2.x > pos1.x: # East
		return cell1.wall_east
	elif pos2.x < pos1.x: # West
		return cell1.wall_west
	
	return false

#endregion


#region AssignCellContent

func assign_cell_content():
	# Calculate center position
	var center_x = maze_width / 2
	var center_y = maze_height / 2
	
	for y in range(maze_height):
		for x in range(maze_width):
			var cell = maze[y][x]
			var wall_count = count_walls(cell)
			
			# Default to EMPTY
			cell.content = MazeCell.Content.EMPTY
			
			# Assign START to center cell
			if x == center_x and y == center_y:
				cell.content = MazeCell.Content.START
				# Clear surrounding cells
				clear_surrounding_cells(Vector2i(x, y))
			# Assign content based on wall count and spawn probability
			elif wall_count == 3 and rng.randf() < chest_spawn_probability:
				cell.content = MazeCell.Content.CHEST
			elif wall_count == 2 and rng.randf() < enemy_spawn_probability:
				cell.content = MazeCell.Content.ENEMY
	
	# Convert one random CHEST to KEY
	var chest_cells: Array[Vector2i] = []
	for y in range(maze_height):
		for x in range(maze_width):
			if maze[y][x].content == MazeCell.Content.CHEST:
				chest_cells.append(Vector2i(x, y))
	
	if chest_cells.size() > 0:
		var key_pos = chest_cells[rng.randi() % chest_cells.size()]
		maze[key_pos.y][key_pos.x].content = MazeCell.Content.KEY
	
	# Assign END to a random cell in the first row (y=0)
	var first_row_cells: Array[int] = []
	for x in range(maze_width):
		if maze[0][x].content == MazeCell.Content.EMPTY:
			first_row_cells.append(x)
	
	if first_row_cells.size() > 0:
		var end_x = first_row_cells[rng.randi() % first_row_cells.size()]
		maze[0][end_x].content = MazeCell.Content.END


func clear_surrounding_cells(pos: Vector2i):
	# Clear all 8 surrounding cells (orthogonal + diagonal)
	var directions = [
		Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1),  # Top row
		Vector2i(-1, 0),                   Vector2i(1, 0),   # Middle row
		Vector2i(-1, 1),  Vector2i(0, 1),  Vector2i(1, 1)    # Bottom row
	]
	
	for dir in directions:
		var neighbor_pos = pos + dir
		if is_valid_position(neighbor_pos):
			maze[neighbor_pos.y][neighbor_pos.x].content = MazeCell.Content.EMPTY

func count_walls(cell :MazeCell) -> int:
	var count = 0
	if cell.wall_north:
		count += 1
	if cell.wall_south:
		count += 1
	if cell.wall_east:
		count += 1
	if cell.wall_west:
		count += 1
	return count

#endregion
