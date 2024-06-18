# HTTP.jl

A client and server side implementation of HTTP for Julia.

To use it you will need the [Kip](https://github.com/jkroso/Kip.jl) module system.

The client returns a `Response` object which contains all the meta data needed to parse the response data into a rich data type such as HTML nodes or JSON objects. Or because `Response` is also an IO, you can just work directly with the bytes stream.

```Julia
@use "github.com/jkroso/HTTP.jl/client" GET PUT

read(GET("google.com"), String) # a string of html
write("google.html", GET("google.com")) # downloads to an html file

@use "github.com/jkroso/DOM.jl/html"
dom = parse(GET("google.com")) # a DOM object

write(PUT("gewgle.com"), MIME("text/html"), dom)
```
