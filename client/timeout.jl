@use "github.com/jkroso/URI.jl" URI
@use "github.com/jkroso/Prospects.jl" @def
@use Reseau: TLS, TCP, HostResolvers

"""
The time budget of one request, in seconds; 0 disables each part.

- `connect`: DNS lookup + TCP connect + TLS handshake
- `read`: the longest the server may go without sending (or accepting) a byte
- `total`: the whole request, redirects and body included. `deadline` is that
  budget as an absolute `time_ns()`, fixed when the request starts.
"""
@def struct Timeouts
  connect::Float64=0
  read::Float64=0
  total::Float64=0
  deadline::Int64=0
end

Timeouts(connect::Real, read::Real, total::Real) =
  Timeouts(Float64(connect), Float64(read), Float64(total), total > 0 ? now_ns() + ns(total) : Int64(0))

Base.isempty(t::Timeouts) = t.connect <= 0 && t.read <= 0 && t.total <= 0

now_ns() = Int64(time_ns())
ns(seconds::Real) = round(Int64, seconds * 1e9)
min_nonzero(a, b) = a == 0 ? b : b == 0 ? a : min(a, b)

"Nanoseconds the connect phase may take, or 0 for no limit"
connect_budget(t::Timeouts) =
  min_nonzero(t.connect > 0 ? ns(t.connect) : 0, t.deadline > 0 ? max(1, t.deadline - now_ns()) : 0)

"""
Raised when a request runs out of time. `phase` is `:connect` (DNS, TCP or TLS
handshake), `:read` (the server went quiet for `readtimeout` seconds) or
`:request` (the overall `timeout` ran out).
"""
struct TimeoutError <: Exception
  phase::Symbol
  seconds::Float64
  uri::String
end

TimeoutError(phase::Symbol, seconds::Real, uri::URI) = TimeoutError(phase, Float64(seconds), redact(uri))

Base.showerror(io::IO, e::TimeoutError) =
  print(io, "HTTP ", e.phase, " timed out after ", round(e.seconds, digits=3), "s: ", e.uri)

"A URI fit for logs: no userinfo, and the query (which often holds keys) elided"
redact(u::URI) = begin
  port = u.port == 0 || (u.protocol == :http && u.port == 80) || (u.protocol == :https && u.port == 443) ? "" : ":$(u.port)"
  path = string(u.path)
  string(u.protocol, "://", u.host, port, isempty(path) ? "/" : path, isempty(u.query) ? "" : "?…")
end

"Is `e` a Reseau deadline expiring, however deeply it's wrapped?"
istimeout(::TCP.DeadlineExceededError) = true
istimeout(::HostResolvers.DialTimeoutError) = true
istimeout(::TLS.TLSHandshakeTimeoutError) = true
istimeout(e::HostResolvers.OpError) = istimeout(e.err)
istimeout(e::TLS.TLSError) = e.message == "i/o timeout" || (e.cause isa Exception && istimeout(e.cause))
istimeout(::Any) = false

"A peer that closed without a TLS close_notify; for a close-delimited body that is just the end"
unexpected_eof(e::TLS.TLSError) = e.message == "unexpected EOF"
unexpected_eof(::EOFError) = true
unexpected_eof(::Any) = false

const Conn = Union{TCP.Conn,TLS.Conn}

tcp(io::TCP.Conn) = io
tcp(io::TLS.Conn) = io.tcp

# Setting a deadline on a socket that's already closed is moot, and failing
# here would mask the error the next read or write reports properly.
set_read_deadline!(io::Conn, at) = try TCP.set_read_deadline!(tcp(io), at) catch; isopen(io) && rethrow() end
set_write_deadline!(io::Conn, at) = try TCP.set_write_deadline!(tcp(io), at) catch; isopen(io) && rethrow() end
set_deadlines!(io::Conn, r, w) = (set_read_deadline!(io, r); set_write_deadline!(io, w))

"""
Wraps a socket so every read and write is bounded by a request's `Timeouts`.
Reseau deadlines are absolute, so the idle (`read`) deadline is pushed forward
before each operation; to keep that cheap it's only re-armed once an eighth of
the window has passed, which makes the effective idle limit 7/8–1× `read`.
"""
mutable struct TimedIO{T<:IO} <: IO
  io::T
  timeouts::Timeouts
  uri::URI
  read_at::Int64
  write_at::Int64
end

"""
Wrap `io` in a `TimedIO` if there is a read or overall timeout to enforce.
Otherwise return it unwrapped, clearing any deadline a previous request on the
same (keep-alive) socket left behind.
"""
timed(io::TimedIO, t::Timeouts, uri::URI) = timed(io.io, t, uri)
timed(io::Conn, t::Timeouts, uri::URI) = begin
  t.read <= 0 && t.deadline == 0 && (set_deadlines!(io, 0, 0); return io)
  TimedIO(io, t, uri, Int64(0), Int64(0))
