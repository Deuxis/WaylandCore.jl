module WaylandCore

using FixedPointNumbers
using Sockets

# Native Wayland types
# Opaque types
abstract type WlFD end
abstract type WlObject end
abstract type WlProxy <: WlObject end

# TEMP aliases for non-opaque, but not yet needed types:
abstract type WlMessage <: WlObject end

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
struct WlInterface <: WlObject
	name::Cstring # Name of the interface
	version::Int # SInterface version
	method_count::Int # Number of methods (requests)
	methods::Ptr{WlMessage} # The array of method signatures
	event_count::Int # Number of events
	events::Ptr{WlMessage} # The array of event signatures
end

# Utility types:
const WlVersion = Int
const WlMsgType = Union{WlInt,WlUInt,WlFixed,WlString,WlID,WlArray,WlFD} # message argument types

# Core functions
"""
    connect(name::AbstractString)

Connect to the named display.
"""
function connect(name::AbstractString)
	body
end
"""
    connect()

Connect to default display, which is named in "WAYLAND_DISPLAY" env variable. If that is missing, connect to the hard default, "wayland-0".
"""
connect() = connect(get(ENV, "WAYLAND_DISPLAY", "wayland-0"))

end # module
