# Contexto del proyecto — Tank Game Multiplayer

## Objetivo
Juego 2D top-down de tanques en un laberinto, pensado ante todo como **práctica de
conexión multiplayer por Steam** (lobbies + invitación vía GodotSteam). El gameplay
(movimiento, disparo, laberinto) existe para tener algo concreto que sincronizar en red.

## Estado actual
- **Player**: `Main/Player/player_controller.gd` + `player.tscn`. Movimiento tanque
  (W/S adelante-atrás según rotación, A/D rota), dispara con `shoot` (Space) con
  cooldown. Autoridad por `set_multiplayer_authority(name.to_int())` **solo si el
  nombre del nodo es numérico** (`name.is_valid_int()`) — si lo agregaste a mano con
  otro nombre (ej. "Player" en Debug.tscn) se deja la autoridad por defecto (1), que
  ya coincide con `multiplayer.get_unique_id()` sin red. Replica posición/rotación
  vía `MultiplayerSynchronizer`. Layer "Player", mask "Wall".
- **Bala**: `Main/Bullet/bullet.gd` + `bullet.tscn`. Se mueve y rebota SOLO en
  paredes (`move_and_collide` + `bounce`, `collision_mask` ya no incluye
  "Player"), máximo 4 rebotes o 5s de vida. Autoridad = quien disparó
  (`shooter_id`), no el servidor. El `BulletSpawner` de cada Player NO trae
  `spawn_path` fijo en el `.tscn` — quien aloja al Player (`Main.gd` /
  `debug_sandbox.gd`) llama `player.set_bullet_container(bullets)` justo
  después de agregarlo al árbol (ver Decisiones tomadas: por qué no `%Bullets`).
  El impacto contra un player YA NO se detecta desde la bala — lo detecta el
  `HurtBox` (Area2D) del Player (ver abajo y Decisiones tomadas).
- **Player tiene DOS colisiones separadas** (`player.tscn`): la `CollisionShape2D`
  principal en el `CharacterBody2D` (layer Player, mask Wall) bloquea el
  movimiento contra el laberinto; un `HurtBox` (Area2D hijo, layer Player, mask
  Bullet, misma cápsula reutilizada) detecta balas via `body_entered`. En
  `player_controller.gd`, `_on_hurt_box_body_entered` (gateado por
  `is_multiplayer_authority()` — solo el dueño del tanque reporta su propio
  impacto) pide `request_kill_player` al servidor y llama
  `body.rpc("_force_destroy")` sobre la bala para que se destruya también en
  el peer que la disparó (que es quien tiene su física real).
- **Laberinto**: `Main/Maze/maze_generator.gd` (recursive backtracker, ahora
  determinístico vía `generate_maze(seed_value)`), `maze_cell.gd` (enum `Content`
  arreglado: EMPTY/START/CHEST/ENEMY/KEY/END), y `maze_builder.gd` (nuevo) que
  construye la geometría física real (StaticBody2D + CollisionShape2D + ColorRect
  placeholder) a partir del array lógico, sin duplicar paredes compartidas.
- **Flujo de escenas**: `MainMenu` (`Main/MainMenu/`, `run_main_scene`) — botones
  Hostear/Debug/Salir — → al hostear, `Lobby` (`Main/Lobby/`) muestra los
  jugadores conectados en tiempo real y tiene un botón "Empezar" (solo visible
  para el host, habilitado con 2+ jugadores) → al apretarlo, RPC
  `start_game()` (`@rpc("authority", "call_local")`) manda a TODOS los peers a
  `Main.tscn` (gameplay). Un cliente que se une via overlay de Steam entra
  directo al `Lobby` (no pasa por `MainMenu`).
- **Multiplayer/Steam**: `Net/networking.gd` (autoload) implementa el patrón de
  `MULTIPLAYER_CONTEXT.md` (host de lobby = servidor/peer 1, `SteamMultiplayerPeer`
  con `server_relay=true`, guard anti-duplicado en `on_lobby_joined`) y además
  decide los cambios de escena de todo el flujo de arriba (`_on_lobby_created`
  → Lobby; `multiplayer.connected_to_server` → Lobby para clientes;
  `multiplayer.server_disconnected` → vuelta a MainMenu) — centralizado ahí
  porque es el único lugar que conoce el estado de conexión sin importar qué
  escena esté activa. `Main.gd` (ahora solo gameplay, se entra con todos ya
  conectados) arma el laberinto y spawnea al propio host
  (`_bootstrap_as_server`, gateado por `multiplayer.is_server()` en `_ready()`).
  Cada CLIENTE, en vez de que el servidor lo spawnee proactivamente, avisa con
  `notify_ready.rpc_id(1)` apenas termina de cargar su propia copia de
  `Main.tscn`; recién ahí el servidor le contesta con el seed del laberinto y
  lo spawnea (ver Decisiones tomadas: por qué el orden es al revés de lo que
  parecería natural). Resuelve la destrucción de un player impactado con un
  RPC (`request_kill_player`) dirigido al servidor. Al morir, el servidor
  respawnea automáticamente al mismo `peer_id` después de `RESPAWN_DELAY=3.0`s
  (`_respawn_after_delay`, con `await get_tree().create_timer(...)`), siempre
  que el peer siga conectado. Junto con el spawn de cada cliente, el servidor
  también le manda `sync_existing_players` (RPC dirigido solo a él) con los
  peer_ids de los jugadores que ya estaban — esto crea copias "espejo" locales
  para los tanques que el `PlayerSpawner` no replica retroactivamente (ver
  Decisiones tomadas).
- **project.godot**: GodotSteam habilitado y configurado (`app_id=480` de test,
  `initialize_on_startup=false`), autoload `Networking`, layers Player/Wall/Bullet,
  input map `move_forward/move_backward/rotate_left/rotate_right/shoot`,
  `run_main_scene=Main/MainMenu/MainMenu.tscn`. `steam_appid.txt` (480) en la
  raíz para builds exportados. `Networking._ready()` ahora inicializa Steam a
  mano con `Steam.steamInitEx(app_id)` (en vez de depender del auto-init del
  motor, que corre demasiado temprano y a veces deja la interfaz de Relay
  Network sin inicializar) y guarda el resultado en `steam_available`; si
  falla, solo tira un `push_warning` controlado en vez del error nativo. El
  resto del juego no depende de esto para nada.
- **`Debug/Debug.tscn`** (nuevo): sandbox aislado para probar Player + Laberinto
  SIN pasar por Steam/Networking/Main.gd — tiene el laberinto y un Player ya
  instanciados como nodos editables (no generados por código), más una Camera2D
  que sigue al tanque. Script `Debug/debug_sandbox.gd`: arma el laberinto con un
  seed fijo (reproducible) y reposiciona cualquier Player que esté en la escena
  sobre la celda START. Anda con F6 directo, sin depender de que Steam esté
  corriendo ni de crear un lobby.
- **`Main/PauseMenu/`** (nuevo): menú de pausa reutilizable, instanciado en
  `Main.tscn`, `Debug.tscn` y `Lobby.tscn`. Escape lo abre (`get_tree().paused = true`),
  Escape de nuevo o "Volver" lo cierra. "Volver al menú principal" llama
  `Networking.leave_game()` (cierra el peer de red si hay uno y vuelve a
  `MainMenu`); "Salir del juego" hace `get_tree().quit()`. El nodo raíz tiene
  `process_mode = PROCESS_MODE_ALWAYS` para poder seguir escuchando Escape/clicks
  mientras el resto del árbol está pausado.
