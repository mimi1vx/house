-- | Pure shell formatting helpers shared by HouseA64 and Shell modules.
module Kernel.Shell.Format (
  hexDigit,
  showHex,
  showHex64,
  showFsError,
  toExecError,
)
where

import Data.Word (Word64)
import qualified H.FileSystem as FS
import qualified Kernel.Userspace.Loader as ULdr

-- | Total hex digit; the index is always reduced mod 16.
hexDigit :: Int -> Char
hexDigit n = case n `mod` 16 of
  0 -> '0'
  1 -> '1'
  2 -> '2'
  3 -> '3'
  4 -> '4'
  5 -> '5'
  6 -> '6'
  7 -> '7'
  8 -> '8'
  9 -> '9'
  10 -> 'a'
  11 -> 'b'
  12 -> 'c'
  13 -> 'd'
  14 -> 'e'
  15 -> 'f'
  _ -> '0'

-- | Hex without prefix; output identical to the previous showHex.
showHex :: Int -> String
showHex m
  | m < 16 = [hexDigit m]
  | otherwise = showHex (m `div` 16) ++ [hexDigit (m `mod` 16)]

showHex64 :: Word64 -> String
showHex64 w
  | w == 0 = "0"
  | otherwise = go w
  where
    go n
      | n < 16 = [hexDigit (fromIntegral n)]
      | otherwise = go (n `div` 16) ++ [hexDigit (fromIntegral (n `mod` 16))]

showFsError :: FS.FsError -> String
showFsError e = case e of
  FS.ENOENT -> "ENOENT: No such file or directory"
  FS.EEXIST -> "EEXIST: File exists"
  FS.ENOTDIR -> "ENOTDIR: Not a directory"
  FS.EISDIR -> "EISDIR: Is a directory"
  FS.ENOSPC -> "ENOSPC: No space left on device"
  FS.EINVAL s -> "EINVAL: " ++ s

toExecError :: ULdr.LoadError -> String
toExecError le = case le of
  ULdr.BadMagic -> "EBADEXEC: not ELF64 LE"
  ULdr.BadArch -> "EBADEXEC: need AArch64"
  ULdr.BadType -> "EBADEXEC: need ET_EXEC"
  _ -> ULdr.loadErrorToString le
