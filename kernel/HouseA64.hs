{-# LANGUAGE ForeignFunctionInterface #-}

module HouseA64 where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Monad (forM_)
import Data.Bits (shiftL)
import Data.Word (Word64)
import Foreign.C.String (peekCString, withCString)
import Foreign.C.Types (CChar (..), CInt (..))
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Ptr (Ptr, plusPtr)
import Foreign.Storable (poke)
import GHC.Conc (getNumCapabilities, getNumProcessors)
import qualified H.FileSystem as FS
import H.Monad (runH)
import qualified Kernel.Driver.Dmesg as Dmesg
import qualified Kernel.Driver.GIC as DGIC
import qualified Kernel.Driver.IRQ as DIRQ
import qualified Kernel.Driver.PL011Server as PL011S
import qualified Kernel.Driver.Registry as DrvReg
import Kernel.Driver.Types (showDriverInfo)
import qualified Kernel.Driver.VirtioProbe as VProbe
import qualified Kernel.IPC.Endpoint as IPC
import qualified Kernel.IPC.Grant as G
import qualified Kernel.IPC.Nameservice as NS
import Kernel.IPC.Types (Message (..))

foreign import ccall "uart_puts" c_uart_puts :: Ptr CChar -> IO ()

foreign import ccall "uart_getc_nonblock" c_getc_nonblock :: IO CInt

foreign import ccall "uart_putc" c_putc :: CChar -> IO ()

foreign import ccall unsafe "house_uptime_secs" c_uptime :: IO Word64

foreign import ccall unsafe "psci_system_off" c_off :: IO ()

foreign import ccall unsafe "psci_system_reset" c_reset :: IO ()

foreign export ccall house_main :: IO ()

house_main :: IO ()
house_main = do
  withCString "Welcome to the House shell! Enter help to see a list of commands.\n\n" c_uart_puts
  _ <- runH FS.fsInit
  _ <- runH Dmesg.dmesgInit
  _ <- runH (Dmesg.dmesgLog "House driver framework online")
  -- Link driver GIC/IRQ helpers into closure (probe-only track keeps them unused at runtime)
  _ <- runH (return (DGIC.enableSpi, DGIC.disableSpi, DIRQ.registerIrqForwarding) >> return ())
  loop
  where
    loop = do
      withCString "> " c_uart_puts
      line <- shellGetLine
      handle line
      loop
    shellGetLine = allocaBytes 256 $ \buf -> go buf 0
      where
        go b n = do
          c <- c_getc_nonblock
          if c == -1
            then go b n
            else
              if c == 13 || c == 10
                then do poke (b `plusPtr` n) (0 :: CChar); withCString "\n" c_uart_puts; peekCString b
                else
                  if c == 127 || c == 8
                    then if n == 0 then go b n else do c_putc 8; c_putc 32; c_putc 8; go b (n - 1)
                    else
                      if n >= 255
                        then go b n
                        else do c_putc (fromIntegral c); poke (b `plusPtr` n) (fromIntegral c :: CChar); go b (n + 1)
    handle line = case words line of
      [] -> return ()
      ("help" : _) -> withCString usage c_uart_puts
      ("echo" : ws) -> handleEcho ws
      ["clear"] -> withCString "\ESC[2J\ESC[H" c_uart_puts
      ["uname"] -> withCString "House/hOp 0.8.93 aarch64 GHC-9.14.1 QEMU-virt\n" c_uart_puts
      ["uptime"] -> do s <- c_uptime; withCString ("up " ++ show s ++ " seconds\n") c_uart_puts
      ("shutdown" : args) -> case args of
        ["-r"] -> c_reset
        ["-h"] -> c_off
        _ -> withCString "usage: shutdown [-h|-r]\n" c_uart_puts
      ["lambda"] -> withCString "Too much to abstract!\n" c_uart_puts
      ["preempt"] -> do withCString (replicate 100 'a' ++ "\n") c_uart_puts; withCString (replicate 100 'b' ++ "\n") c_uart_puts
      ["wastemem", nStr] -> case reads nStr of
        [(n, "")] -> withCString (show (sum [1 .. n :: Integer]) ++ "\n") c_uart_puts
        _ -> withCString "usage: wastemem <number>\n" c_uart_puts
      ["smp"] -> do
        caps <- getNumCapabilities
        procs <- getNumProcessors
        let mask = (1 `shiftL` procs) - 1
        withCString ("smp: " ++ show procs ++ " cores online caps=" ++ show caps ++ " procs=" ++ show procs ++ " timers=PPI27+30 ipi=SGI0 caches=WB onlineMask=0x" ++ showHex mask ++ "\n") c_uart_puts
      ["caps"] -> do caps <- getNumCapabilities; procs <- getNumProcessors; withCString ("caps " ++ show caps ++ " procs " ++ show procs ++ "\n") c_uart_puts
      ["parfib", nStr] -> case reads nStr of
        [(n, "")] -> do v <- parFibIO n; withCString ("parfib " ++ show n ++ " = " ++ show v ++ "\n") c_uart_puts
        _ -> withCString "usage: parfib <n>\n" c_uart_puts
      ["mvar", nStr] -> case reads nStr of
        [(n, "")] -> do ok <- mvarTest n; withCString (if ok then "mvar ok\n" else "mvar fail\n") c_uart_puts
        _ -> withCString "usage: mvar <number>\n" c_uart_puts
      ["ls"] -> handleLs "/"
      ["ls", p] -> handleLs p
      ["cat", p] -> handleCat p
      ["mkdir", p] -> handleMkdir p
      ["rm", p] -> handleRm p
      ["stat", p] -> handleStat p
      ("write" : p : rest) -> handleWrite p (unwords rest)
      ["write"] -> withCString "usage: write <path> <text>\n" c_uart_puts
      ["ns", "ls"] -> handleNsLs
      ["ns", "reg", name] -> handleNsReg name
      ["ns", "reg"] -> withCString "usage: ns reg <name>\n" c_uart_puts
      ["ipc", "ping", name] -> handleIpcPing name
      ["ipc", "ping"] -> withCString "usage: ipc ping <nsName>\n" c_uart_puts
      ["ipc", "grant"] -> handleIpcGrant
      ["ipc"] -> withCString "usage: ipc ping <nsName> | ipc grant\n" c_uart_puts
      ["lsdev"] -> handleLsdev
      ["dmesg"] -> handleDmesg
      ["dmesg", "clear"] -> handleDmesgClear
      ["virtio", "scan"] -> handleVirtioScan
      ["virtio"] -> withCString "usage: virtio scan\n" c_uart_puts
      _ -> withCString ("unknown command: " ++ line ++ "\n") c_uart_puts
    handleEcho ws = case break (== ">") ws of
      (pre, []) -> withCString (unwords pre ++ "\n") c_uart_puts
      (pre, _ : rest) -> case rest of
        [] -> withCString "EINVAL: missing target after >\n" c_uart_puts
        (target : _) -> do
          r <- runH (FS.fsWrite target (unwords pre))
          case r of
            Left e -> withCString (showFsError e ++ "\n") c_uart_puts
            Right () -> return ()
    handleLs p = do
      r <- runH (FS.fsLs p)
      case r of
        Left e -> withCString (showFsError e ++ "\n") c_uart_puts
        Right xs -> withCString (unwords xs ++ "\n") c_uart_puts
    handleCat p = do
      r <- runH (FS.fsRead p)
      case r of
        Left e -> withCString (showFsError e ++ "\n") c_uart_puts
        Right s -> withCString (s ++ "\n") c_uart_puts
    handleMkdir p = do
      r <- runH (FS.fsMkdir p)
      case r of
        Left e -> withCString (showFsError e ++ "\n") c_uart_puts
        Right () -> return ()
    handleRm p = do
      r <- runH (FS.fsRm p)
      case r of
        Left e -> withCString (showFsError e ++ "\n") c_uart_puts
        Right () -> return ()
    handleStat p = do
      r <- runH (FS.fsStat p)
      case r of
        Left e -> withCString (showFsError e ++ "\n") c_uart_puts
        Right st -> withCString (show st ++ "\n") c_uart_puts
    handleWrite p txt = do
      r <- runH (FS.fsWrite p txt)
      case r of
        Left e -> withCString (showFsError e ++ "\n") c_uart_puts
        Right () -> return ()
    handleNsLs = do
      xs <- runH NS.nsList
      withCString (if null xs then "(empty)\n" else unwords xs ++ "\n") c_uart_puts
    handleNsReg name = do
      r <- runH $ do
        -- special-case pl011 launches the server demo
        if name == "pl011"
          then PL011S.launchPL011Server
          else do
            ep <- IPC.newEndpoint
            res <- NS.nsRegister name ep
            case res of
              Left _ -> IPC.freeEndpoint ep >> return res
              Right () -> return res
      case r of
        Left e -> withCString (show e ++ "\n") c_uart_puts
        Right () -> withCString ("registered " ++ name ++ "\n") c_uart_puts
    handleIpcPing name = do
      r <- runH $ do
        mep <- NS.nsLookup name
        case mep of
          Nothing -> return (Left (show name ++ " not found"))
          Just ep -> do
            let msg = Message 0 [42] Nothing
            res <- IPC.call ep msg
            case res of
              Left e -> return (Left (show e))
              Right replyMsg -> return (Right replyMsg)
      case r of
        Left e -> withCString ("ipc ping failed: " ++ e ++ "\n") c_uart_puts
        Right _ -> withCString "ok\n" c_uart_puts
    handleIpcGrant = do
      r <- runH $ do
        mg <- G.grantAlloc
        case mg of
          Left e -> return (Left (show e))
          Right g -> do
            mep <- NS.nsLookup "pl011"
            case mep of
              Nothing -> do
                -- no server yet, just free and report ok (grant alloc succeeded)
                G.grantFree g
                return (Right "ok (no server, grant alloc ok)")
              Just ep -> do
                let msg = Message 1 [] (Just g)
                res <- IPC.call ep msg
                case res of
                  Left e -> do G.grantFree g; return (Left (show e))
                  Right replyMsg -> do
                    -- grant echo: server returns grant, reclaim or free it
                    case G.grantRecv replyMsg of
                      Just g' -> G.grantFree g'
                      Nothing -> return ()
                    return (Right "ok")
      case r of
        Left e -> withCString ("grant failed: " ++ e ++ "\n") c_uart_puts
        Right s -> withCString (s ++ "\n") c_uart_puts
    handleLsdev = do
      ds <- runH DrvReg.listDrivers
      if null ds
        then withCString "(empty)\n" c_uart_puts
        else withCString (unlines (map showDriverInfo ds)) c_uart_puts
    handleDmesg = do
      xs <- runH Dmesg.dmesgRead
      if null xs
        then withCString "(empty)\n" c_uart_puts
        else withCString (unlines xs) c_uart_puts
    handleDmesgClear = do
      _ <- runH Dmesg.dmesgClear
      withCString "cleared\n" c_uart_puts
    handleVirtioScan = do
      infos <- runH VProbe.virtioScan
      let fmt i =
            "virtio slot "
              ++ show (VProbe.vsiSlot i)
              ++ ": "
              ++ ( if VProbe.vsiPresent i
                     then "device_id=" ++ show (VProbe.vsiDeviceId i) ++ " vendor=0x" ++ showHex (fromIntegral (VProbe.vsiVendorId i)) ++ " spi=" ++ maybe "?" show (VProbe.vsiSpi i)
                     else "empty"
                 )
      withCString (unlines (map fmt infos)) c_uart_puts
    showFsError e = case e of
      FS.ENOENT -> "ENOENT: No such file or directory"
      FS.EEXIST -> "EEXIST: File exists"
      FS.ENOTDIR -> "ENOTDIR: Not a directory"
      FS.EISDIR -> "EISDIR: Is a directory"
      FS.ENOSPC -> "ENOSPC: No space left on device"
      FS.EINVAL s -> "EINVAL: " ++ s
    usage =
      unlines
        [ "Usage: help | echo <word>... [> /path] | cat <path> | ls [path] | mkdir <path> | rm <path> | write <path> <text> | stat <path> | clear | uname | uptime | shutdown [-h|-r] -- halt or reboot the machine",
          "       lambda -- lambda demo",
          "       preempt -- preemption demo",
          "       wastemem <number> -- allocate memory",
          "       smp -- show SMP cores online",
          "       caps -- show capabilities",
          "       parfib <n> -- parallel fib",
          "       mvar <n> -- MVar ping-pong test",
          "       ls [path] -- list directory",
          "       cat <path> -- show file",
          "       mkdir <path> -- create directory",
          "       rm <path> -- remove file or empty dir",
          "       write <path> <text> -- write file (truncate)",
          "       stat <path> -- show file stat",
          "       echo <word>... [> /path] -- echo or write via ramfs (volatile 2 MiB pool)",
          "       ns ls -- list IPC names",
          "       ns reg <name> -- register name (pl011 launches server)",
          "       ipc ping <nsName> -- sync call to endpoint",
          "       ipc grant -- alloc one page and send to pl011",
          "       lsdev -- list drivers | dmesg -- kernel log | virtio scan -- probe MMIO slots (0x0a000000+i*0x200)"
        ]
    seqFib :: Int -> Int
    seqFib n
      | n <= 1 = n
      | otherwise = seqFib (n - 1) + seqFib (n - 2)
    parFib :: Int -> Int
    parFib = seqFib
    parFibIO :: Int -> IO Int
    parFibIO n
      | n < 24 = return (parFib n)
      | otherwise = do
          mv <- newEmptyMVar
          _ <- forkIO $ putMVar mv (parFib (n - 1))
          let b = parFib (n - 2)
          a <- takeMVar mv
          return (a + b)
    mvarTest :: Int -> IO Bool
    mvarTest n = do
      m <- newEmptyMVar
      forM_ [1 .. n] $ \_ -> forkIO $ putMVar m (1 :: Int)
      s <- sumMVars n m 0
      return (s == n)
      where
        sumMVars 0 _ acc = return acc
        sumMVars k mv acc = do v <- takeMVar mv; sumMVars (k - 1) mv (acc + v)
    showHex :: Int -> String
    showHex m = let h = "0123456789abcdef" in if m < 16 then [h !! m] else showHex (m `div` 16) ++ [h !! (m `mod` 16)]
