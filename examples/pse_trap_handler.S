/*
 * ==========================================================================
 * TC39x (TriCore TC1.6.2P) — PSE Trap Handler: 汇编现场重建
 * ==========================================================================
 *
 * 目标：Trap Class 4 / TIN 1 (PSE - Program Fetch Synchronous Error) 发生时，
 *      在汇编层抓住真正的错误现场，不依赖任何 C 运行时。
 *
 * 硬件进入 trap 时已自动完成（见 TriCore Arch Manual Vol.1 §6.2.5）：
 *   1. Upper Context (D12-D15, A12-A15, PCXI, PSW) 保存到 FCX 指向的 CSA
 *   2. A[11] = 出错指令的 PC（同步 trap 的返回地址 = 肇事指令本身）
 *   3. D[15] = TIN（进入 handler 前硬件已装好）
 *   4. A[10] = ISP（若 PSW.IS=0，切到中断栈）
 *   5. PSW.IO=10B (Supervisor)，PSW.PRS=0，CDC 清零
 *
 * 因此：错误现场完全可以从两条线索还原：
 *   线索A：当前寄存器 A[11]（肇事 PC）
 *   线索B：FCX 链上的 CSA（被中断任务的 upper context）
 *
 * 注意：trap handler 本身不能再用任何会消耗 CSA 的指令（如 call），
 *      否则可能触发 FCU (Class 3/TIN 1) 二次异常。因此全程用内联汇编
 *      展开访问 CSA，不做函数调用。
 */

    .section .text.pse_trap_handler, "ax"
    .global pse_trap_handler
    .global pse_trap_log

/* ---------------------------------------------------------------------------
 * 错误现场日志区（非初始化数据段，掉电丢失，但调试器/重启后可读）
 * ------------------------------------------------------------------------- */
    .section .bss.pse_trap_log, "aw", @nobits
    .align 4
pse_trap_log:                          /* 供 C 代码/调试器读取 */
    .word 0    /* +0  : PC_at_fault  (肇事指令地址，来自 A11) */
    .word 0    /* +4  : PCXI_at_trap (进入 trap 时 PCXI，指向 upper CSA) */
    .word 0    /* +8  : PSW_at_trap */
    .word 0    /* +12 : A10_at_trap (肇事任务栈指针) */
    .word 0    /* +16 : A11_at_trap (肇事任务返回地址，函数返回地址) */
    .word 0    /* +20 : D15_at_trap (TIN，应恒为1) */
    .word 0    /* +24 : ISP_at_trap (trap 时的中断栈指针) */
    .word 0    /* +28 : SYSCON_at_trap */
    .word 0    /* +32 : csa_upper_d15 (D[15] of faulted task) */
    .word 0    /* +36 : csa_upper_a11 (A[11] of faulted task，其调用者PC) */
    .word 0    /* +40 : csa_upper_a10 (A[10] of faulted task，其栈指针) */
    .word 0    /* +44 : csa_upper_pcxi(故障任务的PCXI，可回溯更上层CSA) */
    .word 0    /* +48 : csa_next_pcxi (CSA 链表下一个，或 0) */
    .word 0    /* +52 : DEEPCD_traps  (累计触发次数，判断是否反复出错) */
    .word 0    /* +56 : PC_at_fault_prev (上次肇事PC，判断是否同一处循环) */
    .word 0    /* +60 : magic (0xC0DEC0DE，标识日志有效) */

/* ---------------------------------------------------------------------------
 * pse_trap_handler
 * --------------------------------------------------------------------------- */
    .text
