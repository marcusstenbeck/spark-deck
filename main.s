.include "nes.inc"

.segment "HEADER"       ; The next bytes go in the 16-byte file header.
  .byte "NES", $1A      ; Bytes 0-3: the magic word of a NES ROM file.
  .byte 32              ; Byte 4: PRG size in 16 KB units. 32 x 16 KB = 512 KB.
  .byte 0               ; Byte 5: CHR-ROM size. 0, because mapper 30 uses CHR-RAM.
  .byte $E1             ; Byte 6: the low 4 bits of the mapper number ($E) in the top half. Bit 0 = 1: vertical mirroring.
  .byte $18             ; Byte 7: the high 4 bits of the mapper number ($1). Bits 2–3 = %10: NES 2.0. $1E = 30.
  .byte $00             ; Byte 8: mapper bits 8–11 and the submapper. All 0.
  .byte $00             ; Byte 9: extra size bits. Not needed.
  .byte $00             ; Byte 10: no battery RAM.
  .byte $09             ; Byte 11: CHR-RAM size. 64 << 9 = 32 KB.
  .byte $00             ; Byte 12: timing. 0 = NTSC.
  .byte $00, $00, $00   ; Bytes 13–15: not used.

PPUCTRL_ON = %10001000  ; Bit 7: NMI on. Bit 3: sprite tiles at PPU $1000. Bit 4 = 0: background tiles at $0000.
PPUMASK_ON = %00011110  ; Bits 4 and 3: show sprites and background. Bits 2 and 1: show them in the left 8 pixels too.
FADE_FRAMES = 8         ; Fade step duration in frames.
HOLD_FADE_FRAMES = 16   ; Hold fade for frames.
SLIDE_NAM = 0
SLIDE_TEXT = 1
TEXT_ATTR = $FF         ; Use palette 3 in all corners.

.segment "ZEROPAGE"     ; Variables in zero page. Access is faster, and (ptr), y works only with zero page.
frame_counter:  .res 1  ; The NMI adds 1 every frame. The main loop watches it to wait for a frame.
buttons:        .res 1  ; The buttons held this frame. One bit per button.
buttons_prev:   .res 1  ; The buttons held last frame.
pressed:        .res 1  ; The buttons that went down this frame. One press gives one step.
current_bank:   .res 1  ; The PRG bank at $8000 now.
palette_dirty:  .res 1  ; Set it to 1 and the NMI sends palette_buf to the PPU.
current_slide:  .res 1
temp:           .res 1  ; A scratch byte for short calculations.
ptr:            .res 2  ; A 16-bit address: low byte, then high byte. Code reads data through it with lda (ptr), y.
fade_level:     .res 1  ; 0 = full color, 4 = black
bg_color:       .res 1  ; Backdrop color for each slide.

.segment "OAM"          ; The RAM page at $0200.
oam:           .res 256 ; 64 sprites × 4 bytes: Y, tile, attributes, X.

.segment "BSS"          ; Other RAM, from $0300.
palette_buf:   .res 32  ; A RAM copy of the 32 palette bytes. The main loop changes it. The NMI sends it.

.segment "CODE"         ; Code goes in the fixed bank, from $C000.
RESET:                  ; The CPU starts here at power-on and when you press Reset. The vector at $FFFC points here.
  SEI                   ; Block IRQ interrupts. This project does not use them.
  CLD                   ; Turn off decimal mode. The NES CPU has none, but this is the usual first step.
  LDX #%01000000
  STX APU_FRAME         ; Bit 6 = 1: turn off the APU frame IRQ.
  LDX #$FF
  TXS                   ; Stack pointer = $FF. The stack grows down from $01FF.
  INX                   ; X = $FF + 1, which wraps to $00.
  STX PPUCTRL           ; PPUCTRL = 0: NMI off.
  STX PPUMASK           ; PPUMASK = 0: rendering off.
  STX DMC_FREQ          ; DMC_FREQ = 0: turn off the sample playback IRQ.
  BIT PPUSTATUS         ; Read PPUSTATUS once. This clears an old vblank flag.

