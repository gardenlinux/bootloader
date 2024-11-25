MAKEFLAGS += --no-builtin-rules
.SILENT:
.DELETE_ON_ERROR:
.PHONY: link_tmp clean test
.SECONDARY: linux/arch/x86/boot/bzImage linux/.config linux

disk: mbr.bin mmap.bin bzImage
	echo 'building $@ [$^]'
	truncate -s 0 '$@'
	truncate -s 64MiB '$@'
	dd if=$(word 1,$^) of=$@ bs=512 count=1 conv=notrunc 2> /dev/null
	dd if=$(word 2,$^) of=$@ bs=512 count=2 seek=33 conv=notrunc 2> /dev/null
	dd if=$(word 3,$^) of=$@ bs=512 count=32768 seek=2048 conv=notrunc 2> /dev/null

mbr.bin: mbr.asm
	echo 'building $^ -> $@'
	nasm -f bin -o '$@' '$<'
	hexdump -vC '$@'

mmap.bin: bzImage
	truncate -s 0 '$@'
	truncate -s 1KiB '$@'
	./bzImage_to_mmap bzImage 2048 65536 1048576 | ./write_mmap.py | dd of='$@' bs=512 count=2 conv=notrunc 2> /dev/null
	hexdump -C '$@'
	./parse_mmap.py '$@'

bzImage: linux/arch/x86/boot/bzImage
	cp '$<' '$@'

linux/arch/x86/boot/bzImage: linux/.config
	echo 'building linux kernel image'
	make -C linux -j "$$(nproc)" ARCH=x86 CROSS_COMPILE=x86_64-linux-gnu- KBUILD_BUILD_VERSION=0 KBUILD_BUILD_USER=root KBUILD_BUILD_HOST=localhost bzImage

linux/.config: | linux
	echo 'configuring linux kernel'
	make -C linux -j "$$(nproc)" ARCH=x86 CROSS_COMPILE=x86_64-linux-gnu- defconfig
	sed -i 's/=m/=n/' '$@'
	echo 'CONFIG_MODULES=n' >> '$@'
	echo 'CONFIG_CMDLINE_BOOL=y' >> '$@'
	echo 'CONFIG_CMDLINE="console=ttyS0 loglevel=7"' >> '$@'
	make -C linux -j "$$(nproc)" ARCH=x86 CROSS_COMPILE=x86_64-linux-gnu- olddefconfig

linux: .tmp
	echo 'downloading linux kernel sources'
	rm -rf '.tmp/$@'
	mkdir '.tmp/$@'
	curl 'https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.12.tar.xz' | xz -d | tar -x -C .tmp
	ln -s .tmp/linux-6.12 '$@'

.tmp: link_tmp

link_tmp:
	[ -d .tmp ] || ln -sf "$$(mktemp -d)" .tmp

clean: clean_tmp
	rm -f disk mbr.bin mmap.bin bzImage

clean_tmp:
	rm -rf "$$(readlink .tmp)" .tmp linux

test: disk
	echo 'running $< in qemu'
	./run.sh -drive file='$<',format=raw

debug: disk
	echo 'running $< in qemu in debug mode (32bit only, will fail once entered kernel)'
	./debug.sh -drive file='$<',format=raw

test_kernel: bzImage
	echo 'running $< in qemu'
	./run.sh -kernel '$<'
