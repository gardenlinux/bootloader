#!/usr/bin/env bash

set -eufo pipefail

bzImage="$1"
lba="$2"
real_mode_addr="$3"
prot_mode_addr="$4"

size="$(du -b "$bzImage" | cut -f 1)"
if [ "$(( size % 512 ))" != 0 ]; then
	echo "bzImage size not a multiple of 512" >&2
	exit 1
fi

total_sects="$(( size / 512 ))"
real_mode_sects="$(./parse_kernel_header.py "$bzImage" setup_sects '%d')"

prot_mode_lba="$(( lba + real_mode_sects ))"
prot_mode_sects="$(( total_sects - real_mode_sects ))"

printf '%d %d %d\n%d %d %d\n' "$real_mode_sects" "$lba" "$real_mode_addr" "$prot_mode_sects" "$prot_mode_lba" "$prot_mode_addr"
