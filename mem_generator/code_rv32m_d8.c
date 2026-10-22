/* code_rv32m_d8.c - the remaining RV32M operations in the D8 convention (owner: D, reviewer: E).
 * PROJECT_BLUEPRINT.md 6.17, D8, F2, F3: no globals, no function calls, no
 * #include; the result is stored to 0x1000_0000, then any store to
 * 0x1000_0004 sets done, then the program loops.
 * Result is a pass mask, one bit per check; expected 0x7F. A missing bit names
 * the failing operation:
 *   bit 0 MUL (low word)   bit 1 MULH (via 64-bit signed product)
 *   bit 2 MULHU (64-bit unsigned product)   bit 3 DIV   bit 4 REM
 *   bit 5 DIVU   bit 6 REMU
 * gcc does not emit MULHSU from plain C; it is covered in
 * ooo_tests/programs/rv32m_edge.s. [TO VERIFY] that rv32im -O0 expands the
 * 64-bit products inline (MUL/MULH/MULHU) and not as a __muldi3 call;
 * tools/check_elf.py rejects the object if it does not.
 * Expected values were computed with Python (truncating division).
 * Build: make rv32m_d8_im only (make rv32m_d8 stops with an error).
 */
#define MMIO_RESULT (*(volatile int *)0x10000000)
#define MMIO_DONE   (*(volatile int *)0x10000004)

int main(void)
{
    int a = 0x7FFFFFF0;
    int b = -0x10003;
    unsigned int ua = 0xF0000000u;
    unsigned int ub = 0x89ABCDEFu;
    unsigned int uc = 7;
    int mask = 0;

    if ((unsigned int)a * (unsigned int)b == 0x80100030u)
        mask = mask | 0x01;
    if ((int)(((long long)a * (long long)b) >> 32) == (int)0xFFFF7FFEu)
        mask = mask | 0x02;
    if ((unsigned int)(((unsigned long long)ua * (unsigned long long)ub) >> 32) == 0x81111110u)
        mask = mask | 0x04;
    if (a / b == -32766)
        mask = mask | 0x08;
    if (a % b == 32758)
        mask = mask | 0x10;
    if (ua / uc == 0x22492492u)
        mask = mask | 0x20;
    if (ua % uc == 2u)
        mask = mask | 0x40;

    MMIO_RESULT = mask;
    MMIO_DONE = 1;
    for (;;)
        ;
}