pse_trap_handler:

    /* ==========================================================
     * 阶段 1：现场快照 —— 抢救易失寄存器
     * ==========================================================
     * 此刻可用寄存器：D0-D7, A0-A7 (lower context 之外的全部)
     * D[15] 已被硬件占用为 TIN，D8-D15/A8-A15 已在 CSA 里
     */

    /* 保存肇事现场 —— A[11] 即肇事 PC（同步 trap 的返回地址=肇事指令） */
    mov  d0, a11                       /* d0 = 肇事 PC */
    mov  d1, a10                       /* d1 = 当前 ISP */

    /* 读系统寄存器 —— MFCR 不消耗 CSA */
    mfcr d2, $PCXI                     /* d2 = trap 时的 PCXI（指向 upper CSA） */
    mfcr d3, $PSW                      /* d3 = trap 时的 PSW */
    mfcr d4, $FCX                      /* d4 = 当前自由 CSA 指针（upper CSA 已从这里分配） */
    mfcr d5, $SYSCON                   /* d5 = 系统控制 */

    /* ==========================================================
     * 阶段 2：写日志 —— 用 syscall-free 的直接存储
     * ==========================================================
     * 此时 A[10] 指向 ISP（中断栈），可直接在其上临时存储
     * 也可以直接写到 .bss 日志区（映射到 DSPR 或 LMU）
     */

    /* 保存寄存器到日志区 */
    movh.a a2, %hi(pse_trap_log)
    lea   a2, a2, %lo(pse_trap_log)

    st.w  [a2+0],  d0                  /* PC_at_fault */
    st.w  [a2+4],  d2                  /* PCXI_at_trap */
    st.w  [a2+8],  d3                  /* PSW_at_trap */
    st.w  [a2+12], d1                  /* A10_at_trap = ISP */
    st.w  [a2+16], d0                  /* A11_at_trap（同 PC_at_fault） */
    st.w  [a2+20], d15                 /* TIN（由硬件装入，应=1） */
    st.w  [a2+24], d1                  /* ISP_at_trap */
    st.w  [a2+28], d5                  /* SYSCON */

    /* ==========================================================
     * 阶段 3：解析 CSA —— 拿到肇事任务的 upper context
     * ==========================================================
     * PCXI 格式（TriCore Arch §2.3）：
     *   bit 31   : UL  (0=lower context, 1=upper context)
     *   bit 30   : PIE
 *   bit 28-24: PCPN
     *   bit 19   : 0
     *   bit 15   : 0
     *   bit 9-0  : 偏移（64 字节对齐）
     * PCXI 指向的 CSA 地址 = (segment << 28) | (offset << 6)
     *   即 EA = (PCXI.15bit seg << 28) | (PCXI.offset << 6)
     * 上层 context 保存布局（Figure 12，从 CSA 起始向下排）：
     *   CSA+0  : PCXI (Link Word)
     *   CSA+4  : PSW
     *   CSA+8  : A[10] (SP)
     *   CSA+12 : A[11] (RA)
     *   CSA+16 : D[8]
     *   CSA+20 : D[9]
     *   CSA+24 : D[10]
     *   CSA+28 : D[11]
     *   CSA+32 : A[12]
     *   CSA+36 : A[13]
     *   CSA+40 : A[14]
     *   CSA+44 : A[15]
     *   CSA+48 : D[12]
     *   CSA+52 : D[13]
     *   CSA+56 : D[14]
     *   CSA+60 : D[15]
     */

    /* 从 PCXI 提取 CSA 地址
     * PCXI[19:0] 有效：bit 19-16 = segment (4bit), bit 9-0 = offset (10bit)
     * EA = (seg << 28) | (offset << 6)
     */
    extr  d6, d2, 16, 4               /* d6 = PCXI[19:16] = segment */
    shl   d6, d6, 28                  /* seg << 28 */
    extr  d7, d2, 6, 10               /* d7 = PCXI[15:6] = offset */
    shl   d7, d7, 6                   /* offset << 6 */
    or    d6, d6, d7                  /* d6 = upper CSA EA */

    /* 读 CSA 内容 —— 直接内存访问，不消耗 CSA */
    ld.w  d7,  [d6+0]                 /* PCXI (Link Word)，指向下一个 CSA */
    st.w  [a2+48], d7                 /* csa_next_pcxi */
    ld.w  d7,  [d6+12]                /* A[11] of faulted task = 其返回地址 */
    st.w  [a2+36], d7                 /* csa_upper_a11 */
    ld.w  d7,  [d6+8]                 /* A[10] of faulted task = 其栈指针 */
    st.w  [a2+40], d7                 /* csa_upper_a10 */
    ld.w  d7,  [d6+0]                 /* PCXI of faulted task */
    st.w  [a2+44], d7                 /* csa_upper_pcxi */

    /* ==========================================================
     * 阶段 4：栈回溯 —— 沿 A11 链向上走，抓调用栈
     * ==========================================================
     * TriCore 的函数调用帧布局（由 call/ret 指令维护）：
     *   调用者执行 call 后，A[11] 保存返回地址
     *   每个函数的 prologue: st.w [a10]0, a11   ; 保存返回地址
     *                       st.w [a10]-4, a10   ; 保存调用者栈帧指针
     * 因此栈回溯 = 读 [sp+0] 得 RA，读 [sp-4] 得上一层 SP
     *
     * 此处只回溯 3 层，防死循环；实际项目可扩展。
     */

    /* 层1：肇事任务 SP = csa_upper_a10（存在 [a2+40]） */
    ld.w  d0,  [a2+40]                /* d0 = 肇事任务 SP */
    ld.w  d1,  [d0+0]                 /* [SP+0] = 保存的 RA（上层调用者） */
    ld.w  d2,  [d0-4]                 /* [SP-4] = 调用者 SP */

    /* 层2 */
    ld.w  d3,  [d2+0]
    /* d1 = caller RA, d3 = caller's caller RA —— 可继续存到日志或遍历 */

    /* 把调用栈前两层写入日志扩展区 */
    st.w  [a2+56], d1                 /* 第1层调用者 PC */

    /* ==========================================================
     * 阶段 5：终止 —— 停机或软复位
     * ==========================================================
     * PSE 通常意味着总线/存储映射级错误，继续执行没有意义。
     * 方案A：DEBUG 指令挂起，等调试器接管（现场最完整）
     * 方案B：写到复位寄存器软复位
     * 方案C：死循环（喂狗复位）
     * 这里选 A + C 组合：有调试器挂起，无调试器死循环
     */

