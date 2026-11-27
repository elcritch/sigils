const
  sigilsSigilNameStringEnabled* =
    defined(sigilsSigilNameString) or
    defined(sigils.sigNameAsString) or
    defined(features.sigils.sigNameAsString)
  sigilsClosuresEnabled* =
    defined(sigilsClosures) or
    defined(sigils.closures) or
    defined(features.sigils.closures)
  sigilsThetosEnabled* = defined(features.sigils.thetos)
  sigilsCborSerdeEnabled* = defined(sigilsCborSerde)
  sigilsCborRpcEnabled* =
    defined(features.sigils.cbor) or
    defined(features.sigils.ipc)
