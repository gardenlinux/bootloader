org 0x7c00
BITS 16

; memory layout:
;
; === low mem ===
;
;         ? - 0x0007c00 stack (grows down dynamically)
; 0x0007c00 - 0x0007dbe bootloader
; 0x0007dbe - 0x0007dfe partition table
; 0x0007dfe - 0x0007e00 boot signature
; 0x0007e00 - 0x0008200 stage2 bootloader
; 0x0008200 - 0x0008400 boot config
; 0x0008400 - 0x0008800 mmap (maps disk LBA to memory locations)
;                       format:
;                         array of 64 entries, each 16 bytes long
;                         entry format:
;                           word   number of sectors
;                           dword  LBA address
;                           dword  memory address
;                           (zero padding to align each entry on 16 byte boundry)
; 0x00087fc - 0x0008800 initrd size (replaces part of the padding of the final mmap entry)
;
; 0x0010000 - 0x0018000 real mode kernel code
; 0x0018000 - 0x001f000 real mode kernel heap
; 0x001f000 - 0x001f800 kernel cmdline
; 0x0040000 - 0x0048000 disk read temp buffer (for loading protected mode kernel code)
;
; === high mem ===
;
; 0x0100000 - ?         protected mode kernel code
; 0x4000000 - ?         initrd



stage2_lba:             equ 0x00000021                          ; LBA location of stage2 on disk
stage2_addr:            equ 0x00007e00                          ; memory address of stage2
stage2_seg:             equ stage2_addr / 0x10                  ; memory segment of stage2

boot_conf_lba:          equ 0x00000023                          ; LBA location of boot config
boot_conf_addr:         equ 0x00008200                          ; memory address of boot config
boot_conf_seg:          equ boot_conf_addr / 0x10               ; memory segment of boot config

mmap_addr:              equ 0x00008400                          ; memory address of mmap
mmap_seg:               equ mmap_addr / 0x10                    ; memory segment of mmap

real_mode_addr:         equ 0x00010000                          ; memory address of the real mode kernel code
real_mode_seg:          equ real_mode_addr / 0x10               ; memory segment of the real mode kernel code

buffer_addr:            equ 0x040000                            ; memory address of disk read buffer
buffer_base_low:        equ buffer_addr % 0x010000              ; low 16 bits of buffer address
buffer_base_mid:        equ buffer_addr / 0x010000              ; mid 8 bits of buffer address
buffer_seg:             equ buffer_addr / 0x10                  ; memory segment of disk read buffer

initrd_addr:            equ 0x4000000                           ; memory address of the initrd
cmdline:                equ 0x01f000                            ; memory oddress of the cmdline
kernel_stack:           equ cmdline - real_mode_addr            ; sp for kernel entry
heap_end_ptr:           equ kernel_stack - 0x0200               ; offset from the real mode kernel code to the end of heap minus 0x0200 (as according to linux boot protocol spec)

main:
; perform basic init functions and setup stack
	cli                                         ; disable interrupts
	xor      ax,       ax                       ; set ax = 0
	mov      ds,       ax                       ; ensure data segment at 0
	mov      ss,       ax                       ; ensure stack segment at 0
	mov      es,       ax                       ; ensure extra segment at 0
	mov      sp,       0x7c00                   ; set stack pointer to start of bootloader code (grows down below it)
	cld                                         ; ensure forward direction for string operations (lodsb)

	call     flush                              ; flush all output to serial console before mode set
	mov      ax,       0x0002                   ; ah=0x00 (set video mode) al=0x02 (video mode 2: text mode 80x25 chars monochrome)
	int      0x10                               ; set video mode via interrupt

	mov      si,       strings.init             ; load msg ptr into si
	call     print_line                         ; print_line(msg)

; load stage2 from disk into memory
	mov      si,       dap                      ; point si at dap (pre-initialized with source and destination addresses for stage2 load)
	mov      dl,       0x80                     ; select disk 0x80 (primary HDD) for disk access
	mov      ah,       0x42                     ; select LBA read mode for disk access
	int      0x13                               ; perform disk access via interrupt
	jc       disk_read_error                    ; on error jump to print errror msg and halt

	mov      si,       strings2.loaded          ; load msg ptr into si
	call     print_line                         ; print_line(msg)

; from here we can use stage2 functions
	call     pick_entry                         ; look ot boot_conf and decide which entry to pick
	                                            ; after this call ax = mmap LBA, cx = boot id, si = ptr to entry label

	push     ax                                 ; save ax
	call     print_line                         ; print selected entries label
	pop      ax                                 ; restore ax

	push     ax                                 ; sove ax
	mov      si,       cx                       ; load boot id into si
	mov      al,       [strings.hex_map+si]     ; convert boot id to ascii
	mov      [strings2.boot_id_char], al        ; write out boot id ascii

	mov      si,       strings2.cmdline_append  ; load msg ptr into si
	call     print_line                         ; print_line(msg)
	pop      ax                                 ; restore ax

	call     read_mmap                          ; read mmap of selected entry into memory

	call     load_mmap                          ; load all sectors defined in mmap into memory
	mov      si,       strings2.mmap            ; load msg ptr into si
	call     print_line                         ; print_line(msg)

	call     print_kversion                     ; print the version of the loaded kernel
	call     config_kernel                      ; set the necessary headers in the kernel setup data

	call     flush                              ; flush output before entering kernel code
	jmp      exec_kernel                        ; pass control to the kernel

; halts execution
; does not return and may clobber everything!
halt:
	call     flush                              ; ensure final output line is flushed to serial console
	hlt                                         ; halt CPU
	jmp      halt                               ; keep halting if interrupted

; flushes all printed lines to serial output by writing a null byte to ensure cursor is advanced
; clobbers: ax, bx
flush:
	mov      ax,       0x0e00                   ; ah=0x0e (teletype mode) al=0x00 (null byte)
	mov      bx,       0x0000                   ; ensure page number is 0
	int      0x10                               ; output nullbyte
	ret                                         ; return from call

; prints a null terminated string and advances cursor to the next line
; inputs:
;   ds:si: pointer to start of string
; clobbers: ax, bx, si
print_line:
	call     print_str                          ; pass input string on to print_str
	push     ds                                 ; save value of DS
	xor      ax,       ax                       ; set ax = 0
	mov      ds,       ax                       ; ensure data segment at 0
	mov      si,       strings.newline          ; load newline ptr into si
	call     print_str                          ; print newline sequence
	pop      ds                                 ; restore value of DS
	ret                                         ; return from call

; prints a null terminated string
; inputs:
;   ds:si: pointer to start of string
; clobbers: ax, bx, si
print_str:
	lodsb                                       ; load byte pointed to by ds:si into al and increment si
	cmp      al,       0x00                     ; check if al == 0, i.e. we read a null byte
	je       .ret                               ; if al is null byte jump to .ret
	mov      ah,       0x0e                     ; select teletype output mode
	mov      bx,       0x0000                   ; ensure page number is 0
	int      0x10                               ; write character via interrupt
	jmp      print_str                          ; loop until null byte was read
.ret:
	ret                                         ; return from call

; print disk read error and halt
disk_read_error:
	mov      si,       strings.disk_error      ; load msg ptr into si
	jmp      error                             ; error(msg)

error:
	mov      dx,       si                       ; save msg ptr in dx
	mov      bl,       ah                       ; move ah (err code) into bl
	shr      bl,       0x04                     ; select high 4 bits of error code in bl
	movzx    si,       bl                       ; load bl into si to allow mem + offset access
	mov      bl,       [strings.hex_map+si]     ; convert bl to hex char
	mov      bh,       ah                       ; move ah (err code) into bh
	and      bh,       0x0f                     ; select low 4 bits of error code in bh
	movzx    si,       bh                       ; load bh into si to allow mem + offset access
	mov      bh,       [strings.hex_map+si]     ; convert bh to hex char
	mov      [strings.err_code], bx             ; write hex error code into error msg
	mov      si,       strings.error            ; load error prefix string ptr into si
	call     print_str                          ; print_str(error)
	mov      si,       dx                       ; load msg ptr into si
	call     print_line                         ; print_line(msg)
	jmp      halt                               ; halt after printing error

; disk address packet
dap:
	db 0x10                                     ; size of struct = 16
	db 0x00                                     ; unused
.sectors:
	dw 0x0003                                   ; number of sectors to read
	dw 0x0000                                   ; memory offset within segment (always 0 here)
.segment:
	dw stage2_seg                               ; memory segment
.lba:
	dd stage2_lba                               ; low bytes of LBA address of data on disk
	dd 0x00000000                               ; high bytes of LBA address (unused by us)

; string constants
strings:
.init: db "initialized", 0x00
.error: db "ERROR ["
.err_code: db "00]: ", 0x00
.disk_error: db "disk read", 0x00
.newline: db 0x0d, 0x0a, 0x00
.hex_map: db "0123456789ABCDEF"

; assert that we have not over-run the maximum size of an MBR bootloader
%if ($-$$) > 0x01bd
	%error "MBR code exceeds 445 bytes"
%endif

; padd remaining space with zeros
%rep 0x01bd-($-$$)
	db 0
%endrep

; debug label, call this to effectively set a breakpoint in code
debug:
	ret                                         ; return instruction on addr 0x7dbd to set debugger breakpoint at

; empty partition table
%rep 0x01fe-($-$$)
	db 0x00
%endrep

; add the required boot signature
	dw 0xaa55

; look at boot config and choose which entry to boot
; returns:
;   ax: LBA of mmap
;   cx: entry id
;   si: ptr to entry label
; clobbers: ax, bx, cx, dx, si
pick_entry:
	mov      cx,       0x0000                   ; initialize loop counter
.loop:
	cmp      cx,       0x0004                   ; check we haven't surpassed max of 4 boot entries
	jge      pick_entry_error                   ; if so goto error

	mov      si,       cx                       ; copy loop counter to si
	shl      si,       0x07                     ; multiply by 128 (size of boot config entry)
	mov      bl,       [boot_conf_addr+si]      ; read boot entry cntr into bl

	cmp      bl,       0x00                     ; check boot counter not equal 0x00
	jne      .found                             ; if so use this boot entry

	inc      cx                                 ; else increment the loop counter
	jmp      .loop                              ; and continue loop

.found:
	cmp      bl,       0xff                     ; check if boot counter is special "boot blessed" value
	je       .no_dec                            ; if so skip the decrement step
	dec byte [boot_conf_addr+si]                ; decrement the boot tries remaining counter

	mov word  [dap.sectors], 0x0001             ; set dap to one sector only
	mov word  [dap.segment], boot_conf_seg      ; set dap to point at boot config memory sector
	mov dword [dap.lba],     boot_conf_lba      ; set dap to use boot config LBA

	mov      dx,       si                       ; save current value of si
	mov      si,       dap                      ; point si at dap
	mov      dl,       0x80                     ; select disk 0x80 (primary HDD) for disk access
	mov      ah,       0x43                     ; select LBA write mode for disk access
	int      0x13                               ; perform disk access via interrupt
	jc       disk_read_error                    ; on error jump to print errror msg and halt
	mov      si, dx                             ; restore si from saved value

.no_dec:
	mov      ax,       [0x01+boot_conf_addr+si] ; load mmap LBA of entry into ax
	add      si,       0x03+boot_conf_addr      ; set si to point at boot entry label
	ret                                         ; return from call

; read mmap of selected entry to memory
; inputs:
;   ax: LBA of mmap
; outputs: [mmap_addr]
; clobbers: ax, dx, si
read_mmap:
	mov word [dap.sectors], 0x0002              ; set dap to 2 sectors
	mov word [dap.segment], mmap_seg            ; set dap to point at mmap memory sector
	mov      [dap.lba],     ax                  ; set dap to use boot config LBA

	mov      si,       dap                      ; point si at dap
	mov      dl,       0x80                     ; select disk 0x80 (primary HDD) for disk access
	mov      ah,       0x42                     ; select LBA read mode for disk access
	int      0x13                               ; perform disk access via interrupt
	jc       disk_read_error                    ; on error jump to print errror msg and halt

	ret                                         ; return from call

; iterates mmap and loads all sections into memory
; clobbers: ax, bx, cx, dx, si, [buffer 0x040000-0x048000]
load_mmap:
	mov      dx,       0x0000                   ; init dx (loop counter) as 0

.loop:
	cmp      dx,       0x0040                   ; compare if loop counter <= 64
	jge      .break                             ; break once loop counter == 64

	mov      si,       dx                       ; copy loop counter to si
	shl      si,       0x04                     ; multiply by 16 (size of entry)
	add      si,       mmap_addr                ; apply as offset to mmap addr
	mov      cx,       [si]                     ; load number of sectors from mmap entry into cx

	add      si,       0x0002                   ; move pointer to LBA address of mmap entry
	mov      ax,       [si]                     ; read low bits of LBA address
	mov      [dap.lba], ax                      ; write low bits of LBA address to dap
	add      si,       0x0002                   ; shift to high bits
	mov      ax,       [si]                     ; read high bits of LBA address
	mov      [dap.lba+0x0002], ax               ; write high bits of LBA address to dap

	add      si,       0x0002                   ; move pointer to memory address of mmap entry
	mov      ax,       [si]                     ; read low bits of memory address
	mov      [gdt.target_base_low], ax          ; write low bits of memory address to gdt
	add      si,       0x0002                   ; shift to high bits
	mov      ax,       [si]                     ; read high bits of memory address
	mov      [gdt.target_base_mid], al          ; write mid bits of memory address to gdt
	mov      [gdt.target_base_high], ah         ; write mid bits of memory address to gdt

	call     read_sectors                       ; read protected mode kernel code (target pre-defined in gdt)

	inc      dx                                 ; increment loop counter
	jmp      .loop                              ; continue loop

.break:
	ret                                         ; return from call

; fetches the kernel uname from its header and prints it
print_kversion:
	push     ds                                 ; save current value of df
	mov      ax,       real_mode_seg            ; set ax = segment of real mode kernel code
	mov      ds,       ax                       ; set data segment to real mode kernel code location

	mov      si,       [0x020e]                 ; load kernel_version ptr from header
	add      si,       0x0200                   ; add 0x0200 offset (somehow needed according to spec)
	call     print_line                         ; print kernel version

	pop      ds                                 ; restore ds
	ret                                         ; return from call

; setup kernel header fields
; clobbers: ax, bx
config_kernel:
	push     ds                                 ; save current value of df
	mov      ax,       real_mode_seg            ; set ax = segment of real mode kernel code
	mov      ds,       ax                       ; set data segment to real mode kernel code location

	mov      ax,       es:[mmap_addr+0x03fc]    ; read low 16 bits of initrd size into ax (use es, as ds targets kernel)
	mov      bx,       es:[mmap_addr+0x03fe]    ; read high 16 bits of initrd size into bx (use es, as ds targets kernel)

	mov byte  [0x0210], 0xff                    ; set type_of_loader = undefined
	or  byte  [0x0211], 0x80                    ; set CAN_USE_HEAP bit in loadflags
	mov dword [0x0218], initrd_addr             ; set ramdisk_image
	mov       [0x021c], ax                      ; write low 16 bits of initrd size
	mov       [0x021e], bx                      ; write high 16 bits of initrd size
	mov word  [0x0224], heap_end_ptr            ; set heap_end_ptr
	mov dword [0x0228], cmdline                 ; set cmdline

	pop      ds                                 ; restore ds
	ret                                         ; return from call

; pass control to the (configured) kernel
; does not return and may clobber everything!
exec_kernel:
	mov      ax,       real_mode_seg            ; set ax = segment of real mode kernel code
	mov      ds,       ax                       ; set data segment to real mode kernel code location
	mov      es,       ax                       ; set extra segment to real mode kernel code location
	mov      fs,       ax                       ; set fs segment to real mode kernel code location
	mov      gs,       ax                       ; set gs segment to real mode kernel code location
	mov      ss,       ax                       ; set stack segment to real mode kernel code location
	mov      sp,       kernel_stack             ; set the stack pointer to top of kernel heap
	jmp      0x1020:0                           ; far jump to kernel entry point

; read N sectors from disk to memory, supports reading into high mem
; inputs:
;   cx: number of sectors
;   [dap.lba]: starting LBA
;   [gdt.target_base_low]: low 16 bits of target memory address
;   [gdt.target_base_mid]: mid 8 bits of target memory address
; clobbers: ax, bx, cx, si, [buffer 0x040000-0x048000]
read_sectors:
	push     dx                                 ; save dx

	mov word [dap.sectors], 0x0040              ; set dap to read 64 sectors (32 KiB)
	mov word [dap.segment], buffer_seg          ; set dap to target the buffer segment

	push     cx                                 ; save value of cx
	shr      cx,       0x06                     ; divide cx by 64 (the number of sectors to read in one chunk)

.read_chunk:
	cmp      cx,       0x0000                   ; check if we have read all full chunks
	je       .end                               ; if then exit loop

	mov      si,       dap                      ; point si at dap
	mov      dl,       0x80                     ; select disk 0x80 (primary HDD) for disk access
	mov      ah,       0x42                     ; select LBA read mode for disk access
	int      0x13                               ; perform disk access via interrupt
	jc       disk_read_error                    ; on error jump to print errror msg and halt

	mov      dx,       cx                       ; store cx in dx
	mov      cx,       [dap.sectors]            ; load number of sectors to cx
	shl      cx,       0x08                     ; convert from sectors to words (multiply by 256)
	mov      si,       gdt                      ; point es:si at gdt
	mov      ah,       0x87                     ; select block mov mode
	int      0x15                               ; perform block mov via interrupt
	jc       block_move_error                   ; on error jump to print error msg and holt
	mov      cx,       dx                       ; restore saved cx

	add word [dap.lba],             0x0040      ; advance dap LBA by 64 sectors
	add word [gdt.target_base_low], 0x8000      ; advance target base by 32 KiB
	adc byte [gdt.target_base_mid], 0x00        ; if target base low rolled over then advance target base mid
	adc byte [gdt.target_base_high], 0x00       ; if target base mid rolled over then advance target base high

	dec      cx                                 ; decrement number of chunks left to read
	jmp      .read_chunk                        ; continue loop

.end:
	pop      cx                                 ; restore cx
	and      cx,       0x003f                   ; compute mod 64

	cmp      cx,       0x0000                   ; check for no remainder
	je       .ret                               ; skip if no remaining sectors

	push word 0x0000                            ; ensure that after reading final partial chunk remaining sectors is 0

	mov word [dap.sectors], cx                  ; set dap to read remaining number of sectors
	mov      cx,       0x0001                   ; read one partial chunk
	jmp      .read_chunk                        ; jmp back to read_chunk

.ret:

	pop      dx                                 ; restore dx
	ret                                         ; return from call

; print disk read error and halt
block_move_error:
	mov      si,       strings2.move_error      ; load msg ptr into si
	jmp      error                              ; error(msg)

; print no valid entry error and halt
pick_entry_error:
	mov      si,       strings2.entry_error     ; load msg ptr into si
	mov      ax,       0x0000                   ; set error code undefined
	jmp      error                              ; error(msg)

; global descriptor table
gdt:
	times 16 db 0                               ; obligatory null entries
; source segment (0x040000 - 0x048000)
	dw 0x7fff                                   ; limit low bits (32KiB)
	dw buffer_base_low                          ; base low bits
	db buffer_base_mid                          ; base mid bits
	db 0x93                                     ; access mode (present, type=data, rw)
	db 0x00                                     ; flags and limit high bits
	db 0x00                                     ; base high bits
; target segment in high mem, initially at 0x100000 - 0x108000, updated as a sliding window
	dw 0x7fff                                   ; limit low bits (32KiB)
.target_base_low:                               ; label to allow updating base
	dw 0x0000                                   ; base low bits
.target_base_mid:                               ; label to allow updating base
	db 0x00                                     ; base mid bits
	db 0x93                                     ; access mode (present, type=data, rw)
	db 0x00                                     ; flags and limit high bits
.target_base_high:
	db 0x00                                     ; base high bits
	times 16 db 0                               ; obligatory null entries

; string constants
strings2:
.cmdline_append: db "bootloader.entry="
.boot_id_char: db "0", 0x00
.loaded: db "loaded stage2 payload", 0x00
.mmap: db "mmap done", 0x00
.move_error: db "memory block move", 0x00
.entry_error: db "no valid boot entry available", 0x00

; assert that we have not over-run 1K for our stage2 payload
%if ($-$$) > 0x0600
	%error "stage2 code exceeds 1024 bytes"
%endif

; padd remaining space with zeros
%rep 0x0600-($-$$)
	db 0x00
%endrep
