import std/[unittest, strutils]
import sigils/selectors

type MetadataView = ref object of DynamicAgent
  title: string

protocol MetadataProperties {.selectorScope: protocol, setterStyle: nim.}:
  property title -> string
  method setCount*(value: int)
  method unrelated*(value: float)

protocol MetadataSlots from MetadataView:
  proc updateTitle*(view: MetadataView, value: string) {.slot, inline.} =
    # This implementation must never be embedded in protocol signatures.
    view.title = value & "PRIVATE_BODY_MARKER"

suite "compact protocol metadata":
  test "property value types survive disabled signatures":
    check MetadataProperties.requirement(toSigilName(
        "MetadataProperties.title=")).get.valueType == "string"
    check MetadataProperties.requirement(toSigilName(
        "MetadataProperties.setCount")).get.valueType == "int"
    check MetadataProperties.requirement(toSigilName(
        "MetadataProperties.unrelated")).get.valueType == ""
    for item in MetadataProperties.requirements:
      check (item.signature.len > 0) == sigilsProtocolSignatures
  test "slot metadata contains no implementation body":
    for item in MetadataSlots.slots:
      check "PRIVATE_BODY_MARKER" notin item.signature
      check (item.signature.len > 0) == sigilsProtocolSignatures
