version = "0.18.2"
author = "Jaremy Creechley"
description = "A slot and signals implementation for the Nim programming language"
license = "MIT"
srcDir = "."

requires "nim >= 2.0.2"
requires "variant >= 0.2.12"
requires "threading >= 0.2.1"
requires "stack_strings"

feature "cbor":
  requires "cborious"

feature "mummy":
  requires "mummy"

