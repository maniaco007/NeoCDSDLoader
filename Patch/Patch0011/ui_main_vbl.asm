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

VBLProcMain:
    IFNDEF MAMEDEBUG
    ; Check MCU card event flag
    tst.b   CardEvent
    beq     .nocardevent
    ; A card event occured
    clr.b   CardEvent
	jmp     SetupMain
    ;btst.b  #7,MCUStatus
    ;beq     .cardremoved
    ;; Try to re-init card if it is now inserted
    ;bset.b  #7,RefreshFlags
    ;bra     .nocardevent
;.cardremoved:
    ;; Show message if card is removed
    ;;lea     StrMsgBoxCardAbsent,a0
    ;;jsr     MessageBox
    ;bset.b  #6,RefreshFlags
.nocardevent:
    ENDIF

	; Refresh stuff in VRAM while we're at the beginning of the vblank
	btst.b  #0,RefreshFlags
	beq     .norefresh0
	jsr     DrawFileList
	move.b  #0,ScrollX
	move.b  #0,UITemp           ; Reset timer
.norefresh0:

	btst.b  #2,RefreshFlags
	beq     .norefresh_cur
	; Selection is shown as a highlighted row (see DrawFileList), not a
	; separate arrow tile, so a cursor move just needs a full list redraw -
	; it repaints every row in its correct color, including the old and new
	; selected rows.
	move.b  FileCursor,FileCursorPrev
	jsr     DrawFileList
	move.b  #0,UITemp           ; Reset timer
	bclr.b  #2,RefreshFlags
.norefresh_cur:

	btst.b  #3,RefreshFlags
	beq     .noscrolling
	; Redraw currently selected filename with scrolling shift
	moveq.l #0,d0
	move.l  d0,d1
	move.b  FileCursor,d0
	addi.w  #FIXMAP+11+(LIST_NAME_COL*32),d0
	; Display LIST_NAME_WIDTH chars starting from (GUBuffer+ScrollX)
	move.w  #32,REG_VRAMMOD
	lea     GUBuffer,a0
	move.b  ScrollX,d1
	add.l   d1,a0
	move.w  #$2500,d1           ; Highlight palette - this is always the selected row
    move.w  d0,REG_VRAMADDR
    moveq.l #LIST_NAME_WIDTH,d7
.write:
    move.b  (a0)+,d1
    tst.b   d1
    beq     .strend
	move.w  d1,REG_VRAMRW
	subq.b  #1,d7
	bne     .write
.strend:
	bclr.b  #3,RefreshFlags
.noscrolling:

	btst.b  #4,RefreshFlags
	beq     .nomsgbox
    lea     StrMsgBoxExceedGames,a0
    jsr     MessageBox
	bclr.b  #4,RefreshFlags
.nomsgbox:

	; Prevent from navigating lists if there are no games found
	tst.w   TotalFileCount
	beq     .cantmove

    cmp.b   #40,UITemp
    blo     .noscroll
    bne     .scroll
    ; Does the current filename need scrolling ?
	moveq.l #0,d0
	move.b  MenuShift,d0		; Matched entries to skip, for scrolling
	add.b   FileCursor,d0
	lea     MenuIndexList,a0
    ; Get file name pointer from index
	moveq.l #0,d1
    move.b  0(a0,d0),d1
    move.b  d1,d0
    lsl.w   #5,d0               ; *32
    lea     FileList,a0
	btst.b  #1,0(a0,d0)         ; Check "long filename" flag
	beq     .scrolling          ; No
    ; ==40: Init file name scrolling
	; Ask MCU for full filename and store in GUBuffer
    move.b  #1,MCUCmdParams
    move.b  d1,MCUCmdParams+1
    MCUCMD  MCU_CMD_GETGAMES
    bcs     .scrolling          ; Silently ignore
    ; Read 4 words from the MCU (see doc)
    jsr     MCURead4Words
    ; Check that command was processed ok
    move.b  MCUReplyBuffer,d0
    andi.b  #$F0,d0
    cmp.b   #$F0,d0
    bne     .scrolling          ; Silently ignore
    ; Ok, retrieve full filename data
	lea     CPLDREG_DATA,a0
	lea     GUBuffer,a1
	move.w  #256/2,d7 		   ; Load filename in words