@vblank1:               ; Wait for the first vblank. The PPU needs time to start.
  BIT PPUSTATUS         ; Copy bit 7 (vblank) into the N flag.
  BPL @vblank1          ; N = 0: no vblank yet. Read again.

@clear_ram:             ; Clear all 2 KB of RAM. X goes 0, 1 … 255.
  LDA #$00              ; A = 0.
  STA $0000, x          ; Zero page.
  ; Note that $0200 is initialized later.
  STA $0100, x          ; The stack page.
  STA $0300, x          ; RAM page 3.
  STA $0400, x          ; RAM page 4.
  STA $0500, x          ; RAM page 5.
  STA $0600, x          ; RAM page 6.
  STA $0700, x          ; RAM page 7.
  LDA #$FF              ; A = $FF.
  ; `oam` holds $0200, the sprite page. See the `.segment "OAM"` and `unrom.cfg`.
  STA oam, x            ; Fill the sprite page with $FF. Y = $FF puts every sprite below the screen.
  INX                   ; The next byte.
  BNE @clear_ram        ; X wraps to 0 after 256 bytes. Until then, loop.

@vblank2:               ; Wait for the second vblank. After this, the PPU is ready.
  BIT PPUSTATUS         ; Copy the vblank bit into N.
  BPL @vblank2          ; No vblank yet: read again.
  LDA #0                ; A = bank 0.
  JSR bankswitch        ; Select PRG bank 0 at $8000. At power-on, the bank is unknown.

  JSR clear_vram          ; Write 0 to CHR-RAM and both nametables. Now every tile is blank.

  LDA #<base_chr
  STA ptr
  LDA #>base_chr
  STA ptr+1
  LDA #$00              ; PPU $0000
  LDX #32               ; 32 pages = 8 KB
  JSR ppu_copy_pages

  ; initialize by being a black screen
  LDA #$0F
  STA bg_color            ; black before initial slide
  LDA #4
  STA fade_level          ; start fully faded
  JSR set_fade            ; now palette_buf = all black
  LDA #$FF
  STA current_slide       ; now incrementing current_slide will wrap around to 0

  LDA #PPUCTRL_ON         ; NMI on, plus the pattern-table settings.
  STA PPUCTRL             ; From now on, the NMI runs at the start of every vblank.
  JSR wait_frame          ; Wait one frame. The NMI sends the palette and sets the scroll.
  LDA #PPUMASK_ON         ; Background and sprites on.
  STA PPUMASK             ; The picture appears from the next frame.
  JMP main_loop           ; Start the main loop.

main_loop:                ; This runs once per frame, forever.
  JSR wait_frame          ; Sleep until the NMI ran. This sets the speed: 60 passes a second.
  JSR read_joypad         ; Update buttons and pressed.
  LDA pressed
  AND #BUTTON_A
  BEQ main_loop           ; The result if 0: A was not pressed. Wait for the next frame.
  
  INC current_slide
  LDA current_slide
  CMP #SLIDE_COUNT
  BNE @show
  LDA #0              ; after last slide
  STA current_slide   ; go back to first
  
@show:
  JSR fade_out

  LDA #0
  STA PPUMASK         ; screen off
  LDA #PPUCTRL_ON & %01111111
  STA PPUCTRL         ; NMI off
  JSR load_slide
  LDA #PPUCTRL_ON
  STA PPUCTRL         ; NMI on
  JSR wait_frame      ; NMI resets the scroll
  LDA #PPUMASK_ON
  STA PPUMASK         ; screen on

  LDX #HOLD_FADE_FRAMES
:
  JSR wait_frame
  DEX
  BNE :-

  JSR fade_in
  
  JMP main_loop

wait_frame:
  LDA frame_counter
@wait:
  CMP frame_counter
  BEQ @wait
  RTS

