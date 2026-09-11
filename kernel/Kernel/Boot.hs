{-# LANGUAGE GHC2024 #-}

{- |
Module      : Kernel.Boot
Description : Boot sequence extracted from house_main (pid1 slice).

'mounts VFS/RamFS, inits dmesg, probes/unpacks the QEMU initrd, then
'spawnServers' registers/starts the '/etc/house-servers' ELFs.
'Kernel.Init.launchPid1' runs between the two, preserving the
house_main order (unpack -> init -> servers).
-}
module Kernel.Boot (
  boot,
  spawnServers,
)
where

import Control.Monad (forM_)
import Data.Char (chr)
import Data.Word (Word8)
import Foreign.C.String (withCString)
import H.Monad (runH)
import Kernel.Driver.Dmesg qualified as Dmesg
import Kernel.FileSystem.RamFs qualified as RamFs
import Kernel.FileSystem.Vfs qualified as FS
import Kernel.IPC.Endpoint qualified as IPC
import Kernel.IPC.Nameservice qualified as NS
import Kernel.Initramfs qualified as Initrd
import Kernel.Shell.Foreign (c_uart_puts)
import Kernel.Shell.Format (showFsError, toExecError)
import Kernel.Userspace qualified as U
import Kernel.Userspace.Loader qualified as ULdr

-- | Mount root, init dmesg, unpack the QEMU initrd.
boot :: IO ()
boot = do
  _ <- runH (FS.vfsMount FS.defaultNamespace "/" RamFs.ramfsOps)
  _ <- runH (FS.vfsInit FS.defaultNamespace)
  _ <- runH Dmesg.dmesgInit
  _ <- runH (Dmesg.dmesgLog "House driver framework online")
  mInitrd <- runH Initrd.probeInitrd
  case mInitrd of
    Nothing -> return ()
    Just bs -> case Initrd.parseCpio bs of
      Left err -> do
        withCString ("initramfs: parse fail " ++ show err ++ "\n") c_uart_puts
        runH (Dmesg.dmesgLog ("initramfs: parse fail " ++ show err))
      Right entries -> do
        r <- runH (Initrd.unpackEntries FS.defaultNamespace entries)
        case r of
          Left e -> do
            withCString ("initramfs: unpack fail " ++ showFsError e ++ "\n") c_uart_puts
            runH (Dmesg.dmesgLog ("initramfs: unpack fail " ++ showFsError e))
          Right nFiles -> do
            withCString ("initramfs: " ++ show nFiles ++ " files\n") c_uart_puts
            runH (Dmesg.dmesgLog ("initramfs: " ++ show nFiles ++ " files"))

-- | Register + spawn the server manifest ELFs.
spawnServers :: IO ()
spawnServers = do
  mManifest <- runH (FS.vfsRead FS.defaultNamespace "/etc/house-servers")
  case mManifest of
    Left _ -> return ()
    Right bytes -> case Initrd.parseManifest (decodeLatin1 bytes) of
      Left err -> do
        withCString ("servers: manifest fail " ++ err ++ "\n") c_uart_puts
        runH (Dmesg.dmesgLog ("servers: manifest fail " ++ err))
      Right servers ->
        forM_ servers $ \(name, path, epArg) -> do
          r <- runH $ do
            ep <- IPC.newEndpoint
            res <- NS.nsRegister name ep
            case res of
              Left e -> do
                IPC.freeEndpoint ep
                return (Left (show e))
              Right () -> do
                mBytes <- FS.vfsRead FS.defaultNamespace path
                case mBytes of
                  Left e -> do
                    _ <- NS.nsUnregister name
                    IPC.freeEndpoint ep
                    return (Left (showFsError e))
                  Right elfBytes -> case ULdr.loadElf elfBytes of
                    Left le -> do
                      _ <- NS.nsUnregister name
                      IPC.freeEndpoint ep
                      return (Left (toExecError le))
                    Right elf -> do
                      sRes <- U.runElf elf [path, epArg] ["HOUSE=1", "PATH=/bin"]
                      case sRes of
                        Left le2 -> do
                          _ <- NS.nsUnregister name
                          IPC.freeEndpoint ep
                          return (Left (toExecError le2))
                        Right (U.Pid n) -> return (Right n)
          case r of
            Left e -> do
              withCString ("server " ++ name ++ " fail " ++ e ++ "\n") c_uart_puts
              runH (Dmesg.dmesgLog ("server " ++ name ++ " fail " ++ e))
            Right n -> do
              withCString ("server " ++ name ++ " pid " ++ show n ++ "\n") c_uart_puts
              runH (Dmesg.dmesgLog ("server " ++ name ++ " pid " ++ show n))

-- | Shell-edge Latin-1 codec (bytes end-to-end; text converts here only).
decodeLatin1 :: [Word8] -> String
decodeLatin1 bs = [chr (fromIntegral b) | b <- bs]
