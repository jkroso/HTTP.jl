using Morsel

@require "." get

app = Morsel.App()

get(app, "/") do req, res
  "home"
end

get(app, "/json") do req, res
  res.headers["Content-Type"] = "application/json"
  """{"name": "jake"}"""
end

@async start(app, 8000)

@test get("http://localhost:8000").data == "home"
@test get("localhost:8000").data == "home"
@test get(":8000").data == "home"
@test get(":8000/json").data == {"name" => "jake"}
