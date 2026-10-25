/* code_div_d8.c - RV32M divide workload in the D8 convention (owner: D, reviewer: E).
 * PROJECT_BLUEPRINT.md 6.17, D8, F2, F3: no globals, no function calls, no
 * #include; the result is stored to 0x1000_0000, then any store to
 * 0x1000_0004 sets done, then the program loops.
 * Digit sum of 12345 (DIV and REM by 10) = 15; -100 / 7 = -14, -100 % 7 = -2
 * (RISC-V truncates toward zero). Expected result: 15*1000 + 14*10 + 2 = 15142.
 * The divisor 10 is a variable: with a literal 10, gcc (even at -O0) replaces
 * '/' and '%' by a MULH with 0x66666667 and shifts, and the divider is not used.
 * The loop thus runs 5 DIV + 5 REM, plus 1 DIV + 1 REM for -100 / 7.
 * Divide by zero is undefined in C; it is covered in ooo_tests/programs/rv32m_edge.s.
 * Build: make div_d8_im only. Under rv32i gcc turns '/' and '%' into calls to
 * __divsi3/__modsi3, which F2/F3 forbid (make div_d8 stops with an error).
 */
#define MMIO_RESULT (*(volatile int *)0x10000000)
#define MMIO_DONE   (*(volatile int *)0x10000004)

int main(void)
{
    int n = 12345;
    int ten = 10;
    int sum = 0;
    int a = -100;
    int b = 7;
    int q, r;

    while (n != 0) {
        sum = sum + n % ten;
        n = n / ten;
    }
    q = a / b;
    r = a % b;

    MMIO_RESULT = sum * 1000 - q * 10 - r;
    MMIO_DONE = 1;
    for (;;)
        ;
}
