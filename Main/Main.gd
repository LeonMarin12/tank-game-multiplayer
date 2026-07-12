extends Node2D

# ============================================================================
# Main — la escena de gameplay en si (laberinto, jugadores, balas). Se entra
# aca DESPUES de que todos ya estan conectados y el host aprieto "Empezar" en
# el Lobby (ver Main/Lobby/lobby.gd), asi que un MultiplayerPeer ya esta
# asignado a `multiplayer.multiplayer_peer` desde antes de que este script
# corra — no hace falta esperar ninguna señal de conexion aca.
# ============================================================================

const PLAYER_SCENE := preload("res://Main/Player/player.tscn")
const EXPLOSION_SCENE := preload("res://Main/Particles/explosion_particle.tscn")
const SPAWN_RING_SLOTS := 4 # cuantas posiciones distintas hay alrededor del START
const RESPAWN_DELAY := 3.0 # segundos entre morir y respawnear

@onready var maze_container: MazeBuilder = $MazeContainer
@onready var players: Node = $Players
@onready var bullets: Node = $Bullets
@onready var player_spawner: MultiplayerSpawner = $PlayerSpawner
@onready var maze_camera: Camera2D = $MazeCamera

var maze_seed: int = 0

# Peers que ya estaban conectados (esperando en el Lobby) cuando arranco esta
# escena, de los que todavia falta que confirmen notify_ready. Ver
# _try_spawn_initial_cohort para el porque de esperar a TODOS antes de
# spawnear a cualquiera, incluido el propio host.
var _pending_initial_peers: Array = []
var _initial_cohort_spawned := false


func _ready() -> void:
	# La camara ya NO sigue al player (antes vivia como hijo de player.tscn):
	# ahora es una unica camara estatica que encuadra el laberinto completo.
	# "built" se dispara cada vez que maze_container.build() termina, tanto en
	# el servidor (_bootstrap_as_server) como en un cliente (receive_maze_seed),
	# asi no hace falta llamar esto a mano en cada uno de esos dos lugares.
	maze_container.built.connect(_configure_static_camera)
	get_viewport().size_changed.connect(_configure_static_camera)

	# "spawned" se dispara en TODOS los peers (incluido quien crea el nodo)
	# cada vez que el PlayerSpawner replica un jugador nuevo bajo "Players".
	player_spawner.spawned.connect(_on_player_spawned)

	if multiplayer.is_server():
		multiplayer.peer_disconnected.connect(_on_peer_disconnected_while_waiting)
		_bootstrap_as_server()
	else:
		# Le avisamos al servidor que YA terminamos de cargar Main.tscn de este
		# lado. Es el servidor quien decide cuando mandarnos el seed/spawnearnos
		# (ver notify_ready) — no al reves. Ver esa funcion para el porque.
		notify_ready.rpc_id(1)


# --- Flujo del servidor -------------------------------------------------------

# Arma el laberinto. Todavia NO spawnea a nadie (ni siquiera al propio host):
# ver _try_spawn_initial_cohort para el porque.
func _bootstrap_as_server() -> void:
	maze_seed = randi()
	maze_container.build(maze_seed)
	_pending_initial_peers = multiplayer.get_peers().duplicate()
	_try_spawn_initial_cohort()