.readdata:
	move.w  (a0),(a1)+         ; Get two bytes at once
	move.b  d0,REG_DIPSW       ; Shouldn't be necessary
	subq.w  #1,d7
	bne     .readdata
	move.b  #0,(a1)            ; Make sure filename is null terminated
	; Init scrolling vars
    moveq.l #0,d0
    move.b  d0,ScrollX
    move.b  d0,ScrollTimer
    bra     .noscroll
.scroll:
    ; >=41: Do scrolling
    move.b  ScrollTimer,d0
    addq.b  #1,d0
    move.b  d0,ScrollTimer
    andi.b  #7,d0
    bne     .scrolling
    ; Is next filename char null ?
    lea     GUBuffer+MAX_FILENAME-1,a0
    moveq.l #0,d0
    move.b  ScrollX,d0
    tst.b   0(a0,d0)
    beq     .scrolling         ; Don't scroll more
    addq.b  #1,d0
    bset.b  #3,RefreshFlags
    move.b  d0,ScrollX
    bra     .scrolling
.noscroll:
    addq.b  #1,UITemp
.scrolling:

	; After the cursor has settled on a game for a bit, try loading that
	; game's own bg.bmp as the menu background (falls back on its own)
	cmp.b   #20,UITemp          ; ~0.33s @ 60Hz, before filename scrolling kicks in
	blo     .nobgload
	tst.b   LetterGameCount
	beq     .nobgload
	jsr     LoadGameBG
.nobgload:

	; Handle input to jump the cursor to the next/prev letter's first game -
	; no visible letter bar anymore, but esquerda/direita still work as a
	; quick-jump within the one, always-full game list (see JumpToLetter).
	TESTREPEAT CNT_LEFT
    beq     .no_left
    tst.b   LetterCursor
    bne     .left
    ; Warp to rightmost letter
    moveq.l #0,d0
	move.b  LetterCount,d0
    subq.b  #1,d0
    move.b  d0,LetterCursor
	bra     .left_done
.left:
    subq.b  #1,LetterCursor
.left_done:
    move.b  #SFX_MOVE,d0
    jsr     PlaySFX
    jsr     JumpToLetter
.no_left:

	TESTREPEAT CNT_RIGHT
    beq     .no_right
    move.b  LetterCount,d0
    subq.b  #1,d0
    cmp.b   LetterCursor,d0
    bne     .right
    ; Warp back to leftmost letter
	move.b  #0,LetterCursor
	bra     .right_done
.right:
    addq.b  #1,LetterCursor
.right_done:
    move.b  #SFX_MOVE,d0
    jsr     PlaySFX
    jsr     JumpToLetter
.no_right:

    ; Handle input for selection of game from list
    jsr     FileListNav

	TESTCHANGE CNT_A
    beq     .no_a
    tst.b   LetterGameCount
    beq     .no_a
    ; Load selected game
	move.w  #$0000,FixWriteConfig
	; Get selected file number, double lookup
	lea     MenuIndexList,a0
	moveq.l #0,d0
	move.b  FileCursor,d0
	add.b   MenuShift,d0
	moveq.l #0,d1
	move.b  0(a0,d0),d1
	lea     FileList,a0
	lsl.w   #5,d1                   ; *32
	move.b  1(a0,d1),d0
	jsr     LoadGame
.no_a:

.cantmove:

    IF TARGET==1
    ; B: Open/close try on front-loaders
	TESTCHANGE CNT_B
    beq     .no_b
    jsr     ToggleTray
