# lab4 抢占式多任务机制

## 介绍
在这个实验中，你将在多并行的用户环境下实现抢占式多任务机制。  
在part A中，你需要在JOS中加入对多个任务处理器的支持，实现轮询调度机制，加入基本的环境管理的系统调用（通过这些进行创建与销毁用户环境，并且分配内存）。  
在part B中，你将会实现unix风格的fork()， 这个函数运行一个用户环境创建一个自己的拷贝。   
在part C中，你将会加入进程间通信机制(IPC)，运行不同的用户环境显式的进行通信与同步，你还需要加入对硬件时钟中断的支持，和抢占机制。   
## 开始
按照惯例，又有了一些新文件
```
    kern/cpu.h	内核私有的对多处理器的支持
    kern/mpconfig.c 读取多处理器配置的代码
    kern/lapic.c	内核驱动本地AIPC单元的代码
    kern/mpentry.S	非启动CPU的汇编代码entry
    kern/spinlock.h	内核私有的自旋锁，包括内核锁（保存内核的原子性的锁变量）
    kern/spinlock.c	内核的自旋锁代码
    kern/sched.c	你需要补全的调度框架代码

```

## PART A 多处理器支持与协作多任务
在实验的这部分中，我们首先拓展jos使其运行在多处理器系统上，然后实现jos内核一些系统功能调用以支持用户级环境去创建新环境，并且你需要实现协同轮询调度机制，当当前用户环境让出CPU资源时（或者退出时），允许内核从一个用户环境切换至另一个用户环境，在part C中，你还将实现抢占多任务机制，运行内核在一个确定的时间重新获得CPU资源，尽管当前的环境不合作。  
### 多处理器支持
我们现在即将实现JOS的“symetric multiprocessing”(SMP)机制，在这个机制下，所有cpu对系统资源（包括IO总线，内存）有平等的权限。尽管所有CPU在SMP机制中功能一致，不过在系统启动的过程中，他们被分为两类： 
* 启动处理器（Bootstrap Processor, BSP），负责系统的启动；
* 应用处理器(Application Processor, AP)，在BSP启动操作系统后被激活；  
哪一个CPU是BSP是由BIOS决定的，知道目前位置，所有JOS代码通过BSP运行。   
在SMP系统中，每个CPU有一个对应的本地APIC（LAPIC）单元，这个单元负责通过系统传递中断。LAPIC给与之关联的CPU一个唯一标志符，在这个实验中，我们使用下列的LAPIC的基本功能：
* 读取LAPIC的标志符（APIC ID），我们的代码目前是哪个CPU正在运行，函数cpunum()。   
* 从启动处理器到应用处理器，发送STARTUP处理器间中断，进而启动其他CPU，lapic_startup()。    
* 在part C中，我们补全LAPIC的时分，去出发时钟中断，支持抢占多任务, apic_init()。   

处理器通过memory-mapped IO(MMIO)访问其LAPIC，在MMIO中，一部分物理内存硬连接到其他IO设备，在这个情况下，使用存储与读取指令可以直接访问外部设备的寄存器。你已经看到物理地址在0xA0000（我们用于写入VGA显示显示器buffer），LAPIC单元存在起点物理地址为0xfe000000（也就是4G - 32MB），这么高的地址是不能KERNBASE直接进行访问，JOS虚拟地址在MMIOBASE映射了4MB的空隙，我们可以将设备映射到这个位置，在后续的实验中，会引入更多的MMIO区域，你将会写一个简单的函数分配地址从其他不同区域或者设备内存分配到这个地址。


#### 练习1
```
实现kern/pmap.c中的mmio_map_region函数，阅读kern/lapic.c的lapic_init函数，了解该函数是如何被调用的。在测试mmio_map_region进行前，你还有完成下一个练习。
```

------
根据注释的提示，该函数就是将[pa, pa + size]的区域，映射到c从MMIOBASE开始的[base, base + size]的区域，并返回base地址
* 首先需要round up为4k的整数倍
* base + size 不应该超过MMIOLIM，超过应该panic
* 需要更新静态变量base，并返回未更新前的地址。
```

//
// Reserve size bytes in the MMIO region and map [pa,pa+size) at this
// location.  Return the base of the reserved region.  size does *not*
// have to be multiple of PGSIZE.
//
void *
mmio_map_region(physaddr_t pa, size_t size)
{
	// Where to start the next region.  Initially, this is the
	// beginning of the MMIO region.  Because this is static, its
	// value will be preserved between calls to mmio_map_region
	// (just like nextfree in boot_alloc).
	static uintptr_t base = MMIOBASE;

	// Reserve size bytes of virtual memory starting at base and
	// map physical pages [pa,pa+size) to virtual addresses
	// [base,base+size).  Since this is device memory and not
	// regular DRAM, you'll have to tell the CPU that it isn't
	// safe to cache access to this memory.  Luckily, the page
	// tables provide bits for this purpose; simply create the
	// mapping with PTE_PCD|PTE_PWT (cache-disable and
	// write-through) in addition to PTE_W.  (If you're interested
	// in more details on this, see section 10.5 of IA32 volume
	// 3A.)
	//
	// Be sure to round size up to a multiple of PGSIZE and to
	// handle if this reservation would overflow MMIOLIM (it's
	// okay to simply panic if this happens).
	//
	// Hint: The staff solution uses boot_map_region.
	//
	// Your code here:
	size = ROUNDUP(size, PGSIZE);
	if (size + base > MMIOLIM)
		panic("mmio_map_region overflow");
	boot_map_region(kern_pgdir, base, size, pa, PTE_PCD | PTE_PWT | PTE_W);
	uintptr_t ret = base;
	base += size;
	return (void *)ret;
	//panic("mmio_map_region not implemented");
}

```
### Application Processor BootStrap

在启动应用处理器之前，BSP首先应该收集多处理器系统的信息，比如，总CPU数量，他们的APIC ID和LAPIC单元在MMIO的地址，'kern/mpconfig.c'中的mp_init()函数通过位于BIOS区域的MP配置表检索这类信息。

'kern/init.c'的boot_aps函数引导AP的bootstrap进程，AP启动与实模式，与boot.s中的bootloader类似，boot_aps()拷贝AP入口代码，到BSP实模式下的内存中，与bootloader不同的是，我们对于AP入口代码存放的位置可以有一定控制权：在JOS中使用MPENTRY_PADDR(0x7000)作为入口地址的存放位置，但是实际上640KB下任何未使用的地址都是可以使用的。

接下来，boot_aps()函数一个接一个的激活AP，通过向对应的AP发送STARTUP的IPI信号（处理器间中断），使用AP的入口代码初始化CS：IP地址（也就是entry code的起始地址）依次激活APs。AP就运行mpentry.s中的代码，从实模式运行到保护模式，最后mpentry.s调用C语言代码mp_main()('kern/init.c')，boot_aps等待AP将更新cpu_status到CPU_STATRTED，再去唤醒下一个AP。

#### 练习2
阅读boot_aps()与mp_main()与'kern/mpentry.s'代码，确保你理解了控制流的转换，然后修改page_init()避免在MPENTRY_PADDR的page加入空闲的页链表，由此可以安全的拷贝核运行AP的bootstrap代码，你的代码应该可用过测试check_page_free_list()。

