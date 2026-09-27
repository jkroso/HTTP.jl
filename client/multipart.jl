@use Random: randstring

"""
A file part of a `Form`: `data` is bytes, a String, or an IO read when the form
is sent.

```julia
Multipart("memo.m4a", read("memo.m4a"), "audio/mp4")
```
"""
struct Multipart
  filename::String
  data::Any
  content_type::String
end

Multipart(filename::AbstractString, data, content_type::AbstractString="application/octet-stream") =
  Multipart(String(filename), data, String(content_type))

"""
A `multipart/form-data` body. Values are text fields, except `Multipart`s and
open files (`open(path)`), which are sent as file parts.

```julia
POST("api.example.com/transcribe", data=Form("model" => "whisper-1",
                                             "file" => Multipart("a.m4a", bytes, "audio/mp4")))
```
"""
struct Form
  parts::Vector{Pair{String,Any}}
  boundary::String
  Form(parts::Vector{Pair{String,Any}}, boundary::String) = new(parts, boundary)
end

Form(parts::Pair...) = Form(Pair{String,Any}[String(string(k)) => v for (k, v) in parts], "JuliaFormBoundary" * randstring(16))
Form(parts::Union{AbstractDict,NamedTuple}) = Form(pairs(parts)...)
Form(parts::AbstractVector{<:Pair}) = Form(parts...)

content_type(f::Form) = "multipart/form-data; boundary=$(f.boundary)"

"The whole encoded body, ready to send with a Content-Length"
function body(f::Form)
  io = IOBuffer()
  for (name, value) in f.parts
    write(io, "--", f.boundary, "\r\n")
    write_part(io, name, value)
    write(io, "\r\n")
  end
  write(io, "--", f.boundary, "--\r\n")
  take!(io)
end

write_part(io, name, value) = begin
  write(io, "Content-Disposition: form-data; name=\"", quote_param(name), "\"\r\n\r\n")
  print(io, value)
end
write_part(io, name, file::IOStream) = write_part(io, name, Multipart(filename(file), file))
write_part(io, name, part::Multipart) = begin
  write(io, "Content-Disposition: form-data; name=\"", quote_param(name),
            "\"; filename=\"", quote_param(part.filename), "\"\r\n")
  write(io, "Content-Type: ", part.content_type, "\r\n\r\n")
  write(io, bytes(part.data))
end

bytes(data::AbstractVector{UInt8}) = data
bytes(data::AbstractString) = codeunits(data)
bytes(data::IO) = read(data)

"An IOStream's name is \"<file path>\""
filename(io::IOStream) = basename(replace(io.name, r"^<file (.*)>$" => s"\1"))

"Quotes and newlines would end the parameter early"
quote_param(s::AbstractString) = replace(s, '"' => "%22", '\r' => "%0D", '\n' => "%0A")
