{- | Bounded device-poll ceiling for one virtio-blk request.

'awaitCompletion' is the retry loop 'Kernel.Driver.Virtio.Blk.Server' runs
inline, with the poll action injected so the bound is host-testable without a
device. The loop stops on the first poll that reports the request finished, so
the ceiling bounds the *failure* path only: a completing request never waits
more than one interval.
-}
module Kernel.Driver.Virtio.Blk.Completion (
  blkPollIntervalUs,
  blkPollCeilingUs,
  blkPollAttempts,
  awaitCompletion,
)
where

import H.Concurrency qualified as HC
import H.Monad (H)
import Kernel.Driver.Virtio.Blk.Types (BlkError (..))

{- | Gap between completion polls (us). Used-ring completion is IRQ-driven, so
this is only the fallback for a poll that outruns the IRQ.
-}
blkPollIntervalUs :: Int
blkPollIntervalUs = 200

{- | Total poll budget before a request is declared failed (us), i.e. 100 polls.

A completing request returns on the first poll, so the ceiling bounds the
*failure* path and nothing else; @blk read@ latency is unaffected by it.
Chosen against the 10 ms @blk read@ round-trip measured under TCG at
SPIKE_MEM=4G on 2026-10-07 — 2x that. The 8 ms ceiling considered first sits
below the measured TCG round-trip, which would turn a slow-but-successful
completion into a spurious @BlkIoError 99@. The untuned budget this replaces
was 200 x 2 ms = 400 ms.
-}
blkPollCeilingUs :: Int
blkPollCeilingUs = 20000

-- | Polls a request gets before the budget runs out.
blkPollAttempts :: Int
blkPollAttempts = blkPollCeilingUs `div` blkPollIntervalUs

-- | Reported once the budget is spent with no completion.
blkPollTimeout :: BlkError
blkPollTimeout = BlkIoError 99

{- | Poll @poll@ at most 'blkPollAttempts' times, 'blkPollIntervalUs' apart.
@poll@ answers @Right True@ when the request is done, @Right False@ while it
is still outstanding, and @Left@ on a device error, which returns at once.
-}
awaitCompletion :: H (Either BlkError Bool) -> H (Either BlkError ())
awaitCompletion poll = go blkPollAttempts
  where
    go 0 = return (Left blkPollTimeout)
    go n = do
      HC.threadDelay blkPollIntervalUs
      r <- poll
      case r of
        Left e -> return (Left e)
        Right True -> return (Right ())
        Right False -> go (n - 1)
