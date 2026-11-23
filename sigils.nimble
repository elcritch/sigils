version = "0.37.1"
author = "Jaremy Creechley"
description = "A slot and signals implementation for the Nim programming language"
license = "MIT"
srcDir = "."

requires "nim >= 2.0.2"
requires "threading >= 0.2.1"
requires "stack_strings"
requires "results >= 0.5.1"

feature "sigNameAsString":
  discard

feature "closures":
  discard

feature "cbor":
  requires "cborious"

feature "mummy":
  requires "mummy"

feature "siwin":
  requires "siwin"

feature "chronos":
  requires "https://github.com/status-im/nim-chronos >= 4.2.0"

feature "ipc":
  requires "cborious"
