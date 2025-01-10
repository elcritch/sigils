--path:
  "../"

--gc:
  arc
--threads:
  on
--d:
  useMalloc

--debuginfo:
  on
--debugger:
  native
--deepcopy:
  on

--d:
  sigilsDebug

--passc:
  "-Wno-int-conversion"

when defined(tsan):
  --debugger:
    native
  --passc:
    "-fsanitize=thread -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer"
  --passl:
    "-fsanitize=thread -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer"
  --passc:
    "-fsanitize-blacklist=tests/tsan.ignore"