end
timed(io::IO, ::Timeouts, ::URI) = io

deadline_at(t::Timeouts, now) = min_nonzero(t.read > 0 ? now + ns(t.read) : Int64(0), t.deadline)
slack(t::Timeouts) = t.read > 0 ? ns(t.read) ÷ 8 : typemax(Int64)

arm_read!(t::TimedIO) = begin
  now = now_ns()
  t.read_at != 0 && now - t.read_at < slack(t.timeouts) && return
  t.read_at = now
  set_read_deadline!(t.io, deadline_at(t.timeouts, now))
end

arm_write!(t::TimedIO) = begin
  now = now_ns()
  t.write_at != 0 && now - t.write_at < slack(t.timeouts) && return
  t.write_at = now
  set_write_deadline!(t.io, deadline_at(t.timeouts, now))
end

"Run `f`, turning a Reseau deadline into a `TimeoutError` that says which limit ran out"
guard(f, t::TimedIO) = try
  f()
catch e
  istimeout(e) || rethrow()
  (; deadline, total, read) = t.timeouts
  throw(deadline != 0 && now_ns() >= deadline - 1_000_000 ?
        TimeoutError(:request, total, t.uri) :
        TimeoutError(:read, read, t.uri))
end

"""
Read at least one byte into `buf` (at most `length(buf)`), blocking until some
arrive. Returns 0 at end of stream.
"""
readsome!(t::TimedIO, buf) = (arm_read!(t); guard(() -> readsome!(t.io, buf), t))
readsome!(io::Conn, buf) = try
  readbytes!(io, buf, length(buf); all=false)
catch e
  unexpected_eof(e) ? 0 : rethrow()
end
readsome!(io::IO, buf) = begin
  eof(io) && return 0
  bytes = read(io, clamp(bytesavailable(io), 1, length(buf)))
  copyto!(buf, 1, bytes, 1, length(bytes))
  length(bytes)
end

readsome(io::IO, n::Integer) = (buf = Vector{UInt8}(undef, n); resize!(buf, readsome!(io, buf)))

"Read until the peer closes the stream"
readall(io::IO) = begin
  out = UInt8[]
  buf = Vector{UInt8}(undef, 65536)
  while (n = readsome!(io, buf)) > 0
    append!(out, @view buf[1:n])
  end
  out
end

Base.read(t::TimedIO, ::Type{UInt8}) = (arm_read!(t); guard(() -> read(t.io, UInt8), t))
Base.read(t::TimedIO) = readall(t)
Base.read(t::TimedIO, n::Integer) = begin
  buf = Vector{UInt8}(undef, n)
  off = 0
  while off < n
    k = readsome!(t, view(buf, off+1:n))
    k == 0 && break
    off += k
  end
  resize!(buf, off)
end
Base.unsafe_read(t::TimedIO, p::Ptr{UInt8}, n::UInt) = begin
  buf = unsafe_wrap(Array, p, n)
  off = 0
  while off < n
    k = readsome!(t, view(buf, off+1:Int(n)))
    k == 0 && throw(EOFError())
    off += k
  end
  nothing
end
Base.readbytes!(t::TimedIO, buf::AbstractVector{UInt8}, nb::Integer=length(buf); all::Bool=true) = begin
  nb > length(buf) && resize!(buf, nb)
  off = 0
  while off < nb
    k = readsome!(t, view(buf, off+1:Int(nb)))
    k == 0 && break
    off += k
    all || break
  end
  off
end
Base.readavailable(t::TimedIO) = readsome(t, 65536)
Base.eof(t::TimedIO) = (arm_read!(t); guard(t) do
  try eof(t.io) catch e; unexpected_eof(e) ? true : rethrow() end
end)

Base.write(t::TimedIO, b::UInt8) = (arm_write!(t); guard(() -> write(t.io, b), t))
Base.unsafe_write(t::TimedIO, p::Ptr{UInt8}, n::UInt) = begin
  off = UInt(0)
  while off < n
    k = min(n - off, UInt(65536))
    arm_write!(t)
    guard(() -> unsafe_write(t.io, p + off, k), t)
    off += k
  end
  Int(n)
end

Base.flush(t::TimedIO) = flush(t.io)
Base.close(t::TimedIO) = close(t.io)
Base.isopen(t::TimedIO) = isopen(t.io)
Base.isreadable(t::TimedIO) = isreadable(t.io)
Base.iswritable(t::TimedIO) = iswritable(t.io)
