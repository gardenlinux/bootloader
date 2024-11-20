org 0x7c00
BITS 16

main:
; perform basic init functions and setup stack
	cli                                         ; disable interrupts
	mov      ax,       0x0000                   ; set ax = 0
	mov      ds,       ax                       ; ensure data segment at 0
	mov      ss,       ax                       ; ensure stack segment at 0
	mov      es,       ax                       ; ensure extra segment at 0
	mov      sp,       0x7c00                   ; set stack pointer to start of bootloader code (grows down below it)
	cld                                         ; ensure forward direction for string operations (lodsb)

; print hello
	mov      si,       msg                      ; load msg ptr into si
	call     print_str                          ; print_str(msg)

; halts execution
halt:
	hlt                                         ; halt CPU
	jmp      halt                               ; keep halting if interrupted

; prints a null terminated string
; inputs:
;   ds:si: points to start of string
; clobbers: ax, bx, si
print_str:
	lodsb                                       ; load byte pointed to by ds:si into al and increment si
	mov      ah,       0x0e                     ; select teletype output mode
	mov      bx,       0x0000                   ; ensure page number is 0
	int      0x10                               ; write character via interrupt
	cmp      al,       0x00                     ; check if al == 0, i.e. we reached end of string
	jne      print_str                          ; loop until null byte was read
	ret                                         ; return from call

msg:
	db "hello", 0x0d, 0x0a, 0x00

; assert that we have not over-run the maximum size of an MBR bootloader
%if ($-$$) > 0x01be
	%error "MBR code exceeds 446 bytes"
%endif

; padd remaining space with zeros
%rep 0x01fe-($-$$)
	db 0
%endrep

; add the required boot signature
	dw 0xaa55
