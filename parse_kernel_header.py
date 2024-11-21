#!/usr/bin/env python3

import sys
import struct
import binascii

KERNEL_SETUP_HEADER_OFFSET = 0x01f1
KERNEL_SETUP_HEADER_LEN = 0x007b

header_format = {
	"setup_sects": "B",
	"root_flags": "H",
	"syssize": "I",
	"ram_size": "H",
	"vid_mode": "H",
	"root_dev": "H",
	"boot_flag": "H",
	"jump": "H",
	"header": "I",
	"version": "H",
	"realmode_swtch": "I",
	"start_sys_seg": "H",
	"kernel_version": "H",
	"type_of_loader": "B",
	"loadflags": "B",
	"setup_move_size": "H",
	"code32_start": "I",
	"ramdisk_image": "I",
	"ramdisk_size": "I",
	"bootsect_kludge": "I",
	"heap_end_ptr": "H",
	"ext_loader_ver": "B",
	"ext_loader_type": "B",
	"cmd_line_ptr": "I",
	"initrd_addr_max": "I",
	"kernel_alignment": "I",
	"relocatable_kernel": "B",
	"min_alignment": "B",
	"xloadflags": "H",
	"cmdline_size": "I",
	"hardware_subarch": "I",
	"hardware_subarch_data": "Q",
	"payload_offset": "I",
	"payload_length": "I",
	"setup_data": "Q",
	"pref_address": "Q",
	"init_size": "I",
	"handover_offset": "I",
	"kernel_info_offset": "I"
}

print_format = {
	"B": "0x%02x",
	"H": "0x%04x",
	"I": "0x%08x",
	"Q": "0x%016x",
}

def main():
	sys.tracebacklimit = 0

	dump_header = False
	output_file = None
	set_values = dict()

	arg_idx = 1
	while sys.argv[arg_idx].startswith("-"):
		if sys.argv[arg_idx] == "--dump-header":
			dump_header = True
			arg_idx += 1
		elif sys.argv[arg_idx] == "--output":
			output_file = sys.argv[arg_idx + 1]
			arg_idx += 2
		elif sys.argv[arg_idx] == "--set":
			(set_key, set_value) = sys.argv[arg_idx + 1].split("=")
			assert set_key in header_format, f"invalid key: {set_key}"
			set_values[set_key] = int(set_value)
			arg_idx += 2
		else:
			assert False, f"invalid arg: {sys.argv[arg_idx]}"

	kernel_image_path = sys.argv[arg_idx]
	output_key = sys.argv[arg_idx + 1] if len(sys.argv) >= arg_idx + 2 else None
	output_format = sys.argv[arg_idx + 2] if len(sys.argv) >= arg_idx + 3 else None

	if kernel_image_path.startswith("0x"):
		header_data = binascii.unhexlify(kernel_image_path[2:])
	else:
		with open(kernel_image_path, "rb") as f:
			f.seek(KERNEL_SETUP_HEADER_OFFSET)
			header_data = f.read(KERNEL_SETUP_HEADER_LEN)

	struct_format = "< " + " ".join(header_format.values())
	header = dict(zip(header_format.keys(), struct.unpack(struct_format, header_data)))

	for (key, value) in set_values.items():
		header[key] = value

	header_data = struct.pack(struct_format, *header.values())

	if output_file:
		with open(output_file, "wb") as f:
			f.write(header_data)

	if dump_header:
		print("0x" + binascii.hexlify(header_data).decode())
		return

	if output_key:
		outputs = [ (output_format or print_format[header_format[output_key]], output_key) ]
	else:
		max_key_length = max(len(key) for key in header_format.keys())
		outputs = [ (f"{key:{max_key_length}} {print_format[header_format[key]]}", key) for key in header.keys() ]

	for (format_str, key) in outputs:
		print(format_str % header[key])

if __name__ == "__main__":
	main()
