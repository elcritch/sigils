when defined(features.sigils.httpSelector) or
    defined(features.sigils.httpAsync) or defined(features.sigils.httpChronos):
  import std/assertions
  import sigils/http

  when defined(features.sigils.httpSelector):
    static: doAssert compiles(newHttpDownloadQueue(nil))
  when defined(features.sigils.httpAsync):
    static: doAssert compiles(newAsyncDownloadQueue())
  when defined(features.sigils.httpChronos):
    import sigils
    static: doAssert compiles(newChronosDownloadQueue())
    static: doAssert compiles(newSigilChronosThread())
