extends Node2D

# ============================================================================
# Main — conecta el flujo de conexion (autoload Networking) con el gameplay
# (laberinto, jugadores, balas). Este script asume que un MultiplayerPeer ya
# fue asignado a `multiplayer.multiplayer_peer` por Networking; el sabe COMO
# se crea/une el peer de Steam, este script solo reacciona a que ya existe.
# ============================================================================

const PLAYER_SCENE := preload("res://Main/Player/player.tscn")
const SPAWN_RING_SLOTS := 4 # cuantas posiciones distintas hay alrededor del START
const RESPAWN_DELAY := 3.0 # segundos entre morir y respawnear

@onready var maze_container: MazeBuilder = $MazeContainer
@onready var players: Node = $Players
@onready var bullets: Node = $Bullets
@onready var player_spawner: MultiplayerSpawner = $PlayerSpawner
@onready var lobby_ui: Control = $CanvasLayer/LobbyUI

var maze_seed: int = 0


func _ready() -> void:
	# "spawned" se dispara en TODOS los peers (incluido quien crea el nodo)
	# cada vez que el PlayerSpawner replica un jugador nuevo bajo "Players".
	player_spawner.spawned.connect(_on_player_spawned)

	Networking.host_created.connect(_on_host_created)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


# --- Flujo del host ----------------------------------------------------------

# Se dispara solo en la maquina que crea el lobby (ver Networking._on_lobby_created).
func _on_host_created() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)

	maze_seed = randi()
	maze_container.build(maze_seed)
	_set_status("Hosteando (lobby %d) - esperando jugadores" % Networking.lobby_id)

	spawn_player(multiplayer.get_unique_id())


# Se dispara SOLO en el servidor, una vez por cada peer nuevo que termina de conectar.
func _on_peer_connected(peer_id: int) -> void:
	# Orden importante: primero el seed del laberinto, recien despues el spawn del
	# jugador. Asi el cliente ya puede calcular la celda START cuando le llegue su
	# propio tanque (ver _place_player).
	receive_maze_seed.rpc_id(peer_id, maze_seed)
	spawn_player(peer_id)
	_set_status("Hosteando (lobby %d) - %d jugador(es)" % [Networking.lobby_id, players.get_child_count()])


# El servidor es la unica autoridad del PlayerSpawner: agregar un hijo aca bajo
# "Players" es lo que el MultiplayerSpawner detecta y replica automaticamente a
# todos los clientes (instanciando player.tscn, definido en _spawnable_scenes).
#
# OJO: la señal "spawned" del PlayerSpawner NO se dispara para este mismo peer
# (el que hace add_child) — solo se dispara en los DEMAS peers cuando reciben la
# replicacion (ver _on_player_spawned). Por eso ac configuramos el bullet
# container y la posicion inicial a mano, en vez de depender solo de la señal.
func spawn_player(peer_id: int) -> void:
	var new_player := PLAYER_SCENE.instantiate()
	new_player.name = str(peer_id) # el nombre = peer_id es lo que usa set_multiplayer_authority()
	players.add_child(new_player)
	new_player.set_bullet_container(bullets)
	_place_player(new_player)


# --- Flujo compartido (host y clientes) --------------------------------------

# RPC dirigido, mandado unicamente por el servidor (ver _on_peer_connected).
# "authority" limita quien puede invocar esto de forma remota a quien tenga
# autoridad sobre este nodo Main (el servidor, por defecto peer id 1).
@rpc("authority", "reliable")
func receive_maze_seed(seed_value: int) -> void:
	maze_seed = seed_value
	maze_container.build(seed_value)


# Se dispara en CADA peer (incluido el servidor) cuando el PlayerSpawner termina
# de instanciar un jugador replicado. Sirve para fijar la posicion inicial local
# y para apuntar el BulletSpawner del jugador a "Bullets" — ambas cosas hay que
# hacerlas de este lado (no dentro de player.tscn) porque "Bullets" vive en esta
# escena, no en la del Player (ver comentario en set_bullet_container).
func _on_player_spawned(node: Node) -> void:
	node.set_bullet_container(bullets)
	_place_player(node)


func _place_player(player: Node) -> void:
	# get_index() es identico en todos los peers porque el orden de add_child()
	# bajo "Players" se replica tal cual via el spawner, asi cada jugador queda
	# separado del resto sin tener que sincronizar un indice a mano.
	var index := player.get_index()
	var offset := Vector2.RIGHT.rotated(TAU * index / float(SPAWN_RING_SLOTS)) * 12.0
	player.global_position = maze_container.get_start_world_position() + offset


# Una bala le pego a un player. La bala solo existe (con fisica real) en el peer
# que disparo, y ese peer NO tiene autoridad para destruir un Player ajeno (los
# players los crea/destruye el servidor via PlayerSpawner). Por eso el impacto
# se resuelve pidiendoselo al servidor por RPC en vez de un queue_free() directo.
# "call_local" es necesario para el caso en que el HOST mismo es quien dispara:
# ahi rpc_id(1, ...) apunta a si mismo (caller_id == target_id == 1), y Godot
# rechaza ese caso salvo que call_local este activado. Para clientes normales
# (caller != 1) esto solo hace que la funcion tambien corra localmente en el
# cliente, donde el guard de abajo la ignora sin problema (no es el servidor).
@rpc("any_peer", "call_local", "reliable")
func request_kill_player(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	var player := players.get_node_or_null(str(peer_id))
	if player:
		# El servidor es autoridad del PlayerSpawner -> este queue_free() se
		# replica solo a todos los peers como un despawn, sin RPC adicional.
		player.queue_free()
		_respawn_after_delay(peer_id)


# Respawnea automaticamente al mismo peer_id despues de RESPAWN_DELAY segundos.
# Corre solo en el servidor (unico llamador: request_kill_player, ya filtrado
# por is_server() arriba). El await no bloquea nada mas: el resto del juego
# sigue andando normal mientras este timer espera de fondo.
func _respawn_after_delay(peer_id: int) -> void:
	await get_tree().create_timer(RESPAWN_DELAY).timeout
	# El peer pudo haberse desconectado durante la espera; si ya no esta
	# conectado, no tiene sentido spawnearle un tanque a nadie.
	if _is_peer_connected(peer_id):
		spawn_player(peer_id)


func _is_peer_connected(peer_id: int) -> bool:
	# get_peers() devuelve los peers conectados SIN incluir el propio id local
	# (que aca, al correr siempre en el servidor, es el del host) — por eso el
	# caso del host se chequea aparte.
	return peer_id == multiplayer.get_unique_id() or multiplayer.get_peers().has(peer_id)


# --- UI de estado --------------------------------------------------------------

func _on_connected_to_server() -> void:
	_set_status("Conectado")


func _on_server_disconnected() -> void:
	_set_status("Desconectado del servidor")
	get_tree().reload_current_scene()


func _set_status(text: String) -> void:
	if lobby_ui != null and lobby_ui.has_method("set_status"):
		lobby_ui.set_status(text)
