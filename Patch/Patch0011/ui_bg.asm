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

; Points the background sprite's tilemap (SPR_BG, BG_BOX_W_TILES x
; BG_BOX_H_TILES tiles - the cover-art box, right side of the menu screen)
; at either the custom bg tile range (double-buffered, see BGActiveBuffer)
; or the default repeating pattern, depending on CustomBGLoaded. Also
; (re)applies the sprite's Z/Y/X. Safe to call again after the menu is
; already up, e.g. once a per-game bg.bmp has just been loaded by LoadGameBG.
SetupBGSprites:
	tst.b   CustomBGLoaded
	beq     .hidebox
	; Setup sprites for custom background
	move.w  #1,REG_VRAMMOD
	move.w  #256,d0                 ; First tile number (buffer 0)
	move.w  #BG_PALETTE_BASE0,d4     ; Palette bank base for this buffer
	lea     TilePaletteMap0,a3       ; Per-tile relative palette index (0..COUNT-1)
	tst.b   BGActiveBuffer
	beq     .buf0
	addi.w  #(BG_BOX_W_TILES*BG_BOX_H_TILES),d0  ; Buffer 1: tiles start right after buffer 0's
	move.w  #BG_PALETTE_BASE1,d4
	lea     TilePaletteMap1,a3
.buf0:
	move.w  #SCB1+(SPR_BG*2*32),d2	; Tile map
	move.w  #BG_BOX_W_TILES,d7		; Box width, in tiles
.setup_c_map:
	move.w  d2,REG_VRAMADDR
	move.w  #BG_BOX_H_TILES,d6		; Box height, in tiles
.setup_c_tiles:
	nop
	move.w  d0,REG_VRAMRW	     	; Tile number
	addq.w  #1,d0
	nop
	moveq.l #0,d3
	move.b  (a3)+,d3				; This tile's relative palette index
	add.w   d4,d3					; -> absolute bank number
	lsl.w   #8,d3					; Bank goes in the upper byte, same as the old $XX00 shape
	move.w  d3,REG_VRAMRW			; Palette bank for this tile
	subq.w  #1,d6
	bne     .setup_c_tiles
	addi.w  #2*32,d2				; Next sprite
	subq.w  #1,d7
	bne     .setup_c_map
	bra     .bgdone
.hidebox:
	; No cover art for this game - hide the box entirely instead of showing
	; the old default repeating pattern (that only made sense back when this
	; sprite was the full-screen background; as a small fixed box, "empty"
	; reads a lot cleaner than a checkered placeholder every other game).
	move.w  #SPR_BG,d0
	move.w  #0,d1                  ; Height 0 = invisible
	move.w  #BG_BOX_W_TILES,d7		; Box width, in tiles
	jsr     SetSprY
	rts
