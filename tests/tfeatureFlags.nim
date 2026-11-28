import std/unittest

import sigils/agents

suite "compile feature flags":
  test "sigil name string aliases":
    when defined(sigilsSigilNameString) or defined(sigils.sigNameAsString) or
        defined(features.sigils.sigNameAsString):
      check sigilsSigilNameStringEnabled
    else:
      check not sigilsSigilNameStringEnabled
    const name = sig"featureName"
    when sigilsSigilNameStringEnabled:
      check SigilName is string
      check not sigilsSigilNameStackEnabled
    else:
      check sigilsSigilNameStackEnabled
      check not (SigilName is string)
    check $name == "featureName"

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
