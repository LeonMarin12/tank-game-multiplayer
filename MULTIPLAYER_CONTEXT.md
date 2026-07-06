# Contexto: Multijugador Godot 4 + GodotSteam (P2P vía Steam Relay)

> Este documento resume la arquitectura de multijugador de este proyecto para poder
> pegarlo como contexto base al pedirle a un asistente (Claude, etc.) que implemente
> el mismo patrón en otro proyecto Godot. Incluye la arquitectura, los archivos clave
> completos como plantilla, los pasos de configuración y los gotchas típicos.

## Resumen de la arquitectura

- **Motor:** Godot 4.7 (GDScript), física `CharacterBody2D`, physics engine Jolt para 3D (no relevante para el multiplayer 2D).
- **Transporte:** [GodotSteam](https://godotsteam.com/) (`addons/godotsteam`), usando `SteamMultiplayerPeer` como `MultiplayerPeer` de alto nivel de Godot. Esto significa que **todo el resto del juego usa la API estándar de Godot multiplayer** (`multiplayer.multiplayer_authority`, `MultiplayerSpawner`, `MultiplayerSynchronizer`, RPCs), y Steam solo se usa para descubrir/conectar peers a través de **lobbies de Steam** y su **relay network** (NAT punch-through gratis, sin servidor propio).
- **Topología:** el que crea el lobby es automáticamente el **servidor/host** (peer id 1); todos los demás son clientes. Es P2P vía relay de Steam, no dedicated server.
- **Patrón de autoridad:** cada jugador es dueño de sí mismo (`set_multiplayer_authority(name.to_int())` usando el peer id como nombre del nodo). El servidor decide cuándo y dónde se spawnean los jugadores.
- **Replicación:** posición del jugador y otros estados visuales se replican con `MultiplayerSynchronizer` + `SceneReplicationConfig` (modo "on change"), no con RPCs manuales para el movimiento.

## Diagrama de flujo

```
Host presiona "HOST"
  -> Networking.host_lobby() -> Steam.createLobby()
  -> signal lobby_created -> crea SteamMultiplayerPeer, peer.create_host()
  -> multiplayer.multiplayer_peer = peer   (host_created.emit())
  -> Main.on_host_created() spawnea su propio player
       y se suscribe a multiplayer.peer_connected -> spawnea player de cada nuevo cliente

Cliente se une (invite de Steam / overlay)
  -> Steam.join_requested -> Steam.joinLobby()
  -> signal lobby_joined -> si no soy el owner del lobby:
       crea SteamMultiplayerPeer, peer.create_client(owner_steam_id)
  -> multiplayer.multiplayer_peer = peer
  -> El servidor detecta peer_connected y spawnea el PlayerController
       via MultiplayerSpawner -> _on_multiplayer_spawner_spawned() en cada peer
       inicializa posición y collision exceptions
```

## Estructura de archivos (mínima)

```
project.godot                # autoload Networking, ajustes [steam]
networking.gd                # autoload: gestiona lobby de Steam + creación del peer
main.gd / main.tscn          # escena raíz: botón Host, SpawnPoint, MultiplayerSpawner
player_controller.gd/.tscn   # jugador: autoridad, movimiento, MultiplayerSynchronizer
addons/godotsteam/           # plugin GodotSteam (gdextension nativo, multiplataforma)
```

## Configuración de `project.godot`

```ini
[autoload]
Networking="*uid://cbff071ao1x3t"   ; el autoload apunta al script networking.gd

[editor_plugins]
enabled=PackedStringArray("res://addons/godotsteam/plugin.cfg")

[steam]
initialization/app_id=480                 ; 480 = Spacewar (app id de test de Valve)
initialization/initialize_on_startup=true
initialization/embed_callbacks=false
multiplayer_peer/max_channels=4
```

**Para replicar en otro proyecto:**
1. Copiar/instalar el addon `godotsteam` (binarios nativos por plataforma) y habilitarlo en `Project Settings > Plugins`.
2. Configurar `[steam] initialization/app_id` con tu App ID real de Steamworks (o `480` para pruebas locales).
3. Crear el autoload `Networking` apuntando al script equivalente a `networking.gd`.
4. Steam debe estar corriendo en el equipo (cliente Steam local) para que `Steam.initRelayNetworkAccess()` y el resto funcionen; en pruebas locales con `480` hace falta el archivo `steam_appid.txt` junto al ejecutable si se corre fuera del editor.

## `networking.gd` (autoload) — plantilla completa

```gdscript
extends Node

signal host_created()

const LOBBY_TYPE := Steam.LobbyType.LOBBY_TYPE_FRIENDS_ONLY
const MAX_MEMBERS := 4

var peer: SteamMultiplayerPeer

func _ready() -> void:
	Steam.initRelayNetworkAccess()
	Steam.lobby_created.connect(on_lobby_created)
	Steam.lobby_joined.connect(on_lobby_joined)
	Steam.join_requested.connect(on_join_requested)


func _process(delta: float) -> void:
	# Must be called every frame
	Steam.run_callbacks()


func host_lobby() -> void:
	# Will cause the "lobby_created" and "lobby_joined" signals to emit
	Steam.createLobby(LOBBY_TYPE, MAX_MEMBERS)


# Called after creating a lobby locally
func on_lobby_created(connect: int, lobby_id: int) -> void:
	# We created the lobby, so we act as server host
	if connect == Steam.RESULT_OK:
		peer = SteamMultiplayerPeer.new()
		peer.server_relay = true
		peer.create_host()
		multiplayer.multiplayer_peer = peer
		host_created.emit()


# Called when joining a lobby (after creating the lobby or joining a friend)
func on_lobby_joined(lobby_id: int, permissions: int, locked: bool, response: int) -> void:
	if response == Steam.CHAT_ROOM_ENTER_RESPONSE_SUCCESS:
		# If we created the lobby, we are already hosting, so we should not create a new client peer
		if Steam.getLobbyOwner(lobby_id) == Steam.getSteamID():
			return
		peer = SteamMultiplayerPeer.new()
		peer.server_relay = true
		peer.create_client(Steam.getLobbyOwner(lobby_id))
		multiplayer.multiplayer_peer = peer


# Called when attempting to join from the Steam interface
func on_join_requested(lobby_id: int, steam_id: int) -> void:
	# Will cause the "lobby_joined" signal to emit
	Steam.joinLobby(lobby_id)
```

Puntos clave a explicarle a la IA al reusar esto:
- `LOBBY_TYPE_FRIENDS_ONLY` + `MAX_MEMBERS` son configurables (público, privado, invite-only, etc.).
- `server_relay = true` en el peer hace que todo el tráfico pase por el relay de Steam (funciona sin abrir puertos ni NAT punch manual). Ponerlo en `false` solo si se sabe lo que se hace (P2P directo).
- El chequeo `Steam.getLobbyOwner(lobby_id) == Steam.getSteamID()` evita que el host se cree un peer cliente duplicado al recibir su propio `lobby_joined`.
- `Steam.run_callbacks()` **debe** llamarse cada frame o los signals de Steam nunca llegan.

## `main.gd` / `main.tscn` — escena raíz y spawn de jugadores

```gdscript
extends Node2D

const PLAYER_CONTROLLER = preload("uid://disid262nfj6n")

var players: Array[CharacterBody2D]

func _ready() -> void:
	Networking.host_created.connect(on_host_created)


func on_host_created() -> void:
	# Spawn the server player
	spawn_player(multiplayer.get_unique_id())
	multiplayer.peer_connected.connect(spawn_player)


# The server spawns the player that just connected
func spawn_player(peer_id: int) -> void:
	var new_player := PLAYER_CONTROLLER.instantiate() as CharacterBody2D
	new_player.name = str(peer_id)
	add_child(new_player)
	initialize_player(new_player)


func initialize_player(player: CharacterBody2D) -> void:
	player.position = $SpawnPoint.position
	for other in players:
		player.add_collision_exception_with(other)
	players.append(player)


func _on_host_pressed() -> void:
	Networking.host_lobby()


func _on_multiplayer_spawner_spawned(node: Node) -> void:
	if node is CharacterBody2D:
		initialize_player(node)
```

Nodos en `main.tscn`:
- `CanvasLayer/Host` (Button) -> conecta `pressed` a `_on_host_pressed`.
- `SpawnPoint` (Node2D) -> posición inicial de spawn.
- `MultiplayerSpawner` con `spawn_path = ".."` (spawnea como hijos de `Main`) y `_spawnable_scenes` apuntando a la escena del jugador -> conecta su signal `spawned` a `_on_multiplayer_spawner_spawned`.

**Cómo funciona el spawn:** solo el **servidor** llama `add_child(new_player)` explícitamente (dentro de `spawn_player`, llamado únicamente desde `on_host_created`, que solo corre en el host). El `MultiplayerSpawner` detecta ese `add_child` en el servidor y lo replica automáticamente hacia todos los clientes; en cada cliente se dispara la señal `spawned`, de ahí `_on_multiplayer_spawner_spawned` que corre `initialize_player` localmente (posición + collision exceptions) para que cada peer tenga el estado inicial correcto sin necesidad de un RPC manual.

## `player_controller.gd` / `.tscn` — jugador con autoridad y replicación

```gdscript
extends CharacterBody2D

@onready var hat: Node2D = %Hat

const SPEED := 500.0

func _enter_tree() -> void:
	set_multiplayer_authority(name.to_int())


func _physics_process(delta: float) -> void:
	# First check if we have authority over this player
	if not is_multiplayer_authority():
		return

	velocity = Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down") * SPEED

	move_and_slide()

	if Input.is_key_pressed(KEY_G):
		hat.scale += Vector2.ONE * delta
	if Input.is_key_pressed(KEY_S):
		hat.scale -= Vector2.ONE * delta
```

Nodos en `player_controller.tscn`:
- Nombre del nodo raíz = `peer_id` como string (asignado en `spawn_player`) — de ahí `set_multiplayer_authority(name.to_int())`.
- `MultiplayerSynchronizer` con `SceneReplicationConfig` replicando:
  - `.:position` (posición del `CharacterBody2D`), `spawn = true`, `replication_mode = 1` (on-change).
  - `Hat:scale` (escala de un nodo hijo), mismo modo.
- Patrón de autoridad: **cada cliente simula su propio movimiento localmente** (`is_multiplayer_authority()` guard) y el `MultiplayerSynchronizer` se encarga de propagar el resultado (posición) a los demás. No hay RPCs de input; es replicación de estado, no de comandos — válido para prototipos, pero implica que el servidor no autoriza el movimiento (sin anti-cheat, sin reconciliación/lag-compensation).

## Pasos para replicar este patrón en un proyecto nuevo

1. **Addon:** instalar GodotSteam (o el addon de networking equivalente) y habilitarlo.
2. **project.godot:** configurar App ID de Steam, agregar el autoload de networking.
3. **Autoload de networking:** copiar `networking.gd`, ajustando `LOBBY_TYPE` y `MAX_MEMBERS` a las necesidades del juego. Exponer una señal `host_created` (y opcionalmente `client_connected`) para que la escena de juego reaccione.
4. **Escena raíz del juego:**
   - Escuchar `host_created` para que **solo el host** empiece a spawnear.
   - Usar `multiplayer.peer_connected` para spawnear un jugador por cada nuevo peer (solo en el servidor).
   - Agregar un `MultiplayerSpawner` apuntando a la ruta donde se agregan los jugadores, con la escena del jugador en `_spawnable_scenes`.
   - Conectar la señal `spawned` del spawner para inicializar el estado localmente en todos los peers (posición, collision exceptions, UI, etc.).
5. **Escena del jugador:**
   - Nombrar el nodo raíz con el `peer_id` al spawnearlo (`str(peer_id)`).
   - En `_enter_tree()`, `set_multiplayer_authority(name.to_int())`.
   - Guardar toda lógica de input/física detrás de `if not is_multiplayer_authority(): return`.
   - Agregar `MultiplayerSynchronizer` + `SceneReplicationConfig` para las propiedades que deban verse en todos los clientes (posición, animación, cosméticos, etc.).
6. **UI de conexión:** un botón "Host" que llame a `host_lobby()`. Unirse a un amigo se dispara automáticamente vía overlay de Steam (`Steam.join_requested`), no requiere UI propia salvo que se quiera lobby browser manual.

## Gotchas / cosas a tener en cuenta

- `Steam.run_callbacks()` en `_process` cada frame es obligatorio; sin esto ningún signal de Steam se dispara.
- Evitar crear un peer cliente duplicado en el host comparando `Steam.getLobbyOwner(lobby_id) == Steam.getSteamID()` dentro de `on_lobby_joined`.
- `server_relay = true` es la opción recomendada por simplicidad (usa el relay de Steam, evita configurar NAT/puertos). Tiene algo más de latencia que P2P directo.
- El servidor es autoritativo solo para **cuándo/dónde se spawnea**, no para el movimiento en este ejemplo — si se necesita anti-cheat o server-authoritative movement, hay que mover la lógica de `_physics_process` a un RPC validado por el servidor en vez de dejar que cada cliente mueva su propio `CharacterBody2D` libremente.
- `add_collision_exception_with` entre todos los jugadores existentes evita que los `CharacterBody2D` se empujen entre sí al spawnear encima uno del otro; hay que mantenerlo sincronizado en `initialize_player` en todo cliente nuevo.
- El nombre del nodo del jugador (string del `peer_id`) es la clave que amarra spawn, autoridad y replicación — si se cambia el esquema de naming hay que actualizar `set_multiplayer_authority(name.to_int())` en consecuencia.
- Para pruebas locales sin lanzar el juego desde Steam, se necesita `steam_appid.txt` (con el App ID, ej. `480`) junto al ejecutable/editor.

## Prompt base sugerido para pedirle a una IA que implemente esto en otro proyecto

> "Quiero implementar multijugador en este proyecto Godot 4 usando GodotSteam +
> SteamMultiplayerPeer, con el mismo patrón que [pegar este documento]: un autoload
> `Networking` que crea/une lobbies de Steam y levanta el peer con `server_relay = true`;
> el servidor spawnea jugadores vía `MultiplayerSpawner` al detectar `peer_connected`;
> cada jugador tiene autoridad sobre sí mismo (`set_multiplayer_authority(name.to_int())`)
> y replica su estado con `MultiplayerSynchronizer`. Adaptalo a [describir la escena/juego
> concreto: qué se debe spawnear, qué propiedades replicar, tipo de lobby, etc.]."
