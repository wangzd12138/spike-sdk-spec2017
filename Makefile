# RISCV should either be unset, or set to point to a directory that contains
# a toolchain install tree that was built via other means.
RISCV ?= $(CURDIR)/toolchain
PATH := $(RISCV)/bin:$(PATH)
ISA ?= rv64imafdc
ABI ?= lp64d

srcdir := $(dir $(realpath $(lastword $(MAKEFILE_LIST))))
srcdir := $(srcdir:/=)
confdir := $(srcdir)/conf
wrkdir := $(CURDIR)/work

toolchain_srcdir := $(srcdir)/riscv-gnu-toolchain
toolchain_wrkdir := $(wrkdir)/riscv-gnu-toolchain
toolchain_dest := $(CURDIR)/toolchain

buildroot_srcdir := $(srcdir)/buildroot
buildroot_initramfs_wrkdir := $(wrkdir)/buildroot_initramfs
buildroot_initramfs_tar := $(buildroot_initramfs_wrkdir)/images/rootfs.tar
buildroot_initramfs_config := $(confdir)/buildroot_initramfs_config
buildroot_initramfs_sysroot_stamp := $(wrkdir)/.buildroot_initramfs_sysroot
buildroot_initramfs_sysroot := $(wrkdir)/buildroot_initramfs_sysroot
buildroot_rootfs_wrkdir := $(wrkdir)/buildroot_rootfs
buildroot_rootfs_ext := $(buildroot_rootfs_wrkdir)/images/rootfs.ext4
buildroot_rootfs_config := $(confdir)/buildroot_rootfs_config

linux_srcdir := $(srcdir)/linux
linux_wrkdir := $(wrkdir)/linux
linux_defconfig := $(confdir)/linux_defconfig

vmlinux := $(linux_wrkdir)/vmlinux
vmlinux_stripped := $(linux_wrkdir)/vmlinux-stripped

pk_srcdir := $(srcdir)/riscv-tools/riscv-pk
pk_wrkdir := $(wrkdir)/riscv-pk
bbl := $(pk_wrkdir)/bbl
pk  := $(pk_wrkdir)/pk

spike_srcdir := $(srcdir)/riscv-tools/riscv-isa-sim
spike_wrkdir := $(wrkdir)/riscv-isa-sim
spike := $(toolchain_dest)/bin/spike

target_linux  := riscv64-unknown-linux-gnu
target_newlib := riscv64-unknown-elf

.PHONY: all
all: sim

newlib: $(RISCV)/bin/$(target_newlib)-gcc


ifneq ($(RISCV),$(toolchain_dest))
$(RISCV)/bin/$(target_linux)-gcc:
	$(error The RISCV environment variable was set, but is not pointing at a toolchain install tree)
endif

$(toolchain_dest)/bin/$(target_linux)-gcc: $(toolchain_srcdir)
	mkdir -p $(toolchain_wrkdir)
	$(MAKE) -C $(linux_srcdir) O=$(dir $<) ARCH=riscv INSTALL_HDR_PATH=$(abspath $(toolchain_srcdir)/linux-headers) headers_install
	cd $(toolchain_wrkdir); $(toolchain_srcdir)/configure \
		--prefix=$(toolchain_dest) \
		--with-arch=$(ISA) \
		--with-abi=$(ABI) 
	$(MAKE) -C $(toolchain_wrkdir) linux
	sed 's/^#define LINUX_VERSION_CODE.*/#define LINUX_VERSION_CODE 327680/' -i $(toolchain_dest)/sysroot/usr/include/linux/version.h

$(toolchain_dest)/bin/$(target_newlib)-gcc: $(toolchain_srcdir)
	mkdir -p $(toolchain_wrkdir)
	cd $(toolchain_wrkdir); $(toolchain_srcdir)/configure \
		--prefix=$(toolchain_dest) \
		--with-arch=$(ISA) \
		--with-abi=$(ABI) 
	$(MAKE) -C $(toolchain_wrkdir) 

$(buildroot_initramfs_wrkdir)/.config: $(buildroot_srcdir)
	rm -rf $(dir $@)
	mkdir -p $(dir $@)
	cp $(buildroot_initramfs_config) $@
	$(MAKE) -C $< RISCV=$(RISCV) PATH=$(PATH) O=$(buildroot_initramfs_wrkdir) olddefconfig CROSS_COMPILE=riscv64-unknown-linux-gnu-

$(buildroot_initramfs_tar): $(buildroot_srcdir) $(buildroot_initramfs_wrkdir)/.config $(RISCV)/bin/$(target_linux)-gcc $(buildroot_initramfs_config)
	$(MAKE) -C $< RISCV=$(RISCV) PATH=$(PATH) O=$(buildroot_initramfs_wrkdir)

.PHONY: buildroot_initramfs-menuconfig
buildroot_initramfs-menuconfig: $(buildroot_initramfs_wrkdir)/.config $(buildroot_srcdir)
	$(MAKE) -C $(dir $<) O=$(buildroot_initramfs_wrkdir) menuconfig
	$(MAKE) -C $(dir $<) O=$(buildroot_initramfs_wrkdir) savedefconfig
	cp $(dir $<)/defconfig conf/buildroot_initramfs_config

$(buildroot_initramfs_sysroot): $(buildroot_initramfs_tar)
	mkdir -p $(buildroot_initramfs_sysroot)
	tar -xpf $< -C $(buildroot_initramfs_sysroot) --exclude ./dev --exclude ./usr/share/locale

$(linux_wrkdir)/.config: $(linux_defconfig) $(linux_srcdir)
	mkdir -p $(dir $@)
	cp -p $< $@
	$(MAKE) -C $(linux_srcdir) O=$(linux_wrkdir) ARCH=riscv olddefconfig
	echo $(ISA)
	echo $(filter rv32%,$(ISA))
ifeq (,$(filter rv%c,$(ISA)))
	sed 's/^.*CONFIG_RISCV_ISA_C.*$$/CONFIG_RISCV_ISA_C=n/' -i $@
	$(MAKE) -C $(linux_srcdir) O=$(linux_wrkdir) ARCH=riscv olddefconfig
endif
ifeq ($(ISA),$(filter rv32%,$(ISA)))
	sed 's/^.*CONFIG_ARCH_RV32I.*$$/CONFIG_ARCH_RV32I=y/' -i $@
	sed 's/^.*CONFIG_ARCH_RV64I.*$$/CONFIG_ARCH_RV64I=n/' -i $@
	$(MAKE) -C $(linux_srcdir) O=$(linux_wrkdir) ARCH=riscv olddefconfig
endif

$(vmlinux): $(linux_srcdir) $(linux_wrkdir)/.config $(buildroot_initramfs_sysroot) 
	$(MAKE) -C $< O=$(linux_wrkdir) \
		CONFIG_INITRAMFS_SOURCE="$(confdir)/initramfs.txt $(buildroot_initramfs_sysroot)" \
		CONFIG_INITRAMFS_ROOT_UID=$(shell id -u) \
		CONFIG_INITRAMFS_ROOT_GID=$(shell id -g) \
		CROSS_COMPILE=riscv64-unknown-linux-gnu- \
		ARCH=riscv \
		vmlinux

$(vmlinux_stripped): $(vmlinux)
	$(target_linux)-strip -o $@ $<
	

.PHONY: linux-menuconfig
linux-menuconfig: $(linux_wrkdir)/.config
	$(MAKE) -C $(linux_srcdir) O=$(dir $<) ARCH=riscv menuconfig
	$(MAKE) -C $(linux_srcdir) O=$(dir $<) ARCH=riscv savedefconfig
	cp $(dir $<)/defconfig conf/linux_defconfig

$(bbl): $(pk_srcdir) $(vmlinux_stripped)
	rm -rf $(pk_wrkdir)
	mkdir -p $(pk_wrkdir)
	cd $(pk_wrkdir) && $</configure \
		--host=$(target_linux) \
		--with-payload=$(vmlinux_stripped) \
		--enable-logo \
		--with-logo=$(abspath conf/logo.txt)
	CFLAGS="-mabi=$(ABI) -march=$(ISA)" $(MAKE) -C $(pk_wrkdir)

$(spike): $(spike_srcdir) 
	rm -rf $(spike_wrkdir)
	mkdir -p $(spike_wrkdir)
	mkdir -p $(dir $@)
	cd $(spike_wrkdir) && $</configure \
		--prefix=$(dir $(abspath $(dir $@))) 
	$(MAKE) -C $(spike_wrkdir)
	$(MAKE) -C $(spike_wrkdir) install
	touch -c $@

.PHONY: buildroot_initramfs_sysroot vmlinux bbl
buildroot_initramfs_sysroot: $(buildroot_initramfs_sysroot)
vmlinux: $(vmlinux)
bbl: $(bbl)

.PHONY: clean
clean:
	rm -rf -- $(wrkdir) $(toolchain_dest)

.PHONY: sim
sim: $(bbl) $(spike)
	$(spike) --isa=$(ISA) -p4 $(bbl)