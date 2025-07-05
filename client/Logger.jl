"Used just for debugging"
struct Logger <: IO
  io::IO
  writelog::IO
  readlog::IO
end

Base.write(l::Logger, x::UInt8) = begin
  write(l.writelog, x)
  flush(l.writelog)
  write(l.io, x)
end

Base.read(l::Logger, ::Type{UInt8}) = begin
  b = read(l.io, UInt8)
  write(l.readlog, b)
  flush(l.readlog)
  b
end

Base.read(l::Logger) = begin
  bytes = read(l.io)
  write(l.readlog, bytes)
  flush(l.readlog)
  bytes
end

Base.read(l::Logger, n::Integer) = begin
  bytes = read(l.io, n)
  write(l.readlog, bytes)
  flush(l.readlog)
  bytes
end

Base.bytesavailable(l::Logger) = bytesavailable(l.io)
Base.eof(l::Logger) = eof(l.io)
Base.isreadable(l::Logger) = isreadable(l.io)
Base.iswritable(l::Logger) = iswritable(l.io)
Base.close(l::Logger) = begin
  close(l.writelog)
  close(l.readlog)
  close(l.io)
end

Base.readavailable(l::Logger) = begin
  bytes = readavailable(l.io)
  write(l.readlog, bytes)
  flush(l.readlog)
  bytes
end
