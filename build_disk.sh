#!/usr/bin/env bash

set -eufo pipefail

bootloader="$1"
uki="$2"
disk="$3"

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

echo "writing MBR to disk"
dd if="$bootloader" of="$disk" bs=446 count=1 conv=notrunc 2> /dev/null

echo "writing stage2 to disk"
dd if="$bootloader" of="$disk" bs=512 iseek=1 count=2 seek=34 conv=notrunc 2> /dev/null

echo "writing config to disk"
./util/bootloader_util disk << EOF
{
	"boot_entries": [
		{
			"partition": 0,
			"uki_path": "/EFI/Linux/test-boot-entry.efi",
			"boot_count_enabled": false
		}
	]
}
EOF

dd if="$disk" bs=512 count=1 iseek=36 | hexdump -vC
dd if="$disk" bs=512 count=2 iseek=37 | hexdump -vC
dd if="$disk" bs=512 count=2 iseek=37 | ./parse_mmap.py
