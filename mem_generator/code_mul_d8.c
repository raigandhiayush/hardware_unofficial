/* code_mul_d8.c - RV32M multiply workload in the D8 convention (owner: D, reviewer: E).
 * PROJECT_BLUEPRINT.md 6.17, D8, F2, F3: no globals, no function calls, no
 * #include; the result is stored to 0x1000_0000, then any store to
 * 0x1000_0004 sets done, then the program loops. Expected result: 5040 (7!).
 * Each MUL depends on the previous one (MUL latency chain, cdb_mul).
 * Build: make mul_d8_im only. Under rv32i gcc turns '*' into a call to
 * __mulsi3, which F2/F3 forbid (make mul_d8 stops with an error).
 */
#define MMIO_RESULT (*(volatile int *)0x10000000)
#define MMIO_DONE   (*(volatile int *)0x10000004)

int main(void)
{
    int f = 1;
    int i;

    for (i = 2; i <= 7; i++)
        f = f * i;

    MMIO_RESULT = f;
    MMIO_DONE = 1;
    for (;;)
        ;
}
