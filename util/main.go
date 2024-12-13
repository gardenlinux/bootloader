package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"reflect"

	"github.com/diskfs/go-diskfs"
	"github.com/diskfs/go-diskfs/disk"
	"github.com/diskfs/go-diskfs/filesystem/fat32"
	"github.com/diskfs/go-diskfs/partition/gpt"
	"github.com/saferwall/pe"
)

const stage2_lba = 0x22
const config_lba = 0x24
const mmap_start_lba = 0x25
const first_part_min = 0x40

type Config struct {
	BootEntries [4]BootEntry `json:"boot_entries"`
}

type BootEntry struct {
	Partition        uint8  `json:"partition"`
	UkiPath          string `json:"uki_path"`
	BootCountEnabled bool   `json:"boot_count_enabled"`
	BootCount        uint8  `json:"boot_count"`
	MmapSector       uint16
	Mmap             []Mmap
	InitrdSize       uint32
}

type SectorRange struct {
	Start  uint32
	Length uint32
}

type Mmap struct {
	Length uint16
	Start  uint32
	Addr   uint32
}

func sectionToSectorRanges(section SectorRange, sector_ranges []SectorRange) []SectorRange {
	var result []SectorRange
	current_offset := uint32(0)

	for _, range_entry := range sector_ranges {
		range_start := range_entry.Start
		range_length := range_entry.Length

		if current_offset+range_length > section.Start && current_offset <= section.Start {
			relative_start := section.Start - current_offset
			start_sector := range_start + relative_start

			remaining_length := section.Length

			output_range_length := range_length - relative_start
			if remaining_length < output_range_length {
				output_range_length = remaining_length
			}

			result = append(result, SectorRange{
				Start:  start_sector,
				Length: output_range_length,
			})

			remaining_length -= output_range_length
			if remaining_length == 0 {
				break
			}

			section.Length = remaining_length
			section.Start += output_range_length
		}

		current_offset += range_length
	}

	return result
}

func getUkiMmap(disk *disk.Disk, partition *gpt.Partition, uki_path string) ([]Mmap, uint32, error) {
	var initrd_size uint32

	file_system, err := fat32.Read(disk.Backend, partition.GetSize(), partition.GetStart(), 512)
	if err != nil {
		return nil, 0, err
	}

	file, err := file_system.OpenFile(uki_path, os.O_RDONLY)
	if err != nil {
		return nil, 0, err
	}

	fat32_file := file.(*fat32.File)

	disk_ranges, err := fat32_file.GetDiskRanges()
	if err != nil {
		return nil, 0, err
	}

	sector_ranges := make([]SectorRange, len(disk_ranges))
	for i, disk_range := range disk_ranges {
		sector_ranges[i] = SectorRange{
			Start:  uint32(disk_range.Offset/512) + uint32(partition.Start),
			Length: uint32(disk_range.Length / 512),
		}
	}

	buf, err := io.ReadAll(file)
	if err != nil {
		return nil, 0, err
	}

	pe_file, err := pe.NewBytes(buf, &pe.Options{})
	if err != nil {
		return nil, 0, err
	}

	err = pe_file.Parse()
	if err != nil {
		return nil, 0, err
	}

	sections := make(map[string]SectorRange, len(pe_file.Sections)+1)

	for _, section := range pe_file.Sections {
		if section.Header.PointerToRawData%512 != 0 {
			return nil, 0, fmt.Errorf("section %s is not sector aligned: %x", section.Header.Name, section.Header.PointerToRawData)
		}

		section_name := string(bytes.TrimRight(section.Header.Name[:], "\x00"))
		start_sector := section.Header.PointerToRawData / 512
		sector_size := (section.Header.SizeOfRawData + 511) / 512

		if section_name == ".linux" {
			data := section.Data(0, 0, pe_file)
			setup_sects := uint(data[0x01f1])

			sections[".linux_real"] = SectorRange{
				Start:  uint32(start_sector),
				Length: uint32(setup_sects),
			}

			sections[".linux_prot"] = SectorRange{
				Start:  start_sector + uint32(setup_sects),
				Length: sector_size - uint32(setup_sects),
			}
		} else {
			sections[section_name] = SectorRange{
				Start:  start_sector,
				Length: sector_size,
			}
		}

		if section_name == ".initrd" {
			initrd_size = section.Header.SizeOfRawData
		}
	}

	mmap_sections := map[string]uint64{
		".linux_real": 0x0010000,
		".cmdline":    0x001f000,
		".linux_prot": 0x0100000,
		".initrd":     0x4000000,
	}

	mmap := make([]Mmap, 0, 64)

	for section, addr := range mmap_sections {
		ranges := sectionToSectorRanges(sections[section], sector_ranges)
		for _, r := range ranges {
			mmap = append(mmap, Mmap{
				Length: uint16(r.Length),
				Start:  r.Start,
				Addr:   uint32(addr),
			})
			addr += uint64(r.Length) * 512
		}
	}

	return mmap, initrd_size, nil
}

