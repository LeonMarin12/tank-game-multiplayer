extends CanvasLayer

# ============================================================================
# Menu de pausa reutilizable: se instancia igual en Main.tscn (gameplay),
# Debug.tscn (sandbox) y Lobby.tscn (sala de espera). Escape lo abre; Escape
# de nuevo (o "Volver") lo cierra. Mientras esta abierto, pausa el arbol local
# (get_tree().paused) para que el propio tanque no siga moviendose por
# detras del menu — este nodo se marca PROCESS_MODE_ALWAYS (ver .tscn) para
# poder seguir escuchando Escape/clicks de los botones mientras todo lo demas
# esta pausado.
# ============================================================================

@onready var root: Control = $Root
@onready var resume_button: Button = $Root/CenterContainer/VBoxContainer/ResumeButton
@onready var main_menu_button: Button = $Root/CenterContainer/VBoxContainer/MainMenuButton
@onready var quit_button: Button = $Root/CenterContainer/VBoxContainer/QuitButton


func _ready() -> void:
	root.visible = false
	resume_button.pressed.connect(close_menu)
	main_menu_button.pressed.connect(_on_main_menu_pressed)
	quit_button.pressed.connect(_on_quit_pressed)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		if root.visible:
			close_menu()
		else:
			open_menu()
		get_viewport().set_input_as_handled()


func open_menu() -> void:
	root.visible = true
	get_tree().paused = true


func close_menu() -> void:
	root.visible = false
	get_tree().paused = false


func _on_main_menu_pressed() -> void:
	# Networking.leave_game() se encarga de cerrar el peer de red (si hay uno)
	# antes de cambiar de escena, para no dejar una conexion colgada.
	close_menu()
	Networking.leave_game()


func _on_quit_pressed() -> void:
	get_tree().quit()
