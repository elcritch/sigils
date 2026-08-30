const
  sigilsSigilNameStringEnabled* =
    defined(sigilsSigilNameString) or
    defined(sigils.sigNameAsString) or
    defined(features.sigils.sigNameAsString)
  sigilsClosuresEnabled* =
    defined(sigilsClosures) or
    defined(sigils.closures) or
    defined(features.sigils.closures)
  sigilsCborSerdeEnabled* = defined(sigilsCborSerde)