# Avisado por CADA cliente apenas termina su propio _ready() en esta escena —
# es decir, apenas su copia local de "Main" ya existe de verdad. "any_peer"
# porque lo llama cualquier cliente, no el servidor.
#
# Por que esperar a esto en vez de mandar el seed/spawn proactivamente al ver
# peer_connected o multiplayer.get_peers(): start_game() en Lobby.gd cambia de
# escena en TODOS los peers con un solo rpc() broadcast, pero el host (via
# call_local) cambia de escena de forma local e INSTANTANEA, mientras que un
# cliente recien recibe ese mismo RPC despues de un viaje de red real (el
# relay de Steam, server_relay = true, nunca es instantaneo ni siquiera en
# LAN). Si el servidor spawneara a alguien (el host incluido) apenas EL
# termina de cargar, ese add_child() se replica AUTOMATICAMENTE a todos los
# peers que YA figuran conectados en ese momento — incluyendo a un cliente que
# todavia sigue en el Lobby o a mitad de cargar Main.tscn. Ese paquete llega
# APUNTANDO A UN NODO QUE TODAVIA NO EXISTE del otro lado (Godot resuelve
# RPCs/replicacion por NodePath al momento de llegar el paquete), se descarta
# sin reintentar, y ademas deja roto para siempre el canal de sincronizacion
# de posicion/rotacion de ese jugador (por eso el sintoma real fue un tanque
# congelado en (0,0) durante toda la partida, no solo un frame perdido).
# Pidiendoselo AL REVES (cada cliente avisa cuando el YA esta listo) esto es
# imposible: para que notify_ready llegue al servidor, ESE cliente ya tuvo que
# recibir el RPC inicial Y terminar de cargar su escena.
@rpc("any_peer", "reliable")
func notify_ready() -> void:
	if not multiplayer.is_server():
		return
	var peer_id := multiplayer.get_remote_sender_id()
	receive_maze_seed.rpc_id(peer_id, maze_seed)

	if _pending_initial_peers.has(peer_id):
		# Formaba parte del grupo que ya estaba en el Lobby cuando arranco la
		# partida. Aca todavia NO lo spawneamos individualmente: si lo
		# hicieramos, ese add_child() se replicaria de una a todos los peers
		# ya conectados, incluidos otros compañeros de ESTE MISMO grupo que
		# quizas todavia no mandaron su propio notify_ready — exactamente la
		# misma condicion de carrera, con otra victima. Se spawnean todos
		# juntos (host incluido) recien cuando el ULTIMO del grupo confirma.
		_pending_initial_peers.erase(peer_id)
		_try_spawn_initial_cohort()
		return

	# Alguien que se conecta DESPUES de que el grupo inicial ya esta todo
	# spawneado y confirmado — no hay nadie mas todavia-cargando con quien
	# competir, asi que se puede spawnear de una.
	spawn_player(peer_id)
	_sync_existing_players_to(peer_id)


# Si alguien que estabamos esperando se desconecta ANTES de mandar su propio
# notify_ready (ej. cierra el juego mientras Main.tscn todavia estaba
# cargando), sacarlo de la lista de espera para no quedar esperando para
# siempre a alguien que ya no va a confirmar nunca.
func _on_peer_disconnected_while_waiting(peer_id: int) -> void:
	if _pending_initial_peers.has(peer_id):
		_pending_initial_peers.erase(peer_id)
		_try_spawn_initial_cohort()


# Recien spawnea al host y a TODOS los peers que ya estaban en el Lobby de una
# sola vez, una vez que CADA UNO de ellos confirmo por su cuenta (notify_ready)
# que ya tiene su propio Main.tscn cargado. En ese momento ya es seguro
# broadcastear todos estos spawns: ninguno de los destinatarios esta "a mitad
# de cargar" (ver notify_ready para el porque importa evitar eso).
func _try_spawn_initial_cohort() -> void:
	if _initial_cohort_spawned or not _pending_initial_peers.is_empty():
		return
	_initial_cohort_spawned = true
	spawn_player(multiplayer.get_unique_id())
	for peer_id in multiplayer.get_peers():
		spawn_player(peer_id)


# Le manda a un peer especifico los peer_ids de los jugadores que ya estaban
# spawneados ANTES de que el se uniera. El PlayerSpawner solo replica un
# add_child() a los peers que YA ESTABAN conectados en ese preciso momento —
# no reenvia retroactivamente los jugadores que ya existian antes de que este
# peer se conectara. Se lo avisamos a mano, con un RPC dirigido solo a el.
func _sync_existing_players_to(peer_id: int) -> void:
	var other_ids: Array = []
	for child in players.get_children():
		var other_id: int = child.name.to_int()
		if other_id != peer_id:
			other_ids.append(other_id)
	if other_ids.size() > 0:
		sync_existing_players.rpc_id(peer_id, other_ids)


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


