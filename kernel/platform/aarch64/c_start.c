#include <stdint.h>
#include "HsFFI.h"
#include "uart.h"
#include "irq.h"

extern void house_spike_main(void);

static void uart_puthex(uint64_t v)
{
    static const char digits[] = "0123456789abcdef";
    int i;
    uart_puts("0x");
    for (i = 60; i >= 0; i -= 4)
        uart_putc(digits[(v >> i) & 0xf]);
}

/* Single-core exclusive emulation. Apple HVF exits guest LL/SC ops as
   ISV=0 data aborts (IMPDEF DFSC=0x35) that QEMU forwards into the guest,
   independent of the mapping's attributes; the same class arises on Device
   memory with the MMU off. With one CPU an always-succeeding STXR is
   architecturally sound, so replay the op with ordinary loads/stores.
   Returns 1 if the faulting instruction was an exclusive op we handled. */
static int emu_exclusive(uint32_t w, uint64_t *gpr)
{
    uint32_t op = w & 0xFFE0FC00u;
    int rn = (int)((w >> 5) & 0x1f);
    int rt = (int)(w & 0x1f);
    int rs = (int)((w >> 16) & 0x1f);
    static const int szb[4] = { 1, 2, 4, 8 };
    volatile uint8_t *m = (volatile uint8_t *)gpr[rn];
    int n = szb[(w >> 30) & 3], i;
    uint64_t v;

    switch (op) {
    case 0x08407C00u: case 0x0840FC00u:     /* ldxrb / ldaxrb */
    case 0x48407C00u: case 0x4840FC00u:     /* ldxrh / ldaxrh */
    case 0x88407C00u: case 0x8840FC00u:     /* ldxr w / ldaxr w */
    case 0xC8407C00u: case 0xC840FC00u:     /* ldxr x / ldaxr x */
        v = 0;
        for (i = 0; i < n; i++)
            v |= (uint64_t)m[i] << (8 * i);
        if (rt != 31)
            gpr[rt] = v;                    /* narrow loads zero-extend */
        return 1;
    case 0x08007C00u: case 0x0800FC00u:     /* stxrb / stlxrb */
    case 0x48007C00u: case 0x4800FC00u:     /* stxrh / stlxrh */
    case 0x88007C00u: case 0x8800FC00u:     /* stxr w / stlxr w */
    case 0xC8007C00u: case 0xC800FC00u:     /* stxr x / stlxr x */
        v = rt != 31 ? gpr[rt] : 0;         /* Rt==31 stores XZR */
        for (i = 0; i < n; i++)
            m[i] = (uint8_t)(v >> (8 * i));
        if (rs != 31)
            gpr[rs] = 0;                    /* report exclusive success */
        return 1;
    }
    return 0;
}

/* Vector table landing for synchronous exceptions. Alignment faults
   (DFSC=0x21) are emulated byte-wise — Debian-built GHC archives contain
   q-register struct copies that assume Linux-style 16B data alignment.
    Anything else is fatal and parked. Returns the ELR to continue at. */