- **Explosión al morir**: `Main/Particles/explosion_particle.tscn` (ya existía,
  `CPUParticles2D` con `one_shot=true`) se instancia en la posición del player
  justo antes de destruirlo. En `Main.gd` es un RPC nuevo
  (`spawn_explosion`, `@rpc("authority", "call_local", "reliable")`) mandado a
  todos los peers desde `request_kill_player`, así se ve en todas las pantallas
  y no solo en la del servidor; en `debug_sandbox.gd` es una función local
  (no hace falta RPC real sin red). En ambos casos la instancia se conecta a su
  propia señal `finished` (que `CPUParticles2D` emite sola cuando `one_shot` ya
  terminó) para hacer `queue_free()` — no hay que llevar la cuenta del tiempo
  de vida a mano.
- **`request_kill_player` ahora recibe un `NodePath` en vez de un `peer_id`
  (int)**: lo manda `player_controller.gd` (`main.get_path_to(self)` desde
  `_on_hurt_box_body_entered`) y tanto `Main.gd` como `debug_sandbox.gd` lo
  resuelven con `get_node_or_null(path)`. En `Main.gd` el `peer_id` para el
  respawn se deriva del propio nombre del nodo (`player.name.to_int()`), que ya
  coincide por convención (ver Decisiones tomadas). El motivo del cambio:
  en `Debug.tscn` el Player y el Dummy de pruebas comparten la misma autoridad
  por defecto (no hay red real), así que `get_multiplayer_authority()` no
  alcanza para distinguir a cuál mataron — el `NodePath` sí, sin ambigüedad,
  en los dos escenarios.
- **`Debug.tscn` ahora implementa `request_kill_player`** (en
  `debug_sandbox.gd`), igual que `Main.gd` pero sin bookkeeping de red: al
  matar a un player, guarda su nombre y su `input_enabled`, lo destruye,
  dispara la explosión, y lo respawnea (mismo nombre, mismo `input_enabled`)
  después de `RESPAWN_DELAY=3.0`s sobre la celda START.
- **Cámara estática**: ya no vive dentro de `player.tscn` (se sacó el
  `Camera2D` que seguía al tanque). Ahora `Main.tscn` y `Debug.tscn` tienen su
  propia `Camera2D` fija ("MazeCamera", `enabled = true`) que encuadra el
  laberinto **completo**, centrada y con el zoom más chico entre ancho/alto
  (`_configure_static_camera()` en `Main.gd`/`debug_sandbox.gd`) para que
  entre entero sin recortarse en ningún eje. `maze_builder.gd` expone
  `get_maze_pixel_size()` / `get_maze_center_world_position()` y una señal
  `built` (se emite al final de `build()`) — la cámara se configura recién
  ahí porque en un cliente el laberinto llega async por RPC (`receive_maze_seed`),
  no en el mismo frame que `_ready()`. También se reconfigura sola si cambia el
  tamaño de la ventana (`get_viewport().size_changed`).
- **Dummy de pruebas** (`Debug.tscn`, nodo "Dummy"): una segunda instancia de
  `player.tscn` con `input_enabled = false` (export nuevo en
  `player_controller.gd`) — un tanque que no lee teclado ni dispara, pero sigue
  reaccionando a balas via su `HurtBox` normalmente, para poder probar
  golpe → explosión → respawn sin necesitar un segundo jugador real. El Player
  y el Dummy se separan en un anillo alrededor del START (mismo esquema que
  `SPAWN_RING_SLOTS` de `Main.gd`) para no quedar apilados.
- Verificado con Godot 4.7 en modo headless (`--check-only --quit`, y tests
  `SceneTree` ad-hoc instanciando `Debug.tscn`/`Main.tscn` completos): el
  proyecto parsea sin errores, y el flujo kill→explosión→respawn se probó de
  punta a punta en ambas escenas (dummy con `input_enabled` preservado tras
  respawnear, y `Main.tscn` standalone con `peer_id` derivado del nombre).

## Decisiones tomadas
- El laberinto **nunca viaja por red como dato**: cada peer lo regenera localmente
  a partir de un seed (int) que manda el servidor — evita transferir el array completo.
