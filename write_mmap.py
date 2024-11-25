#!/usr/bin/env python3

import sys
import struct

def main():
	sys.tracebacklimit = 0

	for line in sys.stdin:
		sects, lba, addr = line.split()
		data = struct.pack("<HII6x", int(sects), int(lba), int(addr))
		sys.stdout.buffer.write(data)

if __name__ == "__main__":
	main()
