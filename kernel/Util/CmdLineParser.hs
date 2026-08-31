{-+
Command-Line Parsing Combinators
================================
-}
module Util.CmdLineParser
  ( -- Parser type:
    P,
    -- Parser constructors:
    token,
    cmd,
    (!),
    (<@),
    (#@),
    chk,
    nil,
    oneof,
    many,
    arg,
    kw,
    opt,
    flag,
    readP,
    named,
    path,
    number,
    (-:),
    -- Parser destructors:
    -- run,
    usage,
    parseAll,
  )
where

import Control.Monad (MonadPlus (..), ap)
import Data.Maybe (isJust)
import Text.PrettyPrint
import Util.Grammar
-- import System(getArgs)
import Util.PM

infixl 3 <@, `chk`, #@

infix 2 -:

infixr 1 !

{-+
The Parser Data Type
--------------------
-}
data P res = P Grammar (PM res)

instance Functor P where fmap f (P g p) = P g (fmap f p)

{-+
Parsing combinators
-------------------
-}

nil :: res -> P res
nil x = P Empty (return x)

(<@) :: P (a -> res) -> P a -> P res
P g1 f <@ P g2 a = P (Seq g1 g2) (f `ap` a)

named :: String -> P res -> P res
named nt (P g p) = P (Nonterminal nt g) p

(-:) :: P res -> String -> P res
P g p -: descr = P (g :--- descr) p

token :: (String -> Maybe res) -> String -> P res
token f s = P (Terminal s) (tokenP f s)

(!) :: P res -> P res -> P res
P g1 p1 ! P g2 p2 = P (Alt g1 g2) (p1 `mplus` p2)

many :: P a -> P [a]
many (P g p) = P (Many g) (manyP p)

opt :: P a -> P (Maybe a)
opt (P g p) = P (Opt g) (fmap Just p `mplus` return Nothing)

oneof :: [P res] -> P res
oneof = foldr1 (!)

chk :: P res -> P a -> P res
chk p p' = const `fmap` p <@ p'

cmd :: String -> res -> P res
cmd s p = nil p `chk` kw s

(#@) :: (Functor f) => (a -> b) -> f a -> f b
f #@ p = fmap f p

arg :: String -> P String
arg = token Just

kw :: String -> P ()
kw s = token check s
  where
    check a = if a == s then Just () else Nothing

readP :: (Read res) => String -> P res
readP desc = token test desc
  where
    test s = case reads s of
      (x, "") : _ -> Just x
      _ -> Nothing

flag :: String -> P Bool
flag s = isJust `fmap` opt (kw s)

{-+
Common tokens
-}
number :: (Read a, Num a) => P a
number = readP "<number>"

path :: P String
path = arg "<path>"

{-+
Extracting the documentation from a grammar
------------------------------------------
-}

usage :: String -> P res -> [Char]
usage prefix = render' . usageDoc prefix

usageDoc :: String -> P res -> Doc
usageDoc prefix (P g _) =
  ( text "Usage:"
      $$ nest
        2
        ( nest 2 (text prefix <+> main)
            $$ if null aux then empty else text "where" $$ vcat aux
        )
  )
  where
    (main, aux) = ppGrammar g

{-+
Running a parser
----------------
-}
-- run p = parseAll p =<< getArgs

parseAll :: P b -> [String] -> Either [Char] b
parseAll (P _g p) = parsePM p
