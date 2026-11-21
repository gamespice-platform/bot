@tool
extends EditorPlugin

## Editor entry point for gs-bot.
##
## It registers nothing. Everything here is a [RefCounted] a game builds in code, or a
## [Resource] ([GSBotProfile]) that Godot already offers by its [code]class_name[/code]. It
## exists so the addon can be enabled and disabled like the others.


func _enter_tree() -> void:
	pass


func _exit_tree() -> void:
	pass
