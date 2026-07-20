import std/unittest

import sigils/agents

suite "compile feature flags":
  test "sigil name string aliases":
    when defined(sigilsSigilNameString) or defined(sigils.sigNameAsString) or
        defined(feature.sigils.sigNameAsString):
      check sigilsSigilNameStringEnabled
      check SigilName is string
      let name = toSigilName("featureName")
      check name == "featureName"
    else:
      check not sigilsSigilNameStringEnabled
      check not (SigilName is string)
      check $toSigilName("featureName") == "featureName"

  test "closure aliases":
    when defined(sigilsClosures) or defined(sigils.closures) or
        defined(feature.sigils.closures):
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
