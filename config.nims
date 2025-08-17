# NimScript configuration and tasks for this repo

import std/[os, strformat, strutils]

const testDir = "tests"

task test, "Compile and run all tests in tests/":
  withDir(testDir):
    var skip: seq[string] = @[]
    when (NimMajor, NimMinor) >= (2, 2):
      # Known incompatibility with Nim 2.2+ closure env API
      skip.add "tclosures.nim"
    for kind, path in walkDir("."):
      if kind == pcFile and path.endsWith(".nim") and not path.endsWith("config.nims"):
        let name = splitFile(path).name
        if not name.startsWith("t"): continue # run only t*.nim files
        let sf = splitFile(path)
        let base = sf.name & sf.ext
        if base in skip:
          echo fmt"[sigils] Skipping {path} (compat)"
          continue
        echo fmt"[sigils] Running {path}"
        exec fmt"nim c --nimcache:../.nimcache -r {path}"
