/* See COPYRIGHT for copyright information. */

#include <inc/mmu.h>
#include <inc/memlayout.h>
#include <inc/trap.h>

#include <kern/picirq.h>


###################################################################
# exceptions/interrupts
###################################################################

/* TRAPHANDLER defines a globally-visible function for handling a trap.
 * It pushes a trap number onto the stack, then jumps to _alltraps.
 * Use TRAPHANDLER for traps where the CPU automatically pushes an error code.
 *
 * You shouldn't call a TRAPHANDLER function from C, but you may
 * need to _declare_ one in C (for instance, to get a function pointer
 * during IDT setup).  You can declare the function with
 *   void NAME();
 * where NAME is the argument passed to TRAPHANDLER.
 */
#define TRAPHANDLER(name, num)						\
	.globl name;		/* define global symbol for 'name' */	\
	.type name, @function;	/* symbol type is function */		\
	.align 2;		/* align function definition */		\
	name:			/* function starts here */		\
	pushl $(num);							\
	jmp _alltraps

/* Use TRAPHANDLER_NOEC for traps where the CPU doesn't push an error code.
 * It pushes a 0 in place of the error code, so the trap frame has the same
 * format in either case.
 */
#define TRAPHANDLER_NOEC(name, num)					\
	.globl name;							\
	.type name, @function;						\
	.align 2;							\
	name:								\
	pushl $0;							\
	pushl $(num);							\
	jmp _alltraps

.text

/*
 * Lab 3: Your code here for generating entry points for the different traps.
 */
TRAPHANDLER_NOEC(t_divide_handler, T_DIVIDE)
TRAPHANDLER_NOEC(t_debug_handler, T_DEBUG)
TRAPHANDLER_NOEC(t_nmi_handler, T_NMI)
TRAPHANDLER_NOEC(t_breakpoint_handler, T_BRKPT)
TRAPHANDLER_NOEC(t_overflow_handler, T_OFLOW)
TRAPHANDLER_NOEC(t_bounds_handler, T_BOUND)
TRAPHANDLER_NOEC(t_illop_handler, T_ILLOP)
TRAPHANDLER_NOEC(t_device_handler, T_DEVICE)
TRAPHANDLER(t_dblfault_handler, T_DBLFLT)
TRAPHANDLER(t_tss_handler, T_TSS)
TRAPHANDLER(t_segnp_handler, T_SEGNP)
TRAPHANDLER(t_stack_handler, T_STACK);
TRAPHANDLER(t_gpfault_handler, T_GPFLT)
TRAPHANDLER(t_pagefault_handler, T_PGFLT)
TRAPHANDLER_NOEC(t_fperr_handler, T_FPERR)
TRAPHANDLER(t_align_handler, T_ALIGN)
TRAPHANDLER_NOEC(t_mchk_handler, T_MCHK)
TRAPHANDLER_NOEC(t_simderr_handler, T_SIMDERR)

TRAPHANDLER_NOEC(t_syscall, T_SYSCALL)

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

/*
 * Lab 3: Your code here for _alltraps
 */
 _alltraps:
	pushl %ds
	pushl %es
	pushal 

	movl $GD_KD, %eax
	movw %ax, %ds
	movw %ax, %es

	push %esp
	call trap	

