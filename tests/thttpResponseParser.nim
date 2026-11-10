when defined(features.sigils.httpSelector):
  import std/unittest
  import sigils/http/responseParser

  suite "HTTP response parser":
    test "parses fragmented content length":
      var parser = initHttpResponseParser()
      check parser.add("HTTP/1.1 200 OK\r\nContent-Len").len == 0
      check parser.add("gth: 5\r\n\r\nhe") == @["he"]
      check parser.add("llo") == @["llo"]
      check parser.status == 200
      check parser.isDone()
      parser.finish()
    test "parses chunks across input boundaries":
      var parser = initHttpResponseParser()
      check parser.add("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\na") ==
          @["a"]
      check parser.add("bc\r\n2\r\nde\r\n0\r\n\r\n") == @["bc", "de"]
      check parser.isDone()
    test "rejects ambiguous and incomplete framing":
      var ambiguous = initHttpResponseParser()
      expect HttpResponseError:
        discard ambiguous.add("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nTransfer-Encoding: chunked\r\n\r\n")
      var truncated = initHttpResponseParser()
      discard truncated.add("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nx")
      expect HttpResponseError: truncated.finish()
    test "bounds bodies":
      var parser = initHttpResponseParser(maxBody = 2)
      expect HttpResponseError:
        discard parser.add("HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\n")
    test "rejects malformed and repeated framing headers":
      for response in [
          "HTTP/1.1 200 OK\r\nContent-Length: 1\r\ncontent-length: 1\r\n\r\n",
          "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\ntransfer-encoding: chunked\r\n\r\n",
          "HTTP/1.1 200 OK\r\nBad Header: value\r\n\r\n",
          "HTTP/1.1 abc OK\r\n\r\n"]:
        var parser = initHttpResponseParser()
        expect HttpResponseError:
          discard parser.add(response)
