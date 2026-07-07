extends Control

const MIN_PLAYERS_TO_START := 2

@onready var status_label: Label = $CenterContainer/VBoxContainer/StatusLabel
@onready var player_list_label: Label = $CenterContainer/VBoxContainer/PlayerListLabel
@onready var start_button: Button = $CenterContainer/VBoxContainer/StartButton


func _ready() -> void:
	# Estas dos señales built-in se disparan en TODOS los peers (no solo en el
	# servidor) cada vez que cualquiera se une o se va — asi la lista se
	# mantiene igual en la pantalla de cada jugador sin necesidad de un RPC propio.
	multiplayer.peer_connected.connect(_on_roster_changed)
	multiplayer.peer_disconnected.connect(_on_roster_changed)
	start_button.pressed.connect(_on_start_pressed)

	# Solo el host puede arrancar la partida.
	start_button.visible = multiplayer.is_server()

	status_label.text = "Lobby de Steam (id %d)" % Networking.lobby_id
	_refresh_roster()


func _on_roster_changed(_peer_id: int) -> void:
	_refresh_roster()


func _refresh_roster() -> void:
	var ids := _get_all_peer_ids()

	var text := ""
	for id in ids:
		var tags := ""
		if id == 1:
			tags += " (host)"
		if id == multiplayer.get_unique_id():
			tags += " (vos)"
		text += "Jugador %d%s\n" % [id, tags]
	player_list_label.text = text

	if multiplayer.is_server():
		start_button.disabled = ids.size() < MIN_PLAYERS_TO_START


# get_peers() no incluye el propio id local, asi que lo agregamos a mano.
func _get_all_peer_ids() -> Array:
	var ids: Array = [multiplayer.get_unique_id()]
	ids.append_array(multiplayer.get_peers())
	ids.sort()
	return ids


func _on_start_pressed() -> void:
	start_game.rpc()


# "authority" limita quien puede llamar esto de forma remota a quien tenga
# autoridad sobre este nodo (el servidor, por defecto peer id 1) — coincide
# con que solo el host ve el boton habilitado. "call_local" para que el propio
# host tambien cambie de escena al llamarlo (ver request_kill_player en
# Main.gd para la misma necesidad con rpc_id apuntando a uno mismo).
@rpc("authority", "call_local", "reliable")
func start_game() -> void:
	get_tree().change_scene_to_file("res://Main/Main.tscn")
