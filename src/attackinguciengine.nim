import std/[strutils, strformat, tables, options, algorithm]
import nimchess
import chessattackingscore

type AttackingUciState = object
  externalEngine: UciEngine
  enginePath: string
  multipv: int = 4
  minCentipawns: int = -10
  currentGame: Game
  ourName: string = "AttackingEngine"
  oppName: string = "Opponent"

proc info(state: AttackingUciState, s: string) =
  echo "info string ", s

proc initializeExternalEngine(state: var AttackingUciState) =
  if state.enginePath == "":
    state.info "No external engine specified, using stockfish"
    state.enginePath = "stockfish"

  state.externalEngine = newUciEngine(state.enginePath)
  state.externalEngine.setOption("MultiPV", $state.multipv)
  state.info fmt"Initialized external engine: {state.externalEngine.name}"

proc createGameFromPv(
    baseGame: Game, pvMoves: seq[Move], ourColor: Color, ourName, oppName: string
): Game =
  result = baseGame

  # Set headers to identify our color
  if ourColor == white:
    result.headers["White"] = ourName
    result.headers["Black"] = oppName
  else:
    result.headers["White"] = oppName
    result.headers["Black"] = ourName

  # Add PV moves to the game
  for move in pvMoves:
    if result.currentPosition().isLegal(move):
      result.addMove(move)
    else:
      break

  # Set result as if we won (required for chessattackingscore)
  if ourColor == white:
    result.headers["Result"] = "1-0"
  else:
    result.headers["Result"] = "0-1"

proc evaluateAttackingScore(
    baseGame: Game, pvMoves: seq[Move], ourColor: Color, ourName: string
): float =
  let testGame = createGameFromPv(baseGame, pvMoves, ourColor, ourName, "Opponent")

  try:
    let stats = analyseGame(testGame, ourName)
    return getAttackingScore(getRawFeatureScores(stats))
  except:
    return 0.0

proc selectBestMove(state: var AttackingUciState, limit: Limit): Move =
  let ourColor = state.currentGame.currentPosition().us

  # Get multipv results from external engine
  let playResult = state.externalEngine.play(state.currentGame, limit)

  var candidates: seq[tuple[move: Move, score: float, attacking: float]] = @[]

  # Evaluate each PV line
  for multipvNum, uciInfo in playResult.pvs:
    if uciInfo.score.isSome and uciInfo.pv.isSome:
      let score = uciInfo.score.get()
      let pvMoves = uciInfo.pv.get()

      if pvMoves.len == 0:
        continue

      # Filter by minimum centipawn threshold
      let centipawns =
        case score.kind
        of skCp:
          score.cp
        of skMate:
          if score.mate > 0: 10000 else: -10000
        of skMateGiven:
          10000

      if centipawns >= state.minCentipawns:
        let attackingScore =
          evaluateAttackingScore(state.currentGame, pvMoves, ourColor, state.ourName)
        candidates.add((pvMoves[0], centipawns.float, attackingScore))

        state.info fmt"PV {multipvNum}: {pvMoves[0]} (cp: {centipawns}, attacking: {attackingScore:.3f})"

  if candidates.len == 0:
    state.info "No valid candidates found, using best move from engine"
    echo "info depth 1 score cp 0"
    return playResult.move

  # Select move with highest attacking score
  candidates.sort(
    proc(a, b: tuple[move: Move, score: float, attacking: float]): int =
      cmp(b.attacking, a.attacking)
  )
  let bestCandidate = candidates[0]

  state.info fmt"Selected move: {bestCandidate.move} (attacking score: {bestCandidate.attacking:.3f})"
  echo "info depth 1 score cp ", int((bestCandidate.attacking - 0.5) * 100)
  return bestCandidate.move

proc uci(state: var AttackingUciState) =
  echo "id name ", state.ourName
  echo "id author UCI Attacking Engine"
  echo "option name Engine type string default stockfish"
  echo "option name internalmultipv type spin default 4 min 1 max 100"
  echo "option name Hash type spin default 4 min 1 max 10000"
  echo "option name Threads type spin default 1 min 1 max 100"
  echo "option name MinCentipawns type spin default -10 min -1000 max 1000"
  echo "uciok"

