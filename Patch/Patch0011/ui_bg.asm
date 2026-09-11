; Copyright (C) 2020 Sean Gonsalves
;
; This file is part of Neo CD SD Loader.
;
; This program is free software; you can redistribute it and/or modify
; it under the terms of the GNU General Public License as published by
; the Free Software Foundation; either version 2, or (at your option)
; any later version.
;
; This program is distributed in the hope that it will be useful,
; but WITHOUT ANY WARRANTY; without even the implied warranty of
; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
; GNU General Public License for more details.
;
; You should have received a copy of the GNU General Public License
; along with this program; see the file COPYING.  If not, write to
; the Free Software Foundation, Inc., 51 Franklin Street,
; Boston, MA 02110-1301, USA.

; Points the background sprite's tilemap (SPR_BG, 20x16 tiles) at either the
; custom bg tile range (256+, filled by LoadCustomBG) or the default repeating
; pattern, depending on CustomBGLoaded. Also (re)applies the sprite's Z/Y/X.
; Safe to call again after the menu is already up, e.g. once a per-game bg.bmp
; has just been loaded by LoadGameBG.
SetupBGSprites:
	tst.b   CustomBGLoaded
	beq     .defaultbg
	; Setup sprites for custom background
	move.w  #1,REG_VRAMMOD
	move.w  #256,d0                 ; First tile number
	move.w  #SCB1+(SPR_BG*2*32),d2	; Tile map
	move.w  #20,d7					; 20 sprites wide
.setup_c_map:
	move.w  d2,REG_VRAMADDR
	move.w  #14,d6					; 14 tiles high
.setup_c_tiles:
	nop
	move.w  d0,REG_VRAMRW	     	; Tile number
	addq.w  #1,d0
	nop
	move.w  #$1000,REG_VRAMRW		; Palette #16
	subq.w  #1,d6
	bne     .setup_c_tiles
	addi.w  #2*32,d2				; Next sprite
	subq.w  #1,d7
	bne     .setup_c_map
	bra     .bgdone
.defaultbg:
	; Setup sprites for default background

	move.w  #1,REG_VRAMMOD
	lea     bg_pal_map,a0
	move.w  #SCB1+(SPR_BG*2*32),d2	; Tile map
	move.w  #20,d7					; 20 sprites wide
.setup_d_map:
	move.w  d2,REG_VRAMADDR
	move.w  #16,d6					; 16 tiles high
.setup_d_tiles:
	nop
	move.w  #$0040,REG_VRAMRW		; Tile number
	move.b  (a0)+,d0
	lsl.w   #8,d0
    ori.w   #$0008,d0
    move.w  d0,REG_VRAMRW		    ; Palette + 3bit auto-animation
	subq.w  #1,d6
	bne     .setup_d_tiles
	addi.w  #2*32,d2				; Next sprite
	subq.w  #1,d7
	bne     .setup_d_map
.bgdone:

	move.w  #SPR_BG,d0
	move.w  #$0FFF,d1				; No shrink
	move.w  #20,d7					; 20 sprites wide
	jsr     SetSprZ
	move.w  #SPR_BG,d0
	move.w  #((496-0)<<7)+16,d1		; Top Y, 16 tiles high
	move.w  #20,d7					; 20 sprites wide
	jsr     SetSprY
	move.w  #SPR_BG,d0
	move.w  #0,d1					; Left X
	move.w  #20,d7					; 20 sprites wide
	jsr     SetSprX
	rts


; Called from the main list's VBL handler once the cursor has stayed on a
; game for a little while. Looks for that game's own bg.bmp (same format/
; folder convention as CUSTOM_BG_FILENAME) and shows it as the menu
; background; falls back to the root bg.bmp, then to the default pattern.
; Does nothing if the highlighted game is already the one currently shown.
LoadGameBG:
	; Resolve currently highlighted game's file index (same lookup as
	; the "Load selected game" code in ui_main_vbl.asm)
	lea     MenuIndexList,a0
	moveq.l #0,d0
	move.b  FileCursor,d0
	add.b   MenuShift,d0
	moveq.l #0,d1
	move.b  0(a0,d0),d1
	lea     FileList,a0
	lsl.w   #5,d1
	move.b  1(a0,d1),d1        ; d1 = resolved game index (file number)

	cmp.b   LastBGGameIndex,d1
	beq     .done               ; Already showing this game's bg, nothing to do
	move.b  d1,LastBGGameIndex

	sf.b    CustomBGLoaded      ; Assume failure until LoadCustomBG proves otherwise
	st.b    BGSilentReload      ; Live reload: don't blank the sprite layer while decoding

	; Try this game's own bg.bmp first
	move.b  LastBGGameIndex,MCUCmdParams
	move.b  #1,MCUCmdParams+1   ; Per-game bg request flag
	MCUCMD  MCU_CMD_SELECTGAME
	bcs     .tryroot             ; Comm timeout, fall back
	jsr     MCURead4Words
	move.b  MCUReplyBuffer,d0
	andi.b  #$F0,d0
	beq     .tryroot             ; No bg.bmp in this game's folder
	jsr     LoadCustomBGSilent
	bra     .apply