-------
* 代码阅读
首先boot_aps()是BSP进行调用,这个函数主要是将mpentry的代码拷贝至0x7000处，同时引导AP启动。此时BSP已经运行在实模式下，所以应该是0x7000的虚拟地址。并通过函数lapic_startup()引导AP在0x7000启动，并等待CPU修改其自身状态。AP启动后，执行mpentry.s的代码；

```
// Start the non-boot (AP) processors.
static void
boot_aps(void)
{
	extern unsigned char mpentry_start[], mpentry_end[];
	void *code;
	struct CpuInfo *c;

	// Write entry code to unused memory at MPENTRY_PADDR
	code = KADDR(MPENTRY_PADDR);
	memmove(code, mpentry_start, mpentry_end - mpentry_start);

	// Boot each AP one at a time
	for (c = cpus; c < cpus + ncpu; c++) {
		if (c == cpus + cpunum())  // We've started already.
			continue;

		// Tell mpentry.S what stack to use 
		mpentry_kstack = percpu_kstacks[c - cpus] + KSTKSIZE;
		// Start the CPU at mpentry_start
		lapic_startap(c->cpu_id, PADDR(code));
		// Wait for the CPU to finish some basic setup in mp_main()
		while(c->cpu_status != CPU_STARTED)
			;
	}
}
```
* 练习解答
在page_init()中，将PGNUM(0x7000)的page不放在free list中即可。
```

//
// Initialize page structure and memory free list.
// After this is done, NEVER use boot_alloc again.  ONLY use the page
// allocator functions below to allocate and deallocate physical
// memory via the page_free_list.
//
void
page_init(void)
{
	// LAB 4:
	// Change your code to mark the physical page at MPENTRY_PADDR
	// as in use

	// The example code here marks all physical pages as free.
	// However this is not truly the case.  What memory is free?
	//  1) Mark physical page 0 as in use.
	//     This way we preserve the real-mode IDT and BIOS structures
	//     in case we ever need them.  (Currently we don't, but...)
	//  2) The rest of base memory, [PGSIZE, npages_basemem * PGSIZE)
	//     is free.
	//  3) Then comes the IO hole [IOPHYSMEM, EXTPHYSMEM), which must
	//     never be allocated.
	//  4) Then extended memory [EXTPHYSMEM, ...).
	//     Some of it is in use, some is free. Where is the kernel
	//     in physical memory?  Which pages are already in use for
	//     page tables and other data structures?
	//
	// Change the code to reflect this.
	// NB: DO NOT actually touch the physical memory corresponding to
	// free pages!
	size_t i;
	page_free_list = NULL;

	//num_alloc：在extmem区域已经被占用的页的个数
	int num_alloc = ((uint32_t)boot_alloc(0) - KERNBASE) / PGSIZE;
	//num_iohole：在io hole区域占用的页数
	int num_iohole = 96;

	for(i=0; i<npages; i++)
	{
		if(i==0)
		{
			pages[i].pp_ref = 1;
		}    
		else if(i >= npages_basemem && i < npages_basemem + num_iohole + num_alloc)
		{
			pages[i].pp_ref = 1;
		}
		else if (i == PGNUM(MPENTRY_PADDR))
			pages[i].pp_ref = 1;
		else
		{
			pages[i].pp_ref = 0;
			pages[i].pp_link = page_free_list;
			page_free_list = &pages[i];
		}
	}
}

```
#### 问题
* 比较'kern/mpentry.S'和'boot/boot.S'，记住两个代码都是编译连接后加载到KERNBASE之上运行的，为什么mpentry.S需要一个多余的宏定义MPBOOTPHYS？换句话说，如果在'kern/mpentry'省略它会出现什么问题？

因为mpentry.s传入的地址均为BSP的虚拟地址，在KERNBASE之上，而此时AP运行在16bits的实模式中，不可能访问到那么高的地址，通过该宏定义做一个内存映射，保证实模式能够正确访问。



### 每个CPU的状态及其初始化（Per—CPU State and Initialization）
当面向多处理器系统编程时，最重要的是区分每个cpu的状态对每个CPU来说是私有的，全局的状态是整个系统共享的，'kern/cpu.h'定义了大部分每个cpu的状态。包括'struct CpuInfo'，'cpunum'总是返回调用该函数的cpu id，该id一般被作为数组的索引值，比如cpus，宏定义'thiscpu'是当前cpu的'struct CpuInfo'的简写：
下面每个cpu值得注意的：
* 每个cpu的内核栈
* 每个cpu的TSS和TSS描述器
* 每个cpu的当前环境指针
* 每个cpu的系统寄存器

#### 练习3
修改'kern/pmap.c'中的'mem_init_mp()'，让CPU内核栈映射到相应的虚拟内存， 在KSTACKTOP开始，每个栈之间还有KSTKGAP的间隔，你的代码应该通过'check_kern_pgdir()'函数。

---
```

// Modify mappings in kern_pgdir to support SMP
//   - Map the per-CPU stacks in the region [KSTACKTOP-PTSIZE, KSTACKTOP)
//
static void
mem_init_mp(void)
{
	// Map per-CPU stacks starting at KSTACKTOP, for up to 'NCPU' CPUs.
	//
	// For CPU i, use the physical memory that 'percpu_kstacks[i]' refers
	// to as its kernel stack. CPU i's kernel stack grows down from virtual
	// address kstacktop_i = KSTACKTOP - i * (KSTKSIZE + KSTKGAP), and is
	// divided into two pieces, just like the single stack you set up in
	// mem_init:
	//     * [kstacktop_i - KSTKSIZE, kstacktop_i)
	//          -- backed by physical memory
	//     * [kstacktop_i - (KSTKSIZE + KSTKGAP), kstacktop_i - KSTKSIZE)
	//          -- not backed; so if the kernel overflows its stack,
	//             it will fault rather than overwrite another CPU's stack.
	//             Known as a "guard page".
	//     Permissions: kernel RW, user NONE
	//
	// LAB 4: Your code here:
	for (uint32_t i = 0; i < NCPU; i ++){
		boot_map_region(kern_pgdir, KSTACKTOP - i * (KSTKSIZE + KSTKGAP) - KSTKSIZE, 
		KSTKSIZE, PADDR(percpu_kstacks[i]), PTE_W);
	}
}

```

#### 练习4
在'kern/trap.c'在trap_init_percpu()初始化了BSP的TSS和TSS描述器，在lab3中他是有效的，但是在其他CPU上是不正确的，修改这部分代码，使其对所有CPU均有效（tips：你的新代码不应该使用全局变量ts）

