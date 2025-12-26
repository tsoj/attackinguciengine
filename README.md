# attackinguciengine

A program that selects MultiPV lines from an underlying UCI engine to make it play more attacking chess.

## Features

- Wraps an existing UCI engine (like Stockfish).
- Evaluates multiple PV (Principal Variation) lines using the [chessattackingscore](https://github.com/tsoj/chessattackingscore) library.
- Selects the line with the highest attacking score among those that are within a certain evaluation range of the best move.

## Installation

Ensure you have [Nim](https://nim-lang.org/) installed (I suggest using [choosenim](https://github.com/nim-lang/choosenim) to install Nim).

```bash
# Clone the repository
git clone https://github.com/tsoj/attackinguciengine
cd attackinguciengine

# Build the project
nimble build
```

## Usage

You can run the engine by specifying the path to the underlying UCI engine as a command-line argument:

```bash
./attackinguciengine /path/to/stockfish
```

If no argument is provided, it defaults to looking for `stockfish` in your PATH.

## UCI Options

The engine supports the following UCI options:

- `Engine`: The path to the underlying UCI engine (re-initializes the engine when changed).
- `Internalmultipv`: How many PV lines the underlying engine should search (default: 3).
- `Hash`: Hash size in MB for the underlying engine.
- `Threads`: Number of threads for the underlying engine.
- `MinCentipawns`: The minimum evaluation (in centipawns) a move must have to be considered.
- `MaxCpLoss`: The maximum allowed centipawn loss compared to the best move to still consider a move for its attacking score.

## License

MIT

Copyright (c) 2025 Jost Triller
