extends Control

@onready var _tree : SceneTree = get_tree() if not Engine.is_editor_hint() else Engine.get_main_loop()
@onready var _root : = _tree.root if not Engine.is_editor_hint() else _tree.edited_scene_root
@onready var _label_container := $CenterContainer/VBoxContainer

var _main : Node2D
var _base_url : String = "http://localhost/{os}/{path}.zip".format({ "os": OS.get_name().to_lower() })
var _request_nodes : Dictionary = {}
var _initialize_error : bool = false
var _load_scenes : Array[Dictionary] = [
	{
		"name": "menu",
		"url": _base_url.format({ "path": "menu" })
	},
	{
		"name": "client",
		"url": _base_url.format({ "path": "client" })
	}
]

func _ready():
	_main = Node2D.new()
	_main.name = "Main"
	_main.visible = false
	_root.add_child.call_deferred(_main)
	while not _main.is_node_ready(): await _tree.process_frame

	for load_scene in _load_scenes:
		load_scene_from_url(load_scene.name, load_scene.url)

	await get_tree().create_timer(1.0).timeout
	while not _request_nodes.is_empty(): await _tree.process_frame
	if _initialize_error: # Failed to load some of the scene
		return

	self.hide()
	_main.show()

	var current_scene = _tree.current_scene
	current_scene.queue_free()
	await current_scene.tree_exited
	_tree.current_scene = _main

func load_scene_from_url(_name: String, _url: String) -> AwaitSignal:
	var _await = AwaitSignal.new()
	var _request : HTTPRequest
	if not _url in _request_nodes:
		_request = HTTPRequest.new()
		_request.download_chunk_size = 4096 # 4 KB, cu'z our assets is less than 50mb which will not appropriate the loading screen
		_request.use_threads = true
		add_child.call_deferred(_request)
		while not _request.is_node_ready(): await _tree.process_frame
		_request_nodes[_url] = _request
	else: _request = _request_nodes[_url]

	var regex = RegEx.new()
	regex.compile("^(?>(?<protocol>[a-zA-Z]+)://)?(?<domain>[a-zA-Z0-9.\\-_]*)?(?>:(?<port>\\d{1,5}))?(?<path>[a-zA-Z0-9_\\-/%]+)?/(?<file>[a-zA-Z0-9_\\-.%]+)")
	var url_reg = regex.search(_url)
	var file_dir = "user://temp/{dir}"
	var file_name = ""
	var file_ext = ""
	if url_reg:
		file_dir = file_dir.format({ "dir": url_reg.get_string("path") if not url_reg.get_string("path")[0] == "/" else url_reg.get_string("path").erase(0) })
		file_name = url_reg.get_string("file").get_slice(".", 0)
		file_ext = url_reg.get_string("file").get_slice(".", 1)
	var file_path = "{dir}/{name}.{ext}".format({ "dir": file_dir, "name": file_name, "ext": file_ext })

	if DirAccess.dir_exists_absolute(file_dir): DirAccess.remove_absolute(file_path)
	DirAccess.make_dir_recursive_absolute(file_dir)

	Callable(func():
		var _label = Label.new()
		_label.name = _name
		_label.text = "Loading..."
		_label.add_theme_font_size_override("font_size", 28)
		_label_container.add_child.call_deferred(_label)
		while not _label.is_node_ready(): await _tree.process_frame

		_await.update.connect(func(progress, _downloaded_bytes, _body_size):
			_label.text = "Loading %s %s%%" % [_name, progress]
		)

		_await.complete.connect(func():
			if _await.error_message:
				DirAccess.remove_absolute(file_path)
				_label.text = "Loading %s failed!" % [_name]
				_initialize_error = true
			else:
				ProjectSettings.load_resource_pack(file_path, true)
				var _resource = ResourceLoader.load("res://{scene}.tscn".format({ "scene": _name.to_lower() }), "PackedScene")
				if _resource:
					var _scene_ = _resource.instantiate()
					_scene_.name = _name.to_pascal_case()
					_main.add_child.call_deferred(_scene_)
					while not _scene_.is_node_ready(): await _tree.process_frame

			_request_nodes[_url].queue_free()
			await _request_nodes[_url].tree_exited
			_request_nodes.erase(_url)
		)

		_request.request_completed.connect(func(result: int, response_code: int, _headers: PackedStringArray, _body: PackedByteArray):
			if result != HTTPRequest.RESULT_SUCCESS && response_code != HTTPClient.RESPONSE_OK:
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
				_await.error_message = error_message
		)

		Callable(func():
			await get_tree().create_timer(0.5).timeout
			while _request.get_http_client_status() in [HTTPClient.STATUS_CONNECTING, HTTPClient.STATUS_RESOLVING]: await _tree.process_frame

			var downloaded_bytes = _request.get_downloaded_bytes()
			var body_size = _request.get_body_size()
			var progress = 0

			while downloaded_bytes != body_size:
				if _await.error_message: break
				await _tree.process_frame

				downloaded_bytes = _request.get_downloaded_bytes()
				body_size = _request.get_body_size()
				var _progress = int(round((float(downloaded_bytes) / body_size) * 100))
				if progress != _progress: # only emit update when it's not equal with the new progress
					progress = _progress
					_await.update.emit(progress, downloaded_bytes, body_size)

			if _await.error_message: push_error(_await.error_message)
			_await.complete.emit()
		).call_deferred()

		_await.update.emit(0.0, 0.0, 0.0)
		_request.download_file = file_path
		var error = _request.request(_url)
		if error != OK:
			var error_message = "An error occurred while making the HTTP request: %d." % error
			_await.error_message = error_message
	).call()

	return _await

class AwaitSignal:
	signal complete
	signal update(progress: int, downloaded_bytes: int, body_size: int)
	var error_message: String
