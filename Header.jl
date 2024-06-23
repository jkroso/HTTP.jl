@use "github.com/jkroso/Prospects.jl" append assoc

mutable struct Header <: AbstractDict{String,String}
  dict::Base.ImmutableDict{String,String}
end

Header(pairs::Pair...) = Header(reduce(append, pairs, init=Base.ImmutableDict{String,String}()))

Base.iterate(h::Header) = iterate(h.dict)
Base.iterate(h::Header, state) = iterate(h.dict, state)
Base.length(h::Header) = length(h.dict)
Base.keys(h::Header) = keys(h.dict)
Base.values(h::Header) = values(h.dict)
Base.get(h::Header, key) = h.dict[key]
Base.get(h::Header, key, default) = get(h.dict, key, default)
Base.getindex(h::Header, key) = h.dict[key]
Base.setindex!(h::Header, val, key) = (h.dict = assoc(h.dict, key, val); val)

parse_header(io::IO) = begin
  meta = Base.ImmutableDict{String,String}()
  for line in eachline(io)
    isempty(line) && break
    key,value = split(line, ':', limit=2)
    meta = assoc(meta, String(lowercase(key)), String(strip(value)))
  end
  Header(meta)
end
