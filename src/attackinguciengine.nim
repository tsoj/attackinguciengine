import std/[strutils, strformat, tables, options, algorithm]
import nimchess
import chessattackingscore

type
  AttackingUciState = object
    externalEngine: UciEngine
    enginePath: string
    multipv: int = 5
    minCentipawns: int = -10
    currentGame: Game
    ourName: string = "AttackingEngine"
    oppName: string = "Opponent"
    searchDepth: int = 15
    searchTime: float = 1.0

proc info(state: AttackingUciState, s: string) =
  echo "info string ", s

proc initializeExternalEngine(state: var AttackingUciState) =
  if state.enginePath == "":
    state.info "No external engine specified, using stockfish"
    state.enginePath = "stockfish"

  state.externalEngine = newUciEngine(state.enginePath)
  state.externalEngine.setOption("MultiPV", $state.multipv)
  state.info fmt"Initialized external engine: {state.externalEngine.name}"

proc createGameFromPv(baseGame: Game, pvMoves: seq[Move], ourColor: Color, ourName, oppName: string): Game =
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

proc evaluateAttackingScore(baseGame: Game, pvMoves: seq[Move], ourColor: Color, ourName: string): float =
  let testGame = createGameFromPv(baseGame, pvMoves, ourColor, ourName, "Opponent")
  var stats = AttackingStats()

  try:
    analyseGame(testGame, ourName, stats)
    return getAttackingScore(getRawFeatureScores(stats))
  except:
    return 0.0

proc selectBestMove(state: var AttackingUciState): Move =
  let ourColor = state.currentGame.currentPosition().us

  # Get multipv results from external engine
  let limit = Limit(depth: state.searchDepth, movetimeSeconds: state.searchTime)
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
      let centipawns = case score.kind:
        of skCp:
          score.cp
        of skMate:
          if score.mate > 0: 10000 else: -10000
        of skMateGiven:
          10000

      if centipawns >= state.minCentipawns:
        let attackingScore = evaluateAttackingScore(state.currentGame, pvMoves, ourColor, state.ourName)
        candidates.add((pvMoves[0], centipawns.float, attackingScore))

        state.info fmt"PV {multipvNum}: {pvMoves[0]} (cp: {centipawns}, attacking: {attackingScore:.3f})"

  if candidates.len == 0:
    state.info "No valid candidates found, using best move from engine"
    return playResult.move

  # Select move with highest attacking score
  candidates.sort(proc(a, b: tuple[move: Move, score: float, attacking: float]): int =
    cmp(b.attacking, a.attacking))
  let bestCandidate = candidates[0]

  state.info fmt"Selected move: {bestCandidate.move} (attacking score: {bestCandidate.attacking:.3f})"
  return bestCandidate.move

proc uci(state: var AttackingUciState) =
  echo "id name ", state.ourName
  echo "id author UCI Attacking Engine"
  echo "option name Engine type string default stockfish"
  echo "option name MultiPV type spin default 5 min 1 max 100"
  echo "option name MinCentipawns type spin default -10 min -1000 max 1000"
  echo "option name SearchDepth type spin default 15 min 1 max 50"
  echo "option name SearchTime type spin default 1000 min 100 max 60000"
  echo "uciok"

proc setOption(state: var AttackingUciState, params: seq[string]) =
  if params.len == 4 and params[0] == "name" and params[2] == "value":
    case params[1].toLowerAscii:
    of "engine":
      state.enginePath = params[3]
      state.info fmt"Set external engine to: {state.enginePath}"
    of "multipv":
      let newMultiPv = params[3].parseInt
      if newMultiPv >= 1 and newMultiPv <= 100:
        state.multipv = newMultiPv
        if state.externalEngine.initialized:
          state.externalEngine.setOption("MultiPV", $newMultiPv)
        state.info fmt"Set MultiPV to: {newMultiPv}"
    of "mincentipawns":
      let newMin = params[3].parseInt
      if newMin >= -1000 and newMin <= 1000:
        state.minCentipawns = newMin
        state.info fmt"Set MinCentipawns to: {newMin}"
    of "searchdepth":
      let newDepth = params[3].parseInt
      if newDepth >= 1 and newDepth <= 50:
        state.searchDepth = newDepth
        state.info fmt"Set SearchDepth to: {newDepth}"
    of "searchtime":
      let newTime = params[3].parseInt
      if newTime >= 100 and newTime <= 60000:
        state.searchTime = newTime.float / 1000.0
        state.info fmt"Set SearchTime to: {newTime}ms"
    else:
      state.info fmt"Unknown option: {params[1]}"

proc setPosition(state: var AttackingUciState, params: seq[string]) =
  var index = 0
  var position: Position

  if params.len >= 1 and params[0] == "startpos":
    position = classicalStartPos
    index = 1
  elif params.len >= 1 and params[0] == "fen":
    var fen = ""
    index = 1
    while params.len > index and params[index] != "moves":
      fen &= " " & params[index]
      index += 1
    position = fen.strip().toPosition()
  else:
    state.info "Invalid position parameters"
    return

  state.currentGame = newGame(startPosition = position)

  if params.len > index and params[index] == "moves":
    index += 1
    for i in index..<params.len:
      try:
        let move = params[i].toMove(state.currentGame.currentPosition())
        state.currentGame.addMove(move)
      except:
        state.info fmt"Invalid move: {params[i]}"
        break

proc go(state: var AttackingUciState, params: seq[string]) =
  if not state.externalEngine.initialized:
    initializeExternalEngine(state)

  # Parse go parameters for time management
  var searchTime = state.searchTime
  var searchDepth = state.searchDepth

  for i in 0..<params.len:
    if i + 1 < params.len:
      case params[i]:
      of "depth":
        searchDepth = params[i + 1].parseInt
      of "movetime":
        searchTime = params[i + 1].parseFloat / 1000.0
      of "wtime", "btime":
        let timeMs = params[i + 1].parseFloat
        searchTime = min(timeMs / 20000.0, 5.0)  # Use 1/20th of remaining time, max 5s
      else:
        discard

  state.searchTime = searchTime
  state.searchDepth = searchDepth

  try:
    let bestMove = selectBestMove(state)
    echo "bestmove ", bestMove
  except:
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

      case params[0]:
      of "uci":
        uci(state)
      of "setoption":
        setOption(state, params[1..^1])
      of "isready":
        if not state.externalEngine.initialized:
          initializeExternalEngine(state)
        echo "readyok"
      of "position":
        setPosition(state, params[1..^1])
      of "go":
        go(state, params[1..^1])
      of "quit":
        break
      of "ucinewgame":
        state.currentGame = newGame()
        if state.externalEngine.initialized:
          state.externalEngine.newGame()
      of "stop":
        # For simplicity, we don't support stopping mid-search
        discard
      else:
        state.info fmt"Unknown command: {params[0]}"

    except EOFError:
      break
    except:
      state.info fmt"Error processing command: {getCurrentExceptionMsg()}"

when isMainModule:
  uciLoop()
