extends SceneTree

func _initialize() -> void:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(38412, 4)
	print("SERVER create_server err=", err)
	get_multiplayer().multiplayer_peer = peer
	get_multiplayer().peer_connected.connect(func(id): print("SERVER saw peer_connected: ", id))

func _process(_delta: float) -> bool:
	return false
