-- | Total parsers for hostile shell/network input.
module Kernel.Shell.Parse (
  Ipv4Error (..),
  parseIpv4,
)
where

import qualified Kernel.Driver.Virtio.Net.Types as NetTypes

-- | IPv4 parse failure; carries the offending input.
data Ipv4Error = BadIpv4 String
  deriving (Eq, Show)

{- | Total dotted-quad parser: 'Right' on four 0-255 octets, 'Left' otherwise.
'reads' at Word8 rejects overflow and empties, so no 'read' partiality.
-}
parseIpv4 :: String -> Either Ipv4Error NetTypes.Ipv4
parseIpv4 s = case splitDot s of
  [a, b, c, d] -> case (reads a, reads b, reads c, reads d) of
    ([(av, "")], [(bv, "")], [(cv, "")], [(dv, "")]) -> Right (NetTypes.Ipv4 av bv cv dv)
    _ -> Left (BadIpv4 s)
  _ -> Left (BadIpv4 s)

-- | Total split on dots; never returns [].
splitDot :: String -> [String]
splitDot = splitOn '.'
  where
    splitOn :: Char -> String -> [String]
    splitOn _ [] = [""]
    splitOn c (x : xs) = case splitOn c xs of
      [] -> [[x]]
      (h : t) -> if x == c then "" : h : t else (x : h) : t
