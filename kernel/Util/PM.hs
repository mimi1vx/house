module Util.PM (PM, tokenP, manyP, parsePM, runPM, render') where

import Control.Applicative (Alternative (..))
import Control.Monad (MonadPlus (..), ap, liftM)
import Text.PrettyPrint

{-+
An implementation of fairly conventional monadic parsing combinators
--------------------------------------------------------------------

This fairly simple. There is a complication in the error to case get
descent error messages.

On success, a parser function returns the result and the remaining input.
On error, the parser function returns the list of acceptable tokens
at the high water mark, and the remaining input.
-}
newtype PM res
  = PM {unPM :: [String] -> Either ([String], [String]) (res, [String])}

runPM :: (MonadFail m) => PM (m a) -> [String] -> m a
runPM p = either fail id . parsePM p

parsePM :: PM b -> [String] -> Either [Char] b
parsePM p args =
  case unPM p args of
    Right (r, []) -> Right r
    Right (_, rest) -> Left $ "Unrecognized arguments: " ++ unwords rest
    Left (rest, errs) ->
      Left
        $ ('\n' :)
        $ render'
        $ text expected
          <+> fsep (map text errs)
          $$ (if null rest then Text.PrettyPrint.empty else text "Found: " <+> fsep (map text rest))
          $$ text ""
      where
        expected =
          if length errs == 1
            then "Expected:"
            else "Expected one of:"

instance Functor PM where fmap = liftM

instance Applicative PM where
  pure x = PM $ \args -> Right (x, args)
  (<*>) = ap

instance Monad PM where
  PM p1 >>= xp2 = PM $ \args -> case p1 args of
    Left err -> Left err
    Right (x, args') -> unPM (xp2 x) args'

instance MonadFail PM where
  fail s = PM $ \args -> Left (args, [s])

instance Alternative PM where
  empty = fail "no parse"
  (<|>) = mplus

instance MonadPlus PM where
  mzero = fail "no parse" -- Hmm. Error message should say what was expected
  mplus (PM p1) (PM p2) =
    PM $ \args -> case (p1 args, p2 args) of
      (Right res, _) -> Right res
      (r1@(Left (a1, errs1)), r2@(Left (a2, errs2))) ->
        case compare (length a1) (length a2) of
          LT -> r1
          EQ -> Left (a1, errs1 ++ errs2)
          GT -> r2
      (_, r2) -> r2

get :: PM [String]
get = PM $ \args -> Right (args, args)

set :: [String] -> PM ()
set args = PM $ \_ -> Right ((), args)

tokenP :: (String -> Maybe b) -> String -> PM b
tokenP check errmsg =
  do
    args <- get
    case args of
      a : as ->
        maybe
          (fail errmsg)
          (\x -> set as >> return x)
          (check a)
      [] -> fail errmsg

manyP :: (MonadPlus m) => m a -> m [a]
manyP p = ((:) `fmap` p `ap` manyP p) `mplus` return []

render' :: Doc -> [Char]
render' = expandTabs . render
  where
    expandTabs = concatMap expand
    expand '\t' = "        "
    expand c = [c]
