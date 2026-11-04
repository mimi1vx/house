# Gate flake policy

Policy for `house-fiu.9`. Docs only — no code, no harness change.
Status: accepted; applies to every QEMU gate in `make check` / `make check-tcg` / nightly.

## The rule this phase learned

**A gate that needs a second stabilization commit is a kernel bug report, not a
harness tweak.**

All three stabilizations in a row masked two kernel defects — the
IRQ-forwarding leak (step 3: teardown left a dangling handler that could
`trySend` into a freed endpoint; fixed by `unregisterIrqForwarding` in
`a6818a5`) and the YIELD capability violation (step 5: a spinning `svc #0`
loop never released the pinned RTS capability; fixed by the bounded-backoff
arm in `3e4a5f4`) — and each fix first landed as a workaround in the harness
or a probe. A second stabilization commit against the same gate therefore
stops being harness work: treat it as a kernel bug report, and keep the gate
red until the kernel fix lands.

Supporting case: the EL0 ping-pong probe gained an EAGAIN retry (`3cfce9b`,
house-gq3) before the hvf root cause — a single global `RECORDED_PDIR`
consulted the wrong tables under SMP — was fixed per-core (`45f8a24`,
house-s95).

## Harness-side rules

1. Probes do not emit UART in a retry loop (`6e0b314` — use `len 0` WRITE).
   The svcmask probe's UART spam choked expect while its YIELD flood starved
   the shell, so revoke always landed after the probe gave up. Probing with a
   `len`-0 `WRITE` plus `YIELD` per iteration over a bounded budget keeps the
   probe observable without perturbing the timing under test.

2. A harness never deletes a prompt wait to make a gate green; it converts it
   to `house_prompt` (`03b1066`, now `scripts/house.exp` from house-fiu.7).
   `03b1066` deleted two prompt waits because the EL1 kill log garbled `> `
   into `>[kill]` and deadlocked the wait. The helper matches the prompt
   line-anchored and drains interleaved output, so a stray dmesg line cannot
   eat the prompt. Deleting the wait hides the race; converting it fixes the
   match.

## Reporting rule

A gate that goes red is triaged product-vs-test the same way the
review-shift skills classify openQA jobs — product bug (the kernel under
test is broken) vs test issue (the harness, probe, or infra is broken) — and
the classification is recorded in the commit that fixes it. Unsure counts as
reported, not as flake: a wrong-but-visible ticket beats a silent retry.
The word "flake" never closes a gate on its own; it opens a triage with one
of the two classifications attached.
