#!/usr/bin/env python3

import sys
from pyfatfs import PyFat

def combine_ranges(list):
	start = None
	length = 0
	for i in list:
		if start is None:
			start = i
			length = 1
		elif i == start + length:
			length += 1
		else:
			yield (start, length)
			start = i
			length = 1
	if start is not None:
		yield (start, length)

def clusters_to_sectors(fat, clusters):
	sectors_per_cluster = fat.bpb_header["BPB_SecPerClus"]

	for cluster in clusters:
		base_address = fat.get_data_cluster_address(cluster)
		base_sector = base_address // 512
		for i in range(sectors_per_cluster):
			yield base_sector + i

def main():
	sys.tracebacklimit = 0

	disk_path = sys.argv[1]
	disk_offset = int(sys.argv[2])
	file_path = sys.argv[3]
	offset = 0
	size = None

	if len(sys.argv) >= 5:
		offset = int(sys.argv[4])
	if len(sys.argv) >= 6:
		size = int(sys.argv[5])

	fat = PyFat.PyFat(offset=disk_offset*512)
	fat.open(disk_path)

	assert fat.bpb_header["BPB_BytsPerSec"] == 512, "invalid bytes per sector"

	file = fat.root_dir.get_entry(file_path)
	file_start_cluster = file.get_cluster()
	file_clusters = fat.get_cluster_chain(file_start_cluster)
	file_sectors = [sector + disk_offset for sector in list(clusters_to_sectors(fat, file_clusters))]

	if size:
		sectors = file_sectors[offset:offset+size]
	else:
		sectors = file_sectors[offset:]

	ranges = combine_ranges(sectors)
	
	for range in ranges:
		print(f"{range[0]} {range[1]}")

if __name__ == "__main__":
	main()
