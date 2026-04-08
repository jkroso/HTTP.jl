using Test
@use ".." serve Request Response Headers
@use "../cookie-session" CookieSession session session_id set_cookie destroy! store COOKIE_NAME

@testset "CookieSession" begin
  @testset "Dict interface" begin
    s = CookieSession("test")
    @test isempty(s)
    @test length(s) == 0
    s["name"] = "alice"
    @test s["name"] == "alice"
    @test haskey(s, "name")
    @test !haskey(s, "missing")
    @test get(s, "missing", 42) == 42
    @test length(s) == 1
    @test !isempty(s)
    @test collect(keys(s)) == ["name"]
    @test collect(values(s)) == ["alice"]
    delete!(s, "name")
    @test isempty(s)
  end

  @testset "session_id parsing" begin
    req = Request("GET /\r\nCookie: sid=abc123; other=val\r\n\r\n")
    @test session_id(req) == "abc123"

    req = Request("GET /\r\nCookie: other=val; sid=xyz\r\n\r\n")
    @test session_id(req) == "xyz"

    req = Request("GET /\r\nCookie: other=val\r\n\r\n")
    @test session_id(req) === nothing

    req = Request("GET /\r\n\r\n")
    @test session_id(req) === nothing
  end

  @testset "session creates new session" begin
    empty!(store)
    req = Request("GET /\r\n\r\n")
    s = session(req)
    @test s isa CookieSession
    @test s.isnew
    @test length(s.id) == 32
    @test haskey(store, s.id)
  end

  @testset "session retrieves existing session" begin
    empty!(store)
    s = CookieSession("known_id")
    s["data"] = "hello"
    store["known_id"] = s

    req = Request("GET /\r\nCookie: sid=known_id\r\n\r\n")
    retrieved = session(req)
    @test retrieved === s
    @test retrieved["data"] == "hello"
  end

  @testset "session ignores unknown id" begin
    empty!(store)
    req = Request("GET /\r\nCookie: sid=bogus\r\n\r\n")
    s = session(req)
    @test s.id != "bogus"
    @test length(store) == 1
  end

  @testset "set_cookie" begin
    empty!(store)
    s = CookieSession("sess123")
    res = set_cookie(Response("ok"), s)
    @test haskey(res.meta, "Set-Cookie")
    cookies = res.meta["Set-Cookie"]
    @test length(cookies) == 1
    @test cookies[1][1] == COOKIE_NAME
    @test startswith(cookies[1][2], "sess123; ")
    @test occursin("HttpOnly", cookies[1][2])
    @test occursin("SameSite=Lax", cookies[1][2])
  end

  @testset "set_cookie renders correctly" begin
    s = CookieSession("abc")
    res = set_cookie(Response("hi"), s)
    buf = IOBuffer()
    write(buf, res)
    output = String(take!(buf))
    @test occursin("Set-Cookie: sid=abc;", output)
    @test occursin("HttpOnly", output)
  end

  @testset "destroy!" begin
    empty!(store)
    s = CookieSession("doomed")
    s["x"] = 1
    store["doomed"] = s
    destroy!(s)
    @test !haskey(store, "doomed")
    @test isempty(s)
  end

  @testset "integration" begin
    empty!(store)
    handler = function(req)
      s = session(req)
      s["visits"] = get(s, "visits", 0) + 1
      set_cookie(Response("visits: $(s["visits"])"), s)
    end

    # first request - no cookie
    res = handler(Request("GET /\r\n\r\n"))
    buf = IOBuffer()
    write(buf, res)
    output = String(take!(buf))
    @test occursin("visits: 1", output)
    @test occursin("Set-Cookie: sid=", output)

    # extract session id from store for next request
    id = first(keys(store))
    res = handler(Request("GET /\r\nCookie: sid=$id\r\n\r\n"))
    buf = IOBuffer()
    write(buf, res)
    output = String(take!(buf))
    @test occursin("visits: 2", output)
  end
end
