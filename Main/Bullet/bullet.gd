extends CharacterBody2D

const SPEED := 300.0
const MAX_BOUNCES := 4
const LIFETIME := 5.0 # segundos antes de autodestruirse si no choco antes

var shooter_id: int = -1 # asignado por player_controller.gd antes de entrar al arbol

var _bounces_left := MAX_BOUNCES
var _lifetime_left := LIFETIME


func _enter_tree() -> void:
	if shooter_id != -1:
		# La bala es autoritativa en el peer que la disparo, NO en el servidor.
		# Solo ese peer simula la fisica del rebote (ver el guard en _physics_process);
		# el resto de los peers ven la copia replicada por MultiplayerSynchronizer.
		# Esto evita que dos peers calculen el rebote por separado y diverjan por
		# pequenas diferencias de timing/redondeo (float drift).
		set_multiplayer_authority(shooter_id)


func _ready() -> void:
	velocity = Vector2.RIGHT.rotated(rotation) * SPEED


func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority():
		return

	_lifetime_left -= delta
	if _lifetime_left <= 0.0:
		queue_free()
		return

	var collision := move_and_collide(velocity * delta)
	if collision:
		_handle_collision(collision)


func _handle_collision(collision: KinematicCollision2D) -> void:
	# get_collider() devuelve Object (generico); lo casteamos a Node para poder
	# leer .name/.is_in_group con tipado estatico en vez de caer en Variant.
	var collider := collision.get_collider() as Node

	if collider != null and collider.is_in_group("players"):
		var hit_id: int = String(collider.name).to_int()
		if hit_id != shooter_id: # inmunidad al propio disparador
			# Esta bala solo existe (con fisica real) en el peer que disparo, pero ese
			# peer no es dueno del Player al que le pego (los players los crea/destruye
			# el servidor via PlayerSpawner). Por eso se pide la destruccion con un RPC
			# dirigido al servidor (peer id 1) en vez de hacer queue_free() directo sobre
			# un nodo ajeno. Ver Main.gd: request_kill_player.
			var main := get_tree().current_scene
			if main.has_method("request_kill_player"):
				main.request_kill_player.rpc_id(1, hit_id)
		queue_free()
		return

	# Cualquier otra cosa (pared) -> rebote reflejando la velocidad contra la normal.
	velocity = velocity.bounce(collision.get_normal())
	rotation = velocity.angle()
	_bounces_left -= 1
	if _bounces_left <= 0:
		queue_free()
