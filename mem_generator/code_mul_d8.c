#define MMIO_RESULT (*(volatile int *)0x10000000)
#define MMIO_DONE   (*(volatile int *)0x10000004)

int main(void)
{
      int a = 10;
      int b = 3;
      int c = a * b; // 10 * 3 = 30 (0x1E)

      MMIO_RESULT = c;
      MMIO_DONE = 1;
      for (;;)
      ;
}