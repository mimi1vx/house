// EL0 yield probe for the park/resume delegation ring (plans/multiprocess.md
// step 4). Parks 3x via `svc #0` (YIELD); the counter lives in x19, which the
// kernel preserves across the EL0 session, so a correct resume keeps it.
// After 3 parks it emits one `svc #1` write and exits with the counter as the
// exit code: `run /bin/yield` must print `yield ok` + `ok exit 3`.
.arch armv8-a
.text
.global _start
.type _start, %function
_start:
    mov     x19, #0
park_loop:
    svc     #0                  // YIELD: park, resume with x0 = 0
    add     x19, x19, #1
    cmp     x19, #3
    b.lt    park_loop
    adrp    x1, ymsg
    add     x1, x1, :lo12:ymsg
    mov     x2, #9
    mov     x0, #1
    svc     #1                  // WRITE(1, "yield ok\n", 9)
    mov     x0, x19             // exit code = park count (3 when correct)
    svc     #2                  // EXIT
ymsg:
    .ascii  "yield ok\n"

    // Scratch data word: keeps the linker's data PT_LOAD non-empty so
    // repack.py sees the hello-style (R+E text + RW data) shape.
    .data
    .align 3
scratch:
    .quad   0