# Corre SOLO en el peer recien conectado (rpc_id lo dirige puntual, ver
# _sync_existing_players_to). Crea copias locales "espejo" de los jugadores
# que ya existian antes de unirse. La posicion inicial se fija igual que
# cualquier spawn (_place_player); el MultiplayerSynchronizer del dueño real
# la va a corregir enseguida con la posicion/rotacion actual, pero no conviene
# depender de eso a ciegas y dejarla en (0,0) mientras tanto. La autoridad de
# cada copia la resuelve player_controller.gd (_enter_tree) por el nombre del
# nodo — no importa que ESTE peer sea quien hizo el add_child.
@rpc("authority", "reliable")
func sync_existing_players(peer_ids: Array) -> void:
	for id in peer_ids:
		if players.get_node_or_null(str(id)) != null:
			continue # ya llego por el camino normal (raro, pero no duplicar)
		var mirror := PLAYER_SCENE.instantiate()
		mirror.name = str(id)
		players.add_child(mirror)
		mirror.set_bullet_container(bullets)
		_place_player(mirror)


# Se dispara en CADA peer (incluido el servidor) cuando el PlayerSpawner termina
# de instanciar un jugador replicado. Sirve para fijar la posicion inicial local
# y para apuntar el BulletSpawner del jugador a "Bullets" — ambas cosas hay que
# hacerlas de este lado (no dentro de player.tscn) porque "Bullets" vive en esta
# escena, no en la del Player (ver comentario en set_bullet_container).
func _on_player_spawned(node: Node) -> void:
	node.set_bullet_container(bullets)
	_place_player(node)


# Encuadra el laberinto entero en una camara fija (no atada a ningun player):
# se centra en el laberinto y usa el zoom mas chico entre ancho/alto para que
# entre completo sin recortarse en ningun eje (el eje sobrante deja un margen,
# en vez de cortar el otro).
func _configure_static_camera() -> void:
	if maze_container.maze.is_empty():
		return # todavia no se genero nada (ej. primer size_changed antes del build)
	maze_camera.global_position = maze_container.get_maze_center_world_position()
	var viewport_size := get_viewport().get_visible_rect().size
	var maze_size := maze_container.get_maze_pixel_size()
	var zoom_value := minf(viewport_size.x / maze_size.x, viewport_size.y / maze_size.y)
	maze_camera.zoom = Vector2(zoom_value, zoom_value)


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
func request_kill_player(player_path: NodePath) -> void:
	if not multiplayer.is_server():
		return
	var player := get_node_or_null(player_path)
	if player:
		# El nombre del nodo YA es el peer_id (ver spawn_player) — no hace falta
		# que el llamador nos lo pase por separado.
		var peer_id: int = player.name.to_int()
		# La posicion hay que guardarla ANTES del queue_free (una vez liberado
		# el nodo, global_position ya no es valido). spawn_explosion se manda
		# a TODOS los peers (incluido el servidor via call_local) para que la
		# explosion se vea en cada pantalla, no solo en la del servidor.
		spawn_explosion.rpc(player.global_position)
		# El servidor es autoridad del PlayerSpawner -> este queue_free() se
		# replica solo a todos los peers como un despawn, sin RPC adicional.
		player.queue_free()
		_respawn_after_delay(peer_id)


# Efecto puramente visual/cosmetico: cada peer instancia su propia copia local
# de la explosion (no se replica via MultiplayerSpawner porque no hace falta
# mantenerla sincronizada, solo se reproduce una vez y se destruye sola).
@rpc("authority", "call_local", "reliable")
func spawn_explosion(explosion_position: Vector2) -> void:
	var explosion := EXPLOSION_SCENE.instantiate()
	add_child(explosion)
	explosion.global_position = explosion_position
	explosion.emitting = true
	explosion.finished.connect(explosion.queue_free)


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
