import std/[os, osproc, strutils, unittest]

import sigils/selectors

type
  ListView = ref object of DynamicAgent

  ListDataSource = ref object of DynamicAgent
    rows: seq[string]

protocol ListViewDataSource {.selectorScope: protocol.}:
  method numberOfRows*(listView: ListView): int {.optional.}
  method objectValueForRow*(listView: ListView, row: int): string {.optional.}

protocol ScopedDefaultDataSource {.selectorScope: protocol.} from ListDataSource:
  method defaultNumberOfRows*(self: ListDataSource, listView: ListView): int =
    self.rows.len

method rowCount(self: ListDataSource, listView: ListView): int {.selector.} =
  self.rows.len

method rowValue(self: ListDataSource, listView: ListView,
    row: int): string {.selector.} =
  self.rows[row]

suite "scoped protocol selectors":
  test "protocol selector scope prefixes runtime selector names":
    let
      listView = ListView()
      dataSource = ListDataSource(rows: @["a", "b"])

    check selectorName(numberOfRows) ==
        toSigilName("ListViewDataSource.numberOfRows")
    check selectorName(objectValueForRow) ==
        toSigilName("ListViewDataSource.objectValueForRow")
    check ListViewDataSource.hasRequirement(
      toSigilName("ListViewDataSource.numberOfRows")
    )
    check not ListViewDataSource.hasRequirement(toSigilName("numberOfRows"))

    check dataSource.addMethod(numberOfRows, rowCount)
    check dataSource.addMethod(objectValueForRow, rowValue)
    check dataSource.numberOfRows(listView) == 2
    check dataSource.objectValueForRow(listView, 1) == "b"

  test "scoped selector names work with default protocol implementations":
    let
      listView = ListView()
      dataSource = ListDataSource(rows: @["a", "b", "c"]).withProto

    check selectorName(defaultNumberOfRows) ==
        toSigilName("ScopedDefaultDataSource.defaultNumberOfRows")
    check ScopedDefaultDataSource.hasRequirement(
      toSigilName("ScopedDefaultDataSource.defaultNumberOfRows")
    )
    check dataSource.hasAdopted(ScopedDefaultDataSource)
    check dataSource.defaultNumberOfRows(listView) == 3

  test "scoped selector names are checked against SigilName capacity at compile time":
    let
      repoRoot = parentDir(parentDir(currentSourcePath()))
      sourcePath = repoRoot / "tests" / "examples" /
        "tooLongScopedSelectorSource.nim"

    let (output, exitCode) = execCmdEx(
      "nim check --hints:off --warnings:off --path:" & quoteShell(repoRoot) &
        " " & quoteShell(sourcePath),
      options = {poStdErrToStdOut, poUsePath},
      workingDir = repoRoot,
    )

    check exitCode != 0
    check output.contains(
      "selector name `ExtremelyLongListViewDataSourceProtocolName.objectValueForVeryLongRowName` is 73 bytes"
    )
    check output.contains("SigilName capacity is 48")
