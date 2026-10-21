/* code_sort_d8.c - 'sort' workload ported to the D8 convention (owner: D, reviewer: E).
 * PROJECT_BLUEPRINT.md 6.17, D8, F2, F3: no globals, no function calls, no
 * #include; the result is stored to 0x1000_0000, then any store to
 * 0x1000_0004 sets done, then the program loops. Expected result: 3 (arr[0] after sorting {6, 3, 9}).
 * Build: make sort_d8 (rv32i, baseline + OoO, D17) or make sort_d8_im (rv32im).
 */
#define MMIO_RESULT (*(volatile int *)0x10000000)
#define MMIO_DONE   (*(volatile int *)0x10000004)

int main(void)
{
    int swapped;
    int n, j;
    int arr[3];

    /* element by element: an initializer list may be copied from .rodata,
       which needs relocations (F3) */
    arr[0] = 6;
    arr[1] = 3;
    arr[2] = 9;
    n = 3;

    do {
        swapped = 0;
        for (j = 0; j < n - 1; j++) {
            if (arr[j] > arr[j + 1]) {
                int temp = arr[j];
                arr[j] = arr[j + 1];
                arr[j + 1] = temp;
                swapped = 1;
            }
        }
        n = n - 1;
    } while (swapped == 1);

    MMIO_RESULT = arr[0];
    MMIO_DONE = 1;
    for (;;)
        ;
}