.tryroot:
	; No per-game art, fall back to the root bg.bmp (same as at menu startup)
	sf.b    CustomBGLoaded
	move.b  #BG_CODE,MCUCmdParams
	MCUCMD  MCU_CMD_SELECTGAME
	bcs     .apply                ; Comm timeout, give up, use default pattern
	jsr     MCURead4Words
	move.b  MCUReplyBuffer,d0
	andi.b  #$F0,d0
	beq     .apply                ; No root bg.bmp either, use default pattern
	jsr     LoadCustomBGSilent
.apply:
	; CustomBGLoaded now reflects whether LoadCustomBG actually succeeded;
	; SetupBGSprites falls back to the default pattern on its own if not.
	jsr     SetupBGSprites
.done:
	rts


LoadCustomBG:
    move.w  #$2000,FixWriteConfig   ; Palette #2 bank 0
    lea     FixStrLoadingBG,a0      ; Show loading window
	move.w  #FIXMAP+13+(10*32),d0
	jsr     WriteFix

; Same as LoadCustomBG but without the "Loading..." fix text overlay — used by
; LoadGameBG while the file list is already on screen, where stamping that
; message over the list every time the cursor settles would leave it stuck
; there (nothing currently clears it outside of the one-time boot sequence).
LoadCustomBGSilent:
	; Load BMP data for custom bg
    move.l  #$00020000,MSFCounter   ; Init MSF at 00:02:00 (MCU subtracts 2s)
    jsr     GetBMPSector
    bcs     CustomBGFail

	move.l  #CDSectorBuffer,a0
    ; Check "BM" magic at 00
    cmp.w   #$424D,$0(a0)
    bne     CustomBGFail
    ; Check 320px width at $12
    cmp.l   #$40010000,$12(a0)
    bne     CustomBGFail
    ; Check 224px height at $16
    cmp.l   #$E0000000,$16(a0)
    bne     CustomBGFail
    ; Check 4bpp at $1C
    cmp.w   #$0400,$1C(a0)
    bne     CustomBGFail
    ; Check no compression code 0 at $1E
    cmp.l   #0,$1E(a0)
    bne     CustomBGFail

    ; Get pixel data pointer from $0A in a2
    move.l  $A(a0),d0       ; DD CC BB AA
    ENDIAN_CHG_L d0         ; AA BB CC DD
    move.l  d0,a2
    add.l   a0,a2
    ; Get size of the DIB header from $0E in a0
    move.l  $E(a0),d0       ; DD CC BB AA
    ENDIAN_CHG_L d0         ; AA BB CC DD
    addi.l  #$E,d0          ; Add size of BMP header
    add.l   d0,a0

    ; Load and convert palette (BGRA * 16)
    jsr     WaitVBL
    lea     (PALETTES+(2*16*16)),a1     ; Palette #16
    moveq.l #16,d7
.convertpal:
    moveq.l #0,d1
    move.b  (a0)+,d0    ; B
    lsr.b   #4,d0
    andi.w  #$000F,d0
    or.w    d0,d1
    move.b  (a0)+,d0    ; G
    andi.w  #$00F0,d0
    or.w    d0,d1
    move.b  (a0)+,d0    ; R
    lsl.w   #4,d0
    andi.w  #$0F00,d0
    or.w    d0,d1
    move.w  d1,(a1)+
    move.b  (a0)+,d0    ; Skip A
    subq.w  #1,d7
    bne     .convertpal
    ; Copy color #0 to BACKDROP and CustomBGBackdrop for reloading
    move.w  (PALETTES+(2*16*16)),d0
    move.w  d0,BACKDROP
    move.w  d0,CustomBGBackdrop

    ; Load and convert pixels
    tst.b   BGSilentReload      ; Live reload while browsing: leave sprites on,
    bne     .skipdisblspr       ; the update just tears in tile by tile instead
    move.b  #1,REG_DISBLSPR     ; of flashing the whole screen blank
