/* code_xor_d8.c - 'xor' workload ported to the D8 convention (owner: D, reviewer: E).
 * PROJECT_BLUEPRINT.md 6.17, D8, F2, F3: no globals, no function calls, no
 * #include; the result is stored to 0x1000_0000, then any store to
 * 0x1000_0004 sets done, then the program loops. Expected result: 9.
 * Build: make xor_d8 (rv32i, baseline + OoO, D17) or make xor_d8_im (rv32im).
 */
#define MMIO_RESULT (*(volatile int *)0x10000000)
#define MMIO_DONE   (*(volatile int *)0x10000004)

int main(void)
{
    int a = 10;
    int b = 3;
    int c = a ^ b;

    MMIO_RESULT = c;
    MMIO_DONE = 1;
    for (;;)
        ;
}
