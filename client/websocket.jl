@use "github.com/jkroso/URI.jl" URI encode_query encode
@use "github.com/jkroso/Buffer.jl" ["ReadBuffer.jl" ReadBuffer]
@use "github.com/jkroso/Prospects.jl" assoc @def
@use Sockets: connect
@use MbedTLS
@use SHA: sha1
@use Base64: base64encode

const GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

const CONTINUATION = 0x0
const TEXT         = 0x1
const BINARY       = 0x2
const CLOSE        = 0x8
const PING         = 0x9
const PONG         = 0xA

struct Message
  opcode::UInt8
  data::Vector{UInt8}
end

Base.String(m::Message) = String(copy(m.data))

@def mutable struct WebSocket
  uri::URI
  sock::IO
  closed::Bool=false
end

WebSocket(url::AbstractString) = begin
  uri = parse_ws_uri(url)
  sock = ws_connect(uri)
  upgrade(uri, sock)
end

parse_ws_uri(str::AbstractString) = begin
  uri = URI(str)
  uri.port > 0 && return uri
  assoc(uri, :port, uri.protocol in (:ws, :http) ? 80 : 443)
end

ws_connect(uri::URI) = begin
  if uri.protocol in (:wss, :https)
    conf = MbedTLS.SSLConfig()
    MbedTLS.config_defaults!(conf)
    rng = MbedTLS.CtrDrbg()
    MbedTLS.seed!(rng, MbedTLS.Entropy())
    MbedTLS.rng!(conf, rng)
    MbedTLS.authmode!(conf, MbedTLS.MBEDTLS_SSL_VERIFY_REQUIRED)
    MbedTLS.ca_chain!(conf)
    ctx = MbedTLS.SSLContext()
    MbedTLS.setup!(ctx, conf)
    MbedTLS.set_bio!(ctx, connect(uri.host, uri.port))
    MbedTLS.hostname!(ctx, uri.host)
    MbedTLS.handshake(ctx)
    ReadBuffer(ctx)
  else
    connect(uri.host, uri.port)
  end
end

upgrade(uri::URI, sock::IO) = begin
  key = base64encode(rand(UInt8, 16))
  p = ws_path(uri)
  host = uri.port in (80, 443) ? uri.host : "$(uri.host):$(uri.port)"
  write(sock, "GET $p HTTP/1.1\r\nHost: $host\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: $key\r\nSec-WebSocket-Version: 13\r\n\r\n")

  status = readline(sock)
  @assert occursin("101", status) "WebSocket upgrade failed: $status"

  headers = Dict{String,String}()
  while true
    line = readline(sock)
    isempty(line) && break
    k, v = split(line, ':', limit=2)
    headers[lowercase(strip(k))] = strip(v)
  end

  expected = base64encode(sha1(key * GUID))
  @assert headers["sec-websocket-accept"] == expected "Invalid Sec-WebSocket-Accept"

  WebSocket(uri=uri, sock=sock)
end

ws_path(uri::URI) = begin
  p = encode(string(uri.path))
  isempty(p) && (p = "/")
  q = encode_query(uri.query)
  isempty(q) || (p *= "?" * q)
  p
end

send(ws::WebSocket, data::AbstractString) = write_frame(ws, true, TEXT, Vector{UInt8}(data))
send(ws::WebSocket, data::Vector{UInt8}) = write_frame(ws, true, BINARY, data)
ping(ws::WebSocket, data::Vector{UInt8}=UInt8[]) = write_frame(ws, true, PING, data)
pong(ws::WebSocket, data::Vector{UInt8}=UInt8[]) = write_frame(ws, true, PONG, data)

