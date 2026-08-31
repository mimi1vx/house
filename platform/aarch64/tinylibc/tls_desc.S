    .text
    .global __tlsdesc_static
    .type __tlsdesc_static, %function
// TLSDESC resolver for static TLS (relaxed to LE in final link, but provide for completeness)
// x0 = descriptor address (contains offset)
__tlsdesc_static:
    ldr x0, [x0]
    mrs x1, tpidr_el0
    add x0, x0, x1
    ret
    .size __tlsdesc_static, .-__tlsdesc_static
    .global __aarch64_tlsdesc_resolve
    .type __aarch64_tlsdesc_resolve, %function
__aarch64_tlsdesc_resolve:
    b __tlsdesc_static
    .size __aarch64_tlsdesc_resolve, .-__aarch64_tlsdesc_resolve
