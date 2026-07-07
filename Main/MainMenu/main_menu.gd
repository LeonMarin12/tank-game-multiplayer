extends Control

@onready var host_button: Button = $CenterContainer/VBoxContainer/HostButton
@onready var debug_button: Button = $CenterContainer/VBoxContainer/DebugButton
@onready var quit_button: Button = $CenterContainer/VBoxContainer/QuitButton
@onready var status_label: Label = $CenterContainer/VBoxContainer/StatusLabel


func _ready() -> void:
	host_button.pressed.connect(_on_host_pressed)
	debug_button.pressed.connect(_on_debug_pressed)
	quit_button.pressed.connect(_on_quit_pressed)


func _on_host_pressed() -> void:
	if not Networking.steam_available:
		status_label.text = "Steam no esta disponible - no se puede hostear."
		return
	# Deshabilita para evitar doble-click mientras Steam crea el lobby de forma
	# asincrona. Networking.gd es quien nos cambia de escena cuando este listo
	# (ver _on_lobby_created) — no hace falta esperar nada aca.
	host_button.disabled = true
	status_label.text = "Creando sala..."
	Networking.host_lobby()


func _on_debug_pressed() -> void:
	get_tree().change_scene_to_file("res://Debug/Debug.tscn")


func _on_quit_pressed() -> void:
	get_tree().quit()