```
void
trap_init_percpu(void)
{
	// The example code here sets up the Task State Segment (TSS) and
	// the TSS descriptor for CPU 0. But it is incorrect if we are
	// running on other CPUs because each CPU has its own kernel stack.
	// Fix the code so that it works for all CPUs.
	//
	// Hints:
	//   - The macro "thiscpu" always refers to the current CPU's
	//     struct CpuInfo;
	//   - The ID of the current CPU is given by cpunum() or
	//     thiscpu->cpu_id;
	//   - Use "thiscpu->cpu_ts" as the TSS for the current CPU,
	//     rather than the global "ts" variable;
	//   - Use gdt[(GD_TSS0 >> 3) + i] for CPU i's TSS descriptor;
	//   - You mapped the per-CPU kernel stacks in mem_init_mp()
	//   - Initialize cpu_ts.ts_iomb to prevent unauthorized environments
	//     from doing IO (0 is not the correct value!)
	//
	// ltr sets a 'busy' flag in the TSS selector, so if you
	// accidentally load the same TSS on more than one CPU, you'll
	// get a triple fault.  If you set up an individual CPU's TSS
	// wrong, you may not get a fault until you try to return from
	// user space on that CPU.
	//
	// LAB 4: Your code here:
	int idx = thiscpu->cpu_id;
	struct Taskstate cpuTs = thiscpu->cpu_ts;
	// Setup a TSS so that we get the right stack
	// when we trap to the kernel.
	cpuTs.ts_esp0 = (uintptr_t)percpu_kstacks[idx];
	cpuTs.ts_ss0 = GD_KD;
	cpuTs.ts_iomb = sizeof(struct Taskstate);

	// Initialize the TSS slot of the gdt.
	gdt[(GD_TSS0 >> 3) + idx] = SEG16(STS_T32A, (uint32_t) (&thiscpu->cpu_ts),
					sizeof(struct Taskstate) - 1, 0);
	gdt[(GD_TSS0 >> 3) + idx].sd_s = 0;

	// Load the TSS selector (like other segment selectors, the
	// bottom three bits are special; we leave them 0)
	ltr(GD_TSS0 + (idx << 3));

	// Load the IDT
	lidt(&idt_pd);
}

```
在完成上述练习后，你使用4个CPU运行JOS'make qemu CPUS=4'，你会看到输出如下所示:
```
...
Physical memory: 66556K available, base = 640K, extended = 65532K
check_page_alloc() succeeded!
check_page() succeeded!
check_kern_pgdir() succeeded!
check_page_installed_pgdir() succeeded!
SMP: CPU 0 found 4 CPU(s)
enabled interrupts: 1 2
SMP: CPU 1 starting
SMP: CPU 2 starting
SMP: CPU 3 starting

```
### locking
我们现在的代码，在AP启动后会一直处于忙等待的状态（又叫自旋-spin），在AP进一步运行其他程序前，我们首先需要解决的是多CPU的内存，最简单的方法实现一个内核锁，内核锁是一个全局的锁变量，当一个环境进入到内核态时，这个锁变量被持有，在这个环境退出内核态时，释放该变量。在这个模式下，用户态的程序可以进行并发，但是只有一个环境可以进入到内核态，在内核态被占用时，任意想要进入内核态的环境被强制要求等待。

'kern/spinlock.h'声明了内核锁变量'kernal_lock'，同时其提供了'lock_kernal'和'unlock_kernal'两个函数对其进行操作。你应该在下面四个地方将其应用:

* 在i386_init()函数中，取得锁变量，在BSP唤醒其他CPU
* 在mp_main()中， 在初始化AP后，获得锁变量，然后调用sched_yield()在该AP中启动环境。
* 在trap中，当用户态通过trap进入内核态时，获取锁变量，为了判断，trap发生在内核态还是用户态，需要将检查tf_cs的low bits
* 在env_run中，在其切换至用户态时，释放锁变量，不能太早或者太晚，否则你会有竞争或者死锁的风险。

#### 练习5
根据上述要求应用锁变量

此时你暂时无法验证你的获取与释放锁变量的位置是否正确，应该是在你完成调度机制之后才可以验证。

#### 问题
使用锁变量保证了只有一个CPU可以进入到内核态，为什么还是需要对不同的内核使用不用内核栈，描述一个尽管使用了内核锁后，共用内核栈会发生错误的情况

---

在不同CPU由于中断发生切换时，？


### CPU的轮询调度（Round-Robin Scheduling）
你的下一个任务是修改JOS内核，使其可以在多任务环境下进行以时间轮转的形式进行切换，Round-robin调度机制如下所示：
* 函数'sched_yield'在'kern/sched.c'中，是负责选择一个新环境进行运行，他顺序搜索envs数组，从上一个运行的环境开始，找到第一个ENV_RUNABLE的环境，然后通过env_run()切换到这个环境。

* 'sched_yield()'不能让相同的环境运行在两个CPU中，他可以通环境的状态是否为'ENV_RUNNING'进行判断。


* 我们已经实现了一个新的系统调用'sys_yield()'，用户态可以通过这个系统调用，自愿放弃CPU资源，从而切换到其他运行环境。

#### 练习6
在'sched_yield()'实现round-robin调度机制(也就是轮询调度机制)，不要忘记了在系统调用中解析sys_yield()，保证在mp_main()中调用sched_yield()

修改'kern/init.c'创建3个或者更多的环境，都运行程序'user/yield.c'

运行'make qemu'，你应该看到环境来回切换，在其终止之前，共来回切换5次，和下面类似:

```
...
Hello, I am environment 00001000.
Hello, I am environment 00001001.
Hello, I am environment 00001002.
Back in environment 00001000, iteration 0.
Back in environment 00001001, iteration 0.
Back in environment 00001002, iteration 0.
Back in environment 00001000, iteration 1.
Back in environment 00001001, iteration 1.
Back in environment 00001002, iteration 1.
...
```

---

* sched_yield()

```

// Choose a user environment to run and run it.
void
sched_yield(void)
{
	struct Env *idle;

	// Implement simple round-robin scheduling.
	//
	// Search through 'envs' for an ENV_RUNNABLE environment in
	// circular fashion starting just after the env this CPU was
	// last running.  Switch to the first such environment found.
	//
	// If no envs are runnable, but the environment previously
	// running on this CPU is still ENV_RUNNING, it's okay to
	// choose that environment.
	//
	// Never choose an environment that's currently running on
	// another CPU (env_status == ENV_RUNNING). If there are
	// no runnable environments, simply drop through to the code
	// below to halt the cpu.

	// LAB 4: Your code here.
	int i, index = 0;
	if (curenv)
		index = ENVX(curenv->env_id);
	else
		index = 0;

	for(i = index; i != index + NENV ; i++) {
		if (envs[i%NENV].env_status == ENV_RUNNABLE)
			env_run(&envs[i%NENV]);
	}
	if(curenv && curenv->env_status == ENV_RUNNING) {
		env_run(curenv);
	}
	// sched_halt never returns
	sched_halt();
}

```

* syscall

```
case SYS_yield:
	sys_yield();
	break;
```

### System Calls for Environment Creation
尽管你目前可以多个用户态中进行切换，但是现有的用户态初始化完全依赖内核，接下来JOS会实现从用户态创建与启动新的用户态。

Unix提供了fork这个系统调用，fork拷贝了父进程的整个地址空间，唯一可见的不同在于父子进程的ID不一样。父进程中的fork返回子进程号，子进程中的fork返回0。默认情况下，每一个进程都有其私有的地址空间，而且任意一个进程对于内核的修改对于其他进程而言都是不可见的。

现在我们将实现一个jos系统调用,以使用户创建新的用户模式环境。完成这些这些系统调用。我们将实现以下的系统调用函数：
* sys_exofork()

* sys_env_set_status:


* sys_page_alloc:


* sys_page_map:

* sys_page_unmap:


## Part B:Copy-on-Write Fork

fork一般需要将父进程的所有数据拷贝至新分配的页中，这也是fork最消耗时间的操作。

但是，fork之后往往在子程序中立刻调用exec函数，这个操作替换了子进程的内存（比如shell经常是这个样子，shell -> fork() -> 其他程序），如此看来，完全拷贝父进程的内存是较为消耗时间的。

基于上述原因，最近版本的unix允许父进程与子进程在他们各自的地址空间共享内存，知道一个进程真的修改内存，这个技术叫写时复制。为了达到这个效果，子进程拷贝的是父进程的内存映射关系，而不是真的内存，同时将其标记为只读。当其中一个进程想要修改这部分只读内存，处理器会报告一个page fault，在这个时候，Unix明白，这页是一个虚拟内存的拷贝，或者是写时复制拷贝，所以操作系统将会在页处理程序中，拷贝一个私有的、可写的页，用于该进程自己使用。通过这个方式，在父子进程真正修改这部分内存的时候才进行复制，这种优化方式，然后fork后立马执行其他程序的情况，摒弃了大量的复制操作。

在接下来的实验中，你将实现一个写时复制的fork。

### 设置页错误的handler
为了捕获自己的page fault，一个用户环境应该注册一个page fault handler入口。用户环境下注册page fault handler通过系统调用`sys_env_set_pgfault_upcall`。我们已经加入了env结构体中加入了新的成员`env_pgfault_upcall`记录这些信息。

#### 练习8
实现`sys_env_set_pgfault_upcall`，确保在查找目标环境ID时候，先进行鉴权。

---
* `sys_env_set_pgfault_upcall`
```
static int
sys_env_set_pgfault_upcall(envid_t envid, void *func)
{
	// LAB 4: Your code here.

	struct Env *env;
	int eid = envid2env(envid, &env, 1);
	if (eid < 0)
		return -E_BAD_ENV;
	env->env_pgfault_upcall = func;
	return 0;
	panic("sys_env_set_pgfault_upcall not implemented");
}
```

#### 用户态的正常栈与异常栈

在正常的执行中，用户环境运行在正常栈中，其ESP指针开始与USTACKTOP，所有的栈数据均在USTACKTOP - 1到USTACKTOP-PGSIZE之间。当用户态发生页错误时，内核会重启用户环境，使其运行在设计好的栈，被称为用户异常栈。我们将会让JOS代表用户态实现自动切换，而x86已经实现栈切换。

JOS的用户异常栈占一个page，栈顶是在UXSTACKTOP。当环境运行在异常栈中，用户态的page fault handler可以使用JOS的普通系统调用去映射新的page或者调整映射，去解决引起page fault的问题。然后用户态的page fault handler返回，通过汇编代码，将错误代码放在原有的栈上。

每个用户环境 需要通过sys_page_alloc()系统调用支持用户级的page fault 捕获需要分配自己的异常栈。

#### 调用用户Page Fault Handler
你需要修改`kern/trap.c`去捕获用户态的page fault，我们将用户态发生错误的时间叫做trap-time。

如果没有page fault handler注册，JOS内核摧毁当前用户环境，并在此之前发出一个消息，否则，内核在异常栈中建立一个trap栈帧，就像`inc/trap.h`的结构体`UTrapframe`一样。
```
                    <-- UXSTACKTOP
trap-time esp
trap-time eflags
trap-time eip
trap-time eax       start of struct PushRegs
trap-time ecx
trap-time edx
trap-time ebx
trap-time esp
trap-time ebp
trap-time esi
trap-time edi       end of struct PushRegs
tf_err (error code)
fault_va            <-- %esp when handler is run
```
然后内核就在异常栈中恢复执行page fault handler，你需要弄清楚这是怎么实现的，fault_va是导致page fault的虚拟地址。

如果用户环境已经运行在用户异常栈中，并再次引发一个异常，page fault handler自己发生错误。在这个情况下，你应在当前tf->tf_esp之下启动一个新的栈帧，而不是在UXSTACKTOP，你应该首先push一个32bits的字，然后是一个UTrapframe结构体。

为了测试`tf->tf_esp`是否已经存在用户异常栈中，需要检查以UXSTACKTOP为起点的一个page。

#### 练习9 
补全`kern/trap.c`的`page_fault_handler`，需要将page fault通过调用用户态的page fault handler处理，在异常栈中写入数据时要有预防措施（如果用户环境在异常栈中stack_overflow会发生什么？）

---

```

void
page_fault_handler(struct Trapframe *tf)
{
	uint32_t fault_va;

	// Read processor's CR2 register to find the faulting address
	fault_va = rcr2();

	// Handle kernel-mode page faults.

	// LAB 3: Your code here.
	if ((tf->tf_cs & 1) == 0)
		panic("page fault in kernal mode, fault address in %d\n", fault_va);
	// We've already handled kernel-mode exceptions, so if we get here,
	// the page fault happened in user mode.

	// Call the environment's page fault upcall, if one exists.  Set up a
	// page fault stack frame on the user exception stack (below
	// UXSTACKTOP), then branch to curenv->env_pgfault_upcall.
	//
	if (curenv->env_pgfault_upcall) {
		struct UTrapframe *utf;
		uintptr_t utf_addr;
		// 判断一下是不是迭代的中断：如果是缺页中断迭代，
		// esp必然在[UXSTACKTOP-PGSIZE, UXSTACKTOP-1]之间
		if (UXSTACKTOP - PGSIZE <= tf->tf_esp && tf->tf_esp <= UXSTACKTOP-1)
			// -4是为了预留4个字节将指向utf的esp压入栈内，
			// 这样就可以作为参数传递给后来的函数。
			utf_addr = tf->tf_esp - sizeof(struct UTrapframe) - 4;
		else 
			utf_addr = UXSTACKTOP - sizeof(struct UTrapframe);
		// 填充utf结构
		user_mem_assert(curenv, (void*)utf_addr, 1, PTE_W);
		utf = (struct UTrapframe *) utf_addr;

		utf->utf_fault_va = fault_va;
		utf->utf_err = tf->tf_err;
		utf->utf_regs = tf->tf_regs;
		utf->utf_eip = tf->tf_eip;
		utf->utf_eflags = tf->tf_eflags;
		utf->utf_esp = tf->tf_esp;

		curenv->env_tf.tf_eip = (uintptr_t)curenv->env_pgfault_upcall;
		// 将原来的stack切换成新的stack，然后运行env_run
		curenv->env_tf.tf_esp = utf_addr;
		env_run(curenv);
		// 现在CPU切换到用户态了。
		// 因为env_run还原的cs寄存器是用户态的cs
	}
	  // Destroy the environment that caused the fault.
	cprintf("[%08x] user fault va %08x ip %08x\n",
		curenv->env_id, fault_va, tf->tf_eip);
	print_trapframe(tf);
	env_destroy(curenv);
	
	
    
	// The page fault upcall might cause another page fault, in which case
	// we branch to the page fault upcall recursively, pushing another
	// page fault stack frame on top of the user exception stack.
	//
	// It is convenient for our code which returns from a page fault
	// (lib/pfentry.S) to have one word of scratch space at the top of the
	// trap-time stack; it allows us to more easily restore the eip/esp. In
	// the non-recursive case, we don't have to worry about this because
	// the top of the regular user stack is free.  In the recursive case,
	// this means we have to leave an extra word between the current top of
	// the exception stack and the new stack frame because the exception
	// stack _is_ the trap-time stack.
	//
	// If there's no page fault upcall, the environment didn't allocate a
	// page for its exception stack or can't write to it, or the exception
	// stack overflows, then destroy the environment that caused the fault.
	// Note that the grade script assumes you will first check for the page
	// fault upcall and print the "user fault va" message below if there is
	// none.  The remaining three checks can be combined into a single test.
	//
	// Hints:
	//   user_mem_assert() and env_run() are useful here.
	//   To change what the user environment runs, modify 'curenv->env_tf'
	//   (the 'tf' variable points at 'curenv->env_tf').

	// LAB 4: Your code here.

	
}
```



