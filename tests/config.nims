--path:
  "../"

--gc:
  arc
--threads:
  on
--d:
  useMalloc

#--debuginfo:
#  on
--debugger:
  native

#--d:
#  sigilsDebug

--passc:
  "-Wno-int-conversion"

when defined(features.sigils.siwin) and defined(macosx):
  --passc:
    "-Wno-incompatible-function-pointer-types"
  --passc:
    "-Wno-error=incompatible-function-pointer-types"

when defined(tsan):
  --debugger:
    native
  --passc:
    "-fsanitize=thread -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer"
  --passl:
    "-fsanitize=thread -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer"
  --passc:
    "-fsanitize-blacklist=tests/tsan.ignore"
