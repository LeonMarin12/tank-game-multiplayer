extends Node2D

# ============================================================================
# Sandbox de debug: prueba Player + Laberinto de forma aislada, SIN pasar por
# Net/networking.gd ni por el flujo de conexion de Main.gd. No hace falta Steam
# corriendo ni crear un lobby para usar esta escena — anda con F6 directo.
#
# Por que funciona sin red: player_controller.gd y bullet.gd solo simulan su
# logica cuando is_multiplayer_authority() es true. Sin un MultiplayerPeer
# asignado (que es el caso aca), CUALQUIER nodo es su propia autoridad por
# defecto, asi que el guard pasa igual y el gameplay corre normal en local.
# ============================================================================

@export var maze_seed := 12345 # fijo (no aleatorio) para que el layout sea siempre el mismo al probar
@export var auto_place_players_at_start := true

@onready var maze_container: MazeBuilder = $MazeContainer
@onready var bullets: Node = $Bullets


func _ready() -> void:
	maze_container.build(maze_seed)
	_configure_players()
	if auto_place_players_at_start:
		_place_players_at_start()


# Los Players que dejaste en la escena a mano no pasan por Main.gd, asi que
# nadie mas les apunta el BulletSpawner al contenedor "Bullets" — lo hacemos
# aca (ver player_controller.gd: set_bullet_container).
func _configure_players() -> void:
	for child in get_children():
		if child is CharacterBody2D and child.is_in_group("players"):
			child.set_bullet_container(bullets)


# Reposiciona cualquier Player que hayas dejado en la escena (el que viene por
# defecto, o los que agregues/dupliques a mano) sobre la celda START del
# laberinto recien generado, para no arrancar incrustado en una pared.
func _place_players_at_start() -> void:
	var start_pos := maze_container.get_start_world_position()
	for child in get_children():
		if child is CharacterBody2D and child.is_in_group("players"):
			child.global_position = start_pos
