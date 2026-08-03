import std/[strutils, unittest]

import sigils/svariant

type ManagedPayload = tuple[requestId: int, text: string, depth: int]

suite "SVariant managed payload ownership":
  test "duplicate survives reuse of the source buffer":
    let
      firstText = repeat('a', 128)
      secondText = repeat('b', 128)
      first: ManagedPayload = (requestId: 1, text: firstText, depth: 4)
      second: ManagedPayload = (requestId: 2, text: secondText, depth: 8)
      source = newWrapperVariant(first)
      queued = source.duplicate()

    source.resetTo(second)

    check queued.getWrapped(ManagedPayload) == first
