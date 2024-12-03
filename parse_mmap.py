#!/usr/bin/env python3

import sys
import struct

def main():
	sys.tracebacklimit = 0

	data = sys.stdin.buffer.read(0x400)

	for i in range(64):
		entry = data[i*16:(i+1)*16]
		sects, lba, addr = struct.unpack("<HII6x", entry)
		if sects != 0:
			print(f"{sects:5} (0x{sects:04x}) sectors @ LBA {lba:10} (0x{lba:08x}) -> mem {addr:10} (0x{addr:08x})")

if __name__ == "__main__":
	main()
