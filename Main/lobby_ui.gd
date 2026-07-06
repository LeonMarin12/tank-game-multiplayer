extends Control

# UI minima de conexion: un boton "Host" + un label de estado. Unirse a una
# partida NO tiene boton propio: llega solo via el overlay de invitacion de
# Steam (Steam.join_requested, manejado en Networking._on_join_requested)
# cuando aceptas la invitacion de un amigo desde el cliente de Steam.

@onready var status_label: Label = $StatusLabel
@onready var host_button: Button = $HostButton


func _ready() -> void:
	host_button.pressed.connect(Networking.host_lobby)


func set_status(text: String) -> void:
	status_label.text = text
