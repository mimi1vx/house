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
          gl draw (before, after) len hist = do
            drawLine draw
            key <- readChan (editorChan editor)
            case translateKey key of
              Char c ->
                if null after
                  then do
                    putChar con c
                    putChar' con inverseVideo ' '
                    clearEOL con
                    moveCursorBackward con 1
                    gl False (before ++ [c], []) (len + 1) hist
                  else gl True (before ++ [c], after) (len + 1) hist
              Accept ->
                do
                  putString con before
                  putString con after
                  clearEOL con
                  return (before ++ after)
              Delete Previous ->
                if null before
                  then gl True (before, after) len hist
                  else gl True (init before, after) (len - 1) hist
              Delete Begin ->
                gl True ([], after) (len - length before) hist
              Delete Next ->
                case after of
                  [] -> gl True (before, after) len hist
                  _ : cs -> gl True (before, cs) (len - 1) hist
              Delete End ->
                gl True (before, []) (len - length after) hist
              Move Previous ->
                if null before
                  then gl True (before, after) len hist
                  else
                    gl
                      True
                      (init before, (last before) : after)
                      len
                      hist
              Move Begin ->
                gl True ([], before ++ after) len hist
              Move Next ->
                case after of
                  [] -> gl True (before, after) len hist
                  c : cs -> gl True (before ++ [c], cs) len hist
              Move End ->
                gl True (before ++ after, []) len hist
              History ->
                case hist of
                  (_, []) -> gl True (before, after) len hist
                  (fut, p : past) ->
                    gl
                      True
                      (p, [])
                      (length p)
                      ((before ++ after) : fut, past)
              Future ->
                case hist of
                  ([], _) -> gl True (before, after) len hist
                  (f : fut, past) ->
                    gl
                      True
                      (f, [])
                      (length f)
                      (fut, (before ++ after) : past)
              Clear ->
                do
                  clearScreen con
                  putString con prompt
                  gl True (before, after) len hist
              Complete -> do
                nb <- completeWord before
                gl True (nb, after) (len + (length nb - length before)) hist
              _ -> gl True (before, after) len hist
            where
              drawLine False = return ()
              drawLine True = do
                putString con before
                case after of
                  [] -> do
                    putChar' con inverseVideo ' '
                    clearEOL con
                    moveCursorBackward con 1
                  c : cs -> do
                    putChar' con inverseVideo c
                    putString con cs
                    clearEOL con
                moveCursorBackward con len
      putString con prompt
      history <- readMVar (editorHistory editor)
      line <- gl True ([], []) 0 ([], history)
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
