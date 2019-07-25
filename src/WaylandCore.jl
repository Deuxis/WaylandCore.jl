"""
	WaylandCore

Provides basic Wayland functionality shared between client- and server-side. Connecting, passing messages, message-level types.
"""
module WaylandCore

export WlVersion, WlInt, WlUInt, WlFixed, WlString, WlID, WlNewID, WlObjID, WlArray, WlFD, WlMsgType, TypeofWlMsgType

import Sockets, Base.read, Base.write
using FixedPointNumbers

# Utility
"""
    typewrap(u)

Get a Type Union that matches all types in `u`.
"""
typewrap(u) = u isa Union ? Union{Type{u.a}, typewrap(u.b)} : Type{u}

const ByteBuffer = Vector{UInt8}

# Native Wayland types
# Opaque types
"""
	WlFD

A file descriptor, corresponds to "fd" wayland protocol type.
"""
const WlFD = RawFD

# Primitives:
"""
	WlUInt

Generic wayland message 32-bit word. Corresponds to "uint" wayland protocol type.
"""
const WlUInt = UInt32
"""
	WlInt

The "int" wayland message argument type.
"""
const WlInt = Int32
"""
	WlID

Either [`WlObjID`](@ref) or [`WlNewID`](@ref) type, as their differences are purely semantic.
"""
const WlID = WlUInt
"""
	WlObjID

Describes a [`WlID`](@ref) argument which represents an existing object. (The "object" wayland protocol type.)
"""
const WlObjID = WlID
"""
	WlNewID

Describes a [`WlID`](@ref) argument which will represent a new object. (The "new_id" wayland protocol type.)
"""
const WlNewID = WlID
"""
    WlFixed

24.8 signed fixed-point number based on Int32
1 sign bit, 23 bits integer prexision, 8 bits decimal precision
Corresponds to "fixed" wayland protocol type.

See also: [`Fixed`](@ref)
"""
const WlFixed = Fixed{Int32,8}

# Transparent types:
"""
	WlArray{T}

Direct representation of the "array" wayland protocol type.
"""
struct WlArray{T}
	size::WlUInt # size of (only, excluding the size) content in bytes
	content::Vector{T} # the content including padding to 32-bit boundary
end
"""
	WlByteArray

A [`WlArray`](@ref) containing generic bytes.
"""
const WlByteArray = WlArray{UInt8}
"""
	WlString

Direct representation of the "string" wayland protocol type.
"""
struct WlString
	length::WlUInt
	content::Vector{Cchar} # the content of the string including NUL terminator and padding to 32-bit boundary
end

# Meta types
"""
	WlVersion

The type used to denote interfaces' and their members' versions.
"""
const WlVersion = Int
"""
	WlMsgType

Represents any message argument type.
"""
const WlMsgType = Union{WlInt, WlUInt, WlFixed, WlString, WlNewID, WlObjID, WlArray, WlFD}
"""
    TypeofWlMsgType

The type that matches all (and only) types in WlMsgType
"""
const TypeofWlMsgType = typewrap(WlMsgType)
"""
	WaylandConnection

A connection that is able to receive all Wayland messages. Currently only a Unix domain socket.
"""
const WaylandConnection = Sockets.PipeEndpoint

# sendmsg- & recvmsg-based message passing:
const Csocklen_t = Cint
const default_outer_flags = 0
const default_inner_flags = 0
"""
	Ciovec

Corresponds to `struct iovec` from `uio.h`.
"""
struct Ciovec
	iov_base::ByteBuffer # Gets passed as a pointer to the buffer.
	iov_len::Csize_t # Byte length of `iov_base`.
end
"Constructor from a DenseVector{UInt8}, which knows its length"
Ciovec(vec::DenseVector{UInt8}) = Ciovec(vec, length(vec))
"""
	Cmsghdr

Corresponds to `struct msghdr` from `socket.h`.
"""
struct Cmsghdr
	msg_name::Ref{Cvoid} # The socket name if given socket is not connected. Never used, will be `C_NULL`
	msg_namelen::Csocklen_t # Length of `msg_name`. Never used, will be `0`
	msg_iov::DenseVector{Ciovec} # Vector of `Ciovec`s, which each represent a normal data buffer.
	msg_iovlen::Csize_t # Count of msg_iov elements.
	msg_control::ByteBuffer # Buffer for control messages
	msg_controllen::Csize_t # Byte length of msg_control
	msg_flags::Cint # Flags of the returned message
end
"Constructor without socket name and with optional flags."
function Cmsghdr(iov::DenseVector{Ciovec}, iovlen::Csize_t, control::DenseVector{UInt8}, controllen::Csize_t, flags::Cint = default_inner_flags)
	Cmsghdr(C_NULL, 0, iov, iovlen, control, controllen, flags)
end
"Constructor from `DenseVector`s, which know their length."
function Cmsghdr(iov::DenseVector{Ciovec}, control::DenseVector{UInt8}, flags::Cint = default_inner_flags)
	Cmsghdr(iov, length(iov), control, length(control), flags)
end

