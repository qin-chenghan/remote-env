问题和目标
当一条指令对某个寄存器或者内存地址写入后，如果接下来对这个寄存器或者内存地址还没有 进行读取就又写入了，则前一次的写入操作就无效了，这造成了存储操作的冗余，因此消除前 一条指令的执行或者把前一条指令替换为没有这个冗余存储操作的版本，从而减少指令的数量； 我们的目标就是找出这种冗余的存储操作。这种冗余又可以分为可下沉和不可下沉，即一些冗 余操作是在部分的路径中冗余的，在部分的路径中是需要的，那么，可以将这些操作移动到需 要的分支路径上，这是可下沉操作；一些冗余操作是所有的路径上都是冗余的，那么是不可下 沉操作。严格来说，case2说的无效存储操作是指不可下沉的操作，可下沉的无效存储被分类 为了代码下沉优化案例。

原理
基本的原理就是对已经写入过的寄存器和内存地址维护一张表，表的key是寄存器或内存地址， value 是一个状态值，状态值1表示写入后还没有被读取，状态值0表示写入后已经被读取了。 当发现某个寄存器或内存地址被写入后，去表中查询，如果不在表中，则添加到表中，状态值 设为1，如果在表中，则查看状态值，如果状态值为0，表示之前这个地址的写入已经被读取了，把状态值重新设为1就行，如果状态值是1，表示之前的写入还没有被读取，而现在又要 写入了，因此前一次的写入操作是冗余的。通过上述的方法可以找出冗余的存储操作。
接着，构建CFG图，如果上述的冗余操作对应的两条写入指令在同一个基本块中，那么是不 可下沉的无效存储，如果两个写入指令不在同一个基本块，那么使用DFS算法遍历CFG图， 判断第一条指令是不是在所有的路径中都是冗余的，如果是，则是无效存储，如果不是则是代 码下沉。

算法流程图
① 状态表扫描（共用检测器）：key = 寄存器/内存地址，value = 状态（1 = 写后未读，0 = 已被读）；先记读再处理写

② 候选产生：写-写无读 → 前一次写入报冗余候选（DeadStoreEvent）；读取清状态

③ 同块捷径：两条写在同一基本块 → 顺序语义足够证明 → Fully Redundant 直接删除

④ 跨块 DFS 分流：沿 CFG 查 use/kill——全路径先 kill → 删除；任一路径先 use → Sinkable 下沉到使用路径

⑤ 工程保守性：EL1 内核态黑盒（进入默认全寄存器被读）；unknown/不支持指令按「可能读取」处理；共享内存补救（load 值≠store 值 → 跳过）

⑥ 收益估算：可删除/可下沉指令占 trace 总指令比例，场景级按 trace 权重加权汇总

机制示意
① mov  x10, x11            x10 ← WRITTEN（写后未读）
② cbz  x0, cold_path       分出冷路径——CFG 上存在另一条路径
③ mov  x10, x12            WRITTEN 再被写、中间无读 → 冗余候选
…
④ 路径 A：全路径先 kill    → Fully Redundant：直接删除第一次写
④ 路径 B：cold_path 先 use → Sinkable：下沉到 cold_path 内


​
① 状态跟踪：地址状态表 value = 写后未读（1）/ 已被读（0），逐条流式更新，GB 级 trace 无需全量载入
② 分流关键点：控制流分出冷路径：当前 trace 未走 ≠ 不存在，必须沿 CFG 全路径验证
③ 候选产生（共用）：写-写无读触发冗余候选——删除与下沉共用同一检测器
④ DFS 两种结局：全路径先 kill → 删除；任一路径先 use → 下沉（热路径少执行、冷路径保留语义）

实验统计
当发现一次无效存储时，也就是一条指令写入一个地址后，这个地址又被后一条指令写入，且 前一条指令是不可下沉的，这时，如果前一条指令是单目标地址的指令，则前一条指令判断为 是可以删除的，前一条指令会被计入冗余指令，无效存储次数加1。而总的性能提升比例可以 用冗余指令的占比近似。

image

Trace 的局限性：
实验检测无效存储的方式是看一个trace文件的指令流，如果存在两次写之间 没有读取，那就算一次无效存储或者代码下沉。因为实际存在内存共享的情况，因此，某个内 存地址第一次被写入后没有被访问就又被写入可能不是真的无效存储，因为trace只是记录了 一个线程的指令流，某个地址第一次被这个线程写入后可以是被别的线程或者设备给读取了， 然后第二次这个线程继续对这个地址写入，这种情况按照目前的实验的方法是无法检测出来的， 会被判定为无效存储。因此会造成误判。
实验其实有采取一定的措施补救：如果在trace中看到一个地址被store了，但是在没有再次store 的情况下，后面的load出来的值和store进去的值不一样，则表示这个地址是一个共享的内存 地址，在判断无效存储的时候会跳过这样的地址。

大模型前处理融合算子源码案例
低效指令片段1（无效存储）
================================================================================
Case 000001 | PC: 0x41e43c -> 0x41e42c
        地址区间: 0x41e41c -> 0x41e45c
        二进制:   /home/workspace/tensor/files/opt_fusion_qwen-master-benchmark-mv-alloc-to-hotfunc-outside-pro/fusion.unittest
================================================================================