#### 用户态下的页错误入口

接下里你需要实现汇编代码，需要实现lib/pfentry.S中的_pgfault_upcall函数，该函数会作为系统调用sys_env_set_pgfault_upcall()的参数。

#### 练习10
实现`lib/pfentry.s`的`_pgfault_upcall`函数，最精彩的部分是返回原来导致page fault的用户代码，你会不经过内核直接到达这里，最难的部分是同时切换栈和重新加载EIP指针。

最后你需要实现用户端的，用户级别的page fault捕获机制

迫于不会写汇编代码，直接贴一个别人的代码吧。

---

```
.text
.globl _pgfault_upcall
_pgfault_upcall:
	// Call the C page fault handler.
	pushl %esp			// function argument: pointer to UTF
	movl _pgfault_handler, %eax
	call *%eax
	addl $4, %esp			// pop function argument
	
	// Now the C page fault handler has returned and you must return
	// to the trap time state.
	// Push trap-time %eip onto the trap-time stack.
	//
	// Explanation:
	//   We must prepare the trap-time stack for our eventual return to
	//   re-execute the instruction that faulted.
	//   Unfortunately, we can't return directly from the exception stack:
	//   We can't call 'jmp', since that requires that we load the address
	//   into a register, and all registers must have their trap-time
	//   values after the return.
	//   We can't call 'ret' from the exception stack either, since if we
	//   did, %esp would have the wrong value.
	//   So instead, we push the trap-time %eip onto the *trap-time* stack!
	//   Below we'll switch to that stack and call 'ret', which will
	//   restore %eip to its pre-fault value.
	//
	//   In the case of a recursive fault on the exception stack,
	//   note that the word we're pushing now will fit in the
	//   blank word that the kernel reserved for us.
	//
	// Throughout the remaining code, think carefully about what
	// registers are available for intermediate calculations.  You
	// may find that you have to rearrange your code in non-obvious
	// ways as registers become unavailable as scratch space.
	//
	// LAB 4: Your code here.
	movl %esp, %ebx
	// Restore the trap-time registers.  After you do this, you
	// can no longer modify any general-purpose registers.
	// LAB 4: Your code here.
	movl 40(%esp), %eax
	movl 48(%esp), %esp
	pushl %eax
	// Restore eflags from the stack.  After you do this, you can
	// no longer use arithmetic operations or anything else that
	// modifies eflags.
	// LAB 4: Your code here.
	movl %ebx, %esp
	subl $4, 48(%esp)
	popl %eax
	popl %eax
	popal
	// Switch back to the adjusted trap-time stack.
	// LAB 4: Your code here.
	add $4, %esp
  	popfl
	// Return to re-execute the instruction that faulted.
	// LAB 4: Your code here.
	popl %esp
	ret
```

#### 练习11
完成`lib/pgfault.c`中的`set_pgfault_handler`函数

---

这个函数的作用是在用户态page fault的时候，准备page fault处理函数之前的准备，包括异常栈的初始化等，这个函数接受一个函数指针参数。

当page fault发生时，系统进入trap，调用page_fault_handler，该函数判断是否为用户态的page fault，如果是调用当前环境下的事先注册的函数，不过，他调用的都是`_pgfault_upcall`部分代码，并由这部分代码再去调用实际函数。也就是(page fault -> sys_page_fault_handler->_pgfault_upcall->registered handler)

```

//
// Set the page fault handler function.
// If there isn't one yet, _pgfault_handler will be 0.
// The first time we register a handler, we need to
// allocate an exception stack (one page of memory with its top
// at UXSTACKTOP), and tell the kernel to call the assembly-language
// _pgfault_upcall routine when a page fault occurs.
//
void
set_pgfault_handler(void (*handler)(struct UTrapframe *utf))
{
	int r;

	if (_pgfault_handler == 0) {
		// First time through!
		// LAB 4: Your code here.
		//panic("set_pgfault_handler not implemented");
		// alloc exception stack
		if (sys_page_alloc(thisenv->env_id, (void *)(UXSTACKTOP - PGSIZE), 
		PTE_P | PTE_W | PTE_U) < 0){
			panic("set_pgfault_handler page alloc failed\n");
		}
		sys_env_set_pgfault_upcall(thisenv->env_id, _pgfault_upcall);
	}

	// Save handler pointer for assembly to call.
	_pgfault_handler = handler;
}

```
在上面练习都完成的情况下，运行`user/faultread`,`user/faultdie`,`user/faultalloc`，`user/faultallocbad.`用于测试程序是否正常。

* 运行`user/faultread`,应该看到
```
...
[00000000] new env 00001000
[00001000] user fault va 00000000 ip 0080003a
TRAP frame ...
[00001000] free env 00001000
```

* 运行`user/faultdie`,应该看到
```
...
[00000000] new env 00001000
i faulted at va deadbeef, err 6
[00001000] exiting gracefully
[00001000] free env 00001000
```

* 运行`user/faultalloc`,应该看到
```
...
[00000000] new env 00001000
fault deadbeef
this string was faulted in at deadbeef
fault cafebffe
fault cafec000
this string was faulted in at cafebffe
[00001000] exiting gracefully
[00001000] free env 00001000
```

* 运行`user/faultallocbad`,应该看到
```
...
[00000000] new env 00001000
[00001000] user_mem_check assertion failure for va deadbeef
[00001000] free env 00001000
```

#### 实现写时复制的Fork
完成上一节准备工作后，开始实现COW的fork，fork实现的流程如下：

* 父进程设置pgfault()函数为页面错误处理函数，用到前面的 set_pgfault_handler 函数。
* 父进程调用 sys_exofork() 创建一个空白子进程。
* 对父进程在UTOP之下的可写或者COW的物理页，父进程调用duppage，duppage会将这些页面设置为COW映射到子进程的地址空间，同时，也要将父进程本身的页面重新映射，将页面权限设置为COW(注：子进程的COW设置要在父进程之前)。duppage将父子进程相关页面权限设置为不可写，且在avail字段设置为COW，用于区分只读页面和COW页面。异常栈不以这种方式重新映射，需要在子进程分配一个新的页面给异常栈用。fork()还要处理那些不是可写的且不是COW的页面。
* 父进程设置子进程的页面错误处理函数。
* 父进程标识子进程状态为可运行。

