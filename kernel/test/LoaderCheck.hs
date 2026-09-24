{-# LANGUAGE GHC2024 #-}

module Main (main) where

import Data.ByteString qualified as BS
import Data.Maybe (fromMaybe)
import Kernel.Userspace.Loader qualified as Ldr
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (IOMode (ReadMode), hFileSize, hPutStrLn, stderr, withBinaryFile)

main :: IO ()
main = do
  args <- getArgs
  case args of
    [path] -> inspect path
    _ -> do
      hPutStrLn stderr "usage: house-loader-check FILE"
      exitFailure

inspect :: FilePath -> IO ()
inspect path = do
  bounded <- readBounded path
  case bounded of
    Left err -> do
      hPutStrLn stderr ("house-loader-check: " ++ err)
      exitFailure
    Right bytes -> case Ldr.loadElf (BS.unpack bytes) of
      Left err -> do
        hPutStrLn stderr ("house-loader-check: " ++ Ldr.loadErrorToString err)
        exitFailure
      Right elf -> printElf elf

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

commaJoin :: [String] -> String
commaJoin [] = "<none>"
commaJoin (first : rest) = first ++ concatMap (',' :) rest