; Copy slide number current_slide to $2000.
; The screen and NMI must be off.
load_slide:
  LDX current_slide
  LDA slide_bg, x
  STA bg_color
  LDA slide_lo, x
  STA ptr
  LDA slide_hi, x
  STA ptr+1
  LDA slide_kind, x
  BNE @text ; not 0 = on a text slide
  LDA #$20  ; PPU $2000
  LDX #4    ; 4 pages = 1 KB
  JSR ppu_copy_pages
  RTS
@text:
  JSR draw_text_slide
  RTS

; TODO: Understand this.
; Draw the text slide at (ptr) to $2000.
; The screen and NMI must be off.
draw_text_slide:
  ; 1. Clear nametable 0 to tile 0 (blank).
  BIT PPUSTATUS
  LDA #$20
  STA PPUADDR
  LDA #$00
  STA PPUADDR
  LDX #4              ; 4 pages = 1 KB
  LDY #0
@clear:
  STA PPUDATA         ; A = 0
  INY
  BNE @clear
  DEX
  BNE @clear

  ; 2. Fill the attribute table with palette 3.
  LDA #$23
  STA PPUADDR
  LDA #$C0
  STA PPUADDR         ; PPU $23C0
  LDA #TEXT_ATTR
  LDX #64
@attr:
  STA PPUDATA
  DEX
  BNE @attr
  LDY #0              ; the first line

  ; 3. Write each line.
@line:
  LDA (ptr), y        ; the column, or $FF
  CMP #$FF
  BEQ @done
  STA temp            ; temp = column
  INY
  LDA (ptr), y        ; A = row
  INY
  PHA                 ; keep the row
  LSR a
  LSR a
  LSR a               ; row / 8
  CLC
  ADC #$20
  STA PPUADDR         ; high byte: $20 + row / 8
  PLA
  ASL a
  ASL a
  ASL a
  ASL a
  ASL a               ; (row x 32) & $FF
  ORA temp            ; + column
  STA PPUADDR         ; low byte
@char:
  LDA (ptr), y
  BEQ @end_line       ; 0: the end of the line
  STA PPUDATA         ; tile number = ASCII code
  INY
  JMP @char
@end_line:
  INY                 ; step over the 0
  TYA
  CLC
  ADC ptr
  STA ptr             ; ptr = the start of the next line
  BCC :+
  INC ptr+1
: LDY #0
  JMP @line
@done:
  RTS

read_joypad:          ; Read controller 1 into buttons. Then work out pressed.
  LDA buttons         ; The buttons from last frame.
  STA buttons_prev    ; Keep them.
  LDA #$01            ; A = 1.
  STA JOY1            ; Strobe on: the controller copies the button states.
  STA buttons         ; buttons = %00000001. This 1 is a marker. When it moves out of bit 7, all 8 buttons are in.
  LSR a               ; A = 0.
  STA JOY1            ; Strobe off: now each read gives the next button, A first.
@loop:                ; One pass per button.
  LDA JOY1            ; Bit 0 = this button. 1 = held.
  LSR a               ; Move bit 0 into the carry flag.
  ROL buttons         ; Shift buttons left. The carry goes into bit 0. Bit 7 goes into the carry.
  BCC @loop           ; Carry = 0: the marker is not out yet. Read the next button.
  LDA buttons_prev    ; Last frame.
  EOR #%11111111      ; Flip every bit. Now 1 = "not held last frame".
  AND buttons         ; Keep the bits that are held now and were not held before.
  STA pressed         ; These are the new presses.
  RTS                 ; Return.

clear_vram:           ; Write 0 to PPU $0000–$2FFF: tiles and nametables. Rendering must be off.
  BIT PPUSTATUS       ; Reset the address latch. The next PPUADDR write is now the high byte.
  LDA #$00
  STA PPUADDR         ; The high byte of $0000.
  STA PPUADDR         ; The low byte of $0000. The PPU address is now $0000.
  ; ???  where's this number from?
  LDY #48             ; 48 pages × 256 bytes = 12 KB.
  LDX #0              ; The byte counter.
