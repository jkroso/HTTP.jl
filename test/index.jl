@require "parse-json"
@require ".." GET

@test readall(GET("http://localhost:8000").data) == "home"
@test readall(GET("localhost:8000").data) == "home"
@test readall(GET(":8000").data) == "home"
@test GET(":8000/json").data == {"name" => "jake"}
