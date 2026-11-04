import std/[unittest, strutils, macros]
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
      check (item.signature.len > 0) == sigilsPreserveProtocolSignatures
  test "slot metadata contains no implementation body":
    for item in MetadataSlots.slots:
      check "PRIVATE_BODY_MARKER" notin item.signature
      check (item.signature.len > 0) == sigilsPreserveProtocolSignatures

macro checkInline(call: typed): untyped =
  let pragmas = call[0].getImpl()[4]
  var found = false
  for pragma in pragmas:
    if pragma.eqIdent("inline"):
      found = true
  doAssert found, "slot implementation must preserve inline"
  newStmtList()

checkInline updateTitle(MetadataView(), "")
