-- | POSIX-ish shell commands: uname, uptime, shutdown.
module Kernel.Shell.Posix (
  handleUname,
  handleUptime,
  handleShutdown,
)
where

import Data.List (isPrefixOf, nub)
import Foreign.C.String (withCString)
import Kernel.Shell.Foreign (c_off, c_reset, c_uart_puts, c_uptime)

-- | Print uptime seconds.
handleUptime :: IO ()
handleUptime = do
  s <- c_uptime
  withCString ("up " ++ show s ++ " seconds\n") c_uart_puts

-- | Halt or reboot; usage otherwise.
handleShutdown :: [String] -> IO ()
handleShutdown args = case args of
  ["-r"] -> c_reset
  ["-h"] -> c_off
  _ -> withCString "usage: shutdown [-h|-r]\n" c_uart_puts

handleUname :: [String] -> IO ()
handleUname args = do
  let sysname = "House"
      nodename = "house"
      release = "0.8.93"
      version = "#1 SMP 2026-09-01 House/hOp GHC-9.14.1 QEMU-virt"
      machine = "aarch64"
      processor = "aarch64"
      hw = "QEMU-virt"
      os = "House"
      canon = "snrvmpio" :: String
      merge sel flags =
        let combined = nub (sel ++ flags)
         in filter (`elem` combined) canon
      flagToStr c = case c of
        's' -> sysname
        'n' -> nodename
        'r' -> release
        'v' -> version
        'm' -> machine
        'p' -> processor
        'i' -> hw
        'o' -> os
        _ -> ""
      unameHelp =
        unlines
          [ "Usage: uname [OPTION]..."
          , "Print certain system information.  With no OPTION, same as -s."
          , ""
          , "  -a, --all                print all information, in the following order,"
          , "                             except omit -p and -i if unknown:"
          , "                             -s -n -r -v -m -p -i -o"
          , "  -s, --kernel-name        print the kernel name"
          , "  -n, --nodename           print the network node hostname"
          , "  -r, --kernel-release     print the kernel release"
          , "  -v, --kernel-version     print the kernel version"
          , "  -m, --machine            print the machine hardware name"
          , "  -p, --processor          print the processor type"
          , "  -i, --hardware-platform  print the hardware platform"
          , "  -o, --operating-system   print the operating system"
          , "      --help               display this help and exit"
          , "      --version            output version information and exit"
          ]
      unameVersionStr = sysname ++ " " ++ release ++ " (" ++ version ++ ") " ++ machine ++ "\n"
      parse [] sel = Right sel
      parse (a : as) sel
        | a == "--help" = Left unameHelp
        | a == "--version" = Left unameVersionStr
        | a == "--all" || a == "-a" = parse as (merge sel canon)
        | a == "--kernel-name" = parse as (merge sel "s")
        | a == "--nodename" = parse as (merge sel "n")
        | a == "--kernel-release" = parse as (merge sel "r")
        | a == "--kernel-version" = parse as (merge sel "v")
        | a == "--machine" = parse as (merge sel "m")
        | a == "--processor" = parse as (merge sel "p")
        | a == "--hardware-platform" = parse as (merge sel "i")
        | a == "--operating-system" = parse as (merge sel "o")
        | "-" `isPrefixOf` a && not ("--" `isPrefixOf` a) =
            let flags = drop 1 a
             in if null flags
                  then Left ("uname: invalid option -- '" ++ a ++ "'\nTry 'uname --help' for more information.\n")
                  else
                    let bad = filter (`notElem` canon) flags
                     in case bad of
                          (b : _) -> Left ("uname: invalid option -- '" ++ [b] ++ "'\nTry 'uname --help' for more information.\n")
                          [] -> parse as (merge sel flags)
        | otherwise = Left ("uname: extra operand '" ++ a ++ "'\nTry 'uname --help' for more information.\n")
  case parse args [] of
    Left msg -> withCString msg c_uart_puts
    Right [] -> withCString (sysname ++ "\n") c_uart_puts
    Right sel -> withCString (unwords (map flagToStr (filter (`elem` sel) canon)) ++ "\n") c_uart_puts
