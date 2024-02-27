extends Node

var DEBUG_NO_SEND = false

@export var sub_viewport: SubViewport
@export var initialize_on_ready: bool = true
@export var MiSTer_ip: String = "192.168.0.168"
@export var MiSTer_port: int = 32100
@export var switchres_modeline: String = "4.905 256 264 287 312 240 241 244 262"

var socket_is_connected: bool = false
var socket: PacketPeerUDP

var v_image: Image

var frame_buffers: Array[PackedByteArray] = []
var is_syncing := false

var frame: int = 0

const CMD_CLOSE = 1
const CMD_INIT = 2
const CMD_SWITCHRES = 3
const CMD_BLIT = 4
const CMD_GET_STATUS = 5
const CMD_BLIT_VSYNC = 6
const MTU_BLOCK_SIZE = 1470

func _ready():
	if initialize_on_ready:
		call_deferred("initialize")

func initialize():
	_initialize_socket()
	
func _physics_process(_delta):
	if Input.is_action_just_released("ui_accept"):
		exit()
	if socket_is_connected:
		#call_deferred("_deferred_sync")
		if is_syncing:
			print("skipping frame, called while processing")
			return
		call_deferred("_send_blit")
		call_deferred("_get_frame_buffer")

func _deferred_sync():
	if is_syncing:
		print("skipping frame, called while processing")
		return
	
	var sync_time = Time.get_ticks_usec()
	is_syncing = true
	_send_blit()
	_get_frame_buffer()
	is_syncing = false
	var total_sync_time = Time.get_ticks_usec()-sync_time
	if total_sync_time > 16000:
		print(str(total_sync_time)+" high total sync time")

func _get_frame_buffer():
	#var frame_buffer_time = Time.get_ticks_usec()
	var image = sub_viewport.get_texture().get_image()
	image.convert(Image.FORMAT_RGB8)
	frame_buffers.push_back(image.get_data())
	#print(str(Time.get_ticks_usec()-frame_buffer_time)+" frame buffer time")
	is_syncing = false

func _initialize_socket():
	socket = PacketPeerUDP.new()
	socket.connect_to_host(MiSTer_ip, MiSTer_port)
	if socket.is_socket_connected:
		print("socket initialized")
		cmd_init()
		cmd_switchres()
		socket_is_connected = true
	else:
		print('Error connecting to GroovyMister, removing GroovyMisterGodot')
		exit()

func cmd_close():
	var buffer = PackedByteArray([CMD_CLOSE])
	_socket_send(buffer)
	print("cmd_close ran")

func cmd_init():
	var buffer = PackedByteArray([
		CMD_CLOSE,
		0, # lz4 compression flag
		0, # (sound_rate == 22050) ? 1 : (sound_rate == 44100) ? 2 : (sound_rate == 48000) ? 3 : 0
		0, # sound_chan
	])
	_socket_send(buffer)
	print("cmd_init ran")

func cmd_switchres():
	var parts = switchres_modeline.split(" ")
	if parts.size() < 9:
		print('Error parsing switchres, removing GroovyMisterGodot')
		exit()
	elif int(parts[1]) != sub_viewport.size.x:
		print('Switchres width mismatch on viewport, removing GroovyMisterGodot')
		exit()
		return
	elif int(parts[5]) != sub_viewport.size.y:
		print('Switchres width mismatch on viewport, removing GroovyMisterGodot')
		exit()
		return
	var buffer = PackedByteArray()
	buffer.resize(26)
	buffer.fill(0)
	buffer.set(0, CMD_SWITCHRES)
	buffer.encode_double(1, float(parts[0])) # pixelClock (x.xx)
	buffer.encode_u16(9, int(parts[1])) # hactive / width
	buffer.encode_u16(11, int(parts[2])) # hbegin
	buffer.encode_u16(13, int(parts[3])) # hend
	buffer.encode_u16(15, int(parts[4])) # htotal
	buffer.encode_u16(17, int(parts[5])) # vactive / height
	buffer.encode_u16(19, int(parts[6])) # vbegin
	buffer.encode_u16(21, int(parts[7])) # vend
	buffer.encode_u16(23, int(parts[8])) # vtotal
	buffer.set(25, 0) # interlace
	_socket_send(buffer)
	print("cmd_switchres ran")

func _cmd_blit(frame_buffer: PackedByteArray):
	frame = frame + 1
	var buffer = PackedByteArray()
	buffer.resize(9)
	buffer.set(0, CMD_BLIT_VSYNC)
	buffer.encode_u32(1, frame)
	buffer.encode_u16(5, 0) # vsyncAuto 
	buffer.set(7, 0) # lz4: blockSize & 0xff
	buffer.set(8, 0) # lz4: blockSize >> 8
	_socket_send(buffer)
	#print("cmd_blit_vsync ran")
	_send_mtu(frame_buffer)
	#print("cmd_blit ran")

func _send_mtu(frame_buffer: PackedByteArray):
	var bytes_to_send = frame_buffer.size()
	var chunk_max_size = MTU_BLOCK_SIZE
	var chunk_size: int = 0
	var offset: int = 0
	while bytes_to_send > 0:
		chunk_size = chunk_max_size if bytes_to_send > chunk_max_size else bytes_to_send
		bytes_to_send = bytes_to_send - chunk_size
		_socket_send(frame_buffer.slice(offset, offset+chunk_size))
		offset += chunk_size

func _socket_send(buffer: PackedByteArray, byte_length: int = 0):
	if byte_length == 0:
		byte_length = buffer.size()
	if DEBUG_NO_SEND:
		return
	#call_deferred("_put_deferred",buffer)
	socket.put_packet(buffer)
	

func _put_deferred(buffer:PackedByteArray):
	socket.put_packet(buffer)

func _send_blit():
		#var blit_time_no_thread = Time.get_ticks_usec()
		var data: PackedByteArray
		if frame_buffers.size() < 1:
			return
		if frame_buffers.size() > 1:
			#print(frame_buffers.size())
			data = frame_buffers[frame_buffers.size()-1]
			frame_buffers.clear()
			frame_buffers.push_front(data)
		else:
			data = frame_buffers[0]
		_cmd_blit(data)
		#print(str(Time.get_ticks_usec()-blit_time_no_thread)+" blit_time_no_thread time")

func _exit_tree():
	exit()

func exit():	
	if socket and socket.is_socket_connected():
		cmd_close()
		socket.close()
	
	queue_free()