.no_b:
    ENDIF

    ; C: Go to options menu
	TESTCHANGE CNT_C
    beq     .no_c
    move.b  #SFX_VAL,d0
    jsr     PlaySFX
    jsr     SetupMenu
.no_c:

    ; D: Reset to original SP ROM
	TESTCHANGE CNT_D
    beq     .no_d
    lea     StrMsgBoxResetConfirm,a0
    lea     ResetConfirm,a1
    jsr     MessageBoxCustom
.notimeout:
.no_d:

	btst   	#7,$10F6B9			; "GameStartState"
	beq     .idle
	jmp     StartGameCD

.idle:
	rts


; After LetterCursor has been moved (CNT_LEFT/CNT_RIGHT above), jump
; FileCursor/MenuShift so the first game matching that letter becomes
; selected and scrolled into view - without hiding any other game from the
; (always full) list, unlike the old per-letter BuildFileList filter this
; replaces. Match logic mirrors what BuildFileList used to do per-entry.
JumpToLetter:
	tst.b   LetterCount
	beq     .done                ; No letters available, nothing to jump to
	jsr     ResolveLetterCursor  ; d1 = target char (0 = numbers bucket)

	lea     LetterLUT,a0
	lea     FileList,a1
	moveq.l #0,d6                ; Scan position, becomes the match's position
.scan:
	tst.b   (a1)+
	beq     .done                ; Reached end of GameList, no match (shouldn't happen)
	addq.l  #1,a1                ; Skip flag and file number bytes
	tst.b   d1
	bne     .letter
	; Match any number
	cmp.b   #'9',(a1)
	bhi     .skip
	bra     .found
.letter:
	; Match letter, case insensitive
	move.b  (a1),d0
	cmp.b   #'@',d0
	blo     .skip
	cmp.b   #'z',d0
	bhi     .skip
	subi.b  #'@',d0
	move.b  0(a0,d0),d0         ; Convert to lower case
	addi.b  #'@',d0
	cmp.b   d0,d1
	bne     .skip
.found:
	; d6 = match's position in FileList == its position in MenuIndexList
	; (identity mapping now that the list is unfiltered). Put it at the top
	; of the visible window, clamped so the window doesn't scroll past the
	; end of the list.
	moveq.l #0,d5
	move.w  TotalFileCount,d5
	cmp.w   #MAX_MENU_LINES,d5
	bhi     .canscroll
	moveq.l #0,d5                ; Whole list fits on screen, MenuShift always 0
	bra     .haveshift
.canscroll:
	subi.w  #MAX_MENU_LINES,d5   ; d5 = highest valid MenuShift
.haveshift:
	move.w  d6,d4                ; d4 = desired MenuShift = match position
	cmp.w   d5,d4
	bls     .noclamp
	move.w  d5,d4
.noclamp:
	move.b  d4,MenuShift
	move.w  d6,d0
	sub.w   d4,d0
	move.b  d0,FileCursor
	bset.b  #0,RefreshFlags      ; Redraw list (MenuShift may have changed)
	bset.b  #2,RefreshFlags      ; Redraw cursor
	rts
.skip:
	addq.w  #1,d6
	cmp.w   #MAX_FILES,d6
	beq     .done                ; Reached end of GameList
	lea     30(a1),a1            ; Next entry (32-2)
	bra     .scan
.done:
	rts


ResetConfirm:
	TESTCHANGE CNT_A
    beq     .no_a
    lea     MCUCmdParams,a0
    st.b    (a0)+               ; SetRunStock(1)
    ; Send country patch parameters to MCU, MCU will send them to the CPLD
    move.b  SettingCountry,(a0)+
    move.b  #RegionPatch>>16,(a0)+
    move.b  #(RegionPatch>>8)&255,(a0)+
    move.b  #(RegionPatch)&255,(a0)
    MCUCMD  MCU_CMD_RESET
    bcs     .timeout
    rts
.timeout:
    jmp     DispErrorTimeout
.no_a:
    move.b  #SFX_NEG,d0
    jmp     PlaySFX
