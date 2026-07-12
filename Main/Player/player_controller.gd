extends CharacterBody2D

@export_category('Stats')
@export var move_speed := 80.0
@export var rotation_speed := 3.0 # rad/s
@export var fire_cooldown := 0.3 # segundos entre disparos

# Si esta en false, el tanque ignora el teclado por completo (pero sigue
# reaccionando a las balas via HurtBox). Se usa en Debug.tscn para tener un
# "dummy" de pruebas: una instancia mas de player.tscn que no se mueve ni
# dispara, solo sirve de blanco para probar el flujo de muerte/explosion/
# respawn sin depender de multiplayer authority (que en modo standalone es
# igual para todos los nodos, asi que no sirve para distinguir "quien controlo
# a quien").
@export var input_enabled := true

@export_category('Scenes')
@export var bullet_scene :PackedScene

var _fire_timer := 0.0
@onready var bullet_spawner: MultiplayerSpawner = $BulletSpawner
@onready var hurt_box: Area2D = $HurtBox
@onready var muzzle: Marker2D = %Muzzle



func _enter_tree() -> void:
	if name.is_valid_int():
		set_multiplayer_authority(name.to_int())


func _ready() -> void:
	add_to_group("players")
	motion_mode = MOTION_MODE_FLOATING # top-down: sin gravedad ni logica de "suelo"
	bullet_spawner.spawn_function = _create_bullet
	hurt_box.body_entered.connect(_on_hurt_box_body_entered)


# El HurtBox (Area2D, layer Player / mask Bullet) es una colision SEPARADA de
# la CollisionShape2D principal (que solo choca con paredes): asi el laberinto
# bloquea el movimiento del tanque, y las balas se detectan aca sin afectarse
# entre si (ver bullet.tscn/bullet.gd: la bala ya NO choca fisicamente con el
# player, solo con paredes — el impacto se resuelve siempre por este camino).
func _on_hurt_box_body_entered(body: Node2D) -> void:
	# Las señales de Area2D corren en cada peer segun SU PROPIA copia replicada
	# (no dependen de multiplayer authority). Si no filtraramos esto, cada peer
	# reportaria el mismo impacto por separado. Por eso solo el dueño de este
	# tanque decide que lo golpearon.
	if not is_multiplayer_authority():
		return
	if not body.is_in_group("bullets"):
		return

	var main := get_tree().current_scene
	if main.has_method("request_kill_player"):
		# Se manda el NodePath (relativo a la escena raiz) en vez del peer_id: en
		# Main.tscn ambos dan lo mismo (el nombre del nodo YA es el peer_id), pero
		# en Debug.tscn el Player y el Dummy comparten multiplayer authority por
		# defecto (no hay conexion real, asi que get_multiplayer_authority() daria
		# 1 para los dos) y el path es la unica forma de saber a CUAL mataron.
		main.request_kill_player.rpc_id(1, main.get_path_to(self))
	# La bala solo tiene autoridad real de fisica en el peer que disparo; le
	# avisamos con un RPC (no requiere ser su autoridad para llamarlo) para que
	# se destruya ahi tambien, no solo en la copia local de este HurtBox.
	if body.has_method("_force_destroy"):
		body.rpc("_force_destroy")


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
	if not input_enabled:
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

	# bullet_spawner.spawn() replica el spawn a todos los peers automaticamente porque
	# BulletSpawner comparte autoridad con este Player (ver _enter_tree). El diccionario
	# viaja como argumento al spawn_function (_create_bullet) en CADA peer, incluido este.
	bullet_spawner.spawn({
		"position": muzzle.global_position,
		"rotation": rotation,
		# get_multiplayer_authority() en vez de name.to_int(): da el mismo peer_id en
		# red, pero tambien funciona sin nombre numerico en pruebas locales (ver _enter_tree).
		"shooter_id": get_multiplayer_authority(),
	})


func _create_bullet(data: Dictionary) -> Node:
	var bullet := bullet_scene.instantiate()
	bullet.global_position = data.position
	bullet.rotation = data.rotation
	# shooter_id debe quedar asignado ANTES de que el nodo entre al arbol: bullet._enter_tree()
	# lo usa para fijar la autoridad de la bala (ver bullet.gd).
	bullet.shooter_id = data.shooter_id
	return bullet
