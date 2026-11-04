const
  sigilsSharedNamesEnabled* = defined(sigilsSharedNames)
  sigilsSigilNameStringEnabled* =
    defined(sigilsSigilNameString) or
    defined(sigils.sigNameAsString) or
    defined(features.sigils.sigNameAsString)
  sigilsClosuresEnabled* =
    defined(sigilsClosures) or
    defined(sigils.closures) or
    defined(features.sigils.closures)
  sigilsCborSerdeEnabled* = defined(sigilsCborSerde)
  sigilsCborRpcEnabled* =
    defined(features.sigils.cbor) or
    defined(features.sigils.ipc)

when sigilsSharedNamesEnabled and sigilsSigilNameStringEnabled:
  {.error: "Choose either sigilsSharedNames or sigilsSigilNameString".}
