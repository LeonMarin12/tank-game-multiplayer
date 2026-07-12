extends SceneTree

func _initialize() -> void:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client("127.0.0.1", 38412)
	print("CLIENT create_client err=", err)
	get_multiplayer().multiplayer_peer = peer
	get_multiplayer().connected_to_server.connect(func(): print("CLIENT connected_to_server!"))
	get_multiplayer().connection_failed.connect(func(): print("CLIENT connection_failed!"))

func _process(_delta: float) -> bool:
	return false