uint64_t c_handle_sync(uint64_t esr, uint64_t far, uint64_t elr,
                       uint64_t *gpr, void *fpi)
{
    uint32_t w, t;
    int ec = (int)((esr >> 26) & 0x3f);
    int dfsc = (int)(esr & 0x3f);
    int load = 0, pair = 0, size = 0, mode = 0; /* mode: 0 off,1 post,2 pre */
    int rt, rn, rt2, disp = 0;

    if (ec == 0x25 && dfsc == 0x35 &&
        emu_exclusive(*(volatile uint32_t *)elr, gpr))
        return elr + 4;

    if (ec != 0x25 || dfsc != 0x21) {
        uart_puts("\n[house] fatal sync exception ESR=");
        uart_puthex(esr);
        uart_puts(" FAR=");
        uart_puthex(far);
        uart_puts(" ELR=");
        uart_puthex(elr);
        if (ec == 0x25) {
            int q;
            uart_puts(" INSN=");
            uart_puthex(*(volatile uint32_t *)elr);
            for (q = 0; q <= 30; q++) { /* TEMP: full GPR dump */
                int k;
                char c = q < 10 ? '0' + q : 'a' + q - 10;
                uart_puts(" x");
                uart_putc(c);
                uart_putc('=');
                for (k = 60; k >= 0; k -= 4)
                    uart_putc("0123456789abcdef"[(gpr[q] >> k) & 0xf]);
            }
        }
        uart_puts("\n");
        for (;;)
            __asm__ volatile ("wfi");
    }

    w = *(volatile uint32_t *)elr;
    rn = (int)((w >> 5) & 0x1f);
    rt = (int)(w & 0x1f);
    rt2 = (int)((w >> 10) & 0x1f);

    t = w & 0xFFC00000u;
    switch (t) {
    /* SIMD&FP register pairs (128-bit) */
    case 0xAD400000u: pair = 1; load = 1; size = 16; break;
    case 0xAD000000u: pair = 1;           size = 16; break;
    case 0xACC00000u: pair = 1; load = 1; size = 16; mode = 1; break;
    case 0xAC800000u: pair = 1;           size = 16; mode = 1; break;
    case 0xADE00000u: pair = 1; load = 1; size = 16; mode = 2; break;
    case 0xADA00000u: pair = 1;           size = 16; mode = 2; break;
    case 0xAC400000u: pair = 1; load = 1; size = 16; break; /* ldnp */
    case 0xAC000000u: pair = 1;           size = 16; break; /* stnp */
    /* 64-bit GPR pairs */
    case 0xA9400000u: pair = 1; load = 1; size = 8;  break;
    case 0xA9000000u: pair = 1;           size = 8;  break;
    case 0xA8C00000u: pair = 1; load = 1; size = 8;  mode = 1; break;
    case 0xA8800000u: pair = 1;           size = 8;  mode = 1; break;
    case 0xA9C00000u: pair = 1; load = 1; size = 8;  mode = 2; break;
    case 0xA9800000u: pair = 1;           size = 8;  mode = 2; break;
    }

    if (pair) {
        int imm = (int)((w >> 15) & 0x7f);
        if (imm & 0x40)
            imm -= 0x80;
        disp = imm * size;
    }

    {
        int v = (int)((w >> 26) & 1);
        int gpr_single = v == 0 && ((w >> 27) & 7u) == 7u;
        int fp_single = v == 1 &&
            ((((w >> 24) & 0xFEu) == 0x3Cu) || ((w >> 27) & 7u) == 7u);
        if (pair == 0) {
            if (!(gpr_single || fp_single))
                goto unknown;

            {
                static const int gsz[4] = { 1, 2, 4, 8 };
                static const int fpw[4] = { 16, 16, 4, 8 }; /* V=1: q q s d */
                int opc, grp, idx, imm;

                size = v == 1 ? fpw[(w >> 30) & 3] : gsz[(w >> 30) & 3];
                opc = (int)((w >> 22) & 3);
                grp = (int)((w >> 24) & 3);
                rt2 = -1;
                if (v == 0 && opc == 3) {
                    /* prfm: no architectural effect */
                    goto done_no_wb;
                }
                load = opc & 1;

                if (grp == 1) {               /* unsigned imm12, scaled */
                    mode = 0;
                    disp = (int)((w >> 10) & 0xFFF) * size;
                } else {                      /* imm9 family */
                    idx = (int)((w >> 10) & 3);
                    imm = (int)((w >> 12) & 0xFFF);
                    if (imm & 0x800)
                        imm -= 0x1000;
                    /* 00=unscaled offset, 10=post-index, 11=pre-index */
                    mode = idx == 2 ? 1 : idx == 3 ? 2 : 0;
                    disp = imm;
                }
                goto decoded;
            }
        }
        /* pairs fall through to decoded */
    }
decoded:
    {
        static int emu_count;
        if (emu_count < 64) {
            uart_puts("[");
            uart_puthex(emu_count);
            uart_puts("]");
            uart_puts(w & 0x04000000 ? " L " : " S ");
            uart_puthex(w);
            uart_puts("@");
            uart_puthex(far);
            uart_puts("\n");
        }
        emu_count++;
    }
    {
        volatile uint8_t *m8 = (volatile uint8_t *)far;
        uint64_t *fp = (uint64_t *)fpi;
        uint8_t *rb;
        int i;
        int v_isfp = (int)((w >> 26) & 1);

        if (!pair) {
            /* single load/store: width `size` bytes at [far];
               Rt==31 is XZR for GPRs (loads discard, stores write zero) */
            int is_xzr = !v_isfp && rt == 31;
            uint8_t zero[16] = { 0 };
            rb = v_isfp ? (uint8_t *)&fp[rt * 2]
                        : (is_xzr ? zero : (uint8_t *)&gpr[rt]);
            if (load) {
                if (!v_isfp && !is_xzr)
                    gpr[rt] = 0;   /* narrow loads zero-extend */
                if (!(is_xzr))
                    for (i = 0; i < size; i++)
                        rb[i] = m8[i];
            } else {
                for (i = 0; i < size; i++)
                    m8[i] = rb[i];
            }
        } else if (size == 16) {
            volatile uint64_t *m = (volatile uint64_t *)far;
            if (load) {
                fp[rt * 2] = m[0];
                fp[rt * 2 + 1] = m[1];
                fp[rt2 * 2] = m[2];
                fp[rt2 * 2 + 1] = m[3];
            } else {
                m[0] = fp[rt * 2];
                m[1] = fp[rt * 2 + 1];
                m[2] = fp[rt2 * 2];
                m[3] = fp[rt2 * 2 + 1];
            }
        } else {
            volatile uint64_t *m = (volatile uint64_t *)far;
            /* GPR pairs: Rn==31 is SP, but Rt/Rt2==31 are XZR */
            if (load) {
                if (rt != 31)
                    gpr[rt] = m[0];
                if (rt2 != 31)
                    gpr[rt2] = m[1];
            } else {
                m[0] = rt == 31 ? 0 : gpr[rt];
                m[1] = rt2 == 31 ? 0 : gpr[rt2];
            }
        }

        /* writeback for post/pre index */
        if (mode != 0) {
            if (rn == 31)
                gpr[31] += disp;
            else
                gpr[rn] += disp;
        }
    }
done_no_wb:
    return elr + 4;

unknown:
    uart_puts("\n[house] unhandled alignment fault insn=");
    uart_puthex(w);
    uart_puts(" FAR=");
    uart_puthex(far);
    uart_puts(" ELR=");
    uart_puthex(elr);
    uart_puts("\n");
    for (;;)
        __asm__ volatile ("wfi");
}

