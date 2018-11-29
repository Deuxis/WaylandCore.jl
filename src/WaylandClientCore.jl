module WaylandClientCore

export WlVersion, WlInt, WlUInt, WlFixed, WlString, WlID, WlArray, WlFD, WlMsgType, TypeofWlMsgType

import Sockets
using FixedPointNumbers

# Utility functions
"""
    typewrap(u)

Get a Type Union that matches all types in u.
"""
typewrap(u) = u isa Union ? Union{Type{u.a}, typewrap(u.b)} : Type{u}

# Native Wayland types
# Opaque types
abstract type WlFD end

# Primitives:
const WlInt = Int32
const WlUInt = UInt32
"""
	WlID

Corresponds to "object" and "new_id" protocol types.
"""
const WlID = WlUInt # Object ID
"""
    WlFixed

24.8 signed fixed-point number based on Int32
1 sign bit, 23 bits integer prexision, 8 bits decimal precision
"""
const WlFixed = Fixed{Int32,8}

# Transparent types:
struct WlArray{T}
	size::WlInt # size of content in bytes
	content::Vector{T} # the content including padding to 32-bit boundary
end
struct WlString
	length::WlInt
	content::Vector{Cchar} # the content of the string including NUL terminator and padding to 32-bit boundary
end

# Utility types:
const WlVersion = Int
const WlMsgType = Union{WlInt,WlUInt,WlFixed,WlString,WlID,WlArray,WlFD} # message argument types
"""
    TypeofWlMsgType

The type that matches all (and only) types in WlMsgType
"""
const TypeofWlMsgType = typewrap(WlMsgType)

# High-level types
"""
	WaylandMessage

Supertype for all messages.
"""
abstract type WaylandMessage end
"""
	WaylandMessage

Supertype for all messages.
"""
abstract type ObjectMessage{T <: WaylandObject} <: WaylandMessage end
"""
	WaylandQueue

A message queue. This is a parametric queue, that can be specialised to only hold a stricter subset of messages for optimization.
"""
struct WaylandQueue{T <: WaylandMessage}
	queue::Vector{T}
end
"""
	MessageQueue

A generic message queue able to hold any messages.
"""
const MessageQueue = WaylandQueue{WaylandMessage}
"""
	abstract type WaylandObject

Supertype for all Wayland objects, in the Wayland spec meaning - things that implement interfaces and you can exchange messages with them.
"""
abstract type WaylandObject end
"""
	abstract type WaylandDisplay

A display is alobal object representing the connection to the server. A high-level API should subtype this with its Display implementation.
"""
abstract type WaylandDisplay <: WaylandObject end

# Core library-side functions.
"""
    connect(name::AbstractString)

Connect to the named display. Returns a connection IO stream.
"""
function connect(path::AbstractString)
	path_isabsolute = path[1] == '/'
	runtimedir = get(ENV, "XDG_RUNTIME_DIR", false)
	if !path_isabsolute && !runtimedir
		throw(ArgumentError("Cannot connect - XDG_RUNTIME_DIR is unset and non-absolute path was provided!"))
	elseif !path_isabsolute
		path = runtimedir * '/' * path
	end
	Sockets.connect(path)
end
"""
    connect()

Connect to default display, which is named in "WAYLAND_DISPLAY" env variable. If that is missing, connect to the hard default, "wayland-0".
"""
connect() = connect(get(ENV, "WAYLAND_DISPLAY", "wayland-0"))
"""
    disconnect(connection::IO)

Disconnect from a connection.

A high-level API should instead create and use a method for its Display object.
"""
function disconnect(connection::IO)
	close(connection)
end
"""
    send(msg::Message, display::WaylandDisplay)

Sends a message to the display.
"""
function send(io::IO, msg::WaylandMessage)
	push!(display.outqueue, msg)
end
"""
    receive(display::WaylandDisplay)

Receive a messege from a display. (Default queue)
"""
function receive(display::WaylandDisplay)
	popfirst!(display.inqueue)
end

end # module
