## Internal copy of the installed stdlib HTTP client with safe status parsing.
## Nim 2.0 and 2.2 convert an untrusted status to HttpCode before checking it,
## causing a RangeDefect (or process termination with --panics:on). Parse the
## installed source so the networking and TLS code still comes from that Nim.

import std/[compilesettings, macros, strutils]

macro loadHttpClient(): untyped =
  let sourcePath = querySetting(SingleValueSetting.libPath) & "/pure/httpclient.nim"
  result = parseStmt(staticRead(sourcePath))
  var replaced = 0
  for node in result:
    if node.kind == nnkProcDef and node.name.eqIdent("code") and
        node.body.kind != nnkEmpty:
      var statements = 0
      for statement in node.body:
        if statement.kind notin {nnkCommentStmt, nnkEmpty}:
          inc statements
      if statements != 1 or not node.body[^1].repr.contains(
          "return response.status[0 .. 2].parseInt.HttpCode"):
        error("unsupported std/httpclient status parser", node)
      node.body = parseStmt("""if response.status.len < 3 or response.status[0] notin {'1'..'5'} or
    response.status[1] notin {'0'..'9'} or response.status[2] notin {'0'..'9'}:
  raise newException(ValueError, "invalid HTTP response status")
return response.status[0..2].parseInt.HttpCode
""")
      inc replaced
  if replaced != 1:
    error("unsupported std/httpclient: expected one status parser")

loadHttpClient()
