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

SetupMain:
	; Palettes should already be set up correctly by InstallDataDRAM
	; CDPPalData is patched with the new palettes

    move.w  #SCREEN_IDLE,CurrentScreen

	move.b  #$FF,REG_Z80RST		; Copied from original routine

    move.b  d0,REG_NOSHADOW     ; Required after exiting from Ironclad

	move.w  #$0100,REG_LSPCMODE ; Set auto-animation speed

	move.b  #1,REG_ENVIDEO
	move.b  #0,REG_DISBLSPR
	move.b  #0,REG_DISBLFIX

    moveq.l #0,d0
    move.b  d0,IsInIGM
	move.b  d0,FileCursor
	move.b  d0,FileCursorPrev
	move.b  d0,MenuShift
	move.b  d0,LetterCursor
	move.b  d0,CurrentMsgBox
	move.b  d0,IsLoading
	move.l  d0,ActiveLetters
    move.w  d0,TotalFileCount
    move.w  d0,UITemp           ; Used as delay timer to start scrolling file names
	move.b  d0,FlagSelectStart
	st.b    PollStatus
	st.b    LastBGGameIndex     ; $FF, no per-game bg loaded yet
	sf.b    BGActiveBuffer

	; RefreshFlags bits use in ui_main:
	; 0: Redraw file list
	; 1: -                       (was "Redraw letter cursor" - bar removed)
	; 2: Redraw file cursor
	; 3: Redraw current file name for scrolling
	; 4: Show msgbox about game count exceeding MAX_FILES
	; 5: -
	; 6: -
	; 7: -
    move.b  #%00000101,RefreshFlags

    jsr     WaitVBL                 ; Wait for vblank to hide dirty things

    lea     IGMPalettes,a0
	lea     (2*16*2)+PALETTES,a1	; Set up palette 2 for msgbox text
    jsr     CopyPalette

    jsr     ClearFix

    jsr     ClearFileList
    jsr     ClearMainSprites

    ; Apply whatever background is already valid (default pattern, or the
    ; still-standing custom buffer from before this screen) right away -
    ; otherwise SPR_BG keeps showing whatever the previous screen (e.g.
    ; Options) left behind for the whole game-list fetch below, which can
    ; take a while. The real SetupBGSprites call further down re-applies it
    ; in case a fresh bg.bmp gets loaded in the meantime.
    jsr     SetupBGSprites

    IFDEF MAMEDEBUG
    jsr     DebugSetupMain
	bra     .setup_interface
    ENDIF

    jsr     GetMCUStatus

	btst.b  #7,MCUStatus
	beq     .setup_interface   ; SD card absent, skip loading game list

    IFNDEF MAMEDEBUG
	jsr     InitSD
	bcs     .setup_interface   ; SD card error, skip loading game list

    ; Check if there's already a custom bg loaded
    tst.b   CustomBGLoaded
    beq     .notloaded
    move.w  CustomBGBackdrop,BACKDROP   ; Restore custom BG backdrop color in case we exited from screen saver
    bra     .nocustombg
.notloaded:
	; Check if there's a custom bg file available
    move.b  #BG_CODE,MCUCmdParams
    MCUCMD  MCU_CMD_SELECTGAME
    bcc     .notimeouta
    jsr     DispErrorTimeout
    bra     .nocustombg
.notimeouta:
    jsr     MCURead4Words
    move.b  MCUReplyBuffer,d0
    andi.b  #$F0,d0
    beq     .nocustombg
    jsr     LoadCustomBG
.nocustombg:

    move.w  #$2000,FixWriteConfig   ; Palette #2 bank 0
    lea     FixStrLoadingList,a0
	move.w  #FIXMAP+13+(10*32),d0
	jsr     WriteFix

    ; Ask MCU for game list
    clr.l   MCUCmdParams
    MCUCMD  MCU_CMD_GETGAMES
    bcc     .notimeoutc
    jsr     DispErrorTimeout
    bra     .setup_interface
.notimeoutc:
    jsr     MCURead4Words
    jsr     CheckACK
    bcs     .setup_interface
    ; Ok, get file count
    moveq.l #0,d0
    move.b  MCUReplyBuffer+1,d0
    cmp.b   #EXCEED_CODE,d0
    bne     .noexceed
    ; Available games count exceed MAX_FILES
    ; Cap to MAX_FILES and warn user with msgbox after listing
    move.b  #MAX_FILES,d0
    bset.b  #4,RefreshFlags     ; Request warning msgbox
.noexceed:
    move.w  d0,TotalFileCount

    ; Retrieve file names
    move.w  TotalFileCount,d6
    tst.w   d6
    beq     .setup_interface    ; Skip if no files
    lea     FileList,a1    
.listfiles:
    move.w  #16,d3              ; 1+30+1, ID.b + string + /0 (no /0 if LFN)
    jsr     MCURead4WordsMult

    lea     MCUReplyBuffer,a0
    move.w  #$0100,d0           ; "Entry used" flag
    tst.b   MAX_FILENAME+1(a0)
    beq     .shortname
    ori.w   #$0200,d0           ; Add "long filename" flag
.shortname:
    move.b  (a0)+,d0
    move.w  d0,(a1)+            ; File index + flags

    movea.l a1,a2
    moveq.l #MAX_FILENAME-1,d7
.cp:
    move.b  (a0)+,(a2)+         ; Copy file name, cap to MAX_FILENAME chars
	subq.b  #1,d7
	bne     .cp
    move.b  #0,(a2)+            ; Force last char to 0

    lea     32-2(a1),a1

	subq.w  #1,d6
	bne     .listfiles

    move.b  #0,(a1)+            ; Terminate
    ENDIF

