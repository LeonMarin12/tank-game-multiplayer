extends CharacterBody2D

const SPEED := 100.0
const MAX_BOUNCES := 10
const LIFETIME := 5.0 # segundos antes de autodestruirse si no choco antes

var shooter_id: int = -1 # asignado por player_controller.gd antes de entrar al arbol

var _bounces_left := MAX_BOUNCES
var _lifetime_left := LIFETIME


func _enter_tree() -> void:
	if shooter_id != -1:
		set_multiplayer_authority(shooter_id)


func _ready() -> void:
	add_to_group("bullets")
	velocity = Vector2.RIGHT.rotated(rotation) * SPEED


func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority():
		return

	_lifetime_left -= delta
	if _lifetime_left <= 0.0:
		queue_free()
		return

	# collision_mask ya no incluye la layer "Player": el impacto contra un
	# tanque se detecta por otro lado (el HurtBox del Player, ver
	# player_controller.gd), asi que aca solo puede tratarse de una pared.
	var collision := move_and_collide(velocity * delta)
	if collision:
		velocity = velocity.bounce(collision.get_normal())
		rotation = velocity.angle()
		_bounces_left -= 1
		if _bounces_left <= 0:
			queue_free()


# Llamado por el HurtBox del Player al que le pego (ver player_controller.gd).
# "any_peer" porque quien detecta el impacto es el PEER GOLPEADO, no el
# disparador (dueño real de esta bala) — sin este RPC, la copia autoritativa
# de la bala en el peer que disparo nunca se enteraria y seguiria rebotando.
@rpc("any_peer", "call_local", "reliable")
func _force_destroy() -> void:
	queue_free()
