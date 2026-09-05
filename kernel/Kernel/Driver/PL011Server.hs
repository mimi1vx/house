-- | PL011 driver as IPC server demo.
-- Demonstrates drivers-as-servers pattern that driver-framework will generalize.
-- Original Kernel.Driver.PL011 stays intact for comparison.
module Kernel.Driver.PL011Server
  ( launchPL011Server,
  )
where

import Foreign.C.Types (CChar (..))
import H.Concurrency (forkH)
import H.Monad (H, liftIO)
import Kernel.IPC.Endpoint (freeEndpoint, newEndpoint, recv, reply)
import Kernel.IPC.Nameservice (nsRegister)
import Kernel.IPC.Types (IpcError, Message (..))

foreign import ccall unsafe "uart_putc" c_uart_putc :: CChar -> IO ()

-- | Launch PL011 server: new endpoint, register "pl011", loop on recv.
-- Tag 0: putc each msgWords word (truncated to CChar); tag 1: grant echo; else error reply.
-- Lock order: 'newEndpoint' releases @endpointSem@ before 'nsRegister' takes @nsSem@ (sequential, never nested).
launchPL011Server :: H (Either IpcError ())
launchPL011Server = do
  ep <- newEndpoint
  r <- nsRegister "pl011" ep
  case r of
    Left e -> do freeEndpoint ep; return (Left e)
    Right () -> do
      _ <- forkH (loop ep)
      return (Right ())
  where
    loop ep = do
      (msg, rv) <- recv ep
      case msgTag msg of
        0 -> do
          liftIO $ mapM_ (\w -> c_uart_putc (fromIntegral w)) (msgWords msg)
          reply rv (Right (Message 0 [] Nothing))
        1 -> do
          -- grant echo: return grant as-is
          reply rv (Right (Message 1 (msgWords msg) (msgGrant msg)))
        _ -> reply rv (Right (Message 0xFFFFFFFF [] Nothing))
      loop ep
