import std/[json, os, osproc, strutils, tempfiles, unittest]

import selectorPublicProtocolsFixture
import sigils/core
import sigils/selectors
import sigils/signals

suite "public selector protocols":
  test "protocol summaries appear on generated documentation entries":
    let
      repoRoot = parentDir(parentDir(currentSourcePath()))
      outputDir = createTempDir("sigils-protocol-docs-", "")
      outputPath = outputDir / "protocols.json"
      sourcePath = repoRoot / "tests" / "selectorPublicProtocolsFixture.nim"
    defer:
      removeDir(outputDir)

    let (output, exitCode) = execCmdEx(
      "nim jsondoc --docInternal:on --hints:off --out:" & quoteShell(outputPath) & " " &
        quoteShell(sourcePath),
      options = {poStdErrToStdOut, poUsePath},
      workingDir = repoRoot,
    )
    checkpoint output
    require exitCode == 0
    let documentation = parseFile(outputPath)
    for (name, summary) in [
      ("PublicWindowLifecycleProtocol", "Exports optional close validation"),
      ("PublicControllerEvents", "Receives window-close notifications"),
      ("PublicCaptionedViewProtocol", "Exports receiver-bound caption access"),
      (
        "PublicCaptionVariant",
        "Supplies caption queries through a named implementation",
      ),
    ]:
      var found = false
      for entry in documentation["entries"]:
        if entry["name"].getStr() == name:
          check entry{"description"}.getStr().contains(summary)
          found = true
      check found

  test "exported receiverless protocol is visible across modules":
    check PublicWindowLifecycleProtocol.requirements.len == 1
    check PublicWindowLifecycleProtocol.signals.len == 1
    check PublicWindowLifecycleProtocol.slots.len == 1
    check PublicWindowLifecycleProtocol.hasSignal(toSigilName("windowWillClose"))
    check PublicWindowLifecycleProtocol.hasSlot(toSigilName("rememberWindowClose"))
    check SignalTypes.windowWillClose(PublicWindow) is tuple[]
    check SignalTypes.rememberWindowClose(PublicController) is tuple[]
    checkProtocolSlots(PublicController, PublicWindowLifecycleProtocol)

    let
      window = PublicWindow()
      controller = PublicController()

    connect(window, windowWillClose, controller, rememberWindowClose)
    emit window.windowWillClose()

    check controller.windowClosed

  test "exported protocol connectors are visible across modules":
    let
      window = PublicWindow()
      controller = PublicController().withProto()

    connectProtocol(
      window, controller, selectorPublicProtocolsFixture.PublicControllerEvents
    )
    emit window.windowDidClose()

    check controller.windowClosed

  test "exported receiver-bound protocol is visible across modules":
    let view = PublicView(caption: "old").withProto

    check PublicCaptionedViewProtocol.requirements.len == 1
    check PublicCaptionedViewProtocol.signals.len == 1
    check PublicCaptionedViewProtocol.slots.len == 1
    check PublicCaptionedViewProtocol.hasRequirement(currentCaption)
    check PublicCaptionedViewProtocol.hasSignal(toSigilName("captionWillChange"))
    check PublicCaptionedViewProtocol.hasSlot(toSigilName("rememberCaption"))
    check SignalTypes.captionWillChange(PublicView) is tuple[]
    check SignalTypes.rememberCaption(PublicView) is (string,)
    checkProtocolSlots(
      PublicView, selectorPublicProtocolsFixture.PublicCaptionedViewProtocol
    )

    check view.hasAdopted(PublicCaptionedViewProtocol)
    check view.currentCaption() == "old"
    check view.captionWillChange().procName == toSigilName("captionWillChange")
    view.rememberCaption("new")
    check view.currentCaption() == "new"
