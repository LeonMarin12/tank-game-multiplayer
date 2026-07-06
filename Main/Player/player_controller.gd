extends CharacterBody2D

@export var move_speed := 200.0
@export var rotation_speed := 3.0 # rad/s
@export var fire_cooldown := 0.3 # segundos entre disparos

const BULLET_SCENE := preload("res://Main/Bullet/bullet.tscn")

var _fire_timer := 0.0
@onready var bullet_spawner: MultiplayerSpawner = $BulletSpawner


func _enter_tree() -> void:
	# El nombre del nodo es el peer_id (asignado por quien spawnea al jugador, ver Main.gd)
	# CUANDO el juego corre en red. Si en cambio agregaste el Player a mano en una escena
	# de prueba (ej. Debug.tscn) el nombre no es numerico ("Player", "Player2", etc.) —
	# ahi NO tocamos la autoridad: queda en su valor por defecto (1), que ya coincide con
	# multiplayer.get_unique_id() sin un MultiplayerPeer activo, asi que
	# is_multiplayer_authority() sigue dando true y el tanque se mueve igual sin red.
	# set_multiplayer_authority es recursivo: tambien deja a BulletSpawner (hijo) bajo la
	# misma autoridad, asi el dueno de este tanque puede spawnear sus propias balas sin
	# pedirle permiso al servidor.
	if name.is_valid_int():
		set_multiplayer_authority(name.to_int())


func _ready() -> void:
	add_to_group("players")
	motion_mode = MOTION_MODE_FLOATING # top-down: sin gravedad ni logica de "suelo"
	bullet_spawner.spawn_function = _create_bullet


# Los nombres unicos (%Nombre) solo se resuelven DENTRO del mismo archivo de
# escena donde se declaran — no cruzan el limite de una escena instanciada. Como
# BulletSpawner vive dentro de player.tscn (una escena distinta de Main.tscn o
# Debug.tscn), no puede resolver "%Bullets" por su cuenta aunque el nodo exista
# en la escena que lo aloja. Por eso quien instancia al Player (Main.gd,
# debug_sandbox.gd) tiene que pasarle el contenedor real llamando esto una vez,
# recien despues de agregar el Player al arbol.
func set_bullet_container(container: Node) -> void:
	bullet_spawner.spawn_path = bullet_spawner.get_path_to(container)


func _physics_process(delta: float) -> void:
	# Guard de autoridad: cada peer solo simula fisica/input de SU PROPIO tanque.
	# Los tanques de otros jugadores en esta misma maquina no ejecutan este bloque;
	# su posicion/rotacion llega replicada por el MultiplayerSynchronizer en su lugar.
	if not is_multiplayer_authority():
		return

	_fire_timer = max(0.0, _fire_timer - delta)

	rotate_body(delta)
	move_body()

	if Input.is_action_just_pressed("shoot") and _fire_timer <= 0.0:
		_shoot()
		_fire_timer = fire_cooldown


func rotate_body(delta: float) -> void:
	var turn := Input.get_axis("rotate_left", "rotate_right") # A = -1, D = +1
	rotation += turn * rotation_speed * delta


func move_body() -> void:
	var forward := Input.get_axis("move_backward", "move_forward") # S = -1, W = +1
	velocity = Vector2.RIGHT.rotated(rotation) * forward * move_speed
	move_and_slide()


func _shoot() -> void:
	# Nace un poco adelante del tanque para no auto-colisionar con la propia CollisionShape2D.
	var muzzle_offset := Vector2.RIGHT.rotated(rotation) * 16.0

	# bullet_spawner.spawn() replica el spawn a todos los peers automaticamente porque
	# BulletSpawner comparte autoridad con este Player (ver _enter_tree). El diccionario
	# viaja como argumento al spawn_function (_create_bullet) en CADA peer, incluido este.
	bullet_spawner.spawn({
		"position": global_position + muzzle_offset,
		"rotation": rotation,
		# get_multiplayer_authority() en vez de name.to_int(): da el mismo peer_id en
		# red, pero tambien funciona sin nombre numerico en pruebas locales (ver _enter_tree).
		"shooter_id": get_multiplayer_authority(),
	})


func _create_bullet(data: Dictionary) -> Node:
	var bullet := BULLET_SCENE.instantiate()
	bullet.global_position = data.position
	bullet.rotation = data.rotation
	# shooter_id debe quedar asignado ANTES de que el nodo entre al arbol: bullet._enter_tree()
	# lo usa para fijar la autoridad de la bala (ver bullet.gd).
	bullet.shooter_id = data.shooter_id
	return bullet
