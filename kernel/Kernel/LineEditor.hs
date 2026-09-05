module Kernel.LineEditor
  ( LineEditor,
    newEditor,
    getLine,
  )
where

import Control.Monad (unless)
import Data.List (elemIndices, isPrefixOf)
import Data.Set (member)
import H.Concurrency
import qualified H.FileSystem as FS
import H.Monad (H)
import Kernel.Console
import Kernel.Driver.Keyboard (KMod (..), KModSide (..), Key (..), KeyPress (..))
import Kernel.Types.Console (VideoAttributes)
{---
 Loosely based on SimpleLineEditor by Malcom Wallace
 http://www.haskell.org/pipermail/glasgow-haskell-users/2003-June/005370.html
---}
import Prelude hiding (getLine, putChar)

data LineEditorData = LineEditorData
  { editorChan :: Chan KeyPress,
    editorConsole :: Console,
    editorHistory :: MVar [String]
  }

data LineEditor = LineEditor (MVar LineEditorData)

data LineCmd
  = Char Char
  | Move Cursor
  | Delete Cursor
  | Accept
  | History
  | Future
  | Clear
  | Complete
  | NoOp

data Cursor
  = Previous
  | Next
  | Begin
  | End

newEditor :: Chan KeyPress -> Console -> H LineEditor
newEditor chan console =
  do
    vHistory <- newMVar []
    vEditor <-
      newMVar $
        LineEditorData
          { editorChan = chan,
            editorConsole = console,
            editorHistory = vHistory
          }
    return $ LineEditor vEditor

inverseVideo :: VideoAttributes
inverseVideo = 0x71

getLine :: LineEditor -> String -> H String
getLine (LineEditor vEditor) prompt =
  withMVar vEditor $ \editor ->
    do
      let con = editorConsole editor
          -- Cursor invariant: the terminal cursor sits `length before`
          -- past the line start. Every transition redraws from the old
          -- cursor via `redraw`; unchanged state skips redraw entirely.
          gl (before, after) hist = do
            key <- readChan (editorChan editor)
            case translateKey key of
              Char c ->
                if null after
                  then do
                    putChar con c
                    putChar' con inverseVideo ' '
                    clearEOL con
                    moveCursorBackward con 1
                    gl (before ++ [c], []) hist
                  else do
                    redraw before (before ++ [c]) after
                    gl (before ++ [c], after) hist
              Accept ->
                do
                  putString con after
                  clearEOL con
                  putChar con '\n'
                  -- Barrier: the line echo must hit the UART before the
                  -- shell's direct-uart command output, else output glues
                  -- onto the typed line on a real terminal.
                  syncConsole con
                  return (before ++ after)
              Delete Previous ->
                if null before
                  then gl (before, after) hist
                  else do
                    redraw before (init before) after
                    gl (init before, after) hist
              Delete Begin ->
                if null before
                  then gl (before, after) hist
                  else do
                    redraw before [] after
                    gl ([], after) hist
              Delete Next ->
                case after of
                  [] -> gl (before, after) hist
                  _ : cs -> do
                    redraw before before cs
                    gl (before, cs) hist
              Delete End ->
                if null after
                  then gl (before, after) hist
                  else do
                    redraw before before []
                    gl (before, []) hist
              Move Previous ->
                if null before
                  then gl (before, after) hist
                  else do
                    let nb = init before
                        na = last before : after
                    redraw before nb na
                    gl (nb, na) hist
              Move Begin ->
                if null before
                  then gl (before, after) hist
                  else do
                    redraw before [] (before ++ after)
                    gl ([], before ++ after) hist
              Move Next ->
                case after of
                  [] -> gl (before, after) hist
                  c : cs -> do
                    redraw before (before ++ [c]) cs
                    gl (before ++ [c], cs) hist
              Move End ->
                if null after
                  then gl (before, after) hist
                  else do
                    redraw before (before ++ after) []
                    gl (before ++ after, []) hist
              History ->
                case hist of
                  (_, []) -> gl (before, after) hist
                  (fut, p : past) -> do
                    redraw before p []
                    gl (p, []) ((before ++ after) : fut, past)
              Future ->
                case hist of
                  ([], _) -> gl (before, after) hist
                  (f : fut, past) -> do
                    redraw before f []
                    gl (f, []) (fut, (before ++ after) : past)
              Clear ->
                do
                  clearScreen con
                  putString con prompt
                  redraw [] before after
                  gl (before, after) hist
              Complete -> do
                nb <- completeWord before
                if nb == before
                  then gl (before, after) hist
                  else do
                    redraw before nb after
                    gl (nb, after) hist
              _ -> gl (before, after) hist
            where
              -- Back `length oldBefore` to the line start, print the new
              -- buffer with the cursor cell first, clear any ghost suffix
              -- from a longer prior line, then sit back on the cursor.
              redraw oldBefore newBefore newAfter = do
                unless (null oldBefore) $
                  moveCursorBackward con (length oldBefore)
                putString con newBefore
                case newAfter of
                  [] -> do
                    putChar' con inverseVideo ' '
                    clearEOL con
                    moveCursorBackward con 1
                  c : cs -> do
                    putChar' con inverseVideo c
                    putString con cs
                    clearEOL con
                    moveCursorBackward con (length newAfter)
      putString con prompt
      history <- readMVar (editorHistory editor)
      putChar' con inverseVideo ' '
      clearEOL con
      moveCursorBackward con 1
      line <- gl ([], []) ([], history)
      unless (null line)
        $ modifyMVar_ (editorHistory editor)
        $ return . (line :)
      return line

