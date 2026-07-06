class_name MazeCell extends Resource

enum Content { EMPTY, START, CHEST, ENEMY, KEY, END }

var visited :bool = false #boolean used to create the maze
var position :Vector2i #position in the maze grid
var content :Content = Content.EMPTY #whats inside the cell

# Walls - true means there is a wall, false means open
var wall_north :bool = true
var wall_south :bool = true
var wall_east :bool = true
var wall_west :bool = true