当父子进程中任意一个试图修改一个还没有写过的COW页面，会触发页面错误，开始下面流程：

* 内核发现用户程序页面错误后，转至_pgfault_upcall处理，而_pgfault_upcall会调用pgfault()。
* pgfault()检查这是一个写错误(错误码中的FEC_WR)且页面权限是COW的，如果不是则报错。
* pgfault()分配一个新的物理页，并映射到一个临时位置，然后将出错页面的内容拷贝到新的物理页中，然后将新的页设置为用户可读写权限，并映射到对应位置。

##### 练习12 
在`lib/fork.c`中实现`fork`,`dubpage`,`pgfault`函数

---


* `dubpage`

```
static int
duppage(envid_t envid, unsigned pn)
{
  int r;

  void *addr = (void*) (pn*PGSIZE);
  if ((uvpt[pn] & PTE_W) || (uvpt[pn] & PTE_COW)) {
      r = sys_page_map(0, addr, envid, addr, PTE_COW|PTE_U|PTE_P);
      if(r < 0)
          return r;
      // 在子进程写addr之前，如果父进程改变p的内容
      // 就会发生copy on write，这样就不会改变原来那一页的内容
      // 于是子进程的内容也就不会改变。
      r = sys_page_map(0, addr, 0, addr, PTE_COW|PTE_U|PTE_P);
      if(r < 0)
          return r;
  }
  else sys_page_map(0, addr, envid, addr, PTE_U|PTE_P);
  return 0;
  panic("duppage not implemented");
}
```

* `pgfault`

```
static void
pgfault(struct UTrapframe *utf)
{
  void *addr = (void *) utf->utf_fault_va;
  uint32_t err = utf->utf_err;
  int r;
   
  if (!((err & FEC_WR) && (uvpd[PDX(addr)] & PTE_P) && (uvpt[PGNUM(addr)] & PTE_P) && (uvpt[PGNUM(addr)] & PTE_COW)))
      panic("not copy-on-write");

  addr = ROUNDDOWN(addr, PGSIZE);
  if (sys_page_alloc(0, PFTEMP, PTE_W|PTE_U|PTE_P) < 0)
      panic("sys_page_alloc");
  memcpy(PFTEMP, addr, PGSIZE);
  if (sys_page_map(0, PFTEMP, 0, addr, PTE_W|PTE_U|PTE_P) < 0)
      panic("sys_page_map");
  if (sys_page_unmap(0, PFTEMP) < 0)
      panic("sys_page_unmap");
  return;
}

```

* `fork`

```
envid_t
fork(void)
{
  // LAB 4: Your code here.
  set_pgfault_handler(pgfault);

  envid_t envid;
  uint32_t addr;
  envid = sys_exofork();
  if (envid == 0) {
      // panic("child");
      thisenv = &envs[ENVX(sys_getenvid())];
      return 0;
  }
  // cprintf("sys_exofork: %x\n", envid);
  if (envid < 0)
      panic("sys_exofork: %e", envid);

  for (addr = 0; addr < USTACKTOP; addr += PGSIZE)
      if ((uvpd[PDX(addr)] & PTE_P) && (uvpt[PGNUM(addr)] & PTE_P)
          && (uvpt[PGNUM(addr)] & PTE_U)) {
          duppage(envid, PGNUM(addr));
      }

  if (sys_page_alloc(envid, (void *)(UXSTACKTOP-PGSIZE), PTE_U|PTE_W|PTE_P) < 0)
      panic("1");
  extern void _pgfault_upcall();
  sys_env_set_pgfault_upcall(envid, _pgfault_upcall);

  if (sys_env_set_status(envid, ENV_RUNNABLE) < 0)
      panic("sys_env_set_status");

  return envid;
  //  panic("fork not implemented");
}
```


## PartC:抢占式多任务与进程间通信

在实验4的最后一部分，我们将修改kernel以抢占不配合的进程（抢占式多任务），并允许进程之间显式地进行传递消息。

### 时钟中断与抢占

运行`user/spin`进程，这个测试程序fork了一个子进程，然后就直接进入一个死循环并一直占用该CPU。父进程与内核都不能再次获得该CPU的。这显然不是一个理想的情况，因为这意味着一个用户进程可用无限占用CPU。为了运行内核抢占有一个正在运行的进程，并重新获取CPU的控制，我们必须扩展CPU支持外部时钟的硬件中断。

#### 中断规则

外部中断，也叫设备中断，被称为IRQs（interrupt Requests， 中断请求），一共有16个可能的中断请求，从0到15，中断请求号与IDT入口的映射关系是不固定的,`pic_init`将0-15中断请求映射到`IRQ_OFFSET`到'IRQ_OFFSET + 15'的IDT表中。

在JOS中，我们做了一个关键的简化处理，外部中断请求总是关闭的，外部中断被`FL_IF`这个标志位控制，当这个标志位被置位时，外部中断是使能的，这个标志位可以被多种方式进行修改，但是由于我们的简化，在进入和离开用户模式时，我们将只通过保存和恢复%eflags寄存器的过程来处理它。

我们必须确保在用户运行时在用户环境中设置FL_IF标志，以便当中断到来时，它被传递到处理器并由中断代码处理。否则，中断将被屏蔽或忽略，直到中断被重新启用。此前，我们在bootloader的第一条指令中设置了中断屏蔽(masked interrupts)，到目前为止我们还没有重新启用过它们。


#### 练习13
* 修改`kern/trapentry.S`和`kern/trap.c`来初始化IDT中IRQs0-15的入口和处理函数。
* 修改env_alloc函数来确保进程在用户态运行时中断是打开的。
* 取消注释`sched_halt()`函数中的`sti`指令，让CPU不屏蔽中断。

这个参照之前lab3的初始化即可

* `trapentry.S`加入
```
// IRQs
TRAPHANDLER_NOEC(irq_0_handler,  IRQ_OFFSET + 0);
TRAPHANDLER_NOEC(irq_1_handler,  IRQ_OFFSET + 1);
TRAPHANDLER_NOEC(irq_2_handler,  IRQ_OFFSET + 2);
TRAPHANDLER_NOEC(irq_3_handler,  IRQ_OFFSET + 3);
TRAPHANDLER_NOEC(irq_4_handler,  IRQ_OFFSET + 4);
TRAPHANDLER_NOEC(irq_5_handler,  IRQ_OFFSET + 5);
TRAPHANDLER_NOEC(irq_6_handler,  IRQ_OFFSET + 6);
TRAPHANDLER_NOEC(irq_7_handler,  IRQ_OFFSET + 7);
TRAPHANDLER_NOEC(irq_8_handler,  IRQ_OFFSET + 8);
TRAPHANDLER_NOEC(irq_9_handler,  IRQ_OFFSET + 9);
TRAPHANDLER_NOEC(irq_10_handler, IRQ_OFFSET + 10);
TRAPHANDLER_NOEC(irq_11_handler, IRQ_OFFSET + 11);
TRAPHANDLER_NOEC(irq_12_handler, IRQ_OFFSET + 12);
TRAPHANDLER_NOEC(irq_13_handler, IRQ_OFFSET + 13);
TRAPHANDLER_NOEC(irq_14_handler, IRQ_OFFSET + 14);
TRAPHANDLER_NOEC(irq_15_handler, IRQ_OFFSET + 15);
```