.skipdisblspr:
    move.b  #1,REG_UPLOAD_EN
    move.b  d0,REG_UPMAPSPR
    move.b  #0,REG_TRANSAREA

    lea     LUTIndexToBitplane,a0
    ; Start at bottom left pixel of bottom left tile
    ; Pen and paper required !
    lea     ($E00000+(256*128)+(128*14)-4),a4

    move.l  #14,d4      ; Height in tiles
.fullheight:
    move.l  a4,a3       ; Restore base address
    subi.l  #128,a4     ; -1 tile (go to tile row above)

    move.l  #16,d5      ; Pixel rows per tile
.tileheight:
    move.l  a3,a1       ; Restore base address
    subi.l  #4,a3       ; -1 row (go to pixel row above)

    moveq.l #20,d6      ; Width in tiles
.sixteenpixelsrow:

    ; Load left 8 pixels
    moveq.l #0,d0
    move.l  d0,d1
    move.l  d0,d2       ; 4 bitplane * 8 bit shift register
    moveq.l #4,d7
.rowa:
    move.b  (a2)+,d1    ; Left pixel
    move.b  d1,d0
    lsr.b   #4,d1
    lsl.b   #2,d1
    lsr.l   #1,d2       ; Next pixel in SR
    or.l    0(a0,d1),d2
    andi.b  #$F,d0      ; Right pixel
    lsl.b   #2,d0
    lsr.l   #1,d2       ; Next pixel in SR
    or.l    0(a0,d0),d2

    ; Check if we need to load the next sector
    cmp.l   #CDSectorBuffer+CD_SECTOR_SIZE,a2    ; End of CDSectorBuffer
    bne     .noreloada
    jsr     GetNewBMPSector
.noreloada:

    subq.b  #1,d7
    bne     .rowa
    move.l  d2,0(a1)    ; Left column

    ; Load right 8 pixels
    moveq.l #0,d0
    move.l  d0,d1
    move.l  d0,d2       ; 4 bitplane * 8 bit shift register
    moveq.l #4,d7
.rowb:
    move.b  (a2)+,d1    ; Left pixel
    move.b  d1,d0
    lsr.b   #4,d1
    lsl.b   #2,d1
    lsr.l   #1,d2       ; Next pixel in SR
    or.l    0(a0,d1),d2
    andi.b  #$F,d0      ; Right pixel
    lsl.b   #2,d0
    lsr.l   #1,d2       ; Next pixel in SR
    or.l    0(a0,d0),d2

    ; Check if we need to load the next sector
    cmp.l   #CDSectorBuffer+CD_SECTOR_SIZE,a2
    bne     .noreloadb
    jsr     GetNewBMPSector
.noreloadb:

    subq.b  #1,d7
    bne     .rowb
    move.l  d2,-64(a1)      ; Right column
    
    lea     128*14(a1),a1   ; Next tile to the right

    subq.w  #1,d6           ; Done one tile pixel row
    bne     .sixteenpixelsrow

    subq.w  #1,d5           ; Done an entire pixel row
    bne     .tileheight

    subq.w  #1,d4           ; Done one tile row
    bne     .fullheight
    
    st.b    CustomBGLoaded

CustomBGFail:
    move.b  d0,REG_UPUNMAPSPR
    move.b  #0,REG_UPLOAD_EN
    move.b  #0,REG_DISBLSPR
    rts
    
    
GetNewBMPSector:
    move.b  MSFCounter+2,d0 ; No need to do proper MSF inc here as file will always fit under 1 second worth of data
    moveq   #1,d1           ; Only inc frames
    move    #0,ccr
    abcd    d1,d0           ; BCD inc
    move.b  d0,MSFCounter+2
    jsr     GetBMPSector
    bcs     CustomBGFail    ; Error loading sector
    move.l  #CDSectorBuffer,a2
    rts
    

; Used for custom bg, linear -> sprite bitplane conversion
LUTIndexToBitplane:
    ;     11003322
    dc.l $00000000
    dc.l $00800000
    dc.l $80000000
    dc.l $80800000
    dc.l $00000080
    dc.l $00800080
    dc.l $80000080
    dc.l $80800080
    dc.l $00008000
    dc.l $00808000
    dc.l $80008000
    dc.l $80808000
    dc.l $00008080
    dc.l $00808080
    dc.l $80008080
    dc.l $80808080