@loop:
  STA PPUDATA         ; Write 0. The PPU address moves to the next byte.
  INX                 ; Increase to hit all.
  BNE @loop
  DEY                 ; Move to next address downwards.
  BNE @loop           ; Keeps going until both X and Y are zero.
  RTS

ppu_copy_pages:       ; Copy X pages of 256 bytes from (ptr) to the PPU. A =the high byte of the PPU address.
  BIT PPUSTATUS       ; Reset the address latch.
  STA PPUADDR         ; The high byte of the PPU address.
  LDA #0
  STA PPUADDR         ; The low byte. The PPU address is now A × 256.
  LDY #0              ; The byte counter in the page.
@loop:
  LDA (ptr), y        ; Read the next byte from the ROM.
  STA PPUDATA         ; Write it. The PPU address moves on by 1.
  INY                 ; The next byte in the page.
  BNE @loop           ; Until Y wraps to 0: the full page is done.
  INC ptr+1           ; Move the source to the next page.
  DEX                 ; One page less to copy.
  BNE @loop           ; Until all pages are done.
  RTS

bankswitch:           ; Select PRG bank A (0–30) at $8000–$BFFF.
  STA current_bank    ; Remember the bank.
  TAX                 ; X = the bank number
  STA bank_table, x   ; Write to the mapper. The ROM byte at this address holds the same number, so there is no bus conflict;
  RTS

; Copy default palette to palette_buf, A rows darker (0-4).
set_fade:
  ASL a
  ASL a
  ASL a
  ASL a               ; A = level * $10
  STA temp
  LDX #0
@loop:
  LDA default_palette, x
  SEC
  SBC temp            ; A rows darker
  BCS @ok             ; no borrow, a real color
  LDA #$0F            ; below row 0 => black
@ok:
  STA palette_buf, x
  INX
  CPX #32
  BNE @loop
  LDA bg_color
  SEC
  SBC temp
  BCS @bg_ok
  LDA #$0F            ; below row 0 => black
@bg_ok:
  STA palette_buf+0   ; the backdrop
  STA palette_buf+16  ; mirrored value that NMI writes after byte 0.
  LDA #1
  STA palette_dirty
  RTS

; full color to black
fade_out:
@step:
  LDA fade_level
  CMP #4
  BEQ @done           ; we're already black
  INC fade_level      ; 1, 2, 3, 4
  LDA fade_level
  JSR set_fade
  JSR wait_frames
  JMP @step
@done:
  RTS

; black to full color
fade_in:
  LDA #4
  STA fade_level
@step:
  DEC fade_level      ; 3, 2, 1, 0
  LDA fade_level
  JSR set_fade
  JSR wait_frames
  LDA fade_level
  BNE @step
  RTS

; Wait FADE_FRAMES frames.
wait_frames:
  LDX #FADE_FRAMES
@loop:
  JSR wait_frame      ; uses only A
  DEX
  BNE @loop
  RTS

NMI:                  ; The PPU starts this at the beginning of every vblank: 60 times a second.
  PHA                 ; Save A on the stack. The main loop was using it.
  TXA                 ; A = X.
  PHA                 ; Save X to the stack.
  TYA                 ; A = Y.
  PHA                 ; Save Y to the stack.
  LDA #$00
  STA OAMADDR         ; Set sprite memory address = 0.
  LDA #>oam           ; The high byte of oam: $02.
  STA OAMDMA          ; Copy $0200–$02FF to sprite memory. The CPU waits about 513 cycles.
  LDA palette_dirty   ; Does the main loop want new colors?
  BEQ @no_palette     ; 0: no. Skip the upload.
  BIT PPUSTATUS       ; Reset the address latch.
  LDA #$3F            ; The high byte of $3F00, the palette.
  STA PPUADDR
  LDA #$00            ; The low byte of $3F00, the palette.
  STA PPUADDR         ; The PPU address is now set to $3F00.
  LDX #0
@palette_loop:        ; Send 32 bytes.
  LDA palette_buf, x  ; Byte X of the RAM copy.
  STA PPUDATA         ; Write it. The address moves to the next entry.
  INX
  CPX #32             ; All 32 done?
  BNE @palette_loop
  LDA #0
  STA palette_dirty   ; Done. Clear the dirty flag request.
@no_palette:
  BIT PPUSTATUS       ; Reset the latch before the scroll writes.
  LDA #0
  STA PPUSCROLL       ; Scroll X = 0.
  STA PPUSCROLL       ; Scroll Y = 0. PPUADDR writes change the scroll, so set it after them.
  LDA #PPUCTRL_ON
  STA PPUCTRL         ; Bits 0–1 = 0: show nametable 0.
  INC frame_counter   ; Tell the main loop that a frame passed.
  PLA                 ; Pop the copy of Y.
  TAY                 ; Restore Y.
  PLA                 ; Pop the copy of X.
  TAX                 ; Restore X.
  PLA                 ; Pop the copy of A to restore it.
  RTI

IRQ:                  ; The IRQ handler. Nothing in this project makes an IRQ.
  RTI                 ; Return at once.


.segment "RODATA"                               ; Read-only data in the fixed bank.
default_palette:                                ; 32 colors: 4 background palettes, then 4 sprite palettes.
  .byte $0F, $00, $10, $30                      ; Background palette 0. Entry 0 ($0F, black) is the backdrop for the whole screen. Then grey, light grey, white.
  .byte $0F, $01, $11, $30                      ; Background palette 1: reds. The PPU does not show the first byte of palettes 1–3.
  .byte $0F, $06, $16, $30                      ; Background palette 2: greens.
  .byte $0F, $0F, $0F, $0F                      ; Background palette 3: blues.
  .byte $0F, $07, $27, $30                      ; Sprite palette 0. For sprites, color 0 is see-through.
  .byte $0F, $01, $21, $30                      ; Sprite palette 1.
  .byte $0F, $09, $29, $30                      ; Sprite palette 2.
  .byte $0F, $05, $25, $30                      ; Sprite palette 3.

bank_table:                                     ; 128 bytes that hold 0, 1, 2 … 127. bankswitch writes to these bytes.
  .repeat 128, i                                ; Repeat the next line 128 times. i counts from 0.
    .byte i                                     ; Store the count.
  .endrepeat                                    ; The end of the repeat.

slide_kind:  .byte SLIDE_NAM, SLIDE_NAM, SLIDE_NAM, SLIDE_TEXT
slide_bg:    .byte $0F, $26, $23, $25
slide_lo: .lobytes slide1_nam, slide2_nam, slide3_nam, text_intro
slide_hi: .hibytes slide1_nam, slide2_nam, slide3_nam, text_intro
SLIDE_COUNT = slide_hi - slide_lo

.segment "VECTORS"  ; The last 6 bytes of the fixed bank: $FFFA–$FFFF.
  .word NMI         ; $FFFA: where the CPU goes on an NMI (every vblank).
  .word RESET       ; $FFFC: where the CPU goes at power-on and Reset.
  .word IRQ         ; $FFFE: where the CPU goes on an IRQ or BRK.

.segment "BANK0"
base_chr: .incbin "chr/base.chr" ; 8KB of tiles, 32 pages.
slide1_nam: .incbin "slides/slide1.nam"
slide2_nam: .incbin "slides/slide2.nam"
slide3_nam: .incbin "slides/slide3.nam"

; Text slide format:
;  for each line: columns (0-31), row (0-29), text, 0
;  $FF: the end of the slide
text_intro:
  .byte 4, 4, "Spark deck", 0
  .byte 4, 8,  "- Made on a NES", 0
  .byte 4, 10, "- Press A for more", 0
  .byte $FF