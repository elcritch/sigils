import std/os
import binny/native_dynlib/build

let
  exampleDir = currentSourcePath.parentDir
  sigilsDir = exampleDir.parentDir.parentDir
  binnyDir = getEnv("BINNY_PATH", sigilsDir / "deps" / "binny")
var nativeBuild = initNativeDynlibBuildConfig(
  exampleDir / "producer.nim", "libcounter",
  buildRoot = exampleDir / "build",
  sourceRoot = exampleDir,
  exportConfigPath = exampleDir / "native_dynlib.json",
  bindingsPath = exampleDir / "build" / "counter_abi.nim",
)
nativeBuild.nimArgs = @[
  "--mm:arc", "-d:useMalloc", "--path:" & sigilsDir, "--path:" & binnyDir,
]

task producer, "Build the counter library and bindings":
  nativeBuild.buildNativeDynlibAndBindings()

task testDynlib, "Build the library and run a separate protocol consumer":
  nativeBuild.buildNativeDynlibAndBindings()
  let args = @[nativeBuild.compiler, "c", "-r"] & nativeBuild.nimArgs &
    @["--out:" & exampleDir / "build" / "consumer", exampleDir / "consumer.nim"]
  exec quoteShellCommand(args)
