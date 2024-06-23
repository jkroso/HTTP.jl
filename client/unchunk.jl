@use "github.com/jkroso/Buffer.jl" Buffer AbstractBuffer ["ReadBuffer" AbstractReadBuffer pull]
@use "github.com/jkroso/Prospects.jl" @mutable
@use "github.com/jkroso/Promises.jl" Future
@use "../Header.jl" Header parse_header

const CRLF = b"\r\n"

@mutable struct Unchunker <: AbstractReadBuffer
  trailers::Future{Header}=Future{Header}()
  open::Bool=true
  nextchunk::Int=0
end

Unchunker(io::IO) = Unchunker(io=io, nextchunk=parse(Int, readline(io), base=16))

pull(io::Unchunker) = begin
  bytes = read(io.io, io.nextchunk)
  @assert length(bytes) == io.nextchunk
  @assert read(io.io, 2) == CRLF
  io.nextchunk = parse(Int, readline(io.io), base=16)
  if io.nextchunk == 0
    put!(io.trailers, parse_header(io.io))
  end
  bytes
end

Base.eof(io::Unchunker) = io.nextchunk == 0 && bytesavailable(io) == 0
