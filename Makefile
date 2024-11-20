MAKEFLAGS += --no-builtin-rules
.SILENT:
.PHONY: clean test

mbr.bin: mbr.asm
	echo 'building $^ -> $@'
	nasm -f bin -o '$@' '$<'
	hexdump -vC '$@'

clean:
	rm -f mbr.bin

test: mbr.bin
	echo "running $< in qemu"
	qemu-system-x86_64 -machine pc -cpu qemu64 -accel tcg -m 1024 -nodefaults -nographic -serial stdio -drive file='$<',format=raw | stdbuf -i0 -o0 sed 's/\x1b[\[0-9;?]*[a-zA-Z]//g;s/[^[:print:]\t]//g'
