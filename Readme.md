
# request

A simple HTTP client

## Installation

With [packin](//github.com/jkroso/packin): `packin add jkroso/request`

## API

All the common HTTP verbs have their own functions for making that particular type of HTTP request. All requests block until a `Response` is recieved. `Response` objects take the following shape:

```julia
immutable Response
  status::Int
  meta::Headers
  data::Any
end
```

### get | post | put | delete | head (uri::String)

Performs a HTTP request of the type corresponding to the functions name to `uri`. For example a GET request looks like this:

```julia
get("github.com") # => Response(200, ["Content-Type"=>"text/html"], "<title>github</title>...")
```