.setup_interface:

    jsr     ClearFix            ; Erase any "Please wait" messages

    ; Prepare ActiveLetters
    moveq.l #0,d3
    move.w  TotalFileCount,d7
    tst.w   d7
    beq     .noactive           ; Skip if no files
    lea     FileList,a0
    lea     LetterLUT,a1
    move.l  ActiveLetters,d2
    moveq.l #0,d0
.setupactive
    move.b  #0,d1
    move.b  2(a0),d0            ; Get game's name first letter
    cmp.b   #'@',d0
    blo     .notletter
    cmp.b   #'z',d0
    bhi     .notletter
    subi.b  #64,d0
    move.b  0(a1,d0),d1         ; Look up corresponding ActiveLetters bit position
.notletter:
    bset.l  d1,d2
    bne     .alreadyset         ; BSET does a BTST before setting the bit
    addq.b  #1,d3
.alreadyset:
    lea     32(a0),a0
    subq.w  #1,d7
    bne     .setupactive
    move.l  d2,ActiveLetters
.noactive:
    move.b  d3,LetterCount
    
    ; Wait for vblank to hide dirty things
    jsr     WaitVBL

    jsr     SetupBGSprites

	; Letters bar is gone (no on-screen A-Z strip anymore), but ActiveLetters/
	; LetterCount/LetterCursor still drive CNT_LEFT/CNT_RIGHT letter-jump
	; navigation in VBLProcMain (JumpToLetter) - no sprites to set up here.

    ; Restore cursors to last valid ones
	tst.b   CursorsValid
	beq     .invalid
	move.b  LastFileCursor,FileCursor
	move.b  LastMenuShift,MenuShift
	move.b  LastLetterCursor,LetterCursor
.invalid:

	; Draw footer: compact action-button hints (left, bottom rows) and the
	; region flag (right, bottom rows) - the header logo/instructions and
	; the old START+SELECT/version footer are gone; this replaces them.
	move.w  #$0500,FixWriteConfig
	move.w  #FIXMAP+26+(LIST_NAME_COL*32),d0
	IF TARGET==1
    lea     FixStrFooterActionsFront,a0
	ELSE
    lea     FixStrFooterActionsTop,a0
	ENDIF
	jsr     WriteFix

	; Draw nationality flag (footer, right-hand side)
	lea     FlagLUT,a0
	moveq.l #0,d0
	move.b  SettingCountry,d0
	add.w   d0,d0
	add.w   d0,d0
	movea.l (a0,d0),a0
	move.w  #$1500,d0
	move.w  #FIXMAP+26+(34*32),REG_VRAMADDR
	move.w  #32,REG_VRAMMOD    ; 20
	nop                        ; 4
	nop                        ; 4
	move.b  (a0)+,d0           ; 8
	move.w  d0,REG_VRAMRW      ; 16
	nop                        ; 4
	nop                        ; 4
	move.b  (a0)+,d0           ; 8
	move.w  d0,REG_VRAMRW      ; 16
	nop
	nop
	move.b  (a0)+,d0
	move.w  d0,REG_VRAMRW
	nop
	nop
	move.w  #FIXMAP+27+(34*32),REG_VRAMADDR
	nop
	nop
	move.b  (a0)+,d0
	move.w  d0,REG_VRAMRW
	nop
	nop
	move.b  (a0)+,d0
	move.w  d0,REG_VRAMRW
	nop
	nop
	move.b  (a0),d0
	move.w  d0,REG_VRAMRW

    jsr     BuildFileList

	move.w  #SCREEN_MAIN,CurrentScreen
	rts


; Builds the (always full, unfiltered) visible game list: MenuIndexList[i]=i
; for every game in FileList, in the order the MCU returned them. There's no
; on-screen letter bar anymore to filter by, so the list always shows every
; game - CNT_LEFT/CNT_RIGHT (JumpToLetter in ui_main_vbl.asm) just move the
; cursor to the next/prev letter's first match within this same full list,
; they don't change what's in it. Called once from SetupMain after the game
; list is fetched.
BuildFileList:
	clr.b   LetterGameCount     ; Reset entry count (== TotalFileCount below)

	moveq.l #0,d6
	move.w  TotalFileCount,d6
	beq     .done                ; No files
	move.b  d6,LetterGameCount    ; Fits a byte: TotalFileCount capped to MAX_FILES

	lea     MenuIndexList,a0
	moveq.l #0,d0
.fill:
	move.b  d0,(a0)+
	addq.w  #1,d0
	subq.w  #1,d6
	bne     .fill
.done:

	bset.b  #0,RefreshFlags 	; File list needs refresh
	tst.b   CursorsValid
	bne     .keepcursor
	clr.b   FileCursor          ; Reset file cursor to top
	clr.b   MenuShift
	bset.b  #2,RefreshFlags     ; File cursor needs refresh
	rts
.keepcursor:
    clr.b   CursorsValid
    rts


; Resolves LetterCursor (index into the active-letters bitmap) to the actual
; letter character (or 0 for the numbers/"#" bucket), same lookup BuildFileList
; used to do per-filter. d1 = resolved match char (0 = numbers bucket).
ResolveLetterCursor:
	moveq.l #0,d2
	move.b  LetterCursor,d0
	move.l  ActiveLetters,d1
.countbits:
    lsr.l   #1,d1
    bcc     .zero               ; Unused letter
    tst.b   d0
    beq     .found
    subq.b  #1,d0
.zero:
    addq.b  #1,d2
    bra     .countbits
.found:
	lea     MenuLetterList,a0
	move.b  0(a0,d2),d1
	rts


FlagLUT:
    dc.l    FixMapFlagJP
    dc.l    FixMapFlagUS
    dc.l    FixMapFlagEU
    dc.l    FixMapFlagBR