- **Players no colisionan entre sí** (collision mask), en vez de
  `add_collision_exception_with` por par: cada peer solo simula físicamente su
  propio tanque, así que un choque contra un tanque ajeno (que es solo un mirror
  replicado) generaría jitter.
- **Bullets no colisionan entre sí**: cada bala es autoritativa en un peer distinto
  (quien disparó), no hay forma consistente de resolver ese choque en este modelo.
- **Cada bala solo simula física en el peer que disparó** (autoridad = shooter_id,
  no el servidor) — evita divergencia de rebotes por float drift entre peers.
- **El impacto bala-vs-player se detecta desde el HurtBox del PLAYER, no desde
  la bala**: Godot no permite layers/masks distintas por `CollisionShape2D`
  dentro del mismo cuerpo, así que "chocar con el laberinto" (movimiento) y
  "detectar una bala" (hurtbox) necesitan ser objetos de colisión separados.
  Al detectar el impacto (gateado por `is_multiplayer_authority()` para que
  solo el dueño del tanque golpeado lo reporte, ya que las señales de Area2D
  corren localmente en cada peer sin importar autoridad), se avisa a la bala
  con un RPC (`_force_destroy`, `any_peer`) para que también se destruya en el
  peer que la disparó — si no, esa copia autoritativa seguiría rebotando ahí
  sin enterarse nunca del impacto.
- Los jugadores se spawnean con el patrón "solo el servidor hace `add_child` bajo
  el `PlayerSpawner`", igual al template de `MULTIPLAYER_CONTEXT.md`.
- Se usan las señales built-in `multiplayer.connected_to_server` /
  `server_disconnected` para la UI en vez de inventar señales propias.
- Paredes del laberinto: visual simple (ColorRect gris), sin TileMap todavía.
- **Los nombres únicos (`%Nombre`) no cruzan el límite de una escena instanciada**:
  solo se resuelven dentro del mismo archivo `.tscn` donde se declaran. Por eso
  `BulletSpawner` (dentro de `player.tscn`) no puede usar `spawn_path="%Bullets"`
  para apuntar a un nodo que vive en `Main.tscn`/`Debug.tscn` — hay que
  configurarlo en runtime desde la escena que aloja al Player
  (`set_bullet_container()`), no hardcodeado en el `.tscn` del Player.
- **`input_enabled` (export en `player_controller.gd`) es independiente de
  `is_multiplayer_authority()`**: la autoridad decide "quién simula la física
  de este tanque en esta máquina" (necesario para red real); `input_enabled`
  decide "¿este tanque en particular debería reaccionar al teclado?" —
  distinción que hace falta para el Dummy de `Debug.tscn`, que es autoritativo
  local (no hay red) pero no debe moverse ni disparar solo.
