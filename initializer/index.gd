extends Control

@onready var scene_root : Window = get_tree().root if not Engine.is_editor_hint() else Engine.get_main_loop().editor_scene_root

var _main : Node2D
var _url : String = "http://localhost/{os}/{path}.zip".format({ "os": OS.get_name().to_lower() })
var _request_nodes : Dictionary = {}
var _client_loaded : bool = false
var _menu_loaded : bool = false

func _ready():

	_main = Node2D.new()
	_main.name = "Main"
	_main.visible = false
	scene_root.call_deferred("add_child", _main)
	while _main.is_node_ready() != true: await get_tree().create_timer(1.0).timeout

	load_client()
	load_menu()

	while _client_loaded != true && _menu_loaded != true: await get_tree().create_timer(1.0).timeout

	self.hide()
	_main.show()

func load_client():
	var packed := await load_packed_from_url(_url.format({ "path": "client" }))
	packed.update.connect(func(downloaded_bytes, body_size):
		$CenterContainer/VBoxContainer/LoadingClient.text = "Loading Client %d%%" % [int(floor(downloaded_bytes * 100.0 / body_size))]
	)
	if not await packed.complete: $CenterContainer/VBoxContainer/LoadingClient.text = "Loading Client failed!"
	else:
		var resource = ResourceLoader.load("res://client/index.tscn", "PackedScene")
		if resource:
			var instance_scene = resource.instantiate()
			_main.call_deferred("add_child", instance_scene)
			while instance_scene.is_node_ready() != true: await get_tree().create_timer(1.0).timeout
		_client_loaded = true

func load_menu():
	var packed := await load_packed_from_url(_url.format({ "path": "menu" }))
	packed.update.connect(func(downloaded_bytes, body_size):
		$CenterContainer/VBoxContainer/LoadingMenu.text = "Loading Menu %d%%" % [int(floor(downloaded_bytes * 100.0 / body_size))]
	)
	if not await packed.complete: $CenterContainer/VBoxContainer/LoadingMenu.text = "Loading Menu failed!"
	else:
		var resource = ResourceLoader.load("res://menu/index.tscn", "PackedScene")
		if resource:
			var instance_scene = resource.instantiate()
			_main.call_deferred("add_child", instance_scene)
			while instance_scene.is_node_ready() != true: await get_tree().create_timer(1.0).timeout
		_menu_loaded = true

func load_packed_from_url(url: String) -> AwaitSignal:
	var _await = AwaitSignal.new()
	var _request : HTTPRequest
	if not url in _request_nodes:
		_request = HTTPRequest.new()
		_request.download_chunk_size = 4096
		_request.use_threads = true
		self.add_child(_request)
		while _request.is_node_ready() != true: await get_tree().create_timer(1.0).timeout
		_request_nodes[url] = _request
	else: _request = _request_nodes[url]

	Callable(func():
		var uuid = UUID.v4().substr(0, 8)
		var file_name = url.get_file().get_slice(".", 0)
		var file_ext = url.get_file().get_slice(".", 1)
		var file_path = "user://temp/{name}-{uuid}.{ext}".format({ "uuid": uuid, "name": file_name, "ext": file_ext })

		if not DirAccess.dir_exists_absolute(file_path.get_base_dir()):
			DirAccess.make_dir_recursive_absolute(file_path.get_base_dir())

		_await.update.emit(0.0, 0.0)
		while _request.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
			await get_tree().create_timer(1.5).timeout

		_request.download_file = file_path

		_request.request_completed.connect(func(result: int, response_code: int, _headers: PackedStringArray, _body: PackedByteArray):
			if result == HTTPRequest.RESULT_SUCCESS && response_code == HTTPClient.RESPONSE_OK:
				ProjectSettings.load_resource_pack(file_path)
				DirAccess.remove_absolute(file_path)
			else:
				var error_message = "The HTTP request for the asset pack did not succeed. "
				match result:
					HTTPRequest.RESULT_CHUNKED_BODY_SIZE_MISMATCH:
						error_message += "Chunked body size mismatch."
					HTTPRequest.RESULT_CANT_CONNECT:
						error_message += "Request failed while connecting."
					HTTPRequest.RESULT_CANT_RESOLVE:
						error_message += "Request failed while resolving."
					HTTPRequest.RESULT_CONNECTION_ERROR:
						error_message += "Request failed due to connection (read/write) error."
					HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:
						error_message += "Request failed on TSL handshake."
					HTTPRequest.RESULT_NO_RESPONSE:
						error_message += "No response."
					HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED:
						error_message += "Request exceeded its maximum body size limit."
					HTTPRequest.RESULT_REQUEST_FAILED:
						error_message += "Request failed."
					HTTPRequest.RESULT_DOWNLOAD_FILE_CANT_OPEN:
						error_message += "HTTPRequest couldn't open the download file."
					HTTPRequest.RESULT_DOWNLOAD_FILE_WRITE_ERROR:
						error_message += "HTTPRequest couldn't write to the download file."
					HTTPRequest.RESULT_REDIRECT_LIMIT_REACHED:
						error_message += "Request reached its maximum redirect limit."
					HTTPRequest.RESULT_TIMEOUT:
						error_message += "Request timed out."
					_:
						match response_code:
							HTTPClient.RESPONSE_NOT_FOUND:
								error_message += "Request failed due to invalid URL."
				push_error(error_message)
				_await.error_message = error_message
				_await.complete.emit(false)
				return
		)

		_request.request_ready()
		var error = _request.request(url)
		if error != OK:
			_request_nodes[url].queue_free()
			_request_nodes.erase(url)
			var error_message = "An error occurred while making the HTTP request: %d." % error
			push_error(error_message)
			_await.error_message = error_message
			_await.complete.emit(false)
			return

		Callable(func():
			var downloaded_bytes = _request.get_downloaded_bytes()
			var body_size = _request.get_body_size()
			while downloaded_bytes != body_size:
				downloaded_bytes = _request.get_downloaded_bytes()
				body_size = _request.get_body_size()
				await get_tree().create_timer(0.1).timeout
				if _await.error_message: return
				_await.update.emit(downloaded_bytes, body_size)
			await get_tree().create_timer(1.0).timeout
			_await.complete.emit(true)
			_request_nodes[url].queue_free()
			_request_nodes.erase(url)
		).call()
	).call()

	return _await

class AwaitSignal:
	signal complete(success: bool)
	signal update(downloaded_bytes: int, body_size: int)
	var error_message: String
