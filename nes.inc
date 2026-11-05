PPUCTRL   = $2000          ; PPU control: NMI on or off, which tiles to use, which nametable to show.
PPUMASK   = $2001          ; PPU mask: show or hide the background and the sprites.
PPUSTATUS = $2002          ; PPU status. Bit 7 is 1 during vblank. A read also resets the address latch.
OAMADDR   = $2003          ; The start address in sprite memory. Set it to 0 before the sprite copy.
PPUSCROLL = $2005          ; The scroll position. Write X, then Y.
PPUADDR   = $2006          ; The PPU memory address. Write the high byte, then the low byte.
PPUDATA   = $2007          ; Reads or writes one byte at the PPU address. Then the address moves on.
DMC_FREQ  = $4010          ; Sample playback control. Write 0 to turn off its IRQ.
OAMDMA    = $4014          ; Write a page number here. The CPU then copies that 256-byte page to sprite memory.
JOY1      = $4016          ; Controller 1. Write 1 and then 0 to latch the buttons. Then each read gives one button.
APU_FRAME = $4017          ; The APU frame counter, when you write to it. Bit 6 = 1 turns off its IRQ.

BUTTON_A      = %10000000  ; Bit 7 of buttons. The controller sends A first, so A ends in the top bit.
BUTTON_B      = %01000000  ; Bit 6: B.
BUTTON_SELECT = %00100000  ; Bit 5: Select.
BUTTON_START  = %00010000  ; Bit 4: Start.
BUTTON_UP     = %00001000  ; Bit 3: Up.
BUTTON_DOWN   = %00000100  ; Bit 2: Down.
BUTTON_LEFT   = %00000010  ; Bit 1: Left.
BUTTON_RIGHT  = %00000001  ; Bit 0: Right.