proc setOption(state: var AttackingUciState, params: seq[string]) =
  let nameIdx = params.find("name")
  let valueIdx = params.find("value")

  if nameIdx != -1 and valueIdx != -1 and nameIdx + 1 < valueIdx and
      valueIdx + 1 < params.len:
    let name = params[nameIdx + 1].toLowerAscii
    let value = params[valueIdx + 1]

    case name
    of "engine":
      state.enginePath = value
      state.info fmt"Set external engine to: {state.enginePath}"
    of "internalmultipv":
      let newMultiPv = value.parseInt
      if newMultiPv >= 1 and newMultiPv <= 100:
        state.multipv = newMultiPv
        if state.externalEngine.initialized:
          state.externalEngine.setOption("MultiPV", $newMultiPv)
        state.info fmt"Set MultiPV to: {newMultiPv}"
    of "mincentipawns":
      let newMin = value.parseInt
      if newMin >= -1000 and newMin <= 1000:
        state.minCentipawns = newMin
        state.info fmt"Set MinCentipawns to: {newMin}"
    of "hash":
      let newHash = value.parseInt
      if state.externalEngine.initialized:
        state.externalEngine.setOption("Hash", $newHash)
      state.info fmt"Set Hash to: {newHash}MB"
    of "threads":
      let newThreads = value.parseInt
      if state.externalEngine.initialized:
        state.externalEngine.setOption("Threads", $newThreads)
      state.info fmt"Set Threads to: {newThreads}"
    else:
      state.info fmt"Unknown option: {name}"
  else:
    state.info "Invalid setoption parameters"

proc setPosition(state: var AttackingUciState, params: seq[string]) =
  if params.len == 0:
    return

  var position: Position
  let movesIdx = params.find("moves")

  if params[0] == "startpos":
    position = classicalStartPos
  elif params[0] == "fen":
    let fenEnd = if movesIdx == -1: params.len else: movesIdx
    if fenEnd <= 1:
      state.info "Invalid FEN"
      return
    position = params[1 ..< fenEnd].join(" ").toPosition()
  else:
    state.info "Invalid position parameters"
    return

  state.currentGame = newGame(startPosition = position)

  if movesIdx != -1 and movesIdx + 1 < params.len:
    for i in (movesIdx + 1) ..< params.len:
      try:
        let move = params[i].toMove(state.currentGame.currentPosition())
        state.currentGame.addMove(move)
      except CatchableError:
        state.info fmt"Invalid move: {params[i]}"
        break

proc go(state: var AttackingUciState, params: seq[string]) =
  if not state.externalEngine.initialized:
    initializeExternalEngine(state)

  var limit = Limit()
  var i = 0

  template getArg(body: untyped) =
    if i + 1 < params.len:
      inc i
      let arg {.inject.} = params[i]
      body

  while i < params.len:
    case params[i]
    of "depth":
      getArg:
        limit.depth = arg.parseInt
    of "nodes":
      getArg:
        limit.nodes = arg.parseInt
    of "movetime":
      getArg:
        limit.movetimeSeconds = arg.parseFloat / 1000.0
    of "wtime":
      getArg:
        limit.whiteTimeSeconds = arg.parseFloat / 1000.0
    of "btime":
      getArg:
        limit.blackTimeSeconds = arg.parseFloat / 1000.0
    of "winc":
      getArg:
        limit.whiteIncSeconds = arg.parseFloat / 1000.0
    of "binc":
      getArg:
        limit.blackIncSeconds = arg.parseFloat / 1000.0
    of "movestogo":
      getArg:
        limit.movesToGo = arg.parseInt
    else:
      discard
    inc i

  try:
    let bestMove = selectBestMove(state, limit)
    echo "bestmove ", bestMove.toUCI(state.currentGame.currentPosition())
  except CatchableError:
    state.info fmt"Error during search: {getCurrentExceptionMsg()}"
    # Fallback to a legal move
    let legalMoves = state.currentGame.currentPosition().legalMoves()
    if legalMoves.len > 0:
      echo "bestmove ", legalMoves[0]
    else:
      echo "bestmove 0000"

proc uciLoop() =
  var state = AttackingUciState(currentGame: newGame())

  while true:
    try:
      let command = readLine(stdin)
      let params = command.splitWhitespace()

      if params.len == 0:
        continue

      case params[0].toLowerAscii
      of "uci":
        uci(state)
      of "setoption":
        setOption(state, params[1 ..^ 1])
      of "isready":
        if not state.externalEngine.initialized:
          initializeExternalEngine(state)
        echo "readyok"
      of "position":
        setPosition(state, params[1 ..^ 1])
      of "go":
        go(state, params[1 ..^ 1])
      of "quit":
        break
      of "ucinewgame":
        state.currentGame = newGame()
        if state.externalEngine.initialized:
          state.externalEngine.newGame()
      of "stop":
        # For simplicity, we don't support stopping mid-search
        discard
      of "internalmultipv", "hash", "threads":
        if params.len >= 2:
          setOption(state, @["name", params[0], "value", params[1]])
      else:
        state.info fmt"Unknown command: {params[0]}"
    except EOFError:
      break
    except CatchableError:
      state.info fmt"Error processing command: {getCurrentExceptionMsg()}"

when isMainModule:
  uciLoop()
