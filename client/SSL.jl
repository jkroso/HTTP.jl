@use "github.com/jkroso/URI.jl" URI
@use Sockets: connect
@use MbedTLS

connect(uri::URI{:https}) = begin
  conf = MbedTLS.SSLConfig()
  MbedTLS.config_defaults!(conf)
  rng = MbedTLS.CtrDrbg()
  MbedTLS.seed!(rng, MbedTLS.Entropy())
  MbedTLS.rng!(conf, rng)
  MbedTLS.authmode!(conf, MbedTLS.MBEDTLS_SSL_VERIFY_REQUIRED)
  MbedTLS.dbg!(conf, function(level, filename, number, msg)
    warn("MbedTLS emitted debug info: $msg in $filename:$number")
  end)
  MbedTLS.ca_chain!(conf)
  sock = MbedTLS.SSLContext()
  MbedTLS.setup!(sock, conf)
  MbedTLS.set_bio!(sock, connect(uri.host, uri.port))
  MbedTLS.hostname!(sock, uri.host)
  MbedTLS.handshake(sock)
  SSLBuffer(sock)
end

"The job of the SSLBuffer is really just to make SSL sockets easy to use"
mutable struct SSLBuffer <: IO
  sock::MbedTLS.SSLContext
  buffer::Vector{UInt8}
  i::Int
end

SSLBuffer(sock) = SSLBuffer(sock, UInt8[], 0)

Base.write(io::SSLBuffer, b::UInt8) = write(io.sock, b)
Base.read(io::SSLBuffer, ::Type{UInt8}) = begin
  if io.i < length(io.buffer)
    io.buffer[io.i+=1]
  else
    io.buffer = readavailable(io.sock)
    if isempty(io.buffer)
      io.buffer = read(io.buffer, 1)
    end
    io.i = 1
    io.buffer[1]
  end
end

Base.readavailable(io::SSLBuffer) = begin
  if io.i < length(io.buffer)
    bytes = @view io.buffer[io.i+1:end]
    io.i = length(io.buffer)
    bytes
  else
    readavailable(io.sock)
  end
end

Base.read(io::SSLBuffer, n::Integer) = begin
  rem = length(io.buffer) - io.i
  if rem >= n
    bytes = @view io.buffer[io.i+1:io.i+n]
    io.i += n
    bytes
  else
    out = IOBuffer(maxsize=n)
    len = length(io.buffer)
    n -= write(out, @view io.buffer[io.i+1:len])
    io.i = len
    while n > 0
      n -= write(out, read(io.sock, n))
    end
    take!(out)
  end
end

Base.isopen(io::SSLBuffer) = isopen(io.sock)
Base.close(io::SSLBuffer) = close(io.sock)
Base.eof(io::SSLBuffer) = io.i == length(io.buffer) && eof(io.sock)
Base.bytesavailable(io::SSLBuffer) = begin
  if io.i < length(io.buffer)
    length(io.buffer) - io.i
  else
    bytesavailable(io.sock)
  end
end
