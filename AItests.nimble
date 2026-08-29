# Package

version       = "0.1.0"
author        = "xlebore3o4ka"
description   = "A new awesome nimble package"
license       = "AGPL-3.0-only"
srcDir        = "src"
binDir        = "bin"
bin           = @["AItests"]


# Dependencies

requires "nim >= 2.2.10"
requires "llama_leap"
requires "linenoise"

task myRun, "Run with debug flags":
  exec "nimble run --debugger:native --stacktrace:on --linetrace:on --define:debug -d:ssl -- " & commandLineParams.join(" ")