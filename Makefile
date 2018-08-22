#
# Makefile for out-of-tree building eBPF programs
#  similar to kernel/samples/bpf/
#
# Still depend on a kernel source tree.
#
TARGETS += xdp_autocutoff xdp_bypass


CMDLINE_TOOLS := xdp_bypass_cli
COMMON_H      =  ${CMDLINE_TOOLS:_cli=_lib.h}

# Targets that use the library bpf/libbpf
### TARGETS_USING_LIBBPF += xdp_monitor_user

# Files under kernel/samples/bpf/ have a name-scheme:
# ---------------------------------------------------
# The eBPF program is called xxx_kern.c. This is the restricted-C
# code, that need to be compiled with LLVM/clang, to generate an ELF
# binary containing the eBPF instructions.
#
# The userspace program called xxx_user.c, is a regular C-code
# program.  It need two external components from kernel tree, from
# samples/bpf/ and tools/lib/bpf/.
#
# 1) When loading the ELF eBPF binary is uses the API load_bpf_file()
#    via "bpf_load.h" (compiles against a modified local copy of
#    kernels samples/bpf/bpf_load.c).
#
# 2) The API for interacting with eBPF comes from tools/lib/bpf/bpf.h.
#    For now, tools/lib/bpf/bpf.c is compiled directly, and executable
#    is statically linked with object file.
#
#    This is likely improper use of tools/lib/bpf/, that can generate
#    shared library code.  Hopefully someone will cleanup this
#    Makefile and correct this usage.


# Generate file name-scheme based on TARGETS
KERN_SOURCES = ${TARGETS:=_kern.c}
USER_SOURCES = ${TARGETS:=_user.c}
KERN_OBJECTS = ${KERN_SOURCES:.c=.o}
USER_OBJECTS = ${USER_SOURCES:.c=.o}

# Notice: the kbuilddir can be redefined on make cmdline
kbuilddir ?= /lib/modules/$(shell uname -r)/build/
KERNEL=$(kbuilddir)

CFLAGS := -g -O2 -Wall

# Local copy of kernel/tools/lib/
CFLAGS += -I./tools/lib
#CFLAGS += -I$(KERNEL)/tools/lib
#
# Local copy of uapi/linux/bpf.h kept under ./tools/include
# needed due to enum dependency in bpf_helpers.h
CFLAGS += -I./tools/include
# For building libbpf there is a lot of kernel includes in tools/include/
CFLAGS += -I$(KERNEL)/tools/include
#CFLAGS += -I$(KERNEL)/tools/perf
CFLAGS += -I$(KERNEL)/tools/include/uapi
# Strange dependency to "selftests" due to "bpf_util.h"
#CFLAGS += -I$(KERNEL)/tools/testing/selftests/bpf/

LDFLAGS= -lelf

# Objects that xxx_user program is linked with:
OBJECT_BPF_SYSCALLS  = tools/lib/bpf/bpf.o
OBJECT_LOADBPF = bpf_load.o
#
# The tools/lib/bpf/libbpf is avail via a library
OBJECT_BPF_LIBBPF  = tools/lib/bpf/libbpf.o tools/lib/bpf/nlattr.o
OBJECTS = $(OBJECT_BPF_SYSCALLS) $(OBJECT_BPF_LIBBPF)

# Allows pointing LLC/CLANG to another LLVM backend, redefine on cmdline:
#  make LLC=~/git/llvm/build/bin/llc CLANG=~/git/llvm/build/bin/clang
LLC ?= llc
CLANG ?= clang

CC = gcc

NOSTDINC_FLAGS := -nostdinc -isystem $(shell $(CC) -print-file-name=include)

# Copy of uapi/linux/bpf.h stored here:
LINUXINCLUDE := -I./tools/include/

LINUXINCLUDE += -I$(KERNEL)/arch/x86/include
LINUXINCLUDE += -I$(KERNEL)/arch/x86/include/generated/uapi
LINUXINCLUDE += -I$(KERNEL)/arch/x86/include/generated
LINUXINCLUDE += -I$(KERNEL)/include
LINUXINCLUDE += -I$(KERNEL)/arch/x86/include/uapi
LINUXINCLUDE += -I$(KERNEL)/include/uapi
LINUXINCLUDE += -I$(KERNEL)/include/generated/uapi
LINUXINCLUDE += -include $(KERNEL)/include/linux/kconfig.h
LINUXINCLUDE += -I$(KERNEL)/tools/lib
EXTRA_CFLAGS=-Werror

all: dependencies $(TARGETS) $(KERN_OBJECTS) $(CMDLINE_TOOLS)

.PHONY: dependencies clean verify_cmds verify_llvm_target_bpf $(CLANG) $(LLC)

# Manually define dependencies to e.g. include files

clean:
	@find . -type f \
		\( -name '*~' \
		-o -name '*.ll' \
		-o -name '*.bc' \
		-o -name 'core' \) \
		-exec rm -vf '{}' \;
	rm -f $(OBJECTS)
	rm -f $(TARGETS)
	rm -f $(KERN_OBJECTS)
	rm -f $(USER_OBJECTS)
	rm -f $(OBJECT_BPF_LIBBPF) libbpf.a

dependencies: verify_llvm_target_bpf linux-src-devel-headers

linux-src:
	@if ! test -d $(KERNEL)/; then \
		echo "ERROR: Need kernel source code to compile against" ;\
		echo "(Cannot open directory: $(KERNEL))" ;\
		exit 1; \
	else true; fi

linux-src-libbpf: linux-src
	@if ! test -d $(KERNEL)/tools/lib/bpf/; then \
		echo "ERROR: Need kernel source code to compile against" ;\
		echo "       and specifically tools/lib/bpf/ "; \
		exit 1; \
	else true; fi

linux-src-devel-headers: linux-src-libbpf
	@if ! test -d $(KERNEL)/usr/include/ ; then \
		echo -n "WARNING: Need kernel source devel headers"; \
		echo    " likely need to run:"; \
		echo "       (in kernel source dir: $(KERNEL))"; \
		echo -e "\n  make headers_install\n"; \
		true ; \
	else true; fi

verify_cmds: $(CLANG) $(LLC)
	@for TOOL in $^ ; do \
		if ! (which -- "$${TOOL}" > /dev/null 2>&1); then \
			echo "*** ERROR: Cannot find LLVM tool $${TOOL}" ;\
			exit 1; \
		else true; fi; \
	done

verify_llvm_target_bpf: verify_cmds
	@if ! (${LLC} -march=bpf -mattr=help > /dev/null 2>&1); then \
		echo "*** ERROR: LLVM (${LLC}) does not support 'bpf' target" ;\
		echo "   NOTICE: LLVM version >= 3.7.1 required" ;\
		exit 2; \
	else true; fi

# Helpers for bpf syscalls (from tools/lib/bpf/bpf.c)
$(OBJECT_BPF_SYSCALLS): %.o: %.c
	$(CC) $(CFLAGS) -o $@ -c $<

$(OBJECT_LOADBPF): bpf_load.c bpf_load.h
	$(CC) $(CFLAGS) -o $@ -c $<

# ISSUE: The libbpf.a library creates a kernel source dependency, for
# include files from tools/include/
$(OBJECT_BPF_LIBBPF): %.o: %.c
	$(CC) $(CFLAGS) -o $@ -c $<
#
libbpf.a: $(OBJECT_BPF_LIBBPF) $(OBJECT_BPF_SYSCALLS)
	$(RM) $@; $(AR) rcs $@ $^

# Compiling of eBPF restricted-C code with LLVM
#  clang option -S generated output file with suffix .ll
#   which is the non-binary LLVM assembly language format
#   (normally LLVM bitcode format .bc is generated)
#
# Use -Wno-address-of-packed-member as eBPF verifier enforces
# unaligned access checks where necessary
#
$(KERN_OBJECTS): %.o: %.c bpf_helpers.h
	$(CLANG) -S $(NOSTDINC_FLAGS) $(LINUXINCLUDE) $(EXTRA_CFLAGS) \
	    -D__KERNEL__ -D__ASM_SYSREG_H \
	    -D__BPF_TRACING__ \
	    -Wall \
	    -Wno-unused-value -Wno-pointer-sign \
	    -D__TARGET_ARCH_$(ARCH) \
	    -Wno-compare-distinct-pointer-types \
	    -Wno-gnu-variable-sized-type-not-at-end \
	    -Wno-tautological-compare \
	    -Wno-unknown-warning-option \
	    -Wno-address-of-packed-member \
	    -O2 -emit-llvm -c $<
	$(LLC) -march=bpf -filetype=obj -o $@ ${@:.o=.ll}

$(TARGETS): %: %_user.c $(OBJECTS) Makefile bpf_util.h
	$(CC) $(CFLAGS) $(OBJECTS) $(LDFLAGS) -o $@ $<

$(CMDLINE_TOOLS): %: %.c $(OBJECTS) Makefile $(COMMON_H) bpf_util.h
	$(CC) -g $(CFLAGS) $(OBJECTS) $(LDFLAGS) -o $@ $<
