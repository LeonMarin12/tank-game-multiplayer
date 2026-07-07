extends Node2D


@export var maze_seed := 12345
@export var auto_place_players_at_start := true

const PLAYER_SCENE := preload("res://Main/Player/player.tscn")
const EXPLOSION_SCENE := preload("res://Main/Particles/explosion_particle.tscn")
const RESPAWN_DELAY := 3.0 # segundos entre morir y respawnear, igual que Main.gd
const SPAWN_RING_SLOTS := 4 # mismo esquema que Main.gd para no apilar tanques encima del otro

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
# laberinto recien generado, para no arrancar incrustado en una pared. Cada uno
# se separa en un anillo alrededor del START (mismo esquema que Main.gd) para
# que el Player y el Dummy de pruebas no queden apilados en el mismo punto.
func _place_players_at_start() -> void:
	for child in get_children():
		if child is CharacterBody2D and child.is_in_group("players"):
			_place_player(child)


func _place_player(player: Node2D) -> void:
	var start_pos := maze_container.get_start_world_position()
	var index := player.get_index()
	var offset := Vector2.RIGHT.rotated(TAU * index / float(SPAWN_RING_SLOTS)) * 12.0
	player.global_position = start_pos + offset


# Equivalente standalone de Main.gd:request_kill_player. No usa peer_id porque
# aca no hay conexion real: el Player y cualquier Dummy de pruebas comparten
# multiplayer authority por defecto (1), asi que get_multiplayer_authority()
# no alcanza para saber a cual mataron. player_controller.gd ya nos manda
# directamente el NodePath del nodo golpeado (ver _on_hurt_box_body_entered).
@rpc("any_peer", "call_local", "reliable")
func request_kill_player(player_path: NodePath) -> void:
	var player := get_node_or_null(player_path)
	if not player:
		return

	spawn_explosion(player.global_position)

	# Guardamos como era el nodo antes de destruirlo para poder respawnear una
	# copia identica (mismo nombre e igual valor de input_enabled, asi un
	# Dummy sigue siendo Dummy y el Player controlado sigue respondiendo al
	# teclado despues de respawnear).
	var node_name := player.name
	var was_input_enabled: bool = player.input_enabled
	player.queue_free()
	_respawn_after_delay(node_name, was_input_enabled)


func spawn_explosion(explosion_position: Vector2) -> void:
	var explosion := EXPLOSION_SCENE.instantiate()
	add_child(explosion)
	explosion.global_position = explosion_position
	explosion.emitting = true
	explosion.finished.connect(explosion.queue_free)


func _respawn_after_delay(node_name: String, input_enabled: bool) -> void:
	await get_tree().create_timer(RESPAWN_DELAY).timeout
	var new_player := PLAYER_SCENE.instantiate()
	new_player.name = node_name
	new_player.input_enabled = input_enabled
	add_child(new_player)
	new_player.set_bullet_container(bullets)
	_place_player(new_player)