pse_halt:
    debug                             /* 触发调试断点，调试器在此停下 */
    j       pse_halt                  /* 无调试器则原地打转（触发看门狗） */

    .size pse_trap_handler, .-pse_trap_handler

/* ===========================================================================
 * 陷阱向量表（Trap Vector Table）—— 放在链接脚本指定的 BTV 地址
 * ===========================================================================
 * BTV 指向本表；硬件跳转到 BTV + (TCN << 5)
 * 每个向量 8 个字（32 字节），不能跨条目
 */
    .section .traptab, "ax"
    .global _trap_table
_trap_table:
    /* Class 0 - MMU  (TCN=0) */
    .rept 8
    nop
    .endr
    /* Class 1 - Internal Protection (TCN=1) */
    .rept 8
    nop
    .endr
    /* Class 2 - Instruction Errors (TCN=2) */
    .rept 8
    nop
    .endr
    /* Class 3 - Context Management (TCN=3) */
    .rept 8
    nop
    .endr

    /* ===== Class 4 - System Bus and Peripheral Errors (TCN=4) ===== */
    /* 向量入口：BTV + (4 << 5) = BTV + 128 */
pse_vector:
    /* 进来时 D[15] 已是 TIN */
    /* TIN 1 = PSE，TIN 2 = DSE，TIN 3 = DAE，... */
    movh.a a3, %hi(pse_trap_handler)
    lea    a3, a3, %lo(pse_trap_handler)
    /* 检查 TIN==1 (PSE)？ */
    mov    d0, 1
    jeq    d15, d0, .Ldispatch_pse
    /* 非 PSE：跳到通用 Class4 处理器（此处简化，全部进 PSE handler） */
.Ldispatch_pse:
    ji     a3
    .rept 3                  /* 补满 32 字节 */
    nop
    .endr

    /* Class 5-7 同理省略 */
    .rept 24
    nop
    .endr
    .size _trap_table, .-_trap_table

/* ===========================================================================
 * 初始化代码（在启动早期、ENDINIT 之前调用）
 * =========================================================================== */
    .section .text.trap_init, "ax"
    .global trap_init
trap_init:
    /* 设置 BTV 指向陷阱向量表（ENDINIT 保护，必须在解锁后） */
    movh.a  a4, %hi(_trap_table)
    lea     a4, a4, %lo(_trap_table)
    mov     d0, a4
    mtcr    $BTV, d0

    /* 设置 BIV（中断向量表，此处示意） */
    /* mtcr  $BIV, ... */

    /* CSA 链初始化（FCX/LCX 由启动代码/.crt0完成，此处不重复） */
    ret
    .size trap_init, .-trap_init
