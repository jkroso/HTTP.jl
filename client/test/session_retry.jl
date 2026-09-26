# Unit tests for keep-alive reconnect classification (no network).
# Run: julia --project=. client/test/session_retry.jl
using Test
@use "../Session.jl" because_closed reconnect! Session

@testset "because_closed: OS errors" begin
  @test because_closed(Base.IOError("stream is closed or unusable", -Libc.EPIPE))
  @test because_closed(Base.IOError("connection reset", -Libc.ECONNRESET))
  @test because_closed(Base.IOError("legacy EPIPE", -32))
  @test because_closed(Base.SystemError("read", Libc.ECONNRESET))
  @test because_closed(Base.SystemError("write", Libc.EPIPE))
  @test because_closed(EOFError())
  # Status-line parse on empty buffer after peer closed
  @test because_closed(BoundsError("HTTP/1.1", 10:12))
  # Real application errors must not look closed
  @test !because_closed(ErrorException("invalid API key"))
  @test !because_closed(ArgumentError("bad payload"))
end

@testset "because_closed: nested / TLS-style messages" begin
  # Mimic Reseau TLSError showerror: "tls peek failed: unexpected TLS failure [SystemError: …]"
  inner = Base.SystemError("read", Libc.ECONNRESET)
  # Wrapper that embeds cause like TLSError
  struct FakeTLSError <: Exception
    op::String
    message::String
    cause::Exception
  end
  Base.showerror(io::IO, e::FakeTLSError) =
    print(io, "tls ", e.op, " failed: ", e.message, " [", sprint(showerror, e.cause), "]")

  e = FakeTLSError("peek", "unexpected TLS failure", inner)
  @test because_closed(e)

  # Message-only path (no usable cause field of Exception type for nested walk)
  @test because_closed(ErrorException(
    "tls peek failed: unexpected TLS failure [SystemError: read: Connection reset by peer]"))
  @test because_closed(ErrorException("tls read failed: connection is closed"))
  @test !because_closed(ErrorException("HTTP 429 rate limited"))
end

@testset "because_closed: cause chain" begin
  struct Caused <: Exception
    cause::Exception
  end
  Base.showerror(io::IO, e::Caused) = print(io, "caused: ", sprint(showerror, e.cause))
  @test because_closed(Caused(Base.IOError("broken pipe", -Libc.EPIPE)))
  @test !because_closed(Caused(ErrorException("nope")))
end

println("session_retry tests OK")
