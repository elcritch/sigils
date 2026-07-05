const
  sigilsSigilNameStringEnabled* =
    defined(sigilsSigilNameString) or
    defined(sigils.sigNameAsString) or
    defined(feature.sigils.sigNameAsString)
  sigilsClosuresEnabled* =
    defined(sigilsClosures) or
    defined(sigils.closures) or
    defined(feature.sigils.closures)
