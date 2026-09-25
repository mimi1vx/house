{-# LANGUAGE GHC2024 #-}

module Main (main) where

import Control.Monad (foldM)
import Data.ByteString qualified as BS
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Kernel.Userspace.Linker qualified as Linker
import Kernel.Userspace.Loader qualified as Ldr
import Numeric (showHex)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (IOMode (ReadMode), hFileSize, hPutStrLn, stderr, withBinaryFile)

main :: IO ()
main = do
  args <- getArgs
  case args of
    [path] -> inspect path
    "link" : mainPath : dependencyPaths -> linkFiles mainPath dependencyPaths
    _ -> do
      hPutStrLn stderr "usage: house-loader-check FILE"
      hPutStrLn stderr "       house-loader-check link MAIN DEPENDENCY..."
      exitFailure

inspect :: FilePath -> IO ()
inspect path = do
  loaded <- loadForCheck path
  case loaded of
    Left err -> failWith err
    Right elf -> printElf elf

linkFiles :: FilePath -> [FilePath] -> IO ()
linkFiles mainPath dependencyPaths = do
  loadedMain <- loadForCheck mainPath
  loadedDependencies <- mapM loadDependency dependencyPaths
  let dependencyResult = sequence loadedDependencies
      dependencyMap = dependencyResult >>= collectDependencies
  case (loadedMain, dependencyMap) of
    (Left err, _) -> failWith (mainPath ++ ": " ++ err)
    (_, Left err) -> failWith err
    (Right mainElf, Right deps) -> case Linker.linkDynamic mainElf deps of
      Left err -> failWith (Ldr.loadErrorToString err)
      Right plan -> printLinkPlan plan

loadDependency :: FilePath -> IO (Either String (FilePath, Ldr.Elf))
loadDependency path = do
  loaded <- loadForCheck path
  pure ((path,) <$> loaded)

collectDependencies :: [(FilePath, Ldr.Elf)] -> Either String (Map String Ldr.Elf)
collectDependencies = foldM add Map.empty
  where
    add dependencies (path, elf) = case Ldr.dynSoname (Ldr.elfDyn elf) of
      Nothing -> Left (path ++ ": dependency has no SONAME")
      Just soname
        | Map.member soname dependencies -> Left (path ++ ": duplicate SONAME " ++ soname)
        | otherwise -> Right (Map.insert soname elf dependencies)

loadForCheck :: FilePath -> IO (Either String Ldr.Elf)
loadForCheck path = do
  bounded <- readBounded path
  case bounded of
    Left err -> pure (Left err)
    Right bytes -> pure $ case Ldr.loadElf (BS.unpack bytes) of
      Left err -> Left (Ldr.loadErrorToString err)
      Right elf -> Right elf

readBounded :: FilePath -> IO (Either String BS.ByteString)
readBounded path =
  withBinaryFile path ReadMode $ \handle -> do
    size <- hFileSize handle
    if size > fromIntegral Ldr.maxElfBytes
      then pure (Left "file exceeds maxElfBytes")
      else do
        bytes <- BS.hGet handle (fromIntegral size)
        if BS.length bytes == fromIntegral size
          then pure (Right bytes)
          else pure (Left "file changed while reading")

printElf :: Ldr.Elf -> IO ()
printElf elf = do
  putStrLn ("elf-type=" ++ if Ldr.elfIsDyn elf then "ET_DYN" else "ET_EXEC")
  putStrLn ("interp=" ++ fromMaybe "<none>" (Ldr.elfInterp elf))
  putStrLn ("soname=" ++ fromMaybe "<none>" (Ldr.dynSoname dyn))
  putStrLn ("needed=" ++ commaJoin (Ldr.dynNeeded dyn))
  putStrLn ("bind-now=" ++ show (Ldr.dynBindNow dyn))
  printHash (Ldr.dynHashStyle dyn)
  case Ldr.dynRelocations dyn of
    [] -> putStrLn "relocations=none"
    tables -> mapM_ printRelocations tables
  where
    dyn = Ldr.elfDyn elf

printHash :: Ldr.HashStyle -> IO ()
printHash style = case style of
  Ldr.NoHash -> putStrLn "hash=none"
  Ldr.SysVHash hash ->
    putStrLn
      ( "hash=sysv"
          ++ " buckets="
          ++ show (Ldr.sysvHashBuckets hash)
          ++ " symbols="
          ++ show (Ldr.sysvHashSymbols hash)
      )

printRelocations :: Ldr.RelocationTable -> IO ()
printRelocations table = do
  let (relative, eager) = relocationCounts (Ldr.relocationTableEntries table)
      kind = case Ldr.relocationTableKind table of
        Ldr.DynamicRelocations -> "dynamic"
        Ldr.PltRelocations -> "plt"
  putStrLn
    ( "relocations="
        ++ kind
        ++ " relative="
        ++ show relative
        ++ " eager="
        ++ show eager
        ++ " total="
        ++ show (relative + eager)
        ++ " offset="
        ++ show (Ldr.relocationTableOffset table)
        ++ " size="
        ++ show (Ldr.relocationTableSize table)
    )

relocationCounts :: [Ldr.Relocation] -> (Int, Int)
relocationCounts = foldr count (0, 0)
  where
    count relocation (relative, eager) = case relocation of
      Ldr.RelativeBinding _ -> (relative + 1, eager)
      Ldr.EagerSymbolBinding _ -> (relative, eager + 1)

printLinkPlan :: Linker.LinkPlan -> IO ()
printLinkPlan plan = do
  mapM_ printPlacedObject (Linker.linkObjects plan)
  mapM_ printRelocationPatch (Linker.linkPatches plan)

printPlacedObject :: Linker.PlacedObject -> IO ()
printPlacedObject object =
  putStrLn
    ( "object="
        ++ Linker.placedObjectName object
        ++ " base=0x"
        ++ showHex (Linker.placedObjectBase object) ""
        ++ " entry=0x"
        ++ showHex (Linker.placedObjectEntry object) ""
    )

printRelocationPatch :: Linker.RelocationPatch -> IO ()
printRelocationPatch relocation =
  putStrLn
    ( "relocation object="
        ++ Linker.patchObject relocation
        ++ " provider="
        ++ Linker.patchProvider relocation
        ++ " symbol="
        ++ fromMaybe "-" (Linker.patchSymbol relocation)
        ++ " type="
        ++ relocationName (Linker.patchRelocation relocation)
        ++ " target=0x"
        ++ showHex (Linker.patchTarget relocation) ""
        ++ " resolved=0x"
        ++ showHex (Linker.patchValue relocation) ""
    )

relocationName :: Linker.LinkRelocation -> String
relocationName relocation = case relocation of
  Linker.LinkRelative -> "R_AARCH64_RELATIVE"
  Linker.LinkGlobDat -> "R_AARCH64_GLOB_DAT"
  Linker.LinkJumpSlot -> "R_AARCH64_JUMP_SLOT"

commaJoin :: [String] -> String
commaJoin [] = "<none>"
commaJoin (first : rest) = first ++ concatMap (',' :) rest

failWith :: String -> IO a
failWith message = do
  hPutStrLn stderr ("house-loader-check: " ++ message)
  exitFailure
