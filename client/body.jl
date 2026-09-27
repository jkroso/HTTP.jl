@use "github.com/jkroso/Buffer.jl" ["ReadBuffer" AbstractReadBuffer pull pull!]
@use "github.com/jkroso/Prospects.jl" @def
@use "./timeout.jl" readsome

"""
A response body read straight off the socket as the caller asks for it, so a
large download never has to fit in memory. `remaining` is the number of bytes
still on the wire: the Content-Length counting down, or -1 for a body that runs
until the server closes the connection.

A Content-Length body cut short by the server throws `EOFError` rather than
looking like a clean end, so a download can tell it needs resuming.
"""
@def mutable struct Body <: AbstractReadBuffer
  remaining::Int=-1
end

Body(io::IO, remaining::Integer) = Body(io=io, remaining=remaining)

pull(b::Body) = begin
  b.remaining == 0 && return UInt8[]
  bytes = readsome(b.io, b.remaining < 0 ? 65536 : min(b.remaining, 65536))
  if isempty(bytes)
    b.remaining > 0 && throw(EOFError())
    b.remaining = 0
  elseif b.remaining > 0
    b.remaining -= length(bytes)
  end
  bytes
end

Base.eof(b::Body) = begin
  bytesavailable(b) > 0 && return false
  b.remaining == 0 && return true
  b.remaining > 0 && return false # a truncated body throws on the next read instead
  pull!(b) == 0
end

Base.read(b::Body) = begin
  out = copy(@view b.data[b.i+1:end])
  b.i = length(b.data)
  while !eof(b)
    append!(out, readavailable(b))
  end
  out
end

Base.read(b::Body, ::Type{UInt8}) = begin
  b.i < length(b.data) || pull!(b) > 0 || throw(EOFError())
  @inbounds b.data[b.i+=1]
end

Base.read(b::Body, n::Integer) = begin
  while length(b.data) - b.i < n
    pull!(b) == 0 && break
  end
  k = min(n, length(b.data) - b.i)
  bytes = b.data[b.i+1:b.i+k]
  b.i += k
  bytes
end

Base.unsafe_read(b::Body, p::Ptr{UInt8}, n::UInt) = begin
  bytes = read(b, Int(n))
  length(bytes) < n && throw(EOFError())
  GC.@preserve bytes unsafe_copyto!(p, pointer(bytes), n)
  nothing
end
