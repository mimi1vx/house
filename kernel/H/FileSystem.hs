{-# LANGUAGE GHC2024 #-}

{- | Thin shim over the VFS default namespace.

RamFS logic lives in 'Kernel.FileSystem.RamFs' as 'ramfsOps'; this
module preserves the historical 'H.FileSystem' API by routing every
call through 'Vfs.defaultNamespace' (RamFS mounted at @/@). New code
should import 'Kernel.FileSystem.Vfs' directly with an explicit
namespace.
-}
module H.FileSystem (
  FsError (..),
  FsStat (..),
  fsInit,
  fsCreate,
  fsMkdir,
  fsWrite,
  fsRead,
  fsLs,
  fsRm,
  fsStat,
  splitPath,
  freePageCount,
)
where

import Data.Word (Word8)
import H.Monad (H)
import Kernel.FileSystem.RamFs qualified as RamFs
import Kernel.FileSystem.Vfs (
  FsError (..),
  FsStat (..),
  defaultNamespace,
  splitPath,
  vfsCreate,
  vfsInit,
  vfsLs,
  vfsMkdir,
  vfsMount,
  vfsRead,
  vfsRm,
  vfsStat,
  vfsWrite,
 )

-- | Reset the default namespace (RamFS at @/@) to empty.
fsInit :: H ()
fsInit = do
  _ <- vfsMount defaultNamespace "/" RamFs.ramfsOps
  vfsInit defaultNamespace

fsCreate :: FilePath -> H (Either FsError ())
fsCreate = vfsCreate defaultNamespace

fsMkdir :: FilePath -> H (Either FsError ())
fsMkdir = vfsMkdir defaultNamespace

fsWrite :: FilePath -> [Word8] -> H (Either FsError ())
fsWrite = vfsWrite defaultNamespace

fsRead :: FilePath -> H (Either FsError [Word8])
fsRead = vfsRead defaultNamespace

fsLs :: FilePath -> H (Either FsError [String])
fsLs = vfsLs defaultNamespace

fsRm :: FilePath -> H (Either FsError ())
fsRm = vfsRm defaultNamespace

fsStat :: FilePath -> H (Either FsError FsStat)
fsStat = vfsStat defaultNamespace

-- | Re-export pool observability for IPC coexistence checks.
freePageCount :: H Int
freePageCount = RamFs.ramfsFreePages