--- Original case ---
7545043 0x41e43c    8b0f0a4f add	x15, x18, x15, lsl #2
7545044 0x41e440    8b110923 add	x3, x9, x17, lsl #2
7545045 0x41e444    aa1103e6 mov	x6, x17
7545046 0x41e448    52800007 mov	w7, #0x0                   	// #0
7545047 0x41e44c    d503201f nop
7545048 0x41e450    8b0a0061 add	x1, x3, x10
7545049 0x41e454    cb0b0020 sub	x0, x1, x11
7545050 0x41e458    f100201f cmp	x0, #0x8
7545051 0x41e45c    d2800000 mov	x0, #0x0                   	// #0
7545052 0x41e460    7a478aa0 ccmp	w21, #0x7, #0x0, hi  // hi = pmore
7545053 0x41e464    54000be9 b.ls	0x000000000000017c  // b.plast
7545055 0x41e468    3ce06840 ldr	q0, [x2, x0]
7545059 0x41e46c    3ca06820 str	q0, [x1, x0]
7545063 0x41e470    91004000 add	x0, x0, #0x10
7545064 0x41e474    eb00009f cmp	x4, x0
7545065 0x41e478    54ffff81 b.ne	0xfffffffffffffff0  // b.any
7545067 0x41e468    3ce06840 ldr	q0, [x2, x0]
7545071 0x41e46c    3ca06820 str	q0, [x1, x0]
7545075 0x41e470    91004000 add	x0, x0, #0x10
7545076 0x41e474    eb00009f cmp	x4, x0
7545077 0x41e478    54ffff81 b.ne	0xfffffffffffffff0  // b.any
7545079 0x41e468    3ce06840 ldr	q0, [x2, x0]
7545083 0x41e46c    3ca06820 str	q0, [x1, x0]
7545087 0x41e470    91004000 add	x0, x0, #0x10
7545088 0x41e474    eb00009f cmp	x4, x0
7545089 0x41e478    54ffff81 b.ne	0xfffffffffffffff0  // b.any
7545091 0x41e47c    6b1c00bf cmp	w5, w28
7545092 0x41e480    540001c0 b.eq	0x0000000000000038  // b.none
7545094 0x41e484    8b0602c0 add	x0, x22, x6
7545095 0x41e488    bd400180 ldr	s0, [x12]
7545098 0x41e48c    bc207920 str	s0, [x9, x0, lsl #2]
7545101 0x41e490    6b1700bf cmp	w5, w23
7545102 0x41e494    5400012d b.le	0x0000000000000024
7545104 0x41e498    8b060320 add	x0, x25, x6
7545105 0x41e49c    bd4001c0 ldr	s0, [x14]
7545108 0x41e4a0    bc207920 str	s0, [x9, x0, lsl #2]
7545111 0x41e4a4    6b1800bf cmp	w5, w24
7545112 0x41e4a8    5400008d b.le	0x0000000000000010
7545114 0x41e4b8    110004e7 add	w7, w7, #0x1
7545115 0x41e4bc    8b1b00c6 add	x6, x6, x27
7545116 0x41e4c0    8b1a0063 add	x3, x3, x26
7545117 0x41e4c4    6b0701bf cmp	w13, w7
7545118 0x41e4c8    54fffc41 b.ne	0xffffffffffffff88  // b.any
7545120 0x41e450    8b0a0061 add	x1, x3, x10
7545121 0x41e454    cb0b0020 sub	x0, x1, x11
7545122 0x41e458    f100201f cmp	x0, #0x8
7545123 0x41e45c    d2800000 mov	x0, #0x0                   	// #0
7545124 0x41e460    7a478aa0 ccmp	w21, #0x7, #0x0, hi  // hi = pmore
7545125 0x41e464    54000be9 b.ls	0x000000000000017c  // b.plast
7545127 0x41e468    3ce06840 ldr	q0, [x2, x0]
7545131 0x41e46c    3ca06820 str	q0, [x1, x0]
7545135 0x41e470    91004000 add	x0, x0, #0x10
7545136 0x41e474    eb00009f cmp	x4, x0
7545137 0x41e478    54ffff81 b.ne	0xfffffffffffffff0  // b.any
7545139 0x41e468    3ce06840 ldr	q0, [x2, x0]
7545143 0x41e46c    3ca06820 str	q0, [x1, x0]
7545147 0x41e470    91004000 add	x0, x0, #0x10
7545148 0x41e474    eb00009f cmp	x4, x0
7545149 0x41e478    54ffff81 b.ne	0xfffffffffffffff0  // b.any
7545151 0x41e468    3ce06840 ldr	q0, [x2, x0]
7545155 0x41e46c    3ca06820 str	q0, [x1, x0]
7545159 0x41e470    91004000 add	x0, x0, #0x10
7545160 0x41e474    eb00009f cmp	x4, x0
7545161 0x41e478    54ffff81 b.ne	0xfffffffffffffff0  // b.any
7545163 0x41e47c    6b1c00bf cmp	w5, w28
7545164 0x41e480    540001c0 b.eq	0x0000000000000038  // b.none
7545166 0x41e484    8b0602c0 add	x0, x22, x6
7545167 0x41e488    bd400180 ldr	s0, [x12]
7545170 0x41e48c    bc207920 str	s0, [x9, x0, lsl #2]
7545173 0x41e490    6b1700bf cmp	w5, w23
7545174 0x41e494    5400012d b.le	0x0000000000000024
7545176 0x41e498    8b060320 add	x0, x25, x6
7545177 0x41e49c    bd4001c0 ldr	s0, [x14]
7545180 0x41e4a0    bc207920 str	s0, [x9, x0, lsl #2]
7545183 0x41e4a4    6b1800bf cmp	w5, w24
7545184 0x41e4a8    5400008d b.le	0x0000000000000010
7545186 0x41e4b8    110004e7 add	w7, w7, #0x1
7545187 0x41e4bc    8b1b00c6 add	x6, x6, x27
7545188 0x41e4c0    8b1a0063 add	x3, x3, x26
7545189 0x41e4c4    6b0701bf cmp	w13, w7
7545190 0x41e4c8    54fffc41 b.ne	0xffffffffffffff88  // b.any
7545192 0x41e4cc    f9403be1 ldr	x1, [sp, #112]
7545195 0x41e4d0    8b130108 add	x8, x8, x19
7545196 0x41e4d4    b9406be0 ldr	w0, [sp, #104]
7545199 0x41e4d8    8b130042 add	x2, x2, x19
7545200 0x41e4dc    8b010210 add	x16, x16, x1
7545201 0x41e4e0    8b13016b add	x11, x11, x19
7545202 0x41e4e4    f9403fe1 ldr	x1, [sp, #120]
7545205 0x41e4e8    11000400 add	w0, w0, #0x1
7545206 0x41e4ec    b9006be0 str	w0, [sp, #104]
7545209 0x41e4f0    8b010231 add	x17, x17, x1
7545210 0x41e4f4    8b010294 add	x20, x20, x1
7545211 0x41e4f8    b9406fe1 ldr	w1, [sp, #108]
7545214 0x41e4fc    6b00003f cmp	w1, w0
7545215 0x41e500    54fff901 b.ne	0xffffffffffffff20  // b.any
7545217 0x41e420    cb11028a sub	x10, x20, x17
7545218 0x41e424    8b1002cc add	x12, x22, x16
7545219 0x41e428    8b10032e add	x14, x25, x16
7545220 0x41e42c    8b1003cf add	x15, x30, x16

​
带源码的反汇编
--- OBJDUMP disassembly (with source, PC START/END marked) ---

/home/workspace/tensor/files/opt_fusion_qwen-master-benchmark-mv-alloc-to-hotfunc-outside-pro/fusion.unittest:     file format elf64-littleaarch64


Disassembly of section .text:

000000000041e41c <_ZN12_GLOBAL__N_114TranposeSingleIfEEiPKT_PS1_PiS5_i.isra.0+0x1fc>:
_ZN12_GLOBAL__N_114TranposeSingleIfEEiPKT_PS1_PiS5_i.isra.0():
/home/workspace/tensor/files/opt_fusion_qwen-master-benchmark-mv-alloc-to-hotfunc-outside-pro/pillow_fusion_func_v2.cpp:856
        T *dp = dst + h0 * hstride0 + h1 * hstride1 + h2 * hstride2 + c * cstride;
        const T *sp = src + c * height * width + h * width;
        for (int w2 = 0; w2 < wdim[2]; w2 ++) {
          T *dp2 = dp + w2 * wstride2; 
          const T *sp2 = sp + w2 * wdim[1] * wdim[0]; 
          for (int w1 = 0; w1 < wdim[1]; w1 ++) {
  41e41c:	8b010014 	add	x20, x0, x1
/home/workspace/tensor/files/opt_fusion_qwen-master-benchmark-mv-alloc-to-hotfunc-outside-pro/pillow_fusion_func_v2.cpp:859
            T *dp1 = dp2 + w1 * wstride1;
            const T *sp1 = sp2 + w1 * wdim[0];
            for (int j = 0; j < b; j ++) { 
  41e420:	cb11028a 	sub	x10, x20, x17
/home/workspace/tensor/files/opt_fusion_qwen-master-benchmark-mv-alloc-to-hotfunc-outside-pro/pillow_fusion_func_v2.cpp:863
              T *dp0 = dp1 + j * bstride;
              const T *sp0 = sp1;
              for (int w0 = 0; w0 < wdim[0]; w0 ++) {
                dp0[w0] = sp0[w0]; 
  41e424:	8b1002cc 	add	x12, x22, x16
  41e428:	8b10032e 	add	x14, x25, x16
  41e42c:	8b1003cf 	add	x15, x30, x16    <=== PC END (0x41e42c)
  41e430:	d37ef54a 	lsl	x10, x10, #2
  41e434:	8b0c0a4c 	add	x12, x18, x12, lsl #2
  41e438:	8b0e0a4e 	add	x14, x18, x14, lsl #2
  41e43c:	8b0f0a4f 	add	x15, x18, x15, lsl #2    <=== PC START (0x41e43c)
  41e440:	8b110923 	add	x3, x9, x17, lsl #2
  41e444:	aa1103e6 	mov	x6, x17
/home/workspace/tensor/files/opt_fusion_qwen-master-benchmark-mv-alloc-to-hotfunc-outside-pro/pillow_fusion_func_v2.cpp:859
            for (int j = 0; j < b; j ++) { 
  41e448:	52800007 	mov	w7, #0x0                   	// #0
  41e44c:	d503201f 	nop
/home/workspace/tensor/files/opt_fusion_qwen-master-benchmark-mv-alloc-to-hotfunc-outside-pro/pillow_fusion_func_v2.cpp:862
              for (int w0 = 0; w0 < wdim[0]; w0 ++) {
  41e450:	8b0a0061 	add	x1, x3, x10
  41e454:	cb0b0020 	sub	x0, x1, x11
  41e458:	f100201f 	cmp	x0, #0x8

​
低效指令片段2（可下沉指令）
================================================================================
Case 000002 | PC: 0x41e4c0 -> 0x41e440
        地址区间: 0x41e430 -> 0x41e4d0
        二进制:   /home/workspace/tensor/files/opt_fusion_qwen-master-benchmark-mv-alloc-to-hotfunc-outside-pro/fusion.unittest
================================================================================

--- Original case ---
7545188 0x41e4c0    8b1a0063 add	x3, x3, x26
7545189 0x41e4c4    6b0701bf cmp	w13, w7
7545190 0x41e4c8    54fffc41 b.ne	0xffffffffffffff88  // b.any
7545192 0x41e4cc    f9403be1 ldr	x1, [sp, #112]
7545195 0x41e4d0    8b130108 add	x8, x8, x19
7545196 0x41e4d4    b9406be0 ldr	w0, [sp, #104]
7545199 0x41e4d8    8b130042 add	x2, x2, x19
7545200 0x41e4dc    8b010210 add	x16, x16, x1
7545201 0x41e4e0    8b13016b add	x11, x11, x19
7545202 0x41e4e4    f9403fe1 ldr	x1, [sp, #120]
7545205 0x41e4e8    11000400 add	w0, w0, #0x1
7545206 0x41e4ec    b9006be0 str	w0, [sp, #104]
7545209 0x41e4f0    8b010231 add	x17, x17, x1
7545210 0x41e4f4    8b010294 add	x20, x20, x1
7545211 0x41e4f8    b9406fe1 ldr	w1, [sp, #108]
7545214 0x41e4fc    6b00003f cmp	w1, w0
7545215 0x41e500    54fff901 b.ne	0xffffffffffffff20  // b.any
7545217 0x41e420    cb11028a sub	x10, x20, x17
7545218 0x41e424    8b1002cc add	x12, x22, x16
7545219 0x41e428    8b10032e add	x14, x25, x16
7545220 0x41e42c    8b1003cf add	x15, x30, x16
7545221 0x41e430    d37ef54a lsl	x10, x10, #2
7545222 0x41e434    8b0c0a4c add	x12, x18, x12, lsl #2
7545223 0x41e438    8b0e0a4e add	x14, x18, x14, lsl #2
7545224 0x41e43c    8b0f0a4f add	x15, x18, x15, lsl #2
7545225 0x41e440    8b110923 add	x3, x9, x17, lsl #2

​
带源码的反汇编
--- OBJDUMP disassembly (with source, PC START/END marked) ---

/home/workspace/tensor/files/opt_fusion_qwen-master-benchmark-mv-alloc-to-hotfunc-outside-pro/fusion.unittest:     file format elf64-littleaarch64


Disassembly of section .text:

000000000041e430 <_ZN12_GLOBAL__N_114TranposeSingleIfEEiPKT_PS1_PiS5_i.isra.0+0x210>:
_ZN12_GLOBAL__N_114TranposeSingleIfEEiPKT_PS1_PiS5_i.isra.0():
/home/workspace/tensor/files/opt_fusion_qwen-master-benchmark-mv-alloc-to-hotfunc-outside-pro/pillow_fusion_func_v2.cpp:863
            const T *sp1 = sp2 + w1 * wdim[0];
            for (int j = 0; j < b; j ++) { 
              T *dp0 = dp1 + j * bstride;
              const T *sp0 = sp1;
              for (int w0 = 0; w0 < wdim[0]; w0 ++) {
                dp0[w0] = sp0[w0]; 
  41e430:	d37ef54a 	lsl	x10, x10, #2
  41e434:	8b0c0a4c 	add	x12, x18, x12, lsl #2
  41e438:	8b0e0a4e 	add	x14, x18, x14, lsl #2
  41e43c:	8b0f0a4f 	add	x15, x18, x15, lsl #2
  41e440:	8b110923 	add	x3, x9, x17, lsl #2    <=== PC END (0x41e440)
  41e444:	aa1103e6 	mov	x6, x17
/home/workspace/tensor/files/opt_fusion_qwen-master-benchmark-mv-alloc-to-hotfunc-outside-pro/pillow_fusion_func_v2.cpp:859
            for (int j = 0; j < b; j ++) { 
  41e448:	52800007 	mov	w7, #0x0                   	// #0
  41e44c:	d503201f 	nop
/home/workspace/tensor/files/opt_fusion_qwen-master-benchmark-mv-alloc-to-hotfunc-outside-pro/pillow_fusion_func_v2.cpp:862
              for (int w0 = 0; w0 < wdim[0]; w0 ++) {
  41e450:	8b0a0061 	add	x1, x3, x10
  41e454:	cb0b0020 	sub	x0, x1, x11
  41e458:	f100201f 	cmp	x0, #0x8
/home/workspace/tensor/files/opt_fusion_qwen-master-benchmark-mv-alloc-to-hotfunc-outside-pro/pillow_fusion_func_v2.cpp:859
            for (int j = 0; j < b; j ++) { 
  41e45c:	d2800000 	mov	x0, #0x0                   	// #0
  41e460:	7a478aa0 	ccmp	w21, #0x7, #0x0, hi  // hi = pmore
  41e464:	54000be9 	b.ls	41e5e0 <_ZN12_GLOBAL__N_114TranposeSingleIfEEiPKT_PS1_PiS5_i.isra.0+0x3c0>  // b.plast
/home/workspace/tensor/files/opt_fusion_qwen-master-benchmark-mv-alloc-to-hotfunc-outside-pro/pillow_fusion_func_v2.cpp:863 (discriminator 2)
                dp0[w0] = sp0[w0]; 
  41e468:	3ce06840 	ldr	q0, [x2, x0]
  41e46c:	3ca06820 	str	q0, [x1, x0]
/home/workspace/tensor/files/opt_fusion_qwen-master-benchmark-mv-alloc-to-hotfunc-outside-pro/pillow_fusion_func_v2.cpp:862 (discriminator 2)
              for (int w0 = 0; w0 < wdim[0]; w0 ++) {
  41e470:	91004000 	add	x0, x0, #0x10
  41e474:	eb00009f 	cmp	x4, x0
  41e478:	54ffff81 	b.ne	41e468 <_ZN12_GLOBAL__N_114TranposeSingleIfEEiPKT_PS1_PiS5_i.isra.0+0x248>  // b.any
  41e47c:	6b1c00bf 	cmp	w5, w28
  41e480:	540001c0 	b.eq	41e4b8 <_ZN12_GLOBAL__N_114TranposeSingleIfEEiPKT_PS1_PiS5_i.isra.0+0x298>  // b.none
/home/workspace/tensor/files/opt_fusion_qwen-master-benchmark-mv-alloc-to-hotfunc-outside-pro/pillow_fusion_func_v2.cpp:863 (discriminator 2)
                dp0[w0] = sp0[w0]; 
  41e484:	8b0602c0 	add	x0, x22, x6
  41e488:	bd400180 	ldr	s0, [x12]
  41e48c:	bc207920 	str	s0, [x9, x0, lsl #2]
/home/workspace/tensor/files/opt_fusion_qwen-master-benchmark-mv-alloc-to-hotfunc-outside-pro/pillow_fusion_func_v2.cpp:862 (discriminator 2)
              for (int w0 = 0; w0 < wdim[0]; w0 ++) {
  41e490:	6b1700bf 	cmp	w5, w23
  41e494:	5400012d 	b.le	41e4b8 <_ZN12_GLOBAL__N_114TranposeSingleIfEEiPKT_PS1_PiS5_i.isra.0+0x298>
/home/workspace/tensor/files/opt_fusion_qwen-master-benchmark-mv-alloc-to-hotfunc-outside-pro/pillow_fusion_func_v2.cpp:863 (discriminator 2)
                dp0[w0] = sp0[w0]; 
  41e498:	8b060320 	add	x0, x25, x6
  41e49c:	bd4001c0 	ldr	s0, [x14]
  41e4a0:	bc207920 	str	s0, [x9, x0, lsl #2]
/home/workspace/tensor/files/opt_fusion_qwen-master-benchmark-mv-alloc-to-hotfunc-outside-pro/pillow_fusion_func_v2.cpp:862 (discriminator 2)
              for (int w0 = 0; w0 < wdim[0]; w0 ++) {
  41e4a4:	6b1800bf 	cmp	w5, w24
  41e4a8:	5400008d 	b.le	41e4b8 <_ZN12_GLOBAL__N_114TranposeSingleIfEEiPKT_PS1_PiS5_i.isra.0+0x298>
/home/workspace/tensor/files/opt_fusion_qwen-master-benchmark-mv-alloc-to-hotfunc-outside-pro/pillow_fusion_func_v2.cpp:863 (discriminator 2)
                dp0[w0] = sp0[w0]; 
  41e4ac:	8b1e00c0 	add	x0, x6, x30
  41e4b0:	bd4001e0 	ldr	s0, [x15]
  41e4b4:	bc207920 	str	s0, [x9, x0, lsl #2]
/home/workspace/tensor/files/opt_fusion_qwen-master-benchmark-mv-alloc-to-hotfunc-outside-pro/pillow_fusion_func_v2.cpp:859
            for (int j = 0; j < b; j ++) { 
  41e4b8:	110004e7 	add	w7, w7, #0x1
  41e4bc:	8b1b00c6 	add	x6, x6, x27
  41e4c0:	8b1a0063 	add	x3, x3, x26    <=== PC START (0x41e4c0)
  41e4c4:	6b0701bf 	cmp	w13, w7
  41e4c8:	54fffc41 	b.ne	41e450 <_ZN12_GLOBAL__N_114TranposeSingleIfEEiPKT_PS1_PiS5_i.isra.0+0x230>  // b.any
/home/workspace/tensor/files/opt_fusion_qwen-master-benchmark-mv-alloc-to-hotfunc-outside-pro/pillow_fusion_func_v2.cpp:856
          for (int w1 = 0; w1 < wdim[1]; w1 ++) {
  41e4cc:	f9403be1 	ldr	x1, [sp, #112]

​
redis源码案例
低效指令片段1
--- Original case ---
   944 0x445590    52800000 mov	w0, #0x0                   	// #0
   946 0x445594    b7fffe45 tbnz	x5, #63, 0xffffffffffffffc8
   948 0x445598    52800020 mov	w0, #0x1                   	// #1

   --- OBJDUMP disassembly (with source, PC START/END marked) ---

   /root/redis/src/install/bin/redis-server:     file format elf64-littleaarch64


   Disassembly of section .text:

   0000000000445580 <string2ll+0xe0>:
   string2ll():
   /root/redis/src/redis-6.0.20/src/util.c:406
               return 0;
       }

       /* First digit should be 1-9, otherwise the string should just be 0. */
       if (p[0] >= '1' && p[0] <= '9') {
           v = p[0]-'0';
     445580:	93407ca5 	sxtw	x5, w5
   /root/redis/src/redis-6.0.20/src/util.c:405
       if (p[0] >= '1' && p[0] <= '9') {
     445584:	7100203f 	cmp	w1, #0x8
     445588:	54fffea8 	b.hi	44555c <string2ll+0xbc>  // b.pmore
     44558c:	d503201f 	nop
   /root/redis/src/redis-6.0.20/src/util.c:385
           return 0;
     445590:	52800000 	mov	w0, #0x0                   	// #0    <=== PC START (0x445590)
   /root/redis/src/redis-6.0.20/src/util.c:436
       if (negative) {
           if (v > ((unsigned long long)(-(LLONG_MIN+1))+1)) /* Overflow. */
               return 0;
           if (value != NULL) *value = -v;
       } else {
           if (v > LLONG_MAX) /* Overflow. */
     445594:	b7fffe45 	tbnz	x5, #63, 44555c <string2ll+0xbc>
   /root/redis/src/redis-6.0.20/src/util.c:390
           return 1;
     445598:	52800020 	mov	w0, #0x1                   	// #1    <=== PC END (0x445598)
   /root/redis/src/redis-6.0.20/src/util.c:438
               return 0;
           if (value != NULL) *value = v;
     44559c:	b4fffe02 	cbz	x2, 44555c <string2ll+0xbc>
   /root/redis/src/redis-6.0.20/src/util.c:438 (discriminator 1)
     4455a0:	f9000045 	str	x5, [x2]
   /root/redis/src/redis-6.0.20/src/util.c:441 (discriminator 1)
       }
       return 1;
   }
     4455a4:	d65f03c0 	ret
   /root/redis/src/redis-6.0.20/src/util.c:431
       if (negative) {
     4455a8:	34ffff40 	cbz	w0, 445590 <string2ll+0xf0>
   /root/redis/src/redis-6.0.20/src/util.c:432
           if (v > ((unsigned long long)(-(LLONG_MIN+1))+1)) /* Overflow. */
     4455ac:	d2f00001 	mov	x1, #0x8000000000000000    	// #-9223372036854775808
     4455b0:	eb0100bf 	cmp	x5, x1
     4455b4:	54fffd28 	b.hi	445558 <string2ll+0xb8>  // b.pmore
   /root/redis/src/redis-6.0.20/src/util.c:434
           if (value != NULL) *value = -v;
     4455b8:	b4fffd22 	cbz	x2, 44555c <string2ll+0xbc>
   /root/redis/src/redis-6.0.20/src/util.c:434 (discriminator 1)
     4455bc:	cb0503e5 	neg	x5, x5

​
低效指令片段2
================================================================================
   Case 000010 | PC: 0x42cd38 -> 0x42cda8
           换算ELF: 0x42cd38 -> 0x42cda8
           START模块: /root/redis/src/install/bin/redis-server (主程序)
           END模块:   /root/redis/src/install/bin/redis-server (主程序)
           共享库基址: 0x7f930a7000
   ================================================================================

   --- Original case ---
   7503 0x42cd38    52800000 mov	w0, #0x0                   	// #0
   7505 0x42cd3c    6b05007f cmp	w3, w5
   7507 0x42cd40    54000300 b.eq	0x0000000000000060  // b.none
   7509 0x42cda0    a9bf7bfd stp	x29, x30, [sp, #-16]!
   7514 0x42cda4    93407c62 sxtw	x2, w3
   7516 0x42cda8    aa0603e0 mov	x0, x6

   --- OBJDUMP disassembly (with source, PC START/END marked) ---

   /root/redis/src/install/bin/redis-server:     file format elf64-littleaarch64


   Disassembly of section .text:

   000000000042cd28 <dictSdsKeyCompare+0x48>:
   sdslen():
   /root/redis/src/redis-6.0.20/src/sds.h:89
   #define SDS_HDR(T,s) ((struct sdshdr##T *)((s)-(sizeof(struct sdshdr##T))))
   #define SDS_TYPE_5_LEN(f) ((f)>>SDS_TYPE_BITS)

   static inline size_t sdslen(const sds s) {
       unsigned char flags = s[-1];
       switch(flags&SDS_TYPE_MASK) {
     42cd28:	540004e0 	b.eq	42cdc4 <dictSdsKeyCompare+0xe4>  // b.none
     42cd2c:	7100109f 	cmp	w4, #0x4
     42cd30:	54000601 	b.ne	42cdf0 <dictSdsKeyCompare+0x110>  // b.any
   dictSdsKeyCompare():
   /root/redis/src/redis-6.0.20/src/server.c:1170
   {
       int l1,l2;
       DICT_NOTUSED(privdata);

       l1 = sdslen((sds)key1);
       l2 = sdslen((sds)key2);
     42cd34:	b85ef025 	ldur	w5, [x1, #-17]
   /root/redis/src/redis-6.0.20/src/server.c:1171
       if (l1 != l2) return 0;
     42cd38:	52800000 	mov	w0, #0x0                   	// #0    <=== PC START (0x42cd38)
     42cd3c:	6b05007f 	cmp	w3, w5
     42cd40:	54000300 	b.eq	42cda0 <dictSdsKeyCompare+0xc0>  // b.none
   /root/redis/src/redis-6.0.20/src/server.c:1173
       return memcmp(key1, key2, l1) == 0;
   }
     42cd44:	d65f03c0 	ret
   /root/redis/src/redis-6.0.20/src/server.c:1170
       l2 = sdslen((sds)key2);
     42cd48:	53037ca5 	lsr	w5, w5, #3
   sdslen():
   /root/redis/src/redis-6.0.20/src/sds.h:89
     42cd4c:	34ffff64 	cbz	w4, 42cd38 <dictSdsKeyCompare+0x58>
     42cd50:	7100049f 	cmp	w4, #0x1
     42cd54:	540004e1 	b.ne	42cdf0 <dictSdsKeyCompare+0x110>  // b.any
   dictSdsKeyCompare():
   /root/redis/src/redis-6.0.20/src/server.c:1170
     42cd58:	385fd025 	ldurb	w5, [x1, #-3]
   /root/redis/src/redis-6.0.20/src/server.c:1171
       if (l1 != l2) return 0;
     42cd5c:	52800000 	mov	w0, #0x0                   	// #0
     42cd60:	6b05007f 	cmp	w3, w5
     42cd64:	54ffff01 	b.ne	42cd44 <dictSdsKeyCompare+0x64>  // b.any
     42cd68:	1400000e 	b	42cda0 <dictSdsKeyCompare+0xc0>
   /root/redis/src/redis-6.0.20/src/server.c:1169
       l1 = sdslen((sds)key1);
     42cd6c:	53037c63 	lsr	w3, w3, #3
   sdslen():
   /root/redis/src/redis-6.0.20/src/sds.h:89
     42cd70:	34fffd04 	cbz	w4, 42cd10 <dictSdsKeyCompare+0x30>
     42cd74:	7100049f 	cmp	w4, #0x1
     42cd78:	54000381 	b.ne	42cde8 <dictSdsKeyCompare+0x108>  // b.any
   /root/redis/src/redis-6.0.20/src/sds.h:88
       unsigned char flags = s[-1];
     42cd7c:	385ff025 	ldurb	w5, [x1, #-1]
   dictSdsKeyCompare():
   /root/redis/src/redis-6.0.20/src/server.c:1169
     42cd80:	385fd0c3 	ldurb	w3, [x6, #-3]
   sdslen():
   /root/redis/src/redis-6.0.20/src/sds.h:89
       switch(flags&SDS_TYPE_MASK) {
     42cd84:	120008a4 	and	w4, w5, #0x7
     42cd88:	7100089f 	cmp	w4, #0x2
     42cd8c:	54fffca1 	b.ne	42cd20 <dictSdsKeyCompare+0x40>  // b.any
   dictSdsKeyCompare():
   /root/redis/src/redis-6.0.20/src/server.c:1170
       l2 = sdslen((sds)key2);
     42cd90:	785fb025 	ldurh	w5, [x1, #-5]
   /root/redis/src/redis-6.0.20/src/server.c:1171
       if (l1 != l2) return 0;
     42cd94:	52800000 	mov	w0, #0x0                   	// #0
     42cd98:	6b05007f 	cmp	w3, w5
     42cd9c:	54fffd41 	b.ne	42cd44 <dictSdsKeyCompare+0x64>  // b.any
   /root/redis/src/redis-6.0.20/src/server.c:1165
   {
     42cda0:	a9bf7bfd 	stp	x29, x30, [sp, #-16]!
   /root/redis/src/redis-6.0.20/src/server.c:1172
       return memcmp(key1, key2, l1) == 0;
     42cda4:	93407c62 	sxtw	x2, w3
     42cda8:	aa0603e0 	mov	x0, x6    <=== PC END (0x42cda8)
   /root/redis/src/redis-6.0.20/src/server.c:1165
   {
     42cdac:	910003fd 	mov	x29, sp
   /root/redis/src/redis-6.0.20/src/server.c:1172
       return memcmp(key1, key2, l1) == 0;
     42cdb0:	97ffe074 	bl	424f80 <memcmp@plt>
     42cdb4:	7100001f 	cmp	w0, #0x0

​
低效指令片段3
================================================================================
Case 000011 | PC: 0x42cd6c -> 0x42cd80
        换算ELF: 0x42cd6c -> 0x42cd80
        START模块: /root/redis/src/install/bin/redis-server (主程序)
        END模块:   /root/redis/src/install/bin/redis-server (主程序)
        共享库基址: 0x7f930a7000
================================================================================

--- Original case ---
7475 0x42cd6c    53037c63 lsr	w3, w3, #3
7477 0x42cd70    34fffd04 cbz	w4, 0xffffffffffffffa0
7479 0x42cd74    7100049f cmp	w4, #0x1
7481 0x42cd78    54000381 b.ne	0x0000000000000070  // b.any
7483 0x42cd7c    385ff025 ldurb	w5, [x1, #-1]
7487 0x42cd80    385fd0c3 ldurb	w3, [x6, #-3]

--- OBJDUMP disassembly (with source, PC START/END marked) ---

/root/redis/src/install/bin/redis-server:     file format elf64-littleaarch64


Disassembly of section .text:

000000000042cd5c <dictSdsKeyCompare+0x7c>:
dictSdsKeyCompare():
/root/redis/src/redis-6.0.20/src/server.c:1171
    int l1,l2;
    DICT_NOTUSED(privdata);

    l1 = sdslen((sds)key1);
    l2 = sdslen((sds)key2);
    if (l1 != l2) return 0;
  42cd5c:	52800000 	mov	w0, #0x0                   	// #0
  42cd60:	6b05007f 	cmp	w3, w5
  42cd64:	54ffff01 	b.ne	42cd44 <dictSdsKeyCompare+0x64>  // b.any
  42cd68:	1400000e 	b	42cda0 <dictSdsKeyCompare+0xc0>
/root/redis/src/redis-6.0.20/src/server.c:1169
    l1 = sdslen((sds)key1);
  42cd6c:	53037c63 	lsr	w3, w3, #3    <=== PC START (0x42cd6c)
sdslen():
/root/redis/src/redis-6.0.20/src/sds.h:89
#define SDS_HDR(T,s) ((struct sdshdr##T *)((s)-(sizeof(struct sdshdr##T))))
#define SDS_TYPE_5_LEN(f) ((f)>>SDS_TYPE_BITS)

static inline size_t sdslen(const sds s) {
    unsigned char flags = s[-1];
    switch(flags&SDS_TYPE_MASK) {
  42cd70:	34fffd04 	cbz	w4, 42cd10 <dictSdsKeyCompare+0x30>
  42cd74:	7100049f 	cmp	w4, #0x1
  42cd78:	54000381 	b.ne	42cde8 <dictSdsKeyCompare+0x108>  // b.any
/root/redis/src/redis-6.0.20/src/sds.h:88
    unsigned char flags = s[-1];
  42cd7c:	385ff025 	ldurb	w5, [x1, #-1]
dictSdsKeyCompare():
/root/redis/src/redis-6.0.20/src/server.c:1169
  42cd80:	385fd0c3 	ldurb	w3, [x6, #-3]    <=== PC END (0x42cd80)
sdslen():
/root/redis/src/redis-6.0.20/src/sds.h:89
    switch(flags&SDS_TYPE_MASK) {
  42cd84:	120008a4 	and	w4, w5, #0x7
  42cd88:	7100089f 	cmp	w4, #0x2
  42cd8c:	54fffca1 	b.ne	42cd20 <dictSdsKeyCompare+0x40>  // b.any
dictSdsKeyCompare():
/root/redis/src/redis-6.0.20/src/server.c:1170
    l2 = sdslen((sds)key2);
  42cd90:	785fb025 	ldurh	w5, [x1, #-5]
/root/redis/src/redis-6.0.20/src/server.c:1171
    if (l1 != l2) return 0;
  42cd94:	52800000 	mov	w0, #0x0                   	// #0
  42cd98:	6b05007f 	cmp	w3, w5

​
pytorch算子下发
低效指令片段1
================================================================================
Case 1 | PC: 0x558d364448 -> 0x558d364470
        模块: python3.12
        换算ELF: 0x1c4448 -> 0x1c4470
        地址区间: 0x1c4438 -> 0x1c4480
        二进制: /spark_trace/n00565043/trace-opti/python-pytorch-lto-pgo-testpackage/pytorch-conda-env-ver-pgo-built-on-950/bin/python3.12
        基址: 0x558d1a0000
================================================================================

--- Original case ---
1977518 0x558d364448    f9004be3 str	x3, [sp, #144]
1977522 0x558d36444c    531f0821 ubfiz	w1, w1, #1, #3
1977524 0x558d364450    11000821 add	w1, w1, #0x2
1977526 0x558d364454    0b050021 add	w1, w1, w5
1977528 0x558d364458    b9007fe1 str	w1, [sp, #124]
1977532 0x558d36445c    eb03009f cmp	x4, x3
1977534 0x558d364460    54002ae9 b.ls	0x000000000000055c  // b.plast
1977536 0x558d364464    39c00446 ldrsb	w6, [x2, #1]
1977540 0x558d364468    37f80326 tbnz	w6, #31, 0x0000000000000064
1977542 0x558d36446c    91000843 add	x3, x2, #0x2
1977544 0x558d364470    f9004be3 str	x3, [sp, #144]

--- OBJDUMP disassembly (with source, PC START/END marked) ---

/spark_trace/n00565043/trace-opti/python-pytorch-lto-pgo-testpackage/pytorch-conda-env-ver-pgo-built-on-950/bin/python3.12:     file format elf64-littleaarch64


Disassembly of section .text:

00000000001c4438 <PyTraceBack_Here+0xe8>:
next_code_delta():
/home/l00886679/projects/python-pgo-affacts/Python-3.12.0/Objects/codeobject.c:887
  1c4438:	aa0203e3 	mov	x3, x2
advance():
/home/l00886679/projects/python-pgo-affacts/Python-3.12.0/Objects/codeobject.c:968
  1c443c:	b9007be5 	str	w5, [sp, #120]
  1c4440:	b90083e1 	str	w1, [sp, #128]
next_code_delta():
/home/l00886679/projects/python-pgo-affacts/Python-3.12.0/Objects/codeobject.c:887
  1c4444:	38401461 	ldrb	w1, [x3], #1
advance():
/home/l00886679/projects/python-pgo-affacts/Python-3.12.0/Objects/codeobject.c:971
  1c4448:	f9004be3 	str	x3, [sp, #144]    <=== PC START (0x558d364448, ELF 0x1c4448)
next_code_delta():
/home/l00886679/projects/python-pgo-affacts/Python-3.12.0/Objects/codeobject.c:887
  1c444c:	531f0821 	ubfiz	w1, w1, #1, #3
  1c4450:	11000821 	add	w1, w1, #0x2
advance():
/home/l00886679/projects/python-pgo-affacts/Python-3.12.0/Objects/codeobject.c:969
  1c4454:	0b050021 	add	w1, w1, w5
  1c4458:	b9007fe1 	str	w1, [sp, #124]
/home/l00886679/projects/python-pgo-affacts/Python-3.12.0/Objects/codeobject.c:972
  1c445c:	eb03009f 	cmp	x4, x3
  1c4460:	54002ae9 	b.ls	1c49bc <PyTraceBack_Here+0x66c>  // b.plast
  1c4464:	39c00446 	ldrsb	w6, [x2, #1]
  1c4468:	37f80326 	tbnz	w6, #31, 1c44cc <PyTraceBack_Here+0x17c>
/home/l00886679/projects/python-pgo-affacts/Python-3.12.0/Objects/codeobject.c:971
  1c446c:	91000843 	add	x3, x2, #0x2
  1c4470:	f9004be3 	str	x3, [sp, #144]    <=== PC END (0x558d364470, ELF 0x1c4470)
/home/l00886679/projects/python-pgo-affacts/Python-3.12.0/Objects/codeobject.c:972
  1c4474:	eb03009f 	cmp	x4, x3
  1c4478:	54002a29 	b.ls	1c49bc <PyTraceBack_Here+0x66c>  // b.plast
  1c447c:	39c00846 	ldrsb	w6, [x2, #2]

​
低效指令片段2
================================================================================
Case 7 | PC: 0x558d364470 -> 0x558d364448
        模块: python3.12
        换算ELF: 0x1c4470 -> 0x1c4448
        地址区间: 0x1c4438 -> 0x1c4480
        二进制: /spark_trace/n00565043/trace-opti/python-pytorch-lto-pgo-testpackage/pytorch-conda-env-ver-pgo-built-on-950/bin/python3.12
        基址: 0x558d1a0000
================================================================================

--- Original case ---
1977544 0x558d364470    f9004be3 str	x3, [sp, #144]
1977548 0x558d364474    eb03009f cmp	x4, x3
1977550 0x558d364478    54002a29 b.ls	0x0000000000000544  // b.plast
1977552 0x558d36447c    39c00846 ldrsb	w6, [x2, #2]
1977556 0x558d364480    37f80266 tbnz	w6, #31, 0x000000000000004c
1977558 0x558d3644cc    aa0303e2 mov	x2, x3
1977560 0x558d3644d0    6b1a003f cmp	w1, w26
1977562 0x558d3644d4    54ffff8d b.le	0xfffffffffffffff0
1977564 0x558d3644c4    2a0103e5 mov	w5, w1
1977566 0x558d3644c8    17ffffca b	0xffffffffffffff28
1977568 0x558d3643f0    eb02009f cmp	x4, x2
1977570 0x558d3643f4    540037c9 b.ls	0x00000000000006f8  // b.plast
1977572 0x558d3643f8    39400041 ldrb	w1, [x2]
1977576 0x558d3643fc    d3431821 ubfx	x1, x1, #3, #4
1977578 0x558d364400    71003c3f cmp	w1, #0xf
1977580 0x558d364404    54001ae0 b.eq	0x000000000000035c  // b.none
1977582 0x558d364408    7100303f cmp	w1, #0xc
1977584 0x558d36440c    540019e8 b.hi	0x000000000000033c  // b.pmore
1977586 0x558d364410    71002c3f cmp	w1, #0xb
1977588 0x558d364414    54001ce0 b.eq	0x000000000000039c  // b.none
1977590 0x558d3647b0    11000673 add	w19, w19, #0x1
1977592 0x558d3647b4    17ffffeb b	0xffffffffffffffac
1977594 0x558d364760    b9008bf3 str	w19, [sp, #136]
1977598 0x558d364764    2a1303e1 mov	w1, w19
1977600 0x558d364768    39400040 ldrb	w0, [x2]
1977604 0x558d36476c    53037c00 lsr	w0, w0, #3
1977606 0x558d364770    71007c1f cmp	w0, #0x1f
1977608 0x558d364774    54ffe621 b.ne	0xfffffffffffffcc4  // b.any
1977610 0x558d364438    aa0203e3 mov	x3, x2
1977612 0x558d36443c    b9007be5 str	w5, [sp, #120]
1977616 0x558d364440    b90083e1 str	w1, [sp, #128]
1977620 0x558d364444    38401461 ldrb	w1, [x3], #1
1977624 0x558d364448    f9004be3 str	x3, [sp, #144]

--- OBJDUMP disassembly (with source, PC START/END marked) ---

/spark_trace/n00565043/trace-opti/python-pytorch-lto-pgo-testpackage/pytorch-conda-env-ver-pgo-built-on-950/bin/python3.12:     file format elf64-littleaarch64


Disassembly of section .text:

00000000001c4438 <PyTraceBack_Here+0xe8>:
next_code_delta():
/home/l00886679/projects/python-pgo-affacts/Python-3.12.0/Objects/codeobject.c:887
  1c4438:	aa0203e3 	mov	x3, x2
advance():
/home/l00886679/projects/python-pgo-affacts/Python-3.12.0/Objects/codeobject.c:968
  1c443c:	b9007be5 	str	w5, [sp, #120]
  1c4440:	b90083e1 	str	w1, [sp, #128]
next_code_delta():
/home/l00886679/projects/python-pgo-affacts/Python-3.12.0/Objects/codeobject.c:887
  1c4444:	38401461 	ldrb	w1, [x3], #1
advance():
/home/l00886679/projects/python-pgo-affacts/Python-3.12.0/Objects/codeobject.c:971
  1c4448:	f9004be3 	str	x3, [sp, #144]    <=== PC END (0x558d364448, ELF 0x1c4448)
next_code_delta():
/home/l00886679/projects/python-pgo-affacts/Python-3.12.0/Objects/codeobject.c:887
  1c444c:	531f0821 	ubfiz	w1, w1, #1, #3
  1c4450:	11000821 	add	w1, w1, #0x2
advance():
/home/l00886679/projects/python-pgo-affacts/Python-3.12.0/Objects/codeobject.c:969
  1c4454:	0b050021 	add	w1, w1, w5
  1c4458:	b9007fe1 	str	w1, [sp, #124]
/home/l00886679/projects/python-pgo-affacts/Python-3.12.0/Objects/codeobject.c:972
  1c445c:	eb03009f 	cmp	x4, x3
  1c4460:	54002ae9 	b.ls	1c49bc <PyTraceBack_Here+0x66c>  // b.plast
  1c4464:	39c00446 	ldrsb	w6, [x2, #1]
  1c4468:	37f80326 	tbnz	w6, #31, 1c44cc <PyTraceBack_Here+0x17c>
/home/l00886679/projects/python-pgo-affacts/Python-3.12.0/Objects/codeobject.c:971
  1c446c:	91000843 	add	x3, x2, #0x2
  1c4470:	f9004be3 	str	x3, [sp, #144]    <=== PC START (0x558d364470, ELF 0x1c4470)
/home/l00886679/projects/python-pgo-affacts/Python-3.12.0/Objects/codeobject.c:972
  1c4474:	eb03009f 	cmp	x4, x3
  1c4478:	54002a29 	b.ls	1c49bc <PyTraceBack_Here+0x66c>  // b.plast
  1c447c:	39c00846 	ldrsb	w6, [x2, #2]

​
低效指令片段3
================================================================================
Case 9 | PC: 0x558d364470 -> 0x558d364488
        模块: python3.12
        换算ELF: 0x1c4470 -> 0x1c4488
        地址区间: 0x1c4460 -> 0x1c44a0
        二进制: /spark_trace/n00565043/trace-opti/python-pytorch-lto-pgo-testpackage/pytorch-conda-env-ver-pgo-built-on-950/bin/python3.12
        基址: 0x558d1a0000
================================================================================

--- Original case ---
1977650 0x558d364470    f9004be3 str	x3, [sp, #144]
1977654 0x558d364474    eb03009f cmp	x4, x3
1977656 0x558d364478    54002a29 b.ls	0x0000000000000544  // b.plast
1977658 0x558d36447c    39c00846 ldrsb	w6, [x2, #2]
1977662 0x558d364480    37f80266 tbnz	w6, #31, 0x000000000000004c
1977664 0x558d364484    91000c43 add	x3, x2, #0x3
1977666 0x558d364488    f9004be3 str	x3, [sp, #144]

--- OBJDUMP disassembly (with source, PC START/END marked) ---

/spark_trace/n00565043/trace-opti/python-pytorch-lto-pgo-testpackage/pytorch-conda-env-ver-pgo-built-on-950/bin/python3.12:     file format elf64-littleaarch64


Disassembly of section .text:

00000000001c4460 <PyTraceBack_Here+0x110>:
advance():
/home/l00886679/projects/python-pgo-affacts/Python-3.12.0/Objects/codeobject.c:972
  1c4460:	54002ae9 	b.ls	1c49bc <PyTraceBack_Here+0x66c>  // b.plast
  1c4464:	39c00446 	ldrsb	w6, [x2, #1]
  1c4468:	37f80326 	tbnz	w6, #31, 1c44cc <PyTraceBack_Here+0x17c>
/home/l00886679/projects/python-pgo-affacts/Python-3.12.0/Objects/codeobject.c:971
  1c446c:	91000843 	add	x3, x2, #0x2
  1c4470:	f9004be3 	str	x3, [sp, #144]    <=== PC START (0x558d364470, ELF 0x1c4470)
/home/l00886679/projects/python-pgo-affacts/Python-3.12.0/Objects/codeobject.c:972
  1c4474:	eb03009f 	cmp	x4, x3
  1c4478:	54002a29 	b.ls	1c49bc <PyTraceBack_Here+0x66c>  // b.plast
  1c447c:	39c00846 	ldrsb	w6, [x2, #2]
  1c4480:	37f80266 	tbnz	w6, #31, 1c44cc <PyTraceBack_Here+0x17c>
/home/l00886679/projects/python-pgo-affacts/Python-3.12.0/Objects/codeobject.c:971
  1c4484:	91000c43 	add	x3, x2, #0x3
  1c4488:	f9004be3 	str	x3, [sp, #144]    <=== PC END (0x558d364488, ELF 0x1c4488)
/home/l00886679/projects/python-pgo-affacts/Python-3.12.0/Objects/codeobject.c:972
  1c448c:	eb03009f 	cmp	x4, x3
  1c4490:	54002969 	b.ls	1c49bc <PyTraceBack_Here+0x66c>  // b.plast
  1c4494:	39c00c40 	ldrsb	w0, [x2, #3]
  1c4498:	37f801a0 	tbnz	w0, #31, 1c44cc <PyTraceBack_Here+0x17c>
  1c449c:	91001043 	add	x3, x2, #0x4