write_frame(ws::WebSocket, fin::Bool, opcode::UInt8, payload::Vector{UInt8}) = begin
  sock = ws.sock
  write(sock, UInt8((fin ? 0x80 : 0x00) | opcode))
  len = length(payload)
  if len < 126
    write(sock, UInt8(0x80 | len))
  elseif len < 65536
    write(sock, UInt8(0x80 | 126))
    write(sock, hton(UInt16(len)))
  else
    write(sock, UInt8(0x80 | 127))
    write(sock, hton(UInt64(len)))
  end
  mask = rand(UInt8, 4)
  write(sock, mask)
  masked = copy(payload)
  for i in eachindex(masked)
    masked[i] = masked[i] ⊻ mask[((i-1) & 3) + 1]
  end
  write(sock, masked)
  nothing
end

receive(ws::WebSocket) = begin
  fragments = UInt8[]
  opcode = 0x0
  while true
    frame = read_frame(ws)
    if frame.opcode >= 0x8
      handle_control(ws, frame)
      frame.opcode == CLOSE && return Message(CLOSE, frame.payload)
      continue
    end
    if frame.opcode == CONTINUATION
      opcode == 0x0 && (fail(ws); error("unexpected continuation frame"))
      append!(fragments, frame.payload)
    else
      opcode != 0x0 && (fail(ws); error("new data frame during fragmented message"))
      opcode = frame.opcode
      fragments = frame.payload
    end
    if frame.fin
      if opcode == TEXT && !isvalid(String, fragments)
        fail(ws, UInt16(1007))
        error("invalid UTF-8 in text message")
      end
      return Message(opcode, fragments)
    end
  end
end

read_frame(ws::WebSocket) = begin
  b1 = read(ws.sock, UInt8)
  fin = (b1 & 0x80) != 0
  rsv = b1 & 0x70
  opcode = b1 & 0x0F
  rsv != 0 && (fail(ws); error("non-zero RSV bits"))
  opcode ∉ (CONTINUATION, TEXT, BINARY, CLOSE, PING, PONG) && (fail(ws); error("reserved opcode $opcode"))
  opcode >= 0x8 && !fin && (fail(ws); error("fragmented control frame"))

  b2 = read(ws.sock, UInt8)
  masked = (b2 & 0x80) != 0
  len_byte = b2 & 0x7F
  len = if len_byte < 126
    UInt64(len_byte)
  elseif len_byte == 126
    UInt64(ntoh(read(ws.sock, UInt16)))
  else
    ntoh(read(ws.sock, UInt64))
  end
  opcode >= 0x8 && len > 125 && (fail(ws); error("control frame too large"))

  mask_key = masked ? read(ws.sock, 4) : nothing
  payload = len > 0 ? read(ws.sock, Int(len)) : UInt8[]
  if masked
    for i in eachindex(payload)
      payload[i] = payload[i] ⊻ mask_key[((i-1) & 3) + 1]
    end
  end
  (fin=fin, opcode=opcode, payload=payload)
end

handle_control(ws::WebSocket, frame) = begin
  if frame.opcode == PING
    pong(ws, frame.payload)
  elseif frame.opcode == CLOSE && !ws.closed
    payload = frame.payload
    if length(payload) == 1
      return fail(ws)
    end
    if length(payload) >= 2
      code = UInt16(payload[1]) << 8 | UInt16(payload[2])
      is_invalid_close_code(code) && return fail(ws)
      length(payload) > 2 && !isvalid(String, @view payload[3:end]) && return fail(ws, UInt16(1007))
    end
    write_frame(ws, true, CLOSE, payload)
    ws.closed = true
  end
end

is_invalid_close_code(code) =
  code < 1000 || code in (1004, 1005, 1006, 1015) || (code >= 1016 && code < 3000) || code >= 5000

Base.close(ws::WebSocket) = begin
  if !ws.closed
    try write_frame(ws, true, CLOSE, UInt8[0x03, 0xE8]) catch end
    ws.closed = true
  end
  try close(ws.sock) catch end
  nothing
end

fail(ws::WebSocket, code::UInt16=UInt16(1002)) = begin
  ws.closed && return
  try write_frame(ws, true, CLOSE, UInt8[UInt8(code >> 8), UInt8(code & 0xFF)]) catch end
  ws.closed = true
  try close(ws.sock) catch end
  nothing
end