void c_handle_irq(uint64_t *gpr, void *fpi)
{
    (void)gpr; (void)fpi;
    uint64_t iar;
    __asm__ volatile("mrs %0, ICC_IAR1_EL1" : "=r"(iar));
    uint32_t intid = (uint32_t)(iar & 0xFFFFFF);
    if (intid == 1023) return; /* spurious */
    if (intid == 27) {
        /* rearm virtual timer and feed tick to RTS via timerfd seam */
        extern volatile uint64_t house_isr_pending;
        extern volatile int house_isr_active;
        __asm__ volatile("msr CNTV_TVAL_EL0, %0" :: "r"((uint64_t)house_timer_interval));
        __asm__ volatile("isb");
        if (house_isr_active) house_isr_pending++;
        house_irq_push(intid);
    } else if (intid == 29 || intid == 30) {
        __asm__ volatile("msr CNTP_TVAL_EL0, %0" :: "r"((uint64_t)house_timer_interval));
        __asm__ volatile("isb");
        house_irq_push(intid);
    } else {
        house_irq_push(intid);
    }
    __asm__ volatile("msr ICC_EOIR1_EL1, %0" :: "r"(iar));
    __asm__ volatile("isb");
}

void fatal_exception(void)
{
    uint64_t esr, far, elr;
    __asm__ volatile ("mrs %0, esr_el1" : "=r" (esr));
    __asm__ volatile ("mrs %0, far_el1" : "=r" (far));
    __asm__ volatile ("mrs %0, elr_el1" : "=r" (elr));
    uart_puts("\n[house] fatal exception ESR=");
    uart_puthex(esr);
    uart_puts(" FAR=");
    uart_puthex(far);
    uart_puts(" ELR=");
    uart_puthex(elr);
    uart_puts("\n");
    for (;;)
        __asm__ volatile ("wfi");
}

__attribute__((weak)) void house_spike_main(void);
__attribute__((weak)) void house_irqcheck_main(void);

void c_start(void)
{
    static int argc = 1;
    static char *argv_vals[] = { "house", 0 };
    static char **argv = argv_vals;

    uart_init();
    uart_puts("[house] c_start: irq_init\n");
    house_irq_init();
    uart_puts("[house] c_start: hs_init\n");
    hs_init(&argc, &argv);
    uart_puts("[house] c_start: calling exported main\n");
    if (house_irqcheck_main)
        house_irqcheck_main();
    else if (house_spike_main)
        house_spike_main();
    else {
        uart_puts("[house] no main\n");
    }
    uart_puts("[house] c_start: returned, halting\n");
    for (;;)
        __asm__ volatile ("wfi");
}
