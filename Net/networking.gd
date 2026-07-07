extends Node

# ============================================================================
# Networking (autoload) — base de multiplayer via Steam.
# ============================================================================
# Idea general: Steam solo se usa para DOS cosas: (1) crear/descubrir un "lobby"
# (una sala con un ID que Steam conoce) y (2) transportar los paquetes de red
# a traves de su Relay Network (que atraviesa NAT/firewalls gratis, sin que el
# host tenga que abrir puertos). Una vez que el peer esta creado, TODO el resto
# del juego usa la API de multiplayer de alto nivel de Godot de siempre
# (MultiplayerSpawner, MultiplayerSynchronizer, RPCs, multiplayer.*) como si
# fuera ENet. Steam desaparece de la ecuacion despues de conectar.
#
# Topologia: quien crea el lobby es automaticamente el host/servidor (peer id 1,
# fijo por convencion de Godot). Todos los que se unen despues son clientes.
# Es peer-to-peer via el relay de Steam, no hay un dedicated server aparte.
#
# Flujo de escenas: MainMenu -> (host_lobby() o unirse via overlay de Steam)
# -> Lobby (espera jugadores, min. 2 para poder empezar) -> el host aprieta
# "Empezar" -> Main (gameplay). Este autoload es quien decide cuando cambiar
# de escena en cada paso: es el unico lugar que sabe de forma confiable en que
# estado de conexion estamos, sin importar que escena este activa en cada
# momento (evita duplicar esta logica en cada escena que podria necesitarla).

const LOBBY_TYPE := Steam.LobbyType.LOBBY_TYPE_FRIENDS_ONLY # solo amigos ven/pueden unirse
const MAX_MEMBERS := 4

const DEFAULT_APP_ID := 480 # Spacewar, app id de test de Valve (ver project.godot [steam])

const MAIN_MENU_SCENE := "res://Main/MainMenu/MainMenu.tscn"
const LOBBY_SCENE := "res://Main/Lobby/Lobby.tscn"

var peer: SteamMultiplayerPeer
var lobby_id: int = 0 # id del lobby actual (0 = ninguno), util para debug/UI

# true si Steam.steamInitEx() confirmo que el cliente de Steam esta arriba y la
# API se inicializo correctamente. Todo el resto del juego (player, laberinto)
# NO depende de esto — solo lo necesitas si vas a hostear/unirte a un lobby real.
# Ver Debug/Debug.tscn para probar el resto sin este requisito.
var steam_available := false


func _ready() -> void:
	# Inicializamos Steam ACA a mano (steamInitEx), en vez de dejar que lo haga
	# solo el motor via "Initialize on Startup" en Project Settings. Ese auto-init
	# corre muy temprano en el arranque del engine, y en la practica algunas
	# interfaces (como la de Relay Network que usa initRelayNetworkAccess) todavia
	# no estan listas en ese momento y tiran un error nativo. Llamandolo nosotros
	# desde el _ready() de un autoload (que corre despues de que el motor ya
	# termino de arrancar) le da a Steam el tiempo real que necesita para responder.
	var app_id: int = ProjectSettings.get_setting("steam/initialization/app_data/app_id", DEFAULT_APP_ID)
	var init_result: Dictionary = Steam.steamInitEx(app_id)
	steam_available = init_result.status == 0 # 0 = OK (ver Steam.STEAM_API_INIT_RESULT)

	# Estas dos son señales built-in de Godot (no de Steam): se disparan solas
	# cuando multiplayer.multiplayer_peer efectivamente conecta/desconecta, sin
	# importar que escena este activa en ese momento — por eso viven aca y no
	# en una escena en particular.
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

	if not steam_available:
		push_warning("No se pudo inicializar Steam (%s). El multiplayer no va a estar disponible, pero el resto del juego (player, laberinto) funciona igual sin problema — ver Debug/Debug.tscn." % str(init_result.get("verbal", "?")))
		return

	# Habilita el uso del Relay Network de Steam (necesario para NAT punch-through
	# gratuito). Sin esto, createLobby/joinLobby funcionan pero el transporte P2P no.
	Steam.initRelayNetworkAccess()

	# Estas tres senales son callbacks que Steam dispara de forma asincrona en
	# respuesta a acciones nuestras (createLobby) o externas (alguien nos invita).
	Steam.lobby_created.connect(_on_lobby_created)
	Steam.lobby_joined.connect(_on_lobby_joined)
	Steam.join_requested.connect(_on_join_requested)


func _process(_delta: float) -> void:
	if not steam_available:
		return
	# CRITICO: sin esto, ninguna senal de Steam (lobby_created, lobby_joined, etc.)
	# llega nunca. Steam.run_callbacks() es lo que efectivamente procesa la cola de
	# eventos de la API de Steam y dispara las senales conectadas arriba.
	Steam.run_callbacks()


