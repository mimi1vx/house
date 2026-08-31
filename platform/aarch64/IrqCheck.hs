{-# LANGUAGE ForeignFunctionInterface #-}

module IrqCheck where

import Control.Monad (forM_, unless, when)
import Data.IORef (modifyIORef', newIORef, readIORef)
import GHC.Conc (threadDelay)
import H.Interrupts
import H.Monad (H, liftIO, runH)
import H.PhysicalMemory
import H.VirtualMemory

foreign export ccall house_irqcheck_main :: IO ()

-- | IrqCheck kernel: proves GIC dispatch + timer tick delivery.
-- Installs handlers for both timer PPIs (27 virtual, 30 physical), counts
-- invocations, prints both counters periodically, asserts both advanced.
-- Success marker is "irq-ok" (and later "vm-ok" after VM round-trip).
house_irqcheck_main :: IO ()
house_irqcheck_main = runH $ do
  liftIO $ putStrLn "house/aarch64: irq-check start (expect 27+30 ticks)"
  c27 <- liftIO $ newIORef (0 :: Int)
  c30 <- liftIO $ newIORef (0 :: Int)
  installHandler ppiVirtTimer $ liftIO $ modifyIORef' c27 (+ 1)
  installHandler ppiPhysTimer $ liftIO $ modifyIORef' c30 (+ 1)
  enableInt ppiVirtTimer
  enableInt ppiPhysTimer
  enableInterrupts
  -- give timers time to fire: 10ms period, so 2s => ~200 ticks each
  forM_ [1 .. 10 :: Int] $ \i -> do
    liftIO $ threadDelay 200000 -- 200ms
    n27 <- liftIO $ readIORef c27
    n30 <- liftIO $ readIORef c30
    liftIO $ putStrLn $ "irq tick " ++ show i ++ ": virt=" ++ show n27 ++ " phys=" ++ show n30
  n27 <- liftIO $ readIORef c27
  n30 <- liftIO $ readIORef c30
  liftIO $ putStrLn $ "final virt=" ++ show n27 ++ " phys=" ++ show n30
  when (n27 > 5 && n30 > 5)
    $ liftIO
    $ putStrLn "irq-ok"
  when (n27 <= 5 || n30 <= 5)
    $ liftIO
    $ putStrLn
    $ "irq-FAIL virt=" ++ show n27 ++ " phys=" ++ show n30
  -- VM round-trip: allocPageMap / setPage / getPage / unsetPage
  liftIO $ putStrLn "vm: allocPageMap/set/get/unset test"
  vmOk <- vmTest
  if vmOk
    then liftIO $ putStrLn "vm-ok"
    else liftIO $ putStrLn "vm-FAIL"
  -- keep alive briefly so expect can capture; then halt
  liftIO $ threadDelay 200000
  return ()

vmTest :: H Bool
vmTest = do
  mp <- allocPageMap
  case mp of
    Nothing -> liftIO (putStrLn "vm: allocPageMap failed") >> return False
    Just pm -> do
      liftIO $ putStrLn $ "vm: PageMap " ++ show pm
      mpp <- allocPhysPage
      case mpp of
        Nothing -> liftIO (putStrLn "vm: allocPhysPage failed") >> return False
        Just pp -> do
          let v0 = minVAddr
              v1 = minVAddr + 0x1000
              piRO = PageInfo pp False False False
              piRW = PageInfo pp True True True
          ok1 <- setPage pm v0 (Just piRO)
          m1 <- getPage pm v0
          let c1 = ok1 && m1 == Just piRO
          unless c1 $ liftIO $ putStrLn $ "vm: RO mismatch ok=" ++ show ok1 ++ " got=" ++ show m1
          ok2 <- setPage pm v0 (Just piRW)
          m2 <- getPage pm v0
          let c2 = ok2 && m2 == Just piRW
          unless c2 $ liftIO $ putStrLn $ "vm: RW mismatch ok=" ++ show ok2 ++ " got=" ++ show m2
          ok3 <- setPage pm v0 Nothing
          m3 <- getPage pm v0
          let c3 = ok3 && m3 == Nothing
          unless c3 $ liftIO $ putStrLn $ "vm: unset failed ok=" ++ show ok3 ++ " got=" ++ show m3
          ok4 <- setPage pm v1 (Just piRO)
          m4 <- getPage pm v1
          let c4 = ok4 && m4 == Just piRO
          unless c4 $ liftIO $ putStrLn $ "vm: v1 mismatch ok=" ++ show ok4 ++ " got=" ++ show m4
          m0again <- getPage pm v0
          let c5 = m0again == Nothing
          unless c5 $ liftIO $ putStrLn $ "vm: v0 should stay unset got=" ++ show m0again
          mp2 <- allocPageMap
          let c6 = case mp2 of
                Nothing -> False
                Just pm2 -> pm /= pm2
          unless c6 $ liftIO $ putStrLn "vm: second PageMap not distinct"
          let ok = c1 && c2 && c3 && c4 && c5 && c6
          when ok $ liftIO $ putStrLn "vm: round-trip ok"
          return ok
