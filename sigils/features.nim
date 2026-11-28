const
  sigilsSigilNameStringEnabled* =
    defined(sigilsSigilNameString) or
    defined(sigils.sigNameAsString) or
    defined(features.sigils.sigNameAsString)
  sigilsSigilNameStackEnabled* = not sigilsSigilNameStringEnabled
  sigilsClosuresEnabled* =
    defined(sigilsClosures) or
    defined(sigils.closures) or
    defined(features.sigils.closures)
  sigilsThetosEnabled* = true ## Generated protocol storage uses Thetos.
  sigilsCborSerdeEnabled* = defined(sigilsCborSerde)
  sigilsCborRpcEnabled* =
    defined(features.sigils.cbor) or
    defined(features.sigils.ipc)
