module WaylandCore

export WlVersion, WlInt, WlUInt, WlFixed, WlString, WlID, WlArray, WlFD, WlMsgType, TypeofWlMsgType

import Sockets, Base.read, Base.write
using FixedPointNumbers

# Utility functions
"""
    typewrap(u)

Get a Type Union that matches all types in u.
"""
typewrap(u) = u isa Union ? Union{Type{u.a}, typewrap(u.b)} : Type{u}

# Native Wayland types
# Abstract types:
"""
	WlObjID

Describes a WlID argument which represents an existing object.
"""
abstract type WlObjID end
"""
	WlNewID

Describes a WlID argument which will represent a new object.
"""
abstract type WlNewID end

# Opaque types
const WlFD = RawFD

# Primitives:
const WlInt = Int32
const WlUInt = UInt32
"""
	WlID

The actual ID type, corresponding to "object" and "new_id" protocol types.
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
const WlByteArray = WlArray{UInt8}
struct WlString
	length::WlInt
	content::Vector{Cchar} # the content of the string including NUL terminator and padding to 32-bit boundary
end

# Meta types
const WlVersion = Int
"""
	AbstractWlMsgType

Represents any message argument's semantic type.
"""
const AbstractWlMsgType = Union{WlInt, WlUInt, WlFixed, WlString, WlNewID, WlObjID, WlArray, WlFD}
"""
	WlMsgType

Represents any message argument's concrete type.
"""
const WlMsgType = Union{WlInt, WlUInt, WlFixed, WlString, WlID, WlArray, WlFD} # message argument types
"""
    TypeofWlMsgType

The type that matches all (and only) types in WlMsgType
"""
const TypeofWlMsgType = typewrap(WlMsgType)
"""
    TypeofAbstractWlMsgType

The type that matches all (and only) types in AbstractWlMsgType
"""
const TypeofAbstractWlMsgType = typewrap(AbstractWlMsgType)

# Core type methods
"""
    read(io::IO, ::Type{WlByteArray})

Read a WlByteArray.
"""
function read(io::IO, ::Type{WlByteArray})
	size = read(io, UInt32)
	if size == 0
		return WlByteArray(size, [])
	end
	vec = Vector{UInt8}()
	for i in 1:size
		push!(vec, read(io, UInt8))
	end
	WlByteArray(size, vec)
end
"""
    read(io::IO, ::WlArray)

Read a WlArray of type T.
"""
function read(io::IO, ::WlArray{T}) where T
	size = read(io, UInt32)
	if size == 0
		WlArray(size, [])
	else
		vec = Vector{T}()
		tsize = sizeof(T)
		for i in tsize:tsize:size
			push!(vec, read(io, UInt8))
		end
		WlArray(size, vec)
	end
end

# Library core types
"""
	WaylandMessage

Supertype for all messages.
"""
abstract type WaylandMessage end
"""
	LookupTable

An interface for looking up argument types. Contains a vector of message argument types in the order they should be received in. Anything implementing it should at least define getindex(x, id::UInt32, opcode::UInt16).
"""
abstract type LookupTable end
#="""
	(::Type{<: WaylandMessage})(from::WlID, size::UInt16, opcode::UInt16)

Constructor with an empty payload for any message, which can accept `nothing` as payload.
"""
(type::Type{<: WaylandMessage})(from::WlID, size::UInt16, opcode::UInt16) = type(from, size, opcode, nothing)=#
"""
	GenericMessage

