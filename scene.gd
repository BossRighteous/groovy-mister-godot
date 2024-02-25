extends Node

var frame_count: int = 0;

# Called when the node enters the scene tree for the first time.
func _ready():
	pass

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _physics_process(_delta):
	frame_count = frame_count+1
	%Label.text = "Frame " + ("%010d" % frame_count) + " "
