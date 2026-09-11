{-# LANGUAGE GHC2024 #-}

module Main (main) where

import Control.Exception (SomeException, catch, evaluate)
import Control.Monad (unless, when)
import Data.Maybe (isJust)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import Userspace.Asm (mkSvc, mkU12, mkW, mkX)
import Userspace.Tool.Cat (catText)
import Userspace.Tool.Echo (echoText)
import Userspace.Tool.Hello (helloText)
import Userspace.Tool.Ls (lsText)
import Userspace.Tool.Mkdir (mkdirText)
import Userspace.Tool.Rm (rmText)
import Userspace.Tool.Stat (statText)
import Userspace.Tool.Write (writeText)

tryRead :: FilePath -> IO (Maybe String)
tryRead p =
  ( do
      s <- readFile p
      -- Force the full contents before comparing (small golden file).
      _ <- evaluate (length s)
      pure (Just s)
  )
    `catch` (\(_ :: SomeException) -> pure Nothing)

pickFile :: String -> IO (FilePath, String)
pickFile name = go [name ++ ".s", "userspace/" ++ name ++ ".s"]
  where
    go [] = do
      hPutStrLn stderr ("golden: " ++ name ++ ".s not found")
      exitFailure
    go (p : ps) = do
      m <- tryRead p
      case m of
        Just s -> pure (p, s)
        Nothing -> go ps

checkGolden :: String -> String -> IO ()
checkGolden name rendered = do
  (path, expected) <- pickFile name
  unless (rendered == expected) $ do
    hPutStrLn stderr ("golden mismatch: rendered " ++ name ++ " /= " ++ path)
    exitFailure
  putStrLn ("golden ok: " ++ name)

main :: IO ()
main = do
  -- Bounds gates: smart constructors reject out-of-range operands.
  when (isJust (mkX 31)) $ do
    hPutStrLn stderr "asm: mkX 31 must be Nothing"
    exitFailure
  when (isJust (mkW 45)) $ do
    hPutStrLn stderr "asm: mkW 45 must be Nothing"
    exitFailure
  when (isJust (mkSvc 0x15)) $ do
    hPutStrLn stderr "asm: mkSvc 0x15 must be Nothing"
    exitFailure
  when (isJust (mkU12 4096)) $ do
    hPutStrLn stderr "asm: mkU12 4096 must be Nothing"
    exitFailure
  -- Golden gates: rendered tools match the checked-in .s byte-for-byte.
  checkGolden "hello" helloText
  checkGolden "echo" echoText
  checkGolden "mkdir" mkdirText
  checkGolden "rm" rmText
  checkGolden "ls" lsText
  checkGolden "stat" statText
  checkGolden "write" writeText
  checkGolden "cat" catText