* trap.c中加入IRQs的函数声明与IDT的初始化代码
```
// trap_init()
// IRQs
	SETGATE(idt[IRQ_OFFSET + 0],  0, GD_KT, irq_0_handler,  0);
	SETGATE(idt[IRQ_OFFSET + 1],  0, GD_KT, irq_1_handler,  0);
	SETGATE(idt[IRQ_OFFSET + 2],  0, GD_KT, irq_2_handler,  0);
	SETGATE(idt[IRQ_OFFSET + 3],  0, GD_KT, irq_3_handler,  0);
	SETGATE(idt[IRQ_OFFSET + 4],  0, GD_KT, irq_4_handler,  0);
	SETGATE(idt[IRQ_OFFSET + 5],  0, GD_KT, irq_5_handler,  0);
	SETGATE(idt[IRQ_OFFSET + 6],  0, GD_KT, irq_6_handler,  0);
	SETGATE(idt[IRQ_OFFSET + 7],  0, GD_KT, irq_7_handler,  0);
	SETGATE(idt[IRQ_OFFSET + 8],  0, GD_KT, irq_8_handler,  0);
	SETGATE(idt[IRQ_OFFSET + 9],  0, GD_KT, irq_9_handler,  0);
	SETGATE(idt[IRQ_OFFSET + 10], 0, GD_KT, irq_10_handler, 0);
	SETGATE(idt[IRQ_OFFSET + 11], 0, GD_KT, irq_11_handler, 0);
	SETGATE(idt[IRQ_OFFSET + 12], 0, GD_KT, irq_12_handler, 0);
	SETGATE(idt[IRQ_OFFSET + 13], 0, GD_KT, irq_13_handler, 0);
	SETGATE(idt[IRQ_OFFSET + 14], 0, GD_KT, irq_14_handler, 0);
	SETGATE(idt[IRQ_OFFSET + 15], 0, GD_KT, irq_15_handler, 0);

	// 函数声明
	// IRQs
	void irq_0_handler();
	void irq_1_handler();
	void irq_2_handler();
	void irq_3_handler();
	void irq_4_handler();
	void irq_5_handler();
	void irq_6_handler();
	void irq_7_handler();
	void irq_8_handler();
	void irq_9_handler();
	void irq_10_handler();
	void irq_11_handler();
	void irq_12_handler();
	void irq_13_handler();
	void irq_14_handler();
	void irq_15_handler();
```

#### 捕获时钟中断
在`user/spin`程序中，子程序会一直自旋而内核永远拿不到CPU的控制权，我们需要让硬件周期性的产生时钟中断，在中断中内核就可以强制得到CPU的控制权，并将其交给其他程序。

现在在`lapic_init()`与`pic_init()`中，已经设置好了中断，你现在需要捕获这些中断。

#### 练习14
修改内核的`trap_dispatch()`函数，然后让其在接到时钟中断后，调用`sched_yield()`进而运行其他进程。
你应该确保`user/spin`运行，


---

按照`trap_dispatch()`的提示写就完事了

```
// in trap_dispatch()
// Handle clock interrupts. Don't forget to acknowledge the
	// interrupt using lapic_eoi() before calling the scheduler!
	// LAB 4: Your code here.
	if (tf->tf_trapno == IRQ_OFFSET + IRQ_TIMER){
		lapic_eoi();
		sched_yield();
	}

```
在完成练习之后应该做一些测试，尝试运行在多个CPU之间，你需要通过`stresssched`测试，运行`make grade`你应该已经获得65/80的成绩。

### 进程间通信

之前，我们总是关注与操作系统的隔离方面，这给每个程序制造了完全占有整个机器的假象。而操作系统的另一个重要的服务是，让程序之间相互进行通信。这会让程序之间的相互作用有效。Unix的管道是一个典型的例子。

目前为止，有很多进程间相互通信的方式，我们将要实现一个简单的进程间相互通信机制。

#### JOS的进程间通信
您将实现一些附加的 JOS 内核系统调用，以共同提供了一个简单的进程间通信机制。具体而言，需要实现两种系统调用`sys_ipc_recv`和`sys_ipc_try_send`。然后，您将实现两个对应的library wrapper，即`ipc _ recv`和`ipc _ send`。

JOS的IPC机制对应的消息，包括两个部分：一个32位的值，和可选一个page的映射关系。允许进程在IPC中传递超过一个32位变量值，同时也允许进程更容易的内存共享。

##### 发送与接受消息

为了接受消息，一个进程调用`sys_ipc_recv`，这个系统调用会进入trap知道收到一个消息后再会返回，当一个环境等待消息时，所有其他环境都可以对其进行发送，而不仅仅是特定的环境，换句话说，你在part A中的进行的鉴权操作不会用于IPC中，因为IPC系统调用相对比较安全，一个进程不会通过消息让另一个进程崩溃。

为了发送一个值，进程通过调用`sys_ipc_try_send`并附上接收者的环境id与要被发送的值，如果接收进程真的在接收，该系统调用会return 0。否则返回一个`-E_IPC_NOT_RECV`表示目标环境没有期望接收一个值。

`ipc_recv`在用户空间中调用`sys_ipc_recv`，然后在当前环境的结构体Env 中查找有关接收值的信息。

相同的，库函数`ipc_send`会负责不断调用`sys_ipc_try_send`尝试进行发送，直到发送成功。


##### 传递page
当某个进程在调用sys_ipc_recv with a valid dstva parameter (below UTOP)时，这个进程则在声明它愿意接收一个页面映射（page mapping）。如果发送方发送一个页面，那么该页面should be mapped at dstva in the receiver’s address space.。如果接收方已经had a page mapped at dstva，那么之前映射的这个页面将被取消映射。

当某个进程调用sys_ipc_try_send with a valid srcva (below UTOP)时，这意味着发送方希望发送一个page currently mapped at srcva给接收方（with permission perm）。在一个成功的 IPC 之后，发送方在其自身的地址空间srcva 处，保留原始的页面映射，但是接收方也会保留a mapping for this same physical page at the dstva originally specified by the receiver。因此，这个页面在发送方和接收方之间共享。

If either the sender or the receiver does not indicate that a page should be transferred, then no page is transferred.

在任何IPC之后，kernel都会取设置一下接收者的struct Env中的新字段 env_ipc_perm，设为the permissions of the page received, or zero if no page was received.

###### 练习15
* 实现`kern/syscall.c`中的`sys_ipc_try_send`，当你调用`envid2env`时，你应该将`checkperm`标志位置0，表示其他进程允许发送，内核只确认目标环境ID是否有效。

* 在`lib/ipc.c`实现`ipc_recv`与`ipc_send`函数。

---

