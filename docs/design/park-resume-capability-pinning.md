# Park/resume capability pinning

An EL0 session runs inside `house_enter_el0`, an *unsafe* FFI call that pins
one RTS capability for the duration of the call. A blocking syscall therefore
cannot block inside the call: parking saves the trap frame into the pid slot
and **returns** through the exit trampoline (`svc_exit_trampoline`), freeing
the capability while the process is parked. Resume re-enters later via
`house_resume_asm` (`rust/crates/house-boot/src/exception.rs`).

Invariant: the park path must return from `house_enter_el0`; the resume path
must re-enter it. Any refactor that turns the trampoline into an in-call loop
(a blocking wait inside the FFI region) pins the capability for the whole
wait and deadlocks every blocking syscall under `-N1`, starves the scheduler
under `-Nn`.

Applies to `house_enter_el0` / `svc_exit_trampoline` / `house_resume_asm`
only; trap-side validators stay non-blocking table lookups by the same rule.
