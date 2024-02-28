# Groovy MiSTer Godot

This is an attempt at a GroovyMiSTer client for Godot. The GroovyMiSTer core
allows broadcast and sync of images and sound on analog monitors.

Issues
- The IP is hardcoded among other vars at the moment
- There is an alt routine to tie blit to the process/physics_process or a thread
- Threaded mode is wildly unoptimized in an attempt to reduce tearing with ASAP blit

- The color channels are RGB, where they should be BRG. Should be fixable with a shader


## Stoppers
I cannot figure out how to get the UDP send times in the blit consistent. \
They frequently exceed the vsync time and lead to tearing even while threaded ASAP

Regardless of threading it seems the PacketPeer works at the mercy of other processes


Feel free to play with this and let me know if you find a fix!