- **Sincronización de spawn de players via VISIBILIDAD, no via timing
  (`MultiplayerSynchronizer.public_visibility`)**: hubo dos intentos previos
  de arreglar una condición de carrera real en la transición Lobby→Main
  (`start_game()` cambia de escena en todos los peers con un solo `rpc()`,
  pero el host, via `call_local`, lo hace al instante, mientras que un cliente
  recién recibe ese RPC después de un viaje de red real — `server_relay = true`
  fuerza el relay de Steam siempre, ni en LAN es instantáneo). Si se manda un
  spawn/replicación a un peer ANTES de que su propio `Main.tscn` haya
  terminado de cargar, el paquete apunta a un nodo que no existe todavía del
  otro lado (Godot resuelve NodePaths al momento de llegar el paquete) y se
  descarta sin reintentar — y PEOR, deja rota para siempre esa ruta para ese
  peer, así que ni la posición/rotación ni el `BulletSpawner` de ese tanque
  vuelven a resolver del otro lado durante toda la partida (síntoma real,
  confirmado en pruebas con 2 PCs el 2026-07-12: tanques congelados en el
  origen, sin input, con errores repitiéndose tipo `get_node: Node not found:
  "Main/Players/1/MultiplayerSynchronizer"` y luego, al disparar,
  `"Main/Players/1/BulletSpawner"`/`on_spawn_receive: spawner is null`). Un
  primer intento (`notify_ready`, el cliente avisa cuando termina de cargar)
  solo protegía el spawn del CLIENTE — el host se seguía spawneando a sí mismo
  de inmediato en `_bootstrap_as_server()`, y ESE spawn seguía llegando
  temprano a un cliente que ya figuraba conectado desde el Lobby. Un segundo
  intento (esperar a que TODOS los del grupo inicial confirmaran antes de
  spawnear a cualquiera, host incluido) seguía sin resolverlo del todo y
  agregaba bastante complejidad (bookkeeping de "quién falta"). La solución
  definitiva usa el mecanismo que Godot ya tiene para exactamente este caso:
  el `MultiplayerSynchronizer` de `player.tscn` nace con
  `public_visibility = false`, así que un `add_child()` bajo `PlayerSpawner`
  **no se replica a NADIE** hasta que se llama
  `player_controller.gd:reveal_to(peer_id)` a mano
  (`synchronizer.set_visibility_for(peer_id, true)`) — y `MultiplayerSpawner`
  respeta esa visibilidad tanto para el spawn inicial como para la
  sincronización de posición/rotación en curso. Esto saca por completo el
  timing de la ecuación: el servidor puede spawnear a quien quiera (host
  incluido) apenas quiera, sin ningún riesgo, porque nadie lo va a VER hasta
  que se lo revele explícitamente. `notify_ready` (el cliente avisa cuando
  termina de cargar) sigue existiendo, pero ahora solo dispara
  `reveal_to()` — nunca puede llegar "temprano" porque exige que ese cliente
  ya haya cargado su propia escena para poder mandarlo. Esto también
  reemplazó por completo el viejo `sync_existing_players` (RPC manual para
  ponerse al día con jugadores preexistentes): revelar un jugador YA
  EXISTENTE a un peer nuevo dispara el mismo mecanismo de "spawn diferido" y
  manda su posición/rotación ACTUAL como parte del reveal, así que no hace
  falta ningún camino separado para el catch-up. Un tanque respawneado
  después de morir es una instancia nueva (visibilidad en `false` de nuevo)
  así que también hay que revelárselo a los peers ya listos
  (`_reveal_to_ready_peers`, en `_respawn_after_delay`).
- **`MultiplayerSpawner` no hace catch-up retroactivo para peers que se
  conectan tarde**: un `add_child()` solo se replica a los peers que YA
  estaban conectados en ese momento. Por eso un jugador que se une después de
  que otros ya estaban jugando no los veía. Se resuelve con un RPC manual
  (`sync_existing_players`, dirigido solo al peer nuevo) que crea copias
  locales de los jugadores preexistentes — con guard para no duplicar si
  alguno ya llegó por el camino normal.

## Próximos pasos
- Playtesting real en el editor: F6 sobre `Debug/Debug.tscn` para iterar rápido
  sobre player/laberinto, y F6 sobre `Main/MainMenu/MainMenu.tscn` (o F5) para
  el flujo completo Menu → Lobby → gameplay con Steam.
- Probar 2 instancias locales (Debug → Run Multiple Instances) para pescar errores
  de NodePath/spawn — **no** sirve para probar el lobby de Steam real (ver Notas).
- Probar host + invitación con una segunda cuenta de Steam (idealmente otra PC).
- Pulir: arte real del laberinto (TileMap con `Tile.png`), UI del menú/lobby/pausa
  más prolija (por ahora es solo botones+labels sin estilo), indicador de
  vida/muerte del jugador, sonidos/efectos de disparo.
- Probar el menú de pausa (Escape) jugando de verdad en el editor — no se pudo
  automatizar con un test headless (ver Notas).
