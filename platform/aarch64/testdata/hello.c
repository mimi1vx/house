__asm__(".global _start\n_start:\n mov x0,#1\n adr x1,msg\n mov x2,#15\n svc #0x01\n mov x0,#0\n svc #0x02\n b .\nmsg: .ascii \"Hello from EL0\\n\"\n");
void _start(void) {}
