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
- **Bala**: `Main/Bullet/bullet.gd` + `bullet.tscn`. Se mueve, rebota en paredes
  (`move_and_collide` + `bounce`), máximo 4 rebotes o 5s de vida. Al tocar un
  player (grupo "players") pide su destrucción al servidor vía RPC y se autodestruye.
  Autoridad = quien disparó (`shooter_id`), no el servidor. El `BulletSpawner` de
  cada Player NO trae `spawn_path` fijo en el `.tscn` — quien aloja al Player
  (`Main.gd` / `debug_sandbox.gd`) llama `player.set_bullet_container(bullets)`
  justo después de agregarlo al árbol (ver Decisiones tomadas: por qué no `%Bullets`).
- **Laberinto**: `Main/Maze/maze_generator.gd` (recursive backtracker, ahora
  determinístico vía `generate_maze(seed_value)`), `maze_cell.gd` (enum `Content`
  arreglado: EMPTY/START/CHEST/ENEMY/KEY/END), y `maze_builder.gd` (nuevo) que
  construye la geometría física real (StaticBody2D + CollisionShape2D + ColorRect
  placeholder) a partir del array lógico, sin duplicar paredes compartidas.
- **Multiplayer/Steam**: `Net/networking.gd` (autoload) implementa el patrón de
  `MULTIPLAYER_CONTEXT.md` (host de lobby = servidor/peer 1, `SteamMultiplayerPeer`
  con `server_relay=true`, guard anti-duplicado en `on_lobby_joined`). `Main.gd`
  sincroniza el seed del laberinto por RPC dirigido a cada peer nuevo (antes de
  spawnearlo), spawnea jugadores vía `PlayerSpawner` (modo automático, solo el
  servidor hace `add_child`), y resuelve la destrucción de un player impactado
  con un RPC (`request_kill_player`) dirigido al servidor. Al morir, el servidor
  respawnea automáticamente al mismo `peer_id` después de `RESPAWN_DELAY=3.0`s
  (`_respawn_after_delay`, con `await get_tree().create_timer(...)`), siempre
  que el peer siga conectado. UI mínima: botón "Host" + label de estado
  (`Main/lobby_ui.gd`).
- **project.godot**: GodotSteam habilitado y configurado (`app_id=480` de test,
  `initialize_on_startup=false`), autoload `Networking`, layers Player/Wall/Bullet,
  input map `move_forward/move_backward/rotate_left/rotate_right/shoot`,
  `run_main_scene=Main/Main.tscn`. `steam_appid.txt` (480) en la raíz para builds
  exportados. `Networking._ready()` ahora inicializa Steam a mano con
  `Steam.steamInitEx(app_id)` (en vez de depender del auto-init del motor, que
  corre demasiado temprano y a veces deja la interfaz de Relay Network sin
  inicializar) y guarda el resultado en `steam_available`; si falla, solo tira un
  `push_warning` controlado en vez del error nativo. El resto del juego no depende
  de esto para nada.
- **`Debug/Debug.tscn`** (nuevo): sandbox aislado para probar Player + Laberinto
  SIN pasar por Steam/Networking/Main.gd — tiene el laberinto y un Player ya
  instanciados como nodos editables (no generados por código), más una Camera2D
  que sigue al tanque. Script `Debug/debug_sandbox.gd`: arma el laberinto con un
  seed fijo (reproducible) y reposiciona cualquier Player que esté en la escena
  sobre la celda START. Anda con F6 directo, sin depender de que Steam esté
  corriendo ni de crear un lobby.
- Verificado con Godot 4.7 en modo headless (`--check-only --quit` y corriendo
  `Debug/Debug.tscn` directo): el proyecto parsea y arranca sin errores de
  script/escena.

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

## Próximos pasos
- Playtesting real en el editor: F6 sobre `Debug/Debug.tscn` para iterar rápido
  sobre player/laberinto, y F6 sobre `Main.tscn` para el flujo completo con Steam.
- Probar 2 instancias locales (Debug → Run Multiple Instances) para pescar errores
  de NodePath/spawn — **no** sirve para probar el lobby de Steam real (ver Notas).
- Probar host + invitación con una segunda cuenta de Steam (idealmente otra PC).
- Pulir: arte real del laberinto (TileMap con `Tile.png`), UI de lobby más
  completa, indicador de vida/muerte del jugador, sonidos/efectos de disparo.

## Notas / Gotchas
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
