extends Node

var DEBUG_NO_SEND = false
var DEBUG_BLIT_VIA_THREAD = true

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
var fps := 60

var frame: int = 0

const CMD_CLOSE = 1
const CMD_INIT = 2
const CMD_SWITCHRES = 3
const CMD_BLIT = 4
const CMD_GET_STATUS = 5
const CMD_BLIT_VSYNC = 6
const MTU_BLOCK_SIZE = 1470 #1470

var mutex: Mutex
var semaphore: Semaphore
var thread: Thread
var exit_thread := false
var delay_timer := Timer.new()

func _ready():
	add_child(delay_timer)
	if initialize_on_ready:
		call_deferred("initialize")

func initialize():
	_initialize_socket()
	
func start_blit_thread():
	mutex = Mutex.new()
	exit_thread = false
	thread = Thread.new()
	thread.start(_blit_thread)

func _process(_delta):
	#_deferred_sync(_delta)
	pass
	
func _physics_process(_delta):
	if Input.is_action_just_released("ui_accept"):
		exit()
	_deferred_sync(_delta)
	##call_deferred("_deferred_sync", _delta)

func _deferred_sync(_delta):
	var sync_time = Time.get_ticks_usec()
	if is_syncing:
		print("skipping frame, called while processing")
		return
	is_syncing = true
	if socket_is_connected and !DEBUG_BLIT_VIA_THREAD:
		print("_delta:"+str(_delta)+ ":"+str(frame))
		var blit_time = Time.get_ticks_usec()
		_send_blit()
		var blit_total = Time.get_ticks_usec()-blit_time
		print("blit_time:"+str(blit_total)+ ":"+str(frame))
		if blit_total/1000000.0 > _delta:
			print("blit exceeded frame"+str(frame)+" by ms "+str((blit_total/1000.0 - _delta*1000.0)))
		
	var frame_buffer_time = Time.get_ticks_usec()
	_get_frame_buffer()
	print("get_frame_buffer:"+str(Time.get_ticks_usec()-frame_buffer_time)+ ":"+str(frame))
	print("sync_time:"+str(Time.get_ticks_usec()-sync_time)+ ":"+str(frame))
	is_syncing = false

func _get_frame_buffer():
	#var frame_buffer_time = Time.get_ticks_usec()
	var image = sub_viewport.get_texture().get_image()
	image.convert(Image.FORMAT_RGB8)
	frame_buffers.push_back(image.get_data())
	#print(str(Time.get_ticks_usec()-frame_buffer_time)+" frame buffer time")
	is_syncing = false

func _initialize_socket():
	socket = PacketPeerUDP.new()
	# socket.set_blocking_mode(true)
	socket.connect_to_host(MiSTer_ip, MiSTer_port)
	#socketAck.bind(MiSTer_port)
	if socket.is_socket_connected:
		print("socket initialized")
		#delay_timer.start(.5)
		#await delay_timer.timeout
		cmd_init()
		delay_timer.start(.5)
		await delay_timer.timeout
		#delay_timer.start(.5)
		#await delay_timer.timeout
		cmd_switchres()
		delay_timer.start(.5)
		await delay_timer.timeout
		socket_is_connected = true
	else:
		print('Error connecting to GroovyMister, removing GroovyMisterGodot')
		exit()
	if DEBUG_BLIT_VIA_THREAD:
		call_deferred("start_blit_thread")

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
	print("cmd_blit_vsync ran" + str(frame))
	_send_mtu(frame_buffer)
	print("cmd_blit ran" + str(frame))

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
	if socket_is_connected:
		socket.put_packet(buffer)
	

func _put_deferred(buffer:PackedByteArray):
	if socket_is_connected:
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

func _blit_thread():
	var tick_rate_usec: int = floor(1000000.0/(fps))
	print("tick rate "+str(tick_rate_usec))
	var next_tick: int = Time.get_ticks_usec() + tick_rate_usec
	print("next_tick "+str(next_tick))
	# wait for init ack
	#while(socket.get_available_packet_count() == 0):
	#	print("waiting for initial ack")
	#	pass
	#print("got init ack")
	var init_ack = socket.get_packet()
	while !exit_thread:
		var curr_time: int = Time.get_ticks_usec()
		#if curr_time < next_tick or !socket_is_connected:
		if !socket_is_connected:
			continue
		next_tick = curr_time + tick_rate_usec
		#print("next_tick "+str(next_tick))
		
		#var blit_time_no_thread = Time.get_ticks_usec()
		var data: PackedByteArray
		mutex.lock()
		if frame_buffers.size() < 1:
			mutex.unlock()
			print("bouncing")
			continue
		if frame_buffers.size() > 1:
			#print(frame_buffers.size())
			data = frame_buffers[frame_buffers.size()-1]
			frame_buffers.clear()
			frame_buffers.push_front(data)
		else:
			data = frame_buffers[0]
		mutex.unlock()
		#print('ran thread at '+str(curr_time)+" next tick "+str(next_tick))
		#call_deferred("_cmd_blit",data)
		_cmd_blit(data)
		var end_time = Time.get_ticks_usec()
		if end_time - curr_time > tick_rate_usec:
			print("Blit time extended tick by "+str(end_time - curr_time - tick_rate_usec))
		#print(str(Time.get_ticks_usec()-blit_time_no_thread)+" blit_time_no_thread time")
		while(socket.get_available_packet_count() == 0):
			pass
		while(socket.get_available_packet_count() > 0):
			var ack = socket.get_packet()
			print('Got Ack')

func _exit_tree():
	exit()

func exit():
	socket_is_connected = false
	exit_thread = true
	if thread.is_started():
		thread.wait_to_finish()
	if socket and (socket.is_socket_connected() or socket.is_bound()):
		cmd_close()
		socket.close()
	
	queue_free()