* sys_ipc_try_send()
```

// Try to send 'value' to the target env 'envid'.
// If srcva < UTOP, then also send page currently mapped at 'srcva',
// so that receiver gets a duplicate mapping of the same page.
//
// The send fails with a return value of -E_IPC_NOT_RECV if the
// target is not blocked, waiting for an IPC.
//
// The send also can fail for the other reasons listed below.
//
// Otherwise, the send succeeds, and the target's ipc fields are
// updated as follows:
//    env_ipc_recving is set to 0 to block future sends;
//    env_ipc_from is set to the sending envid;
//    env_ipc_value is set to the 'value' parameter;
//    env_ipc_perm is set to 'perm' if a page was transferred, 0 otherwise.
// The target environment is marked runnable again, returning 0
// from the paused sys_ipc_recv system call.  (Hint: does the
// sys_ipc_recv function ever actually return?)
//
// If the sender wants to send a page but the receiver isn't asking for one,
// then no page mapping is transferred, but no error occurs.
// The ipc only happens when no errors occur.
//
// Returns 0 on success, < 0 on error.
// Errors are:
//	-E_BAD_ENV if environment envid doesn't currently exist.
//		(No need to check permissions.)
//	-E_IPC_NOT_RECV if envid is not currently blocked in sys_ipc_recv,
//		or another environment managed to send first.
//	-E_INVAL if srcva < UTOP but srcva is not page-aligned.
//	-E_INVAL if srcva < UTOP and perm is inappropriate
//		(see sys_page_alloc).
//	-E_INVAL if srcva < UTOP but srcva is not mapped in the caller's
//		address space.
//	-E_INVAL if (perm & PTE_W), but srcva is read-only in the
//		current environment's address space.
//	-E_NO_MEM if there's not enough memory to map srcva in envid's
//		address space.
static int
sys_ipc_try_send(envid_t envid, uint32_t value, void *srcva, unsigned perm)
{
	// LAB 4: Your code here.
	//panic("sys_ipc_try_send not implemented");
	struct Env *rec_env, *cur_env;
	int r;
	// get current env
	envid2env(0, &cur_env, 0);
	assert(cur_env);
	if ((r = envid2env(envid, &rec_env, 0)) < 0) {
		return r;
	}
	if (!rec_env->env_ipc_recving) {
		return -E_IPC_NOT_RECV;
	}
	if ((uintptr_t)srcva < UTOP) {
		struct PageInfo *pg;
		pte_t *pte;
		// if srcva is not page-aligned
		// 0x1000 - 1=  0x0111
		// if srcva any bit is 1 is not page-aligned
		if ((uintptr_t) srcva & (PGSIZE - 1)) {
			return -E_INVAL;
		}
		// perm is inappropriate is same as the sys_page_alloc
		if(!(perm & PTE_U) || !(perm & PTE_P) || (perm & (~PTE_SYSCALL))){
			return -E_INVAL;
		}
		// srcva is mapped in the caller's address spcae
		if (!(pg = page_lookup(cur_env->env_pgdir,srcva,&pte))) {
			return -E_INVAL;
		}
		// if (perm & PTE_W), but srcva is read-only 
		if ((perm & PTE_W) && !((*pte) & PTE_W)) {
			return -E_INVAL;
		}
		if ((uintptr_t)rec_env->env_ipc_dstva < UTOP) {
			if ((r = page_insert(rec_env->env_pgdir,pg,rec_env->env_ipc_dstva,perm)  < 0)) { 
				return -r;
			}
		}
	}
	rec_env->env_ipc_perm = perm;
	rec_env->env_ipc_value = value;
	rec_env->env_ipc_recving = 0;
	rec_env->env_ipc_from = cur_env->env_id;
	rec_env->env_status = ENV_RUNNABLE;
  	rec_env->env_tf.tf_regs.reg_eax = 0;
	return 0;
}

```

* sys_ipc_recv()函数
```

// Block until a value is ready.  Record that you want to receive
// using the env_ipc_recving and env_ipc_dstva fields of struct Env,
// mark yourself not runnable, and then give up the CPU.
//
// If 'dstva' is < UTOP, then you are willing to receive a page of data.
// 'dstva' is the virtual address at which the sent page should be mapped.
//
// This function only returns on error, but the system call will eventually
// return 0 on success.
// Return < 0 on error.  Errors are:
//	-E_INVAL if dstva < UTOP but dstva is not page-aligned.
static int
sys_ipc_recv(void *dstva)
{
	// LAB 4: Your code here.
	//panic("sys_ipc_recv not implemented");
	if (((uintptr_t) dstva < UTOP) && ((uintptr_t)dstva & (PGSIZE  - 1))) {
		return -E_INVAL;
	}
	struct Env *cur_env;
	envid2env(0,&cur_env,0);
	assert(cur_env);
	cur_env->env_status = ENV_NOT_RUNNABLE;
	cur_env->env_ipc_recving = 1;
	cur_env->env_ipc_dstva = dstva;
	sys_yield();
	return 0;
}

```

* ipc_recv()

```

// Receive a value via IPC and return it.
// If 'pg' is nonnull, then any page sent by the sender will be mapped at
//	that address.
// If 'from_env_store' is nonnull, then store the IPC sender's envid in
//	*from_env_store.
// If 'perm_store' is nonnull, then store the IPC sender's page permission
//	in *perm_store (this is nonzero iff a page was successfully
//	transferred to 'pg').
// If the system call fails, then store 0 in *fromenv and *perm (if
//	they're nonnull) and return the error.
// Otherwise, return the value sent by the sender
//
// Hint:
//   Use 'thisenv' to discover the value and who sent it.
//   If 'pg' is null, pass sys_ipc_recv a value that it will understand
//   as meaning "no page".  (Zero is not the right value, since that's
//   a perfectly valid place to map a page.)
int32_t
ipc_recv(envid_t *from_env_store, void *pg, int *perm_store)
{
	// LAB 4: Your code here.
	//panic("ipc_recv not implemented");
	int error;
	if(!pg)pg = (void *)UTOP; //
	if((error = sys_ipc_recv(pg)) < 0){
		if(from_env_store)*from_env_store = 0;
		if(perm_store)*perm_store = 0;
		return error;
	}

	if(from_env_store)*from_env_store = thisenv->env_ipc_from;
	if(perm_store)*perm_store = thisenv->env_ipc_perm;
	return thisenv->env_ipc_value;
	return 0;
}

```

* ipc_send()

```

// Send 'val' (and 'pg' with 'perm', if 'pg' is nonnull) to 'toenv'.
// This function keeps trying until it succeeds.
// It should panic() on any error other than -E_IPC_NOT_RECV.
//
// Hint:
//   Use sys_yield() to be CPU-friendly.
//   If 'pg' is null, pass sys_ipc_try_send a value that it will understand
//   as meaning "no page".  (Zero is not the right value.)
void
ipc_send(envid_t to_env, uint32_t val, void *pg, int perm)
{
	// LAB 4: Your code here.
	//panic("ipc_send not implemented");
	if (!pg) {
		pg = (void *)UTOP;
	} 
	int r;
	while((r = sys_ipc_try_send(to_env,val,pg,perm)) < 0) {
		if (r != -E_IPC_NOT_RECV) {
			panic("sys_ipc_try_send error %e\n",r);
		}
		sys_yield();
	}
}


```


## 参考文献 
https://www.cnblogs.com/JayL-zxl/p/15024720.html
https://yangminz.github.io/2016/12/25/OperatingSys/
http://xudaxian.fun/2021/02/06/MIT-6.828-MIT-6.828-Fall-2018-lab4-PartBC/
