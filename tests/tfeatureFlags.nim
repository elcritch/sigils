import std/unittest

import sigils/agents

suite "compile feature flags":
  test "sigil name string aliases":
    when defined(sigilsSigilNameString) or defined(sigils.sigNameAsString) or
        defined(features.sigils.sigNameAsString):
      check sigilsSigilNameStringEnabled
    else:
      check not sigilsSigilNameStringEnabled
    let name = sig"featureName"
    when sigilsSigilNameImmStrEnabled:
      check SigilName is ImmStr
      check not sigilsSigilNameStackEnabled
    elif sigilsSigilNameStringEnabled:
      check SigilName is string
    else:
      check sigilsSigilNameStackEnabled
      check not (SigilName is string)
    check $name == "featureName"

  when sigilsSigilNameImmStrEnabled:
    test "immutable name conversions at string APIs":
      proc asName(name: SigilName): SigilName = name
      proc asString(name: string): string = name

      var text = "runtime name with arbitrary bytes \0 \xff"
      let name = asName(text)
      check asString(name) == text
      text[0] = 'R'
      check asString(name) != text

    test "static immutable names share the same allocation":
      let first = sig"shared"
      let second = toSigilName("shared")
      check cast[pointer](first.toCString()) == cast[pointer](second.toCString())

    test "immutable names round trip as packed values":
      let name = toSigilName("feature.name")
      let packed = rpcPack((name: name, value: 17))
      var decoded: tuple[name: SigilName, value: int]
      rpcUnpack(decoded, packed)
      check decoded == (name, 17)

  test "closure aliases":
    when defined(sigilsClosures) or defined(sigils.closures) or
        defined(features.sigils.closures):
      check sigilsClosuresEnabled
      check sigilsSlotEnvEnabled
      check not sigilsSlotEnvDisabled
    else:
      check not sigilsClosuresEnabled
      check not sigilsSlotEnvEnabled
      check sigilsSlotEnvDisabled

  test "IPC leaves global CBOR serde selection unchanged":
    when defined(sigilsCborSerde):
      check sigilsCborSerdeEnabled
    else:
      check not sigilsCborSerdeEnabled
