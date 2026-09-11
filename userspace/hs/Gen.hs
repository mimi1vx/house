{-# LANGUAGE GHC2024 #-}

module Main (main) where

import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import Userspace.Tool.Cat (catText)
import Userspace.Tool.Echo (echoText)
import Userspace.Tool.Hello (helloText)
import Userspace.Tool.Ls (lsText)
import Userspace.Tool.Mkdir (mkdirText)
import Userspace.Tool.Rm (rmText)
import Userspace.Tool.Stat (statText)
import Userspace.Tool.Write (writeText)

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["hello"] -> putStr helloText
    ["echo"] -> putStr echoText
    ["mkdir"] -> putStr mkdirText
    ["rm"] -> putStr rmText
    ["ls"] -> putStr lsText
    ["stat"] -> putStr statText
    ["write"] -> putStr writeText
    ["cat"] -> putStr catText
    _ -> do
      hPutStrLn stderr "usage: house-gen hello|echo|mkdir|rm|ls|stat|write|cat"
      exitFailure