translateKey :: KeyPress -> LineCmd
translateKey (KeyPress modSet key) =
  case key of
    Key c ->
      if (Ctrl LSide) `member` modSet || (Ctrl RSide) `member` modSet
        then case c of
          'a' -> Move Begin
          'e' -> Move End
          'k' -> Delete End
          'u' -> Delete Begin
          'h' -> Delete Previous
          'd' -> Delete Next
          'j' -> Accept
          'l' -> Clear
          _ -> NoOp
        else Char c
    Keypad c -> Char c
    ReturnKey -> Accept
    KeypadEnterKey -> Accept
    BackspaceKey -> Delete Previous
    DeleteKey -> Delete Next
    UpKey -> History
    DownKey -> Future
    LeftKey -> Move Previous
    RightKey -> Move Next
    HomeKey -> Move Begin
    EndKey -> Move End
    TabKey -> Complete
    _ -> NoOp

-- | Read-only path completion: extend the word before the cursor to the
-- longest common prefix of fsLs candidates; single dir match gains "/".
completeWord :: String -> H String
completeWord before = do
  let word = reverse (takeWhile (/= ' ') (reverse before))
      (dir, pref) = splitWord word
  eLs <- FS.fsLs dir
  case eLs of
    Left _ -> return before
    Right names -> do
      let cands = filter (pref `isPrefixOf`) names
      case cands of
        [] -> return before
        [one] -> do
          let full = joinDir dir one
          eSt <- FS.fsStat full
          let slash = case eSt of Right st -> FS.fsIsDir st; _ -> False
              target = one ++ (if slash then "/" else "")
              extra = drop (length pref) target
          return (before ++ extra)
        _ -> do
          let lcp = foldl1 commonPrefix cands
              extra = drop (length pref) lcp
          return (before ++ extra)
  where
    splitWord w = case elemIndices '/' w of
      [] -> ("/", w)
      idxs -> let i = last idxs in (take (i + 1) w, drop (i + 1) w)
    joinDir d n = if not (null d) && last d == '/' then d ++ n else d ++ "/" ++ n
    commonPrefix a b = map fst (takeWhile (uncurry (==)) (zip a b))
