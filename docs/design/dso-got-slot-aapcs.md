# DSO GOT slot: refuted AAPCS premise

A non-main object's GOT slot once appeared to resolve into the wrong page:
a DSO routine calling through its own GOT looped inside its own text, which
reads exactly like "the PLT branched back into the DSO instead of into its
provider". The premise was that the loader had mis-mapped the GOT page.

It had not. The routine was `bl callee; ret` without saving `x30`, so the
trailing `ret` returned to the `bl`'s own return address and re-entered
itself with `x30 == pc` forever. The mapping was verified page-by-page
through the gdb stub (`TTBR0` walk to the data page, `xp` read-back equals
the link resolved value); no flush was added anywhere.

Discriminator: `info registers` during the wedge shows `pc` at the routine's
own `ret` with `x30 == pc` and the PLT leftovers (`x16` = GOT slot address,
`x17` = resolved target) proving the GOT read succeeded and the branch had
already reached the provider before the bad return.

Recorded because a refuted premise is otherwise re-derived: a PC inside the
DSO proves nothing about the GOT mapping until `x30` is checked.