# Llamado por la UI (boton "Host"). Dispara la creacion de un lobby de Steam;
# el resultado llega mas tarde de forma asincrona en _on_lobby_created.
func host_lobby() -> void:
	if not steam_available:
		push_warning("No se puede hostear: Steam no esta corriendo.")
		return
	Steam.createLobby(LOBBY_TYPE, MAX_MEMBERS)


# Se dispara despues de host_lobby(), cuando Steam efectivamente creo el lobby.
func _on_lobby_created(connect_result: int, new_lobby_id: int) -> void:
	if connect_result != Steam.RESULT_OK:
		push_error("No se pudo crear el lobby de Steam (result=%d)" % connect_result)
		return

	lobby_id = new_lobby_id

	# SteamMultiplayerPeer es la implementacion de MultiplayerPeer que sabe hablar
	# el protocolo de Steam por debajo. server_relay = true fuerza a que TODO el
	# trafico pase por el relay de Steam (mas simple, algo mas de latencia que P2P
	# directo, pero funciona sin configurar NAT/puertos manualmente).
	peer = SteamMultiplayerPeer.new()
	peer.server_relay = true
	peer.create_host()

	# Esta linea es la que realmente activa el multiplayer de Godot: a partir de
	# aca, multiplayer.is_server(), multiplayer.peer_connected, RPCs, etc. funcionan.
	multiplayer.multiplayer_peer = peer

	# El host no "se conecta a si mismo" (no dispara connected_to_server, eso
	# es solo para clientes) — por eso pasa a la sala de espera directo aca.
	get_tree().change_scene_to_file(LOBBY_SCENE)


# Se dispara cuando ENTRAMOS a un lobby, tanto si lo creamos nosotros (lobby_created
# tambien dispara esto) como si nos unimos al de otro. Aca es donde un CLIENTE se
# convierte en cliente de verdad.
func _on_lobby_joined(joined_lobby_id: int, _permissions: int, _locked: bool, response: int) -> void:
	if response != Steam.CHAT_ROOM_ENTER_RESPONSE_SUCCESS:
		push_error("No se pudo entrar al lobby (response=%d)" % response)
		return

	lobby_id = joined_lobby_id

	# Guard importante: si EL LOBBY QUE ACABAMOS DE ENTRAR ES EL NUESTRO (o sea,
	# nosotros somos el owner), significa que este callback llego como eco de
	# nuestro propio host_lobby()/_on_lobby_created(), que ya nos dejo como host.
	# Sin este chequeo, el host se crearia a si mismo un peer de tipo CLIENTE
	# encima del peer de HOST que ya tiene, rompiendo la conexion.
	if Steam.getLobbyOwner(lobby_id) == Steam.getSteamID():
		return

	peer = SteamMultiplayerPeer.new()
	peer.server_relay = true
	peer.create_client(Steam.getLobbyOwner(lobby_id))
	multiplayer.multiplayer_peer = peer

	# La transicion a la sala de espera para el CLIENTE no pasa aca: recien pasa
	# cuando la conexion de verdad termina de establecerse, ver _on_connected_to_server.


# Se dispara cuando el jugador acepta una invitacion desde el overlay de Steam
# (o hace doble click en "Unirse a la partida" de un amigo). Simplemente le
# pedimos a Steam que nos una a ese lobby; el resultado llega por _on_lobby_joined.
func _on_join_requested(requested_lobby_id: int, _friend_steam_id: int) -> void:
	Steam.joinLobby(requested_lobby_id)


# Señal built-in de Godot: se dispara SOLO en el CLIENTE cuando su conexion
# con el host termina de establecerse de verdad (no el host, que nunca "se
# conecta a si mismo").
func _on_connected_to_server() -> void:
	get_tree().change_scene_to_file(LOBBY_SCENE)


# Señal built-in de Godot: se dispara en un CLIENTE si pierde la conexion con
# el host. Volvemos al menu principal — no hay partida sin servidor.
func _on_server_disconnected() -> void:
	peer = null
	lobby_id = 0
	get_tree().change_scene_to_file(MAIN_MENU_SCENE)


# Llamado desde el menu de pausa ("Volver al menu principal"). Cierra la
# conexion de red (si hay una) antes de volver — si sos el host, esto tambien
# corta a todos los demas (a ellos les llega server_disconnected solos, y
# vuelven al menu por su cuenta).
func leave_game() -> void:
	if peer != null:
		peer.close()
	multiplayer.multiplayer_peer = null
	lobby_id = 0
	get_tree().change_scene_to_file(MAIN_MENU_SCENE)