- Probar visualmente la explosión (color/escala/duración) y el dummy de
  pruebas jugando en el editor — el flujo lógico ya está verificado con tests
  headless, pero no el aspecto visual real.

## Notas / Gotchas
- **Revisión de sincronización online (2026-07-12)**: se revisó todo el código
  de red a fondo (sin poder probarlo con una segunda cuenta real) buscando
  bugs de timing/orden antes de la primera prueba con 2 PCs. Se encontró y
  corrigió la condición de carrera del `notify_ready` (ver arriba). Quedan dos
  gaps conocidos, **no corregidos todavía porque son features más grandes, no
  bugs de lo que ya existe**:
  - **Unirse a una partida ya empezada (mid-game) no lleva a `Main.tscn`**:
    `Networking._on_connected_to_server()` SIEMPRE manda a un cliente recién
    conectado a `Lobby.tscn`, sin importar si el host ya está jugando en
    `Main.tscn`. Un amigo que acepta una invitación mid-game quedaría esperando
    en un Lobby vacío, sin forma de entrar a la partida en curso. El código que
    sí soportaría esto del lado de `Main.gd` (`notify_ready`/`sync_existing_players`)
    está listo y funcionaría bien SI el cliente llegara a cargar `Main.tscn`,
    pero falta ese último paso (`Networking.gd` necesitaría saber "el host ya
    está jugando" y mandar al recién conectado directo a `Main.tscn` en vez de
    a `Lobby.tscn`). No se implementó porque es una feature nueva, no estaba
    pedida — avisar si se quiere soportar unirse mid-game.
  - **Sin limpieza al desconectarse mid-game**: si un cliente cierra el juego o
    pierde la conexión durante una partida, su tanque (y el de los demás desde
    su perspectiva) no se despawnea — `Main.gd` no escucha
    `multiplayer.peer_disconnected`. Queda un tanque "fantasma" hasta que
    alguien reinicie. No es un bug de sincronización en sí (no rompe a los
    peers que siguen conectados), es una falta de limpieza — bajo impacto para
    una prueba corta entre dos personas, pero anotar si molesta.
- **Testing de Steam con una sola cuenta**: dos instancias del juego en la misma
  PC comparten la misma sesión de Steam (mismo SteamID) y no pueden aparecer como
  dos miembros distintos de un lobby. Para probar host/invitación de verdad hace
  falta una segunda cuenta de Steam.
- Si al abrir el **editor** de Godot aparece un error tipo "Can't open GDExtension
  dynamic library" para `godotsteam`, es porque el DLL está bloqueado (otra
  instancia de Godot abierta, o un archivo temporal `~libgodotsteam...` que quedó
  de una copia interrumpida en `addons/godotsteam/win64/`) — cerrar otras
  instancias de Godot suele resolverlo. No afecta al juego corriendo fuera del editor.
- Si todavía ves en consola "Networking Utils class not found, Steam may not be
  initialized" al arrancar, es un hiccup de la sesión de Steam (por ejemplo, tras
  cerrar de golpe otra instancia del juego con task manager) — no rompe nada, y
  ahora que `Networking._ready()` usa `Steam.steamInitEx()` en vez del auto-init
  del motor debería ser mucho menos frecuente. `steam_available` queda en `false`
  y el resto del juego sigue andando igual.
- **Bug real ya corregido (autoridad)**: si agregás un Player a mano con un nombre
  no numérico (como en `Debug.tscn`), `set_multiplayer_authority(name.to_int())`
  sin guard rompía `is_multiplayer_authority()` (quedaba en 0 en vez de 1) y el
  tanque no procesaba input ni se movía. Ahora `_enter_tree()` solo toca la
  autoridad si `name.is_valid_int()`; verificado con un test headless simulando
  `move_forward`.
- **Bug real ya corregido (disparo, v1)**: `bullet_spawner.spawn()` tiraba "Cannot
  find spawn node" (parent null) porque `spawn_path="%Bullets"` nunca resolvía
  — ver la decisión de arriba sobre nombres únicos. Corregido con
  `set_bullet_container()`; verificado con un test headless simulando `shoot`
  (bullets_before=0 → bullets_after=1, sin errores).
