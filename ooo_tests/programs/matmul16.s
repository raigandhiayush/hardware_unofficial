# matmul16.s - 16x16 integer matrix multiply, C = A * B (RV32IM, needs mul).
# N=16 version of the 30x30 program in imem (1).hex, same structure and -O0 style
# (every variable on the stack). 30x30 needs 10.8 KB and does not fit data_mem (4 KB);
# 3 * 16*16 words = 3,072 bytes, frame 3,104 bytes.
#   A[i][j] = i + j + 1     at s0-1052
#   B[i][j] = i - j + 2     at s0-2076 (= s0-4112+2036)
#   C[i][j] = sum A[i][k] * B[k][j]   at s0-3100 (= s0-4112+1012)
# locals: i s0-20, j s0-24, k s0-28. Result: C[0][0] = 1632 = 0x660, then done.
        addi  sp, sp, -2032
        sw    ra, 2028(sp)
        sw    s0, 2024(sp)
        addi  s0, sp, 2032
        addi  sp, sp, -1072

# fill A and B
        sw    zero, -20(s0)
        j     fill_i_chk
fill_i: sw    zero, -24(s0)
        j     fill_j_chk
fill_j: lw    a4, -20(s0)
        lw    a5, -24(s0)
        add   a5, a4, a5
        addi  a3, a5, 1              # i + j + 1
        lw    a5, -20(s0)
        slli  a5, a5, 4
        lw    a4, -24(s0)
        add   a5, a5, a4
        slli  a5, a5, 2
        add   a5, a5, s0
        sw    a3, -1052(a5)          # A[i][j]
        lw    a4, -20(s0)
        lw    a5, -24(s0)
        sub   a5, a4, a5
        addi  a3, a5, 2              # i - j + 2
        li    a5, -4112
        add   a2, a5, s0
        lw    a5, -20(s0)
        slli  a5, a5, 4
        lw    a4, -24(s0)
        add   a5, a5, a4
        slli  a5, a5, 2
        add   a5, a2, a5
        sw    a3, 2036(a5)           # B[i][j]
        lw    a5, -24(s0)
        addi  a5, a5, 1
        sw    a5, -24(s0)
fill_j_chk:
        lw    a4, -24(s0)
        li    a5, 15
        bge   a5, a4, fill_j
        lw    a5, -20(s0)
        addi  a5, a5, 1
        sw    a5, -20(s0)
fill_i_chk:
        lw    a4, -20(s0)
        li    a5, 15
        bge   a5, a4, fill_i

# C = A * B
        sw    zero, -20(s0)
        j     mul_i_chk
mul_i:  sw    zero, -24(s0)
        j     mul_j_chk
mul_j:  li    a5, -4112
        add   a3, a5, s0
        lw    a5, -20(s0)
        slli  a5, a5, 4
        lw    a4, -24(s0)
        add   a5, a5, a4
        slli  a5, a5, 2
        add   a5, a3, a5
        sw    zero, 1012(a5)         # C[i][j] = 0
        sw    zero, -28(s0)
        j     mul_k_chk
mul_k:  li    a5, -4112
        add   a3, a5, s0
        lw    a5, -20(s0)
        slli  a5, a5, 4
        lw    a4, -24(s0)
        add   a5, a5, a4
        slli  a5, a5, 2
        add   a5, a3, a5
        lw    a3, 1012(a5)           # C[i][j]
        lw    a5, -20(s0)
        slli  a5, a5, 4
        lw    a4, -28(s0)
        add   a5, a5, a4
        slli  a5, a5, 2
        add   a5, a5, s0
        lw    a2, -1052(a5)          # A[i][k]
        li    a5, -4112
        add   a1, a5, s0
        lw    a5, -28(s0)
        slli  a5, a5, 4
        lw    a4, -24(s0)
        add   a5, a5, a4
        slli  a5, a5, 2
        add   a5, a1, a5
        lw    a5, 2036(a5)           # B[k][j]
        mul   a5, a2, a5
        add   a3, a3, a5
        li    a5, -4112
        add   a2, a5, s0
        lw    a5, -20(s0)
        slli  a5, a5, 4
        lw    a4, -24(s0)
        add   a5, a5, a4
        slli  a5, a5, 2
        add   a5, a2, a5
        sw    a3, 1012(a5)           # C[i][j] += A[i][k] * B[k][j]
        lw    a5, -28(s0)
        addi  a5, a5, 1
        sw    a5, -28(s0)
mul_k_chk:
        lw    a4, -28(s0)
        li    a5, 15
        bge   a5, a4, mul_k
        lw    a5, -24(s0)
        addi  a5, a5, 1
        sw    a5, -24(s0)
mul_j_chk:
        lw    a4, -24(s0)
        li    a5, 15
        bge   a5, a4, mul_j
        lw    a5, -20(s0)
        addi  a5, a5, 1
        sw    a5, -20(s0)
mul_i_chk:
        lw    a4, -20(s0)
        li    a5, 15
        bge   a5, a4, mul_i

# report C[0][0], set done
        lui   a5, 0x10000
        li    a4, -4112
        add   a4, a4, s0
        lw    a4, 1012(a4)
        sw    a4, 0(a5)
        lui   a5, 0x10000
        addi  a5, a5, 4
        li    a4, 1
        sw    a4, 0(a5)
end:    j     end