.bgdone:

	move.w  #SPR_BG,d0
	move.w  #BG_BOX_SHRINK,d1		; Slightly shrunk - see equ.asm comment
	move.w  #BG_BOX_W_TILES,d7		; Box width, in tiles
	jsr     SetSprZ
	move.w  #SPR_BG,d0
	move.w  #((496-BG_BOX_Y)<<7)+BG_BOX_H_TILES,d1	; Box top Y, centered vertically
	move.w  #BG_BOX_W_TILES,d7		; Box width, in tiles
	jsr     SetSprY
	move.w  #SPR_BG,d0
	move.w  #BG_BOX_X,d1			; Box left X, right-hand column
	move.w  #BG_BOX_W_TILES,d7		; Box width, in tiles
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
	; Decode into whichever buffer is NOT currently on screen. SetupBGSprites
	; only switches to it (BGActiveBuffer) once the whole decode below has
	; succeeded, so a live reload never shows a half-drawn or wrong-palette
	; image - the switch is an atomic flip, not a gradual overwrite.
	moveq.l #1,d0
	sub.b   BGActiveBuffer,d0
	move.b  d0,BGDecodeBuffer

	; Load BMP data for custom bg
    move.l  #$00020000,MSFCounter   ; Init MSF at 00:02:00 (MCU subtracts 2s)
    jsr     GetBMPSector
    bcs     CustomBGFail

	move.l  #CDSectorBuffer,a0
    ; Check "BM" magic at 00
    cmp.w   #$424D,$0(a0)
    bne     CustomBGFail
    ; Check BG_BOX_W_TILES*16px (128px) width at $12
    cmp.l   #$80000000,$12(a0)
    bne     CustomBGFail
    ; Check BG_BOX_H_TILES*16px (128px) height at $16
    cmp.l   #$80000000,$16(a0)
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

    ; Load and convert BG_PALETTE_COUNT palettes (BGRA * 16 each, back to
    ; back in the file - see bg_maker.py's write_multi_palette_bmp)
    jsr     WaitVBL
    lea     (PALETTES+(2*16*BG_PALETTE_BASE0)),a1
    tst.b   BGDecodeBuffer
    beq     .pal_buf0
    addi.l  #2*16*BG_PALETTE_COUNT,a1
.pal_buf0:
    move.w  #BG_PALETTE_COUNT*16,d7   ; Exceeds moveq's range, needs a real move
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
    ; BACKDROP itself is intentionally left alone here: with the cover art
    ; now a small fixed box instead of a full-screen background, the area
    ; around it should just stay solid black regardless of whichever
    ; game's palette color #0 happens to be - not flicker to a different
    ; color every time the selection changes.

    ; Load and convert pixels - straight into the inactive buffer, currently
    ; not displayed by any sprite, so no need to hide anything while this runs
    move.b  #1,REG_UPLOAD_EN
    move.b  d0,REG_UPMAPSPR
    move.b  #0,REG_TRANSAREA

    lea     LUTIndexToBitplane,a0
    ; Start at bottom left pixel of bottom left tile
    ; Pen and paper required !
    lea     ($E00000+(256*128)+(128*BG_BOX_H_TILES)-4),a4
    tst.b   BGDecodeBuffer
    beq     .tile_buf0
    addi.l  #(BG_BOX_W_TILES*BG_BOX_H_TILES*128),a4  ; Buffer 1: tiles start right after buffer 0's
.tile_buf0:

    move.l  #BG_BOX_H_TILES,d4      ; Height in tiles
.fullheight:
    move.l  a4,a3       ; Restore base address
    subi.l  #128,a4     ; -1 tile (go to tile row above)

    move.l  #16,d5      ; Pixel rows per tile
.tileheight:
    move.l  a3,a1       ; Restore base address
    subi.l  #4,a3       ; -1 row (go to pixel row above)

    moveq.l #BG_BOX_W_TILES,d6      ; Width in tiles
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

    lea     128*BG_BOX_H_TILES(a1),a1   ; Next tile to the right

    subq.w  #1,d6           ; Done one tile pixel row
    bne     .sixteenpixelsrow

    subq.w  #1,d5           ; Done an entire pixel row
    bne     .tileheight

    subq.w  #1,d4           ; Done one tile row
    bne     .fullheight

    ; Read the tile->palette-index map bg_maker.py appends right after the
    ; pixel data (BG_BOX_W_TILES*BG_BOX_H_TILES bytes, column-major) -
    ; continues from the exact file-stream position (a2) pixel decoding
    ; just left off at, same sector-boundary-crossing pattern as above.
    lea     TilePaletteMap0,a1
    tst.b   BGDecodeBuffer
    beq     .tilemap_buf0
    lea     TilePaletteMap1,a1
.tilemap_buf0:
    moveq.l #(BG_BOX_W_TILES*BG_BOX_H_TILES)-1,d7
.readtilemap:
    move.b  (a2)+,(a1)+
    cmp.l   #CDSectorBuffer+CD_SECTOR_SIZE,a2
    bne     .notilereload
    jsr     GetNewBMPSector
.notilereload:
    dbra    d7,.readtilemap

    st.b    CustomBGLoaded
    move.b  BGDecodeBuffer,BGActiveBuffer   ; Flip: SetupBGSprites now shows this freshly-filled buffer

CustomBGFail:
    move.b  d0,REG_UPUNMAPSPR
    move.b  #0,REG_UPLOAD_EN
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
