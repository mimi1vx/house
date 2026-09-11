{-# LANGUAGE GHC2024 #-}

{- |
Module      : Userspace.Shim
Description : Host-buildable placeholder for the EL0 svc shim.
Stability   : experimental

Step-2 package shell only: pure helpers so the ten exes link the
library on the host. Step 3 replaces direct I/O with total FFI
wrappers over the existing svc numbers (no new svc, argv arrays only).
-}
module Userspace.Shim (
  helloLine,
  echoLine,
)
where

-- | Exact line the EL0 hello probe asserts.
helloLine :: String
helloLine = "Hello from EL0"

-- | Pure echo join (edge codec stays Latin-1 in the exes).
echoLine :: [String] -> String
echoLine = unwords
