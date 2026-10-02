{-# LANGUAGE ForeignFunctionInterface #-}

{- | Console output with a mirror hook. Boot depends only on this module,
never on a device driver. The virtio-console mirror is installed via
`setConsoleMirror` by the shell's `con mirror` handler, the single site
that knows the driver.
-}
module H.Console (
  c_uart_puts,
  c_uart_puts_raw,
  setConsoleMirror,
  clearConsoleMirror,
)
where

import Control.Exception (SomeException, catch)
import Foreign.C.Types (CChar (..))
import Foreign.Ptr (Ptr)
import H.Monad (H, runH)
import H.Mutable (Ref, newRef, readRef, writeRef)
import H.Unsafe (unsafePerformH)

foreign import ccall unsafe "uart_puts" c_uart_puts_raw :: Ptr CChar -> IO ()

{-# NOINLINE mirrorHook #-}
mirrorHook :: Ref (Maybe (Ptr CChar -> IO ()))
mirrorHook = unsafePerformH $ newRef Nothing

{- | All kernel output flows through here. The mirror hook is best-effort:
exceptions are swallowed so a wedged console never blocks the shell.
-}
c_uart_puts :: Ptr CChar -> IO ()
c_uart_puts p = c_uart_puts_raw p >> mirrorOut p

mirrorOut :: Ptr CChar -> IO ()
mirrorOut p = do
  mHook <- runH (readRef mirrorHook)
  case mHook of
    Nothing -> return ()
    Just f -> f p `catch` (\(_ :: SomeException) -> return ())

-- | Install the console mirror hook (shell `con mirror on` path).
setConsoleMirror :: (Ptr CChar -> IO ()) -> H ()
setConsoleMirror f = writeRef mirrorHook (Just f)

-- | Remove the console mirror hook (shell `con mirror off` path).
clearConsoleMirror :: H ()
clearConsoleMirror = writeRef mirrorHook Nothing
