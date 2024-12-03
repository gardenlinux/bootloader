#!/usr/bin/env bash

set -eufo pipefail

bootloader="$1"
bzImage="$2"
initrd="$3"
uki="$4"
disk="$5"

truncate -s 0 "$disk"
truncate -s 512MiB "$disk"

printf 'label: gpt\nstart=2048, size=524288, type=uefi, name=EFI\n' | sfdisk "$disk"
mformat -i "$disk@@2048S" -F -T 524288 -c 4 -v EFI ::

# forcing future writes over 1M to be fragmented
free_clusters="$(minfo -i "$disk@@1M" :: | grep -oP '(?<=free clusters=).*')"
n="$(( free_clusters / 1024 ))"
i=0
while [ "$i" -lt "$n" ]; do
	head -c 1M /dev/zero | mcopy -i "$disk@@1M" - ::/tmp-$i-A
	head -c 1M /dev/zero | mcopy -i "$disk@@1M" - ::/tmp-$i-B
	i="$(( i + 1 ))"
	printf '\rfilling disk %d / %d' "$i" "$n"
done
printf '\n'
i=0
while [ "$i" -lt "$n" ]; do
	mdel -i "$disk@@1M" ::/tmp-$i-B
	i="$(( i + 1 ))"
	printf '\rpunching holes %d / %d' "$i" "$n"
done
printf '\n'

echo "writing UKI to disk"

mmd -i "$disk@@1M" ::/EFI
mmd -i "$disk@@1M" ::/EFI/Linux
mcopy -i "$disk@@1M" "$uki" ::/EFI/Linux/test-boot-entry.efi

i=0
while [ "$i" -lt "$n" ]; do
	mdel -i "$disk@@1M" ::/tmp-$i-A
	i="$(( i + 1 ))"
	printf '\rcleaning disk %d / %d' "$i" "$n"
done
printf '\n'

declare -A mmap_addr
mmap_addr[".linux_real"]=65536
mmap_addr[".cmdline"]=126976
mmap_addr[".linux_prot"]=1048576
mmap_addr[".initrd"]=67108864

x86_64-linux-gnu-objdump -h "$uki" \
| gawk '$2 ~ /^\.(linux|initrd|cmdline)/ { offset = strtonum("0x" $6); size = strtonum("0x" $3); if (offset % 512 != 0) { print "section " $2 " not sector aligned" }; print $2, offset / 512, int((size + 511) / 512); }' \
| while read section offset size; do
	if [ "$section" = .linux ]; then
		real_mode_sects="$(./parse_kernel_header.py "$bzImage" setup_sects '%d')"
		prot_mode_offset="$(( offset + real_mode_sects ))"
		prot_mode_sects="$(( size - real_mode_sects ))"
		echo ".linux_real $offset $real_mode_sects"
		echo ".linux_prot $prot_mode_offset $prot_mode_sects"
	else
		echo "$section $offset $size"
	fi
done \
| while read section offset size; do
	addr="${mmap_addr["$section"]}"
	./get_sectors_from_fat.py "$disk" 2048 EFI/Linux/test-boot-entry.efi "$offset" "$size" \
	| while read lba sectors; do
		echo "$sectors $lba $addr"
		addr="$(( addr + ( sectors * 512 ) ))"
	done
done \
| sort -n -k 3 > mmap

truncate -s 0 mmap.bin
truncate -s 1KiB mmap.bin
./write_mmap.py < mmap | dd of=mmap.bin bs=512 count=2 conv=notrunc 2> /dev/null

initrd_size="$(du -b -L "$initrd" | cut -f 1)"
./inject_initrd_size.py mmap.bin "$initrd_size"

hexdump -C mmap.bin
./parse_mmap.py < mmap.bin

dd if=/dev/zero of="config.bin" bs=512 count=1 2> /dev/null
printf '\000\377\377%s' "broken boot entry" | dd of="config.bin" bs=128 count=1 conv=notrunc 2> /dev/null
printf '\002\045\000%s' "test boot entry" | dd of="config.bin" bs=128 count=1 seek=2 conv=notrunc 2> /dev/null
printf '\377\045\000%s' "fallback boot entry" | dd of="config.bin" bs=128 count=1 seek=3 conv=notrunc 2> /dev/null
hexdump -vC "config.bin"

echo "writing MBR to disk"
dd if="$bootloader" of="$disk" bs=446 count=1 conv=notrunc 2> /dev/null

echo "writing stage2 to disk"
dd if="$bootloader" of="$disk" bs=512 iseek=1 count=2 seek=34 conv=notrunc 2> /dev/null

echo "writing config to disk"
dd if=config.bin of="$disk" bs=512 count=1 seek=36 conv=notrunc 2> /dev/null

echo "writing mmap to disk"
dd if=mmap.bin of="$disk" bs=512 count=2 seek=37 conv=notrunc 2> /dev/null
