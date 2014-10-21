using Morsel

@require "parse-json" parse => parse_json
@require "." GET

app = Morsel.app()

get(app, "/") do req, res
  "home"
end

get(app, "/json") do req, res
  res.headers["Content-Type"] = "application/json"
  """{"name": "jake"}"""
end

@async start(app, 8000)

Base.parse(::MIME"application/json", io::IO) = parse_json(readavailable(io))

@test readavailable(GET("http://localhost:8000").data) == "home"
@test readavailable(GET("localhost:8000").data) == "home"
@test readavailable(GET(":8000").data) == "home"
@test GET(":8000/json").data == {"name" => "jake"}
