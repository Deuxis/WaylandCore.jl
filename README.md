# WaylandCore.jl
Core Wayland shared between client- and server-side functionality for Julia - connecting, passing messages, message-level types.

Horribly broken because it cannot send/receive FDs. For the meanwhile I've switched to a libwayland-client wrapper for the core functionality, but I will probably return to this.
