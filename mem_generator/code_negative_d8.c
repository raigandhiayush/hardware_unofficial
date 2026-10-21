/* code_negative_d8.c - 'negative' workload ported to the D8 convention (owner: D, reviewer: E).
 * PROJECT_BLUEPRINT.md 6.17, D8, F2, F3: no globals, no function calls, no
 * #include; the result is stored to 0x1000_0000, then any store to
 * 0x1000_0004 sets done, then the program loops. Expected result: -46 (0xFFFFFFD2).
 * Build: make negative_d8 (rv32i, baseline + OoO, D17) or make negative_d8_im (rv32im).
 */
#define MMIO_RESULT (*(volatile int *)0x10000000)
#define MMIO_DONE   (*(volatile int *)0x10000004)

int main(void)
{
    int a = 4;
    int b = 50;
    int c = a - b;

    MMIO_RESULT = c;
    MMIO_DONE = 1;
    for (;;)
        ;
}
