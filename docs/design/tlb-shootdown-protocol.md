# TLB shootdown protocol

Single initiator per lock domain. `house_tlb_shootdown` stamps a generation
from `TLB_SD_SEQ`, sends SGI 1 to every online peer except self, and waits
until each peer's slot in `TLB_SD_ACK` reaches the stamped generation.

Acks are wrapping-aware: a peer that has already acknowledged a newer
generation satisfies an older requester (`ack.wrapping_sub(seq) <
0x80000000`). This is correct for a single initiator because generations are
monotonic per lock domain; a newer ack implies the peer flushed after the
older request's `tlbi`, which covers the older VA.

Core indexing folds `MPIDR_EL1.AFF0` onto 32 slots (`mpidr & 0xFF) & 31`).
Both the requester loop (`0..32`) and the ack store derive the slot from
`core_slot`, so they agree for every AFF0 value. The guest supports at most
32 cores; higher AFF0 values alias onto the same 32 slots by construction.

A core that goes offline cannot ack; the requester drops it from the pending
set rather than hanging. Peers signal `sev` after acking so the requester
sleeps in `wfe` instead of spinning.