A generic, low-level message. Directly corresponds to the wayland wire format spec, using IOBuffer as storage. Inner constructor enforces padding to 32-bit word boundary.
"""
struct GenericMessage <: WaylandMessage
	from::WlID
	size::UInt16 # Overall (including the `from, size, opcode` header) message size in bytes. This means that a message without any payload has the size of 8. (4 bytes, 2 bytes, 2 bytes)
	opcode::UInt16 # Request/event opcode
	payload::Union{IOBuffer, Nothing} # Aligned to 32-bit words payload.
	GenericMessage(from::WlID, size::UInt16, opcode::UInt16, n::Nothing) = new(from, size, opcode, n)
	function GenericMessage(from::WlID, size::UInt16, opcode::UInt16, buf::IOBuffer)
		over_boundary = bytesavailable(buf) % 4
		if over_boundary == 0
			new(from, size, opcode, buf)
		elseif over_boundary == 1
			write(buf, 0x000000)
			new(from, size, opcode, buf)
		elseif over_boundary == 2
			write(buf, 0x0000)
			new(from, size, opcode, buf)
		elseif over_boundary == 3
			write(buf, 0x00)
			new(from, size, opcode, buf)
		end
	end
end
GenericMessage(from::WlID, size::UInt16, opcode::UInt16) = GenericMessage(from, size, opcode, nothing)
function GenericMessage(from::WlID, size::UInt16, opcode::UInt16, iterable)
	buf = IOBuffer()
	for value in iterable
		write(buf, value)
	end
	GenericMessage(from, size, opcode, buf)
end
function GenericMessage(msg::WaylandMessage)
	GenericMessage(msg.from, msg.size, msg.opcode, msg.payload)
end
"""
	VectorMessage

A generic, low-level message. Uses Vector{WlMsgType} to store arguments.
"""
struct VectorMessage <: WaylandMessage
	from::WlID
	size::UInt16 # Overall (including the `from, size, opcode` header) message size in bytes. This means that a message without any payload has the size of 8. (4 bytes, 2 bytes, 2 bytes)
	opcode::UInt16 # Request/event opcode
	payload::Union{Vector{WlMsgType}, Nothing} # Stored arguments. Need to be aligned to 32-bit word boundary by write()
end
VectorMessage(from::WlID, size::UInt16, opcode::UInt16) = VectorMessage(from, size, opcode, nothing)
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

# Core library-side functions.
# Binary I/O methods:
"""
    write(io::IO, msg::WaylandMessage)

Write any `WaylandMessage` to the io. This requires a `GenericMessage(msg)` compatible constructor to exist.
"""
function write(io::IO, msg::WaylandMessage)
	write(io, GenericMessage(msg))
end
"""
	write(io::IO, msg::GenericMessage)

Write a `GenericMessage` to the io.
"""
function write(io::IO, msg::GenericMessage)
	if msg.payload == nothing
		write(io, msg.from, msg.size, msg.opcode)
	else
		write(io, msg.from, msg.size, msg.opcode, msg.payload)
	end
end
"""
    read(io::IO, ::Type{GenericMessage})

Read a `GenericMessage`.
"""
function read(io::IO, ::Type{GenericMessage})
	from = read(io, WlID)
	size = read(io, UInt16)
	opcode = read(io, UInt16)
	if size == 8
		payload = nothing
	elseif size > 8
		payload = IOBuffer()
		remaining = size - 8
		while remaining > 0
			write(payload, read(io, UInt8))
			remaining -= 1
		end
	else
		error("Wrong size when reading a message!")
	end
	GenericMessage(from, size, opcode, payload)
end
"""
	read(io::IO, ::Type{VectorMessage}, lookup::Dict{UInt32, Dict{UInt16, AbstractVector{DataType}}})

Read a `VectorMessage` using a lookup table mapping object IDs to `opcode=>typevec` dictionaries.
"""
function read(io::IO, ::Type{VectorMessage}, lookup::LookupTable)
	from = read(io, UInt32)
	size = read(io, UInt16)
	@assert size % 4 == 0 "Wrong message size! Not multiple of 4."
	opcode = read(io, UInt16)
	pulled_bytes = 8
	payload = Vector{WlMsgType}()
	types = lookup[from, opcode]
	for type in types
		if size - pulled_bytes <= 0
			# If this gets executed, we're about to try reading something that exceeds message size.
			error("Wrong type vector, exceeded message size!")
		end
		arg = read(io, type)
		push!(payload, arg)
		if type isa WlString
			pulled_bytes += bytesize(arg)
		elseif type isa WlArray
			pulled_bytes += bytesize(arg)
		else
			pulled_bytes += sizeof(type)
		end
	end
	VectorMessage(from, size, opcode, payload)
end
# Connection and I/O
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
    send(io::IO, msg::WaylandMessage)

Send a message to a connection.
"""
function send(io::IO, msg::WaylandMessage)
	write(io, msg)
end
"""
    receive(io::IO, type::DataType)

Receive a message of type `type` from a connection.
"""
function receive(io::IO, type::Type{<: WaylandMessage})
	read(io, type)
end

end # module
