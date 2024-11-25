#!/usr/bin/env python3

import sys
import struct

def main():
	sys.tracebacklimit = 0

	initrd_size = int(sys.argv[2])
	data = struct.pack("<I", initrd_size)

	with open(sys.argv[1], "r+b") as f:
		f.seek(0x03fc)
		f.write(data)

if __name__ == "__main__":
	main()