func mmapToBin(mmap []Mmap, initrd_size uint32) ([1024]byte, error) {
	var bin [1024]byte

	if len(mmap) > 64 {
		return bin, fmt.Errorf("mmap exceeds limit of 64 entries")
	}

	for i, entry := range mmap {
		bin_entry := bin[i*16 : (i+1)*16]

		bin_entry[0] = byte(entry.Length)
		bin_entry[1] = byte(entry.Length >> 8)
		bin_entry[2] = byte(entry.Start)
		bin_entry[3] = byte(entry.Start >> 8)
		bin_entry[4] = byte(entry.Start >> 16)
		bin_entry[5] = byte(entry.Start >> 24)
		bin_entry[6] = byte(entry.Addr)
		bin_entry[7] = byte(entry.Addr >> 8)
		bin_entry[8] = byte(entry.Addr >> 16)
		bin_entry[9] = byte(entry.Addr >> 24)
	}

	bin_initrd_size := bin[1020:1024]
	bin_initrd_size[0] = byte(initrd_size)
	bin_initrd_size[1] = byte(initrd_size >> 8)
	bin_initrd_size[2] = byte(initrd_size >> 16)
	bin_initrd_size[3] = byte(initrd_size >> 32)

	return bin, nil
}

func bootEntryToBin(entry BootEntry) ([128]byte, error) {
	var bin [128]byte

	if len(entry.UkiPath) > 124 {
		return bin, fmt.Errorf("boot entry label exceeds 124 bytes")
	}

	bin[0] = entry.BootCount
	bin[1] = byte(entry.MmapSector)
	bin[2] = byte(entry.MmapSector >> 8)
	copy(bin[3:126], []byte(entry.UkiPath))

	return bin, nil
}

func configToBin(config Config) ([512]byte, error) {
	var bin [512]byte

	for i, entry := range config.BootEntries {
		entry_bin, err := bootEntryToBin(entry)
		if err != nil {
			return bin, err
		}
		copy(bin[i*128:(i+1)*128], entry_bin[:])
	}

	return bin, nil
}

func main() {
	if len(os.Args) != 2 || os.Args[1] == "--help" {
		fmt.Fprintf(os.Stderr, "Usage: %s <disk>\nreads boot config json from stdin\n", os.Args[0])
		os.Exit(1)
	}

	disk_path := os.Args[1]

	decoder := json.NewDecoder(os.Stdin)
	var config Config
	err := decoder.Decode(&config)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to parse config: %v\n", err)
		os.Exit(1)
	}

	for i := range config.BootEntries {
		config.BootEntries[i].MmapSector = uint16(mmap_start_lba + (i * 2))

		if config.BootEntries[i].UkiPath == "" {
			config.BootEntries[i].BootCount = 0
		} else if !config.BootEntries[i].BootCountEnabled {
			config.BootEntries[i].BootCount = 255
		}
	}

	disk, err := diskfs.Open(disk_path)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to open disk \"%s\": %v\n", disk_path, err)
		os.Exit(1)
	}

	part_table, err := disk.GetPartitionTable()
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to read partition table: %v\n", err)
		os.Exit(1)
	}

	if part_table.Type() != "gpt" {
		fmt.Fprintf(os.Stderr, "Not a GPT partition table\n")
		os.Exit(1)
	}

	gpt_table := part_table.(*gpt.Table)

	if gpt_table.LogicalSectorSize != 512 {
		fmt.Fprintf(os.Stderr, "Non standard sector size of %d detected. Must be 512\n", gpt_table.LogicalSectorSize)
		os.Exit(1)
	}

	gpt_table_ref := reflect.ValueOf(gpt_table).Elem()
	partition_array_size := uint64(gpt_table_ref.FieldByName("partitionArraySize").Int())
	partition_entry_size := gpt_table_ref.FieldByName("partitionEntrySize").Uint()
	gpt_lba := gpt_table_ref.FieldByName("partitionFirstLBA").Uint()

	data_lba := gpt_lba + (partition_array_size*partition_entry_size)/512
	if data_lba > stage2_lba {
		fmt.Fprintf(os.Stderr, "GPT table extends beyond sector %d, this is unsupported\n", stage2_lba)
		os.Exit(1)
	}

	for index, partition := range gpt_table.Partitions {
		if partition.Start <= first_part_min {
			fmt.Fprintf(os.Stderr, "Partition %d @%d starts before minimum sector %d, this is unsupported\n", index+1, partition.Start, first_part_min)
		}
	}

	for i, boot_entry := range config.BootEntries {
		if boot_entry.BootCount == 0 {
			continue
		}

		if len(gpt_table.Partitions) < int(boot_entry.Partition)+1 {
			fmt.Fprintf(os.Stderr, "Partiton %d not found on disk\n", boot_entry.Partition)
			os.Exit(1)
		}

		partition := gpt_table.Partitions[boot_entry.Partition]
		mmap, initrd_size, err := getUkiMmap(disk, partition, boot_entry.UkiPath)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Failed to generate mmap for UKI: %v\n", err)
			os.Exit(1)
		}

		config.BootEntries[i].Mmap = mmap
		config.BootEntries[i].InitrdSize = initrd_size
	}

	disk_file, err := os.OpenFile(disk_path, os.O_WRONLY, 0)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to re-open disk for writing: %v\n", err)
		os.Exit(1)
	}

	for _, entry := range config.BootEntries {
		mmap_bin, err := mmapToBin(entry.Mmap, entry.InitrdSize)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Failed to encode mmap: %v\n", err)
			os.Exit(1)
		}

		disk_file.WriteAt(mmap_bin[:], int64(entry.MmapSector)*512)
	}

	config_bin, err := configToBin(config)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to encode config: %v\n", err)
		os.Exit(1)
	}

	disk_file.WriteAt(config_bin[:], config_lba*512)
}
