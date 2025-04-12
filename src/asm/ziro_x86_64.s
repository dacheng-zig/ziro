# See System V x86-64 calling convention
# https://gitlab.com/x86-psABIs/x86-64-ABI
.global _ziro_stack_swap
_ziro_stack_swap:
.global ziro_stack_swap
ziro_stack_swap:
# Store caller registers on the current stack
pushq %rbp
pushq %rbx
pushq %r12
pushq %r13
pushq %r14
pushq %r15

# Modify stack pointer of current coroutine (rdi, first argument)
movq %rsp, (%rdi)

# Load stack pointer from target coroutine (rsi, second argument)
movq (%rsi), %rsp

# Restore target registers
popq %r15
popq %r14
popq %r13
popq %r12
popq %rbx
popq %rbp

# jump
retq
