org 0x7c00
BITS 16

real_mode_lba:  equ 0x00000021                  ; LBA location of the real mode kernel code on disk
real_mode_addr: equ 0x00010000                  ; memory address of the real mode kernel code
real_mode_seg:  equ real_mode_addr / 0x10       ; memory segment of the real mode kernel code

init:
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

	mov      si,       strings.initialized      ; load string ptr into si
	call     print_line                         ; print status msg

load_real_mode:
; read real mode kernel code
	mov      si,       dap                      ; point si at dap (pre-initialized with source and destination addresses for real mode kernel code load)
	mov      dl,       0x80                     ; select disk 0x80 (primary HDD) for disk access
	mov      ah,       0x42                     ; select LBA read mode for disk access
	int      0x13                               ; perform disk access via interrupt
	jc       disk_read_error                    ; on error jump to print errror msg and halt

	mov      si,       strings.real_mode_loaded ; load string ptr into si
	call     print_line                         ; print status msg

; print kernel version
	mov      ax,       real_mode_seg            ; set ax = segment of real mode kernel code
	mov      ds,       ax                       ; set data segment to real mode kernel code location
	mov      si,       [0x020e]                 ; load kernel_version ptr from header
	add      si,       0x0200                   ; add 0x0200 offset (somehow needed according to spec)
	call     print_line                         ; print kernel version

; halts execution
halt:
	call     flush                              ; ensure final output line is flushed to serial console
	hlt                                         ; halt CPU
	jmp      halt                               ; keep halting if interrupted

; print disk read error and halt
disk_read_error:
	mov      si,       strings.disk_error       ; load msg ptr into si
	call     print_line                         ; print_line(msg)
	jmp      halt                               ; halt after printing error

; flushes all printed lines to serial output by writing a null byte to ensure cursor is advanced
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

; disk address packet
dap:
	db 0x10                                     ; size of struct = 16
	db 0x00                                     ; unused
.sectors:
	dw 0x40                                     ; number of sectors to read
	dw 0x0000                                   ; memory offset within segment (always 0 here)
.segment:
	dw real_mode_seg                            ; memory segment
.lba:
	dd real_mode_lba                            ; low bytes of LBA address of data on disk
	dd 0x00000000                               ; high bytes of LBA address (unused by us)

; string constants
strings:
.initialized: db "initialized", 0x00
.real_mode_loaded: db "real mode kernel code loaded", 0x00
.disk_error: db "disk read error", 0x00
.newline: db 0x0d, 0x0a, 0x00

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
	db 0
%endrep

; add the required boot signature
	dw 0xaa55