- **Bug real ya corregido (kill del propio host)**: `request_kill_player.rpc_id(1, hit_id)`
  fallaba con "RPC on yourself is not allowed by selected mode" cuando el HOST
  mismo era quien disparaba (ahi caller_id == target_id == 1, y Godot rechaza
  apuntarte un RPC a vos mismo salvo `call_local`). El `@rpc` de
  `request_kill_player` en `Main.gd` ahora incluye `"call_local"`.
- **Bug real ya corregido (disparo, v2)**: el mismo error volvía a aparecer en
  `Main.tscn` (no en `Debug.tscn`) porque la señal `spawned` del `PlayerSpawner`
  **no se dispara para el propio peer que hace `add_child()`** — solo se dispara
  en los demás peers al recibir la replicación. `set_bullet_container()` estaba
  solo en `_on_player_spawned` (el handler de esa señal), así que el player del
  host nunca lo recibía. Ahora `spawn_player()` también lo llama directo, igual
  que ya hacía con `_place_player()`.
- **Bug real ya corregido (jugadores invisibles al unirse tarde)**: al probar
  con una segunda cuenta de Steam, el cliente veía el laberinto (sincronizado
  por RPC) pero ningún tanque — ni el suyo ni el del host. Causa: `PlayerSpawner`
  no reenvía retroactivamente jugadores que ya existían antes de que ese peer
  se conectara (ver Decisiones tomadas). Corregido con `sync_existing_players`.
  Verificado con test headless (dedup + agregado de copias nuevas, sin
  duplicar). **Limitación conocida que queda pendiente**: si un jugador
  preexistente muere/despawnea, no está garantizado que la copia "espejo" en un
  peer que se unió tarde se borre correctamente (el despawn nativo del
  `PlayerSpawner` podría no reconocer esa copia como "suya") — podría quedar un
  tanque fantasma hasta que ese peer se desconecte. No se aborda todavía porque
  no fue parte de este pedido; anotar si se reporta.
- **Testing de `get_tree().change_scene_to_file()` en scripts headless
  standalone**: probar la cadena completa Lobby→Main (llamando `start_game()`
  directo y esperando el cambio de escena) colgó el proceso en un `SceneTree`
  armado a mano vía `--script` — parece una limitación de ese harness ad-hoc,
  no del código real (Lobby y Main funcionan bien probados por separado). Si
  hace falta volver a automatizar este tipo de test, probar corriendo la
  escena real vía `godot <scena> --quit-after N` en vez de un `SceneTree`
  scripteado.
- **Bug real ya corregido (`Camera2D.current` no existe en Godot 4)**: al
  armar la cámara estática se puso `current = true` en el `.tscn` (idioma de
  Godot 3). En Godot 4 esa propiedad se llama `enabled`; con `current` la
  escena parseaba sin error pero fallaba en tiempo de ejecución apenas algo
  intentaba leer `cam.current` ("Invalid access to property or key
  'current'"). Detectado con un test headless. Corregido a `enabled = true`
  en `Main.tscn` y `Debug.tscn`.
- **Testing de input (`_input`/`_unhandled_input`) en `--headless --script`**:
  confirmado que los eventos simulados con `Input.parse_input_event()` NO
  llegan a `_input`/`_unhandled_input` en este modo (probado con un nodo
  mínimo, sin nada de nuestro código de por medio) — es una limitación del
  modo headless/harness scripteado, no algo para "arreglar" en el juego. El
  menú de pausa (`pause_menu.gd`) usa el patrón estándar de Godot
  (`_unhandled_input` + `event.is_action_pressed("ui_cancel")`), pero no se
  pudo verificar de punta a punta con un test automatizado por esta razón —
  falta probarlo jugando en el editor.
