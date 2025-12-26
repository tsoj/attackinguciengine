# Package

version = "0.1.0"
author = "Jost Triller"
description =
  "A program that selects multipv lines to make an UCI engine play attacking chess"
license = "MIT"
srcDir = "src"
bin = @["attackinguciengine"]

# Dependencies

requires "nim >= 2.2.4"
requires "nimchess >= 0.2.5"
requires "https://github.com/tsoj/chessattackingscore >= 0.3.0"
