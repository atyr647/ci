/* Traps and recovery: each export either returns or traps; the host calls them in one instance and checks that the process survives every trap. */
volatile int zero;
__attribute__((export_name("ok"))) int ok(void) { return 42; }
__attribute__((export_name("oob"))) int oob(void) { return *(volatile int *)0xFFFFFFF0u; }   /* far outside the 80 MiB linear memory */
__attribute__((export_name("div0"))) int div0(void) { return 100 / zero; }
__attribute__((export_name("unreach"))) void unreach(void) { __builtin_trap(); }