"""
    send(io::WaylandConnection, msg::Cmsghdr, flags::Cint = default_outer_flags)

The lowest level message sending mechanism, thin wrapper around `sendmsg` syscall.
"""
function send(io::WaylandConnection, msg::Cmsghdr, flags::Cint = default_outer_flags)
	ret = ccall(:sendmsg, Cssize_t,
	(RawFD, Ref{Cmsghdr}, Cint),
	fd(io), Ref(msg), flags)
	if ret == -1
		error("An error occured.") # TODO: what error?
	end
end
"""
    receive(io::WaylandConnection, msg::Cmsghdr, flags::Cint = default_outer_flags)

The lowest level message receiving mechanism, thin wrapper around `recvmsg` syscall.
"""
function receive(io::WaylandConnection, msg::Cmsghdr, flags::Cint = default_outer_flags)
	ret = ccall(:recvmsg, Cssize_t,
	(RawFD, Ref{Cmsghdr}, Cint),
	fd(io), Ref(msg), flags)
	if ret == 0
		# Server has shut down.
	elseif ret == -1
		error("An error occured.") # TODO: what error?
	end
	return ret
end

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
function read(io::IO, ::Type{WlArray{T}}) where T
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
"""
    read(io::IO, ::Type{WlString})

Read a WlString.
"""
function read(io::IO, ::Type{WlString})
	length = read(io, WlUInt)
	contents = Array{Cchar}()
	for i in 1:length - 1 # length includes the terminating NUL, which we don't care about
		push!(contents, read(io, Cchar))
	end
	# Pull the terminating NUL and assert it's actually NUL
	@assert read(io, UInt8) == 0 "Last byte of string not actually NUL!"
	# Now pull the padding
	for i in 1:length % 4
		read(io, UInt8) # We don't care about padding contents, they are undefined anyway, we just want them out of the stream.
	end
end

# Library core types
"""
	WaylandMessage

Supertype for all messages.
"""
abstract type WaylandMessage end
"""
	BufferedMessage

Medium level, between high level messages and low level wrapped syscalls.
"""
struct BufferedMessage <: WaylandMessage
	from::UInt32
	opcode::UInt16
	size::UInt16
	payload::ByteBuffer
	ancillary::ByteBuffer
end
function receive(io::WaylandConnection, ::Type{BufferedMessage})
	body
end
"""
	LookupTable

An interface for looking up argument types. Contains a vector of message argument types in the order they should be received in. Anything implementing it should at least define getindex(x, id::UInt32, opcode::UInt16).
"""
abstract type LookupTable end
#= GenericMessage seems to not be compatible with passing FDs.
"""
	(::Type{<: WaylandMessage})(from::WlID, size::UInt16, opcode::UInt16)

Constructor with an empty payload for any message, which can accept `nothing` as payload.
"""
(type::Type{<: WaylandMessage})(from::WlID, size::UInt16, opcode::UInt16) = type(from, size, opcode, nothing)
"""
	GenericMessage

A generic, low-level message. Directly corresponds to the wayland wire format spec, using IOBuffer as storage. Inner constructor enforces padding to 32-bit word boundary.

**Do not** use for messages including file descriptors as they are passed with special calls on the socket and will be lost and introduce binary corruption if processed as just data.
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
"""
	GenericMessage(from::WlID, size::UInt16, opcode::UInt16)

Constructor for messages with no payload.
"""
GenericMessage(from::WlID, size::UInt16, opcode::UInt16) = GenericMessage(from, size, opcode, nothing)
"""
	GenericMessage(from::WlID, size::UInt16, opcode::UInt16, iterable)

Constructor using an iterable collection as source of arguments.
"""
function GenericMessage(from::WlID, size::UInt16, opcode::UInt16, iterable)
	buf = IOBuffer()
	for value in iterable
		write(buf, value)
	end
	GenericMessage(from, size, opcode, buf)
end
"""
	GenericMessage(msg::WaylandMessage)

Constructor from any compliant WaylandMessage.
"""
function GenericMessage(msg::WaylandMessage)
	if WlObjID in msg.payload || WlNewID in msg.payload || WlID in msg.payload
		throw(ArgumentError("GenericMessage cannot be used with file descriptors!"))
	end
	GenericMessage(msg.from, msg.size, msg.opcode, msg.payload)
end=#
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

abstract type AbstractQueue end
"""
	GenericQueue

A message queue. This is a parametric queue, that can be specialised to only hold a stricter subset of messages for optimization.
"""
struct GenericQueue{T <: WaylandMessage} <: AbstractQueue
	queue::Vector{T}
end
"""
	MessageQueue

A generic message queue able to hold any messages.
"""
const MessageQueue = GenericQueue{WaylandMessage}

# Core library-side functions.
#= Commented out because they're currently incompatible with passing FDs.
# Message I/O methods:
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

Read a `GenericMessage`. **Do not** use this for messages including file descriptors as they are passed with special calls on the socket and will not be read.
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
end=#
# Connection and I/O
"""
    connect(name::AbstractString)

Connect to the named display. Returns a connection IO stream.
"""
function connect(path::AbstractString)
	path_isabsolute = path[1] == '/'
	runtimedir = get(ENV, "XDG_RUNTIME_DIR", nothing)
	if runtimedir == nothing && !path_isabsolute
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
	Sockets.close(connection)
end

end # module
