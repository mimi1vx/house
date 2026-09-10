{-# LANGUAGE GHC2024 #-}

{- | Unpack parsed cpio entries into a VFS namespace.

Entries are confined through 'Vfs.splitPath' into the explicit
namespace; directories are created before files; payloads are written
as bytes end-to-end (no text detour). Non-file/dir modes are skipped.
-}
module Kernel.Initramfs.Unpack (
  unpackEntries,
  parseManifest,
  maxManifestEntries,
)
where

import Data.Bits ((.&.))
import H.Monad (H)
import Kernel.FileSystem.Vfs (FsError (..), NamespaceId, splitPath, vfsMkdir, vfsWrite)
import Kernel.Initramfs.Cpio (CpioEntry (..))

-- | Unpack entries; returns the number of files written.
unpackEntries :: NamespaceId -> [CpioEntry] -> H (Either FsError Int)
unpackEntries ns es = do
  let (dirs, files) = ([e | e <- es, isDirMode (entryMode e)], [e | e <- es, isFileMode (entryMode e)])
  rd <- makeDirs ns dirs
  case rd of
    Left e -> return (Left e)
    Right () -> writeFiles ns files 0
  where
    isDirMode m = (m .&. 0o170000) == 0o040000
    isFileMode m = (m .&. 0o170000) == 0o100000

makeDirs :: NamespaceId -> [CpioEntry] -> H (Either FsError ())
makeDirs _ [] = return (Right ())
makeDirs ns (e : rest) = case toComps (entryName e) of
  Left err -> return (Left err)
  Right comps -> do
    r <- ensureHierarchy ns comps
    case r of
      Left err -> return (Left err)
      Right () -> makeDirs ns rest

writeFiles :: NamespaceId -> [CpioEntry] -> Int -> H (Either FsError Int)
writeFiles _ [] n = return (Right n)
writeFiles ns (e : rest) n = case toComps (entryName e) of
  Left err -> return (Left err)
  Right comps -> case comps of
    [] -> return (Left (EINVAL "empty path"))
    _ -> do
      r <- ensureHierarchy ns (init comps)
      case r of
        Left err -> return (Left err)
        Right () -> do
          w <- vfsWrite ns (render comps) (entryData e)
          case w of
            Left err -> return (Left err)
            Right () -> writeFiles ns rest (n + 1)

{- | Confine a raw entry name through 'splitPath' ('.'/'..' collapse,
overlong names rejected).
-}
toComps :: String -> Either FsError [String]
toComps name = splitPath ('/' : stripDotSlash name)

stripDotSlash :: String -> String
stripDotSlash s = case s of
  ('.' : '/' : rest) -> stripDotSlash rest
  ['.'] -> []
  _ -> s

render :: [String] -> FilePath
render [] = "/"
render cs = '/' : joinWith "/" cs
  where
    joinWith _ [] = ""
    joinWith _ [x] = x
    joinWith sep (x : xs) = x ++ sep ++ joinWith sep xs

-- | Create each prefix level; existing directories are fine.
ensureHierarchy :: NamespaceId -> [String] -> H (Either FsError ())
ensureHierarchy _ [] = return (Right ())
ensureHierarchy ns comps = go prefixes
  where
    prefixes = [take i comps | i <- [1 .. length comps]]
    go [] = return (Right ())
    go (p : ps) = do
      r <- vfsMkdir ns (render p)
      case r of
        Right () -> go ps
        Left EEXIST -> go ps
        Left err -> return (Left err)

-- Manifest ---------------------------------------------------------------------

-- | Server manifest entry cap: 64 lines.
maxManifestEntries :: Int
maxManifestEntries = 64

{- | Parse `/etc/house-servers` (Latin-1 text at the edge): lines of
@name path endpoint@, `#` comments, blank lines skipped. Names match
the nameservice rules (non-empty, ≤255, no `/`); paths must be
absolute with no `..` component and pass 'splitPath'.
-}
parseManifest :: String -> Either String [(String, FilePath, String)]
parseManifest s
  | length entries > maxManifestEntries = Left "too many servers"
  | otherwise = mapM parseLine entries
  where
    clean = filter (/= '\r') s
    entries = filter isEntry (lines clean)
    isEntry ln = case ln of
      [] -> False
      ('#' : _) -> False
      _ -> True
    parseLine ln = case words ln of
      [name, path, ep] -> do
        checkName name
        checkPath path
        if null ep then Left "empty endpoint arg" else Right (name, path, ep)
      _ -> Left ("bad line: " ++ take 32 ln)
    checkName name
      | length name > 255 = Left "name too long"
      | '/' `elem` name = Left "name contains '/'"
      | otherwise = Right ()
    checkPath path = case path of
      ('/' : _) ->
        let raw = splitOn '/' path
         in if ".." `elem` raw
              then Left "dotdot in path"
              else case splitPath path of
                Left _ -> Left "bad path"
                Right [] -> Left "empty path"
                Right _ -> Right ()
      _ -> Left "path must be absolute"

splitOn :: Char -> String -> [String]
splitOn d str = case break (== d) str of
  (pre, []) -> [pre]
  (pre, _ : rest) -> pre : splitOn d rest
