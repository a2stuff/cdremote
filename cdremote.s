.setcpu "65c02"
.org $4000
ZP1                 := $19
ZP2                 := $1B
ZP3                 := $1D
PlayedListPtr       := $1F

COUT                := $FDED
MLIEntry            := $BF00

Kbd                 := $C000
KbdStrobe           := $C010
SetGraphics         := $C050
SetFullScreen       := $C052
SetPage1            := $C054
SetHiRes            := $C057
OpenApple           := $C061

CardROMByte         := $C5FF


                    ; Save the ZP values for the locations we're going to use
MAIN:               lda ZP1
                    pha
                    lda ZP1 + 1
                    pha
                    lda ZP2
                    pha
                    lda ZP2 + 1
                    pha
                    lda ZP3
                    pha
                    lda ZP3 + 1
                    pha

                    ; "Null" out T/M/S values
                    lda #$aa
                    sta BCDRelTrack
                    sta BCDRelMinutes
                    sta BCDRelSeconds

                    ; Locate an Apple SCSI card and CDSC/CDSC+ drive
                    jsr FindHardware
                    bcs EXIT

                    ; Application setup
                    jsr InitializeScreen
                    jsr InitDriveAndDisc
                    jsr InitPlayedList

                    ; Do all the things!
                    jsr MainLoop

                    ; Restore the saved ZP values and call MLI QUIT
EXIT:               pla
                    sta ZP1
                    pla
                    sta ZP1 + 1
                    pla
                    sta ZP2
                    pla
                    sta ZP2 + 1
                    pla
                    sta ZP3
                    pla
                    sta ZP3 + 1
                    jsr MLIQUIT
                    rts

                    ; Is drive online?
InitDriveAndDisc:   jsr StatusDrive
                    bcs ExitInitDriveDisc

                    ; Read the TOC for Track numbers - TOC VALUES ARE BCD!!
                    jsr C27ReadTOC

                    sed
                    clc
                    lda BCDLastTrackTOC
                    sbc BCDFirstTrackTOC
                    adc #$01
                    sta BCDTrackCount0Base
                    cld

                    jsr C24AudioStatus
                    lda SPBuffer
                    ; Audio Status = $00 (currently playing)
                    beq IDDPlaying
                    dec a
                    ; Audio status = $01 (currently paused)
                    beq IDDPaused
                    ; Audio status = anything else - stop operation explicitly
                    jsr DoStopAction
                    bra ExitInitDriveDisc

                    ; Set Pause button to active
IDDPaused:          dec PauseButtonState
                    jsr ToggleUIPauseButton
                    ; Read the current disc position and update the Track and Time display
                    jsr C28ReadQSubcode
                    jsr DrawTrack
                    jsr DrawTime

                    ; Set Play button to active
IDDPlaying:         dec PlayButtonState
                    ; Set drive playing flag to true
                    dec DrivePlayingFlag
                    jsr ToggleUIPlayButton
                    bra ExitInitDriveDisc
ExitInitDriveDisc:  rts

                    ; Set Full-Screen HGR Page 1
InitializeScreen:   lda SetFullScreen
                    lda SetGraphics
                    lda SetHiRes
                    lda SetPage1

                    ; Clear screen to all white, initialize the GUI elements
                    jsr ClearHGR1toWhite
                    jsr PaintCDRemoteUI
                    jsr PaintCDRemoteMenu
                    jsr DrawTrack
                    jsr DrawTime
                    rts

                    ; This is the start of where all the real action takes place
MainLoop:           lda TOCInvalidFlag
                    ; Have we read in a valid, usable TOC from an audio CD?
                    beq TOCisValid

                    ; We don't have a valid TOC - poll the drive to see if it's online so we can try to read a TOC
                    jsr StatusDrive
                    ; No - drive is offline, go check for user input instead
                    bcs NoFurtherBGAction
                    ; Yes - make another attempt at reading a TOC
                    jsr ReReadTOC

                    ; Re-check the status of the drive
TOCisValid:         jsr StatusDrive
                    lda DrivePlayingFlag
                    ; Drive is not currently playing audio, go check for user input
                    beq NoFurtherBGAction

                    ; Drive is playing audio, watch for an AudioStatus return code of $03 = "Play operation complete"
                    jsr C24AudioStatus
                    lda SPBuffer
                    cmp #$03
                    ; Audio playback operation is not complete
                    bne StillPlaying

                    ; Deal with reaching the end of a playback operation.  It's complicated.  :)
                    jsr PlayBackComplete

                    ; Go read the QSubcode channel and update the Track & Time display
StillPlaying:       jsr C28ReadQSubcode
                    bcs NoFurtherBGAction
                    jsr DrawTrack
                    jsr DrawTime

                    ; Read and process any Keyboard inputs from the user
NoFurtherBGAction:  jsr GetKeypress
                    bcs MainLoop

                    ; $51 = Q (Quit)
                    cmp #$51
                    bne NotQ
                    jmp DoQuitAction

                    ; $1B = ESC (Quit)
NotQ:               cmp #$1b
                    bne NotESC
                    jmp DoQuitAction

                    ; $4C = L (Continuous Play)
NotESC:             cmp #$4c
                    bne NotL
                    jsr ToggleLoopMode
                    jmp MainLoop

                    ; $52 = R (Random Play)
NotL:               cmp #$52
                    bne NotR
                    jsr ToggleRandomMode
                    jmp MainLoop

                    ; All other key operations (Play/Stop/Pause/Next/Prev/Eject) require an online drive/disc, so check one more time
NotR:               jsr StatusDrive
                    bcs MainLoop

                    ; Loop falls through to here only if the drive is online
                    pha
                    lda TOCInvalidFlag
                    ; Valid TOC has been read, we can skip the re-read
                    beq SkipTOCRead
                    jsr ReReadTOC
SkipTOCRead:        pla

                    ; $50 = P (Play)
                    cmp #$50
                    bne NotP
                    jsr DoPlayAction
                    jmp MainLoop

                    ; $53 = S (Stop)
NotP:               cmp #$53
                    bne NotS
                    jsr DoStopAction
                    jmp MainLoop

                    ; $20 = Space (Pause)
NotS:               cmp #$20
                    bne NotSpace
                    jsr DoPauseAction
                    jmp MainLoop

                    ; $08 = ^H, LA (Previous Track, Scan Backward)
NotSpace:           cmp #$08
                    bne NotCtrlH
                    lda OpenApple
                    bpl JustLeftArrow
OA_LeftArrow:       jsr DoScanBackAction
                    jmp MainLoop

JustLeftArrow:      jsr DoPrevTrackAction
                    jmp MainLoop

                    ; $15 = ^U, RA (Next Track/Scan Forward)
NotCtrlH:           cmp #$15
                    bne NotCtrlU
                    lda OpenApple
                    bpl JustRightArrow
OA_RightArrow:      jsr DoScanFwdAction
                    jmp MainLoop

JustRightArrow:     jsr DoNextTrackAction
                    jmp MainLoop

                    ; $45 = E (Eject)
NotCtrlU:           cmp #$45
                    bne UnsupportedKeypress
                    jsr C26Eject
UnsupportedKeypress:jmp MainLoop

DoQuitAction:       rts

PlayBackComplete:   lda RandomButtonState
                    ; Random button is inactive - the entire Disc has been played to the end
                    beq PBCRandomIsInactive

                    ; Random button is active - handle rollover to next random track
                    lda PlayButtonState
                    ; Play button is inactive - bail out, there's nothing to do
                    beq ExitPBCHandler

                    ; Increment the count of how many tracks have been played
                    inc HexPlayedCount0Base
                    lda HexPlayedCount0Base
                    cmp HexTrackCount0Base
                    ; Haven't played all the tracks on the disc, so pick another one
                    bne PBCPlayARandomTrack

                    ; All tracks have been played randomly - clear the Play button STATE to inactive (with no UI change) ...
                    lda #$00
                    sta PlayButtonState
                    ; re-randomize from scratch ...
                    jsr RandomModeInit
                    ; then reset the Play button STATE back to active (again with no UI change)
                    lda #$ff
                    sta PlayButtonState

                    lda LoopButtonState
                    ; Loop button is active, so play the whole disc over again - start by picking a new track
                    bne PBCPlayARandomTrack

                    ; Loop button is inactive - reset the first/last/current values to the TOC values and stop
                    lda BCDFirstTrackTOC
                    sta BCDFirstTrackNow
                    sta BCDRelTrack
                    lda BCDLastTrackTOC
                    sta BCDLastTrackNow
                    jsr DoStopAction
                    bra ExitPBCHandler

PBCPlayARandomTrack:jsr PickARandomTrack
                    lda BCDRandomPickedTrk

                    ; We're in random mode, "playing" just one track now, so Current/First/Last are all the same
                    sta BCDRelTrack
                    sta BCDFirstTrackNow
                    sta BCDLastTrackNow
                    ; and we're "stopping" at the end of the current track
                    jsr SetStopToEoBCDLTN

                    ; Set flag to Track mode, because we're in random mode
                    lda #$ff
                    sta TrackOrMSFFlag

                    ; Call AudioPlay function and exit
                    jsr C21AudioPlay
                    bra ExitPBCHandler

                    ; Entire disc has been played to the end, do we need to loop?
PBCRandomIsInactive:lda LoopButtonState
                    ; Loop Button is inactive - so we just stop
                    beq PBCLoopIsInactive

                    ; Loop button is active - reset stop point to EoT LastTrack
                    jsr C23AudioStop
                    lda PlayButtonState
                    ; Play button is inactive - bail out, there's nothing to do
                    beq ExitPBCHandler

                    ; Make sure we start fresh from the first track on the disc
                    lda BCDFirstTrackTOC
                    sta BCDFirstTrackNow
                    ; Set flag to MSF mode, because we're not in random mode
                    dec TrackOrMSFFlag
                    ; Call AudioPlay function and exit
                    jsr C21AudioPlay
                    bra ExitPBCHandler

                    ; Stop, because Loop is inactive
PBCLoopIsInactive:  lda PlayButtonState
                    ; Play button is inactive (already) - bail out, there's nothing to do
                    beq ExitPBCHandler

                    ; Use the existing StopAction to stop everything
                    jsr DoStopAction

ExitPBCHandler:     rts

StatusDrive:        pha
                    ; Try three times for a good status return
                    lda #$03
                    sta RetryCount

                    ; $00 = Status
RetryLoop:          lda #$00
                    sta SPCommandType
                    ; $00 = Code
                    lda #$00
                    sta SPCode
                    jsr SPCallVector
                    bcc GotStatus
                    dec RetryCount
                    bne RetryLoop
                    sec
                    ; Failed Status call three times - exit with carry set
                    bra ExitStatusDrive

                    ; First byte is general status byte
GotStatus:          lda SPBuffer
                    ; $B4 means Block Device, Read-Only, and Online (CD-ROM)
                    cmp #$b4
                    beq StatusDriveSuccess

                    lda TOCInvalidFlag
                    ; TOC is currently flagged invalid - that's expected, so just return the Status call failure
                    bne StatusDriveFail

                    ; EXCEPTION - Call a HardShutdown if we encounter a bad Status call with an existing valid TOC because something's gone very wrong
                    jsr HardShutdown
                    ; Hard-flag the TOC as now invalid
                    lda #$ff
                    sta TOCInvalidFlag

                    ; Exit with carry set
StatusDriveFail:    sec
                    bra ExitStatusDrive

                    ; Exit with carry clear
StatusDriveSuccess: clc
ExitStatusDrive:    pla
                    rts

                    ; EXCEPTION - Explicitly stop the CD drive, forcibly clear the Play/Pause buttons, forcibly set the Stop button, and wipe the Track/Time display clean
HardShutdown:       jsr DoStopAction
                    lda PauseButtonState
                    ; Pause button is inactive (already) - nothing to do
                    beq NoPauseButtonChange

                    ; Clear Pause button to inactive
                    lda #$00
                    sta PauseButtonState
                    jsr ToggleUIPauseButton

NoPauseButtonChange:lda PlayButtonState
                    ; Play button is inactive (already) - nothing to do
                    beq NoPlayButtonChange

                    ; Clear Play button to inactive
                    lda #$00
                    sta PlayButtonState
                    jsr ToggleUIPlayButton

NoPlayButtonChange: lda StopButtonState
                    ; Stop button is active (already) - nothing to do
                    bne ClearTrackAndTime

                    ; Set Stop button to active
                    lda #$ff
                    sta StopButtonState
                    jsr ToggleUIStopButton

                    ; "Null" out T/M/S values and blank Track & Time display
ClearTrackAndTime:  lda #$aa
                    sta BCDRelTrack
                    sta BCDRelMinutes
                    sta BCDRelSeconds

                    jsr DrawTrack
                    jsr DrawTime
                    lda BlankGlyphAddr
                    sta ZP1
                    lda BlankGlyphAddr + 1
                    sta ZP1 + 1
                    ldx #$20
                    jsr DrawDigitAtX

                    rts

                    ; Called in the background if the drive reports a valid/online Status and we still have an invalid TOC.
ReReadTOC:          lda #$00
                    sta TOCInvalidFlag
                    jsr C27ReadTOC

                    sed
                    clc
                    lda BCDLastTrackTOC
                    sbc BCDFirstTrackTOC
                    adc #$01
                    ; Calculate the number of tracks on the disc, minus 1, and stash it
                    sta BCDTrackCount0Base
                    cld

                    ; Explicitly stop playback and set stop point to EoT LastTrack
                    jsr C23AudioStop
                    ; Set flag to Track mode
                    lda #$ff
                    sta TrackOrMSFFlag

                    ; Update Track and Time display
                    jsr C28ReadQSubcode
                    jsr DrawTrack
                    jsr DrawTime

                    lda RandomButtonState
                    ; Random button is inactive, so nothing else to do
                    beq ExitReReadTOC

                    ; Random button is active, so set up random mode
                    jsr RandomModeInit
ExitReReadTOC:      rts

                    ; Read a keypress if there is one
GetKeypress:        inc RandomSeed
                    lda Kbd
                    bpl GKNoKeyPressed
                    bit KbdStrobe

                    ; Strip the high bit
                    and #$7f
                    cmp #$61
                    bmi GKNotLowerCase
                    cmp #$7a
                    bpl GKNotLowerCase
                    ; Force it to upper-case
                    and #$5f

                    ; Set carry flag to indicate keypress or not, and exit
GKNotLowerCase:     clc
                    bra ExitGetKeypress
GKNoKeyPressed:     sec
ExitGetKeypress:    rts

                    ; Function to wait until an existing keypress is released
KeyReleaseWait:     lda KbdStrobe
                    bmi KeyReleaseWait
                    rts

DoPlayAction:       lda PauseButtonState
                    ; Pause button is inactive - nothing to do yet
                    beq DPAPauseIsInactive

                    ; Pause button is active - forcibly clear it to inactive and then...
                    lda #$00
                    sta PauseButtonState
                    jsr ToggleUIPauseButton
                    ; call AudioPause to release Pause (resume playing) and exit
                    jsr C22AudioPause
                    bra ExitPlayAction

DPAPauseIsInactive: lda PlayButtonState
                    ; Play button is active (already) - bail out, there's nothing to do
                    bne ExitPlayAction

                    ; Play button is inactive, we're starting from scratch - before activating, check the random mode
                    lda RandomButtonState
                    ; Random button is inactive - just update the UI buttons and start playback
                    beq DPARandomIsInactive

                    ; Random button is active - initialize random mode, pick a Track, and start it
                    jsr RandomModeInit
                    jsr PickARandomTrack
                    lda BCDRandomPickedTrk

                    ; In random mode, we're "playing" just one track, so Current/First/Last are all the same
                    sta BCDRelTrack
                    sta BCDFirstTrackNow
                    sta BCDLastTrackNow
                    ; and we "stop" playing at the end of that track
                    jsr SetStopToEoBCDLTN
                    jsr C20AudioSearch

                    ; Set Play button to active
DPARandomIsInactive:dec PlayButtonState
                    jsr ToggleUIPlayButton

                    lda StopButtonState
                    ; Stop button is inactive (already) - just start the playback and exit
                    beq DPAStopIsInactive

                    ; Set Stop button to inactive, then start the playback and exit
                    lda #$00
                    sta StopButtonState
                    jsr ToggleUIStopButton

DPAStopIsInactive:  jsr C21AudioPlay
ExitPlayAction:     rts

DoStopAction:       lda StopButtonState
                    ; Stop button is active (already) - bail out, there's nothing to do
                    bne ExitStopAction

                    ; Reset First/Last to TOC values
                    lda BCDFirstTrackTOC
                    sta BCDFirstTrackNow
                    lda BCDLastTrackTOC
                    sta BCDLastTrackNow

                    lda PlayButtonState
                    ; Play button is inactive (already) - nothing to do
                    beq DSAPlayIsInactive

                    ; Clear Play button to inactive
                    lda #$00
                    sta PlayButtonState
                    jsr ToggleUIPlayButton

DSAPlayIsInactive:  lda PauseButtonState
                    ; Pause button is inactive (already) - nothing to do
                    beq DSAPauseIsInactive

                    ; Clear Pause button to inactive
                    lda #$00
                    sta PauseButtonState
                    jsr ToggleUIPauseButton

                    ; Set Stop button to active
DSAPauseIsInactive: lda #$ff
                    sta StopButtonState
                    ; Switch Stop Flag to EoTrack mode
                    dec TrackOrMSFFlag
                    jsr ToggleUIStopButton

                    ; Force drive to seek to first track
                    lda BCDFirstTrackNow
                    sta BCDRelTrack
                    jsr C20AudioSearch

                    ; Explicitly stop playback and set stop point to EoT last Track
                    jsr C23AudioStop

                    ; Update Track and Time display
                    jsr C28ReadQSubcode
                    jsr DrawTrack
                    jsr DrawTime

ExitStopAction:     rts

DoPauseAction:      lda StopButtonState
                    ; Stop button is active - bail out, there's nothing to do
                    bne ExitPauseAction

                    ; Toggle Pause button
                    lda #$ff
                    eor PauseButtonState
                    sta PauseButtonState
                    jsr ToggleUIPauseButton

                    ; Execute pause action (pause or resume) based on new button state
                    jsr C22AudioPause

                    ; Wait for key to be released and exit
                    jsr KeyReleaseWait
ExitPauseAction:    rts

ToggleLoopMode:     lda #$ff
                    eor LoopButtonState
                    sta LoopButtonState
                    jsr ToggleUILoopButton
                    jsr KeyReleaseWait
                    rts

ToggleRandomMode:   lda #$ff
                    eor RandomButtonState
                    sta RandomButtonState
                    beq TRMRandomIsInactive

                    ; Random button is now active - re-initialize random mode and exit
                    jsr RandomModeInit
                    bra TRMUpdateButton

                    ; Random button is now inactive - reset First/Last to TOC values and update stop point to EoT last Track
TRMRandomIsInactive:lda BCDLastTrackTOC
                    sta BCDLastTrackNow
                    lda BCDFirstTrackTOC
                    sta BCDFirstTrackNow
                    jsr SetStopToEoBCDLTN

                    ; Update UI, wait for key release, and exit
TRMUpdateButton:    jsr ToggleUIRandButton
                    jsr KeyReleaseWait
                    rts

                    ; Zero the Played Track Counter
RandomModeInit:     lda #$00
                    sta HexPlayedCount0Base
                    ; Clear the list of what Tracks have been played
                    jsr ClearPlayedList

                    ; Convert the BCD count-of-tracks-minus-1 into a Hex count-of-tracks-minus-1 and store it in HexTrackCount0Base
                    lda BCDTrackCount0Base
                    and #$0f
                    sta HexTrackCount0Base
                    lda BCDTrackCount0Base
                    and #$f0
                    lsr a
                    sta RandFuncTempStorage
                    lsr a
                    lsr a
                    clc
                    adc RandFuncTempStorage
                    clc
                    adc HexTrackCount0Base
                    ; This value is used to compare against HexPlayedCount0Base so we can determine when we've random-played the whole disc
                    sta HexTrackCount0Base

                    lda PlayButtonState
                    ; Play button is inactive - don't do anything else
                    beq ExitRandomInit

                    ; Play button is active - set the current Track as First/Last/Picked, and set the proper random Stop mode
                    lda BCDRelTrack
                    sta BCDRandomPickedTrk
                    sta BCDFirstTrackNow
                    sta BCDLastTrackNow
                    jsr SetStopToEoBCDLTN

                    ; Mark the current Track's element of the Played List as $FF ("played")
                    phy
                    ldy BCDRelTrack
                    lda #$ff
                    sta (PlayedListPtr),y
                    ply

ExitRandomInit:     rts

DoScanBackAction:   lda PlayButtonState
                    ; Play button is inactive - bail out, there's nothing to do
                    beq ExitScanBackAction

                    lda PauseButtonState
                    ; Pause button is active - bail out, there's nothing to do
                    bne ExitScanBackAction

                    ; Highlight the Scan Back button and engage "scan" mode backwards
                    jsr ToggleUIScanBackButton
                    jsr C25AudioScanBack

                    ; Keep updating the time display as long as you get good QSub reads
DSBALoop:           jsr C28ReadQSubcode
                    bcs DSBAQSubReadErr
                    jsr DrawTrack
                    jsr DrawTime

                    ; Keep scanning as long as the key is held down
DSBAQSubReadErr:    lda KbdStrobe
                    bmi DSBALoop

                    ; Key released - dim the Scan Back button, and resume playing from where we are
                    jsr ToggleUIScanBackButton
                    jsr C22AudioPause
ExitScanBackAction: rts

DoScanFwdAction:    lda PlayButtonState
                    ; Play button is inactive - bail out, there's nothing to do
                    beq ExitScanFwdAction

                    lda PauseButtonState
                    ; Pause button is active - bail out, there's nothing to do
                    bne ExitScanFwdAction

                    ; Highlight the Scan Forward button and engage "scan" mode forward
                    jsr ToggleUIScanFwdButton
                    jsr C25AudioScanFwd

                    ; Keep updating the time display as long as you get good QSub reads
DSFALoop:           jsr C28ReadQSubcode
                    bcs DSFAQSubReadErr
                    jsr DrawTrack
                    jsr DrawTime

                    ; Keep scanning as long as the key is held down
DSFAQSubReadErr:    lda KbdStrobe
                    bmi DSFALoop

                    ; Key released - dim the Scan Forward button, and resume playing from where we are
                    jsr ToggleUIScanFwdButton
                    jsr C22AudioPause
ExitScanFwdAction:  rts

DoPrevTrackAction:  jsr ToggleUIPrevButton

                    ; Reset to start of track
                    lda #$00
                    sta BCDRelMinutes
                    sta BCDRelSeconds
                    jsr DrawTime

DPTAWrapCheck:      lda BCDRelTrack
                    cmp BCDFirstTrackTOC
                    ; If we're not at the "first" track, just decrement track #
                    bne DPTAJustPrev

                    ; Otherwise, wrap to the "last" track instead
                    lda BCDLastTrackTOC
                    sta BCDRelTrack
                    bra DPTACheckRandom

                    ; BCD decrement
DPTAJustPrev:       sed
                    lda BCDRelTrack
                    sbc #$01
                    sta BCDRelTrack
                    cld

DPTACheckRandom:    lda RandomButtonState
                    ; Random button is inactive - just execute playback
                    beq DPTARandomInactive

                    ; Random button is active - set the current Track as First/Last/Picked, and set the proper random Stop mode
                    lda BCDRelTrack
                    sta BCDFirstTrackNow
                    sta BCDLastTrackNow
                    sta BCDRandomPickedTrk
                    jsr SetStopToEoBCDLTN

                    ; TODO: Remove - This check/branch does ABSOLUTELY NOTHING. Pointless code, remove these two lines
                    lda PlayButtonState
                    beq DPTARandomInactive

                    ; Seek to new Track and update Track display
DPTARandomInactive: jsr C20AudioSearch
                    jsr DrawTrack

                    ; Wait a comparatively long time for key release
                    ldx #$ff
DPTAHeldKeyCheck:   lda KbdStrobe
                    bpl DPTAKeyReleased
                    dex
                    bne DPTAHeldKeyCheck

DPTAKeyWasHeld:     lda Kbd
                    ; If key is held long enough, loop all the way back to DPTAWrapCheck and go back another track
                    bpl DPTAWrapCheck
                    bit KbdStrobe
                    bra DPTAKeyWasHeld

DPTAKeyReleased:    jsr ToggleUIPrevButton
                    rts

DoNextTrackAction:  jsr ToggleUINextButton

                    ; Reset to start of track
                    lda #$00
                    sta BCDRelMinutes
                    sta BCDRelSeconds
                    jsr DrawTime

DNTAWrapCheck:      lda BCDRelTrack
                    cmp BCDLastTrackTOC
                    ; If we're not at the "last" track, just increment track #
                    bne DNTAJustNext

                    ; Otherwise, wrap to the "first" track instead
                    lda BCDFirstTrackTOC
                    sta BCDRelTrack
                    bra DNTACheckRandom

                    ; BCD increment
DNTAJustNext:       sed
                    lda BCDRelTrack
                    adc #$01
                    sta BCDRelTrack
                    cld

DNTACheckRandom:    lda RandomButtonState
                    ; Random button is inactive - just execute playback
                    beq DNTARandomInactive

                    ; Random button is active - set the current Track as First/Last/Picked, and set the proper random Stop mode
                    lda BCDRelTrack
                    sta BCDFirstTrackNow
                    sta BCDLastTrackNow
                    sta BCDRandomPickedTrk
                    jsr SetStopToEoBCDLTN

                    ; TODO: Remove - This check/branch does ABSOLUTELY NOTHING. Pointless code, remove these two lines
                    lda PlayButtonState
                    beq DNTARandomInactive

                    ; Seek to new Track and update Track display
DNTARandomInactive: jsr C20AudioSearch
                    jsr DrawTrack

                    ; Wait a comparatively long time for key release
                    ldx #$ff
DNTAHeldKeyCheck:   lda KbdStrobe
                    bpl DNTAKeyReleased
                    dex
                    bne DNTAHeldKeyCheck

DNTAKeyWasHeld:     lda Kbd
                    ; If key is held long enough, loop all the way back to DPTAWrapCheck and go forward another track
                    bpl DNTAWrapCheck
                    bit KbdStrobe
                    bra DNTAKeyWasHeld

DNTAKeyReleased:    jsr ToggleUINextButton
                    rts

C26Eject:           jsr ToggleUIEjectButton

                    ; $26 = Eject
                    lda #$26
                    sta SPCode
                    ; $04 = Control
                    lda #$04
                    sta SPCommandType
                    jsr SPCallVector

                    jsr KeyReleaseWait
                    jsr ToggleUIEjectButton

                    lda StopButtonState
                    ; Stop button is active - just go wipe the Track & Time display and clear the TOC
                    bne ClearTrackTime_TOC

                    lda PauseButtonState
                    ; Pause button is inactive (already) - nothing to do
                    beq EjPauseIsInactive

                    ; Clear Pause button to inactive
                    lda #$00
                    sta PauseButtonState
                    jsr ToggleUIPauseButton

EjPauseIsInactive:  lda PlayButtonState
                    ; Play button is inactive (already) - nothing to do
                    beq EjPlayIsInactive

                    ; Clear Play button to inactive
                    lda #$00
                    sta PlayButtonState
                    jsr ToggleUIPlayButton

                    ; Clear Drive Playing state
EjPlayIsInactive:   lda #$00
                    sta DrivePlayingFlag

                    ; Set Stop button to active
                    dec a
                    sta StopButtonState
                    jsr ToggleUIStopButton

                    ; "Null" out T/M/S, blank Track & Time display, and invalidate the TOC
ClearTrackTime_TOC: lda #$aa
                    sta BCDRelTrack
                    sta BCDRelMinutes
                    sta BCDRelSeconds

                    jsr DrawTrack
                    jsr DrawTime
                    lda BlankGlyphAddr
                    sta ZP1
                    lda BlankGlyphAddr + 1
                    sta ZP1 + 1
                    ldx #$20
                    jsr DrawDigitAtX

                    lda #$ff
                    sta TOCInvalidFlag

                    rts

C21AudioPlay:       lda #$ff
                    sta DrivePlayingFlag
                    ; $04 = Control
                    lda #$04
                    sta SPCommandType
                    ; $21 = AudioPlay
                    lda #$21
                    sta SPCode
                    jsr ZeroOutSPBuffer

                    ; Stop flag = $00 (stop address in 2-5)  LA I think this is wrong, and it should be start address?
                    lda #$00
                    sta SPBuffer
                    ; Play mode = $09 (Standard stereo)
                    lda #$09
                    sta SPBuffer + 1

                    lda TrackOrMSFFlag
                    ; Use M/S/F to stop playback at the end of the disc for sequential mode
                    beq APStopAtMSF

                    ; Use end of currently-selected Track as "stop" point for random mode
APStopAtTrack:      lda BCDFirstTrackNow
                    sta SPBuffer + 2
                    ; Address Type = $02 (Track)
                    lda #$02
                    sta SPBuffer + 6
                    lda #$00
                    sta TrackOrMSFFlag
                    bra CallAudioPlay

APStopAtMSF:        lda BCDAbsMinutes
                    sta SPBuffer + 4
                    lda BCDAbsSeconds
                    sta SPBuffer + 3
                    lda BCDAbsFrame
                    sta SPBuffer + 2
                    ; Address Type = $01 (MSF)
                    lda #$01
                    sta SPBuffer + 6

CallAudioPlay:      jsr SPCallVector
                    rts

                    ; $04 = Control
C20AudioSearch:     lda #$04
                    sta SPCommandType
                    lda #$20
                    sta SPCode
                    jsr ZeroOutSPBuffer

                    lda PlayButtonState
                    ; Play button is inactive - seek and hold
                    beq ASHoldAfterSearch

                    ; Play button is active - seek and play
ASPlayAfterSearch:  lda #$ff
                    ; Set the Drive Playing flag to active
                    sta DrivePlayingFlag

                    ; $01 = Play after search
                    lda #$01
                    bra ASExecuteSearch

                    ; $00 = Hold after search
ASHoldAfterSearch:  lda #$00
ASExecuteSearch:    sta SPBuffer
                    ; $09 = Play mode (Standard stereo)
                    lda #$09
                    sta SPBuffer + 1
                    ; Search address = Track
                    lda BCDRelTrack
                    sta SPBuffer + 2
                    ; Address Type = $02 (Track)
                    lda #$02
                    sta SPBuffer + 6
                    jsr SPCallVector

                    ; TODO: Remove - This whole block of code is dead/unbranched - remove all of it up through DeadCodeExit
                    bra ASSkipDeadCode
DeadCode:           phx
                    ldx #$03
DeadCodeLoop:       jsr C24AudioStatus
                    lda SPBuffer
                    cmp #$03
                    beq DeadCodeExit
                    dex
                    bne DeadCodeLoop
                    .byte   $00, $00
DeadCodeExit:       plx

ASSkipDeadCode:     lda PauseButtonState
                    ; Pause button is inactive (already) - nothing to do
                    beq ASPauseIsInactive

                    ; Clear Pause button to inactive
                    inc PauseButtonState
                    jsr ToggleUIPauseButton

ASPauseIsInactive:  lda BCDRelTrack
                    sta BCDFirstTrackNow
                    rts

                    ; $04 = Control
C24AudioStatus:     lda #$04
                    sta SPCommandType
                    ; $24 = Audio Status
                    lda #$24
                    sta SPCode

                    ; Try 3 times to fetch the Audio Status, then give up.
                    lda #$03
                    sta RetryCount
AudioStatusRetry:   jsr SPCallVector
                    bcc ExitAudioStatus
                    dec RetryCount
                    bne AudioStatusRetry

ExitAudioStatus:    rts

                    ; $04 = Control
C27ReadTOC:         lda #$04
                    sta SPCommandType
                    ; $27 = ReadTOC
                    lda #$27
                    sta SPCode
                    ; Start Track # = $00 (Whole Disc), Type = $00 (request First/Last Track numbers)
                    jsr ZeroOutSPBuffer
                    ; Allocation Length = $0A (even though this space is unused)
                    lda #$0a
                    sta SPBuffer + 1

                    ; Try 3 times to read the TOC, then give up.
                    lda #$03
                    sta RetryCount
ReadTOCRetry:       jsr SPCallVector
                    bcc ReadTOCSuccess
                    dec RetryCount
                    bne ReadTOCRetry
                    sec
                    bra ExitReadTOC

                    ; First Track #
ReadTOCSuccess:     lda SPBuffer
                    sta BCDFirstTrackTOC
                    sta BCDFirstTrackNow
                    ; Last Track #
                    lda SPBuffer + 1
                    sta BCDLastTrackTOC
                    sta BCDLastTrackNow
                    clc
ExitReadTOC:        rts

                    ; $04 = Control
C28ReadQSubcode:    lda #$04
                    sta SPCommandType
                    ; $28 = ReadQSubcode
                    lda #$28
                    sta SPCode

                    ; Try 3 times to read the QSubcode, then give up.
                    lda #$03
                    sta RetryCount
RetryReadQSubcode:  jsr SPCallVector
                    bcc ReadQSubcodeSuccess
                    dec RetryCount
                    bne RetryReadQSubcode
                    bra ExitReadQSubcode

                    ; TODO: Analysis - What do these returned values actually represent?  Are the variable names being used here appropriate?
ReadQSubcodeSuccess:lda SPBuffer + 1
                    sta BCDRelTrack
                    lda SPBuffer + 3
                    sta BCDRelMinutes
                    lda SPBuffer + 4
                    sta BCDRelSeconds
                    lda SPBuffer + 6
                    sta BCDAbsMinutes
                    lda SPBuffer + 7
                    sta BCDAbsSeconds
                    lda SPBuffer + 8
                    sta BCDAbsFrame
                    lda SPBuffer + 2
                    ; TODO: Analysis - Is this value perhaps the Track Index?  Does Index 0 (gap/transition) get treated as a QSub read error?
                    beq ReadQSubcodeFail

                    ; Clear carry on success
                    clc
                    bra ExitReadQSubcode

                    ; Set carry on failure
ReadQSubcodeFail:   sec
ExitReadQSubcode:   rts

C23AudioStop:       lda #$00
                    sta DrivePlayingFlag

                    ; $04 = Control
                    lda #$04
                    sta SPCommandType
                    ; $23 = AudioStop
                    lda #$23
                    sta SPCode
                    ; Address type = $00 (Block), Block = 0
                    jsr ZeroOutSPBuffer
                    ; TODO: Analysis - What does an all-zeroes AudioStop call actually do?  Just clear any existing set stop point?  Explicitly stop playback now?  Something else?
                    jsr SPCallVector

                    ; $04 = Control
SetStopToEoBCDLTN:  lda #$04
                    sta SPCommandType
                    ; $23 = AudioStop
                    lda #$23
                    sta SPCode
                    jsr ZeroOutSPBuffer
                    ; Address = Last Track
                    lda BCDLastTrackNow
                    sta SPBuffer
                    ; Address Type = $02 (Track)
                    lda #$02
                    sta SPBuffer + 4
                    ; Set a stop point at EoT, last Track
                    jsr SPCallVector
                    rts

                    ; $04 = Control
C22AudioPause:      lda #$04
                    sta SPCommandType
                    ; $22 = AudoPause
                    lda #$22
                    sta SPCode
                    jsr ZeroOutSPBuffer

                    lda PauseButtonState
                    ; Invert the current Pause button state...
                    eor #$ff
                    ; and make it the Drive Playing state
                    sta DrivePlayingFlag
                    ; Mask off the low bit in order to use the new Drive Playing state value to set the Pause/Unpause parameter for the call
                    and #$01
                    ; $00 = Pause, $01 = UnPause/Resume (Button $00 = Paused, $FF = Unpaused)
                    sta SPBuffer
                    jsr SPCallVector
                    rts

                    ; $25 = AudioScan
C25AudioScanFwd:    lda #$25
                    sta SPCode
                    ; $04 = Control
                    lda #$04
                    sta SPCommandType
                    jsr ZeroOutSPBuffer

                    ; $00 = Forward
                    lda #$00
                    sta SPBuffer
                    ; Start from the current M/S/F
                    lda BCDAbsMinutes
                    sta SPBuffer + 4
                    lda BCDAbsSeconds
                    sta SPBuffer + 3
                    lda BCDAbsFrame
                    sta SPBuffer + 2
                    ; $01 = Type (MSF)
                    lda #$01
                    sta SPBuffer + 6
                    jsr SPCallVector
                    rts

                    ; $04 = Control
C25AudioScanBack:   lda #$04
                    sta SPCommandType
                    ; $25 = AudioScan
                    lda #$25
                    sta SPCode
                    jsr ZeroOutSPBuffer

                    ; $01 = Backward
                    lda #$01
                    sta SPBuffer
                    ; Start from the current M/S/F
                    lda BCDAbsMinutes
                    sta SPBuffer + 4
                    lda BCDAbsSeconds
                    sta SPBuffer + 3
                    lda BCDAbsFrame
                    sta SPBuffer + 2
                    ; $01 = Type (MSF)
                    lda #$01
                    sta SPBuffer + 6
                    jsr SPCallVector
                    rts

ZeroOutSPBuffer:    lda #$00
                    ldx #$0e
SPZeroLoop:         sta SPBuffer,x
                    dex
                    bpl SPZeroLoop
                    rts

                    ; Save state
ClearHGR1toWhite:   pha
                    phx
                    phy
                    lda ZP1
                    pha
                    lda ZP1 + 1
                    pha

                    ; (ZP1) = Memory address $2000/HGR1
                    lda #$00
                    sta ZP1
                    lda #$20
                    sta ZP1 + 1
                    ; X = $20 pages
                    ldx #$20

                    ; $20 (32) pages of 256 bytes = 8K
Loop8K:             ldy #$00

                    lda #$ff
                    ; 256 bytes of $FF (white)
Loop256:            sta (ZP1),y
                    iny
                    bne Loop256

                    clc
                    lda ZP1 + 1
                    adc #$01
                    sta ZP1 + 1
                    dex
                    bne Loop8K

                    ; Restore state and exit
                    pla
                    sta ZP1 + 1
                    pla
                    sta ZP1
                    ply
                    plx
                    pla
                    rts

FindHardware:       jsr FindSCSICard
                    bcs ExitFindHardware
                    jsr SmartPortCallSetup
                    jsr FindCDROM
ExitFindHardware:   rts

FindSCSICard:       lda #$07
CheckSlot:          sta CardSlot
                    and #$0f
                    ora #$c0
                    sta ZP1 + 1
                    lda #$fb
                    sta ZP1
                    lda (ZP1)
                    ; $82 = SCSI card, extended SP calls
                    cmp #$82
                    beq YesFound
                    lda CardSlot
                    dec a
                    bne CheckSlot
                    jsr NoSCSICardError
                    ; Set carry on error
                    sec
                    bra ExitFindSCSICard
                    ; Clear carry on success
YesFound:           clc
ExitFindSCSICard:   rts

NoSCSICardError:    lda ZP1
                    pha
                    lda ZP1 + 1
                    pha
                    lda NoSCSIMsgAddr
                    sta ZP1
                    lda NoSCSIMsgAddr + 1
                    sta ZP1 + 1
                    ldy #$00
NSCEPrintLoop:      lda (ZP1),y
                    beq NSCEKeyPressLoop
                    iny
                    ora #$80
                    jsr COUT
                    bra NSCEPrintLoop

                    ; TODO: Remove - This STA is bypassed, and can be removed.
                    sta KbdStrobe

NSCEKeyPressLoop:   lda KbdStrobe
                    bpl NSCEKeyPressLoop
                    pla
                    sta ZP1 + 1
                    pla
                    sta ZP1
                    rts

                    ; Bell
NoSCSICardMessage:  .byte   $0d, $07, $0d, $0a
                    ; CD Remote cannot run
                    .byte   $43, $44, $20, $52, $65, $6d, $6f, $74, $65, $20, $63, $61, $6e, $6e, $6f, $74, $20, $72, $75, $6e, $0d, $0a
                    ; No Apple SCSI card is installed
                    .byte   $4e, $6f, $20, $41, $70, $70, $6c, $65, $20, $53, $43, $53, $49, $20, $63, $61, $72, $64, $20, $69, $73, $20, $69, $6e, $73, $74, $61, $6c, $6c, $65, $64, $0d, $0a
                    ; Press any key to continue
                    .byte   $50, $72, $65, $73, $73, $20, $61, $6e, $79, $20, $6b, $65, $79, $20, $74, $6f, $20, $63, $6f, $6e, $74, $69, $6e, $75, $65
                    .byte   $00

NoSCSIMsgAddr:      .addr   NoSCSICardMessage

                    ; $00 = Status
FindCDROM:          lda #$00
                    sta SPCommandType

                    ; UnitNum = $00, StatusCode = $00 returns status of SmartPort itself
                    lda #$00
                    sta SPUnitNumber
                    sta SPCode

                    ; ParmCount = 3
                    lda #$03
                    sta SPParmCount

                    jsr SPCallVector

                    ; Byte offset $00 = Number of devices connected
                    ldx SPBuffer
                    ; $03 = Return Device Information Block (DIB), 25 bytes
                    lda #$03
                    sta SPCode

NextDevice:         stx CD_SPDevNum
                    stx SPUnitNumber
                    ; Make DIB call for current device
                    jsr SPCallVector

                    ; Byte 1 = Device status
                    lda SPBuffer
                    ; Force "online" bit true
                    ora #$10
                    ; $B4 = 10110100 = Block device, Not writeable, Readable, Can't format, Write protected (aka CD-ROM)
                    cmp #$b4
                    beq CDROMFound

                    ldx CD_SPDevNum
                    dex
                    bne NextDevice
                    jsr NoCDROMError
                    ; Set carry on failure
                    sec
                    bra ExitFindCDROM
                    ; Clear carry on success
CDROMFound:         clc
ExitFindCDROM:      rts

NoCDROMError:       lda ZP1
                    pha
                    lda ZP1 + 1
                    pha
                    lda NoCDROMMsgAddr
                    sta ZP1
                    lda NoCDROMMsgAddr + 1
                    sta ZP1 + 1
                    ldy #$00
NCDEPrintLoop:      lda (ZP1),y
                    beq NCDEKeyPressLoop
                    iny
                    ora #$80
                    jsr COUT
                    bra NCDEPrintLoop

                    ; TODO: Remove - This STA is bypassed, and can be removed.
                    sta KbdStrobe

NCDEKeyPressLoop:   lda KbdStrobe
                    bpl NCDEKeyPressLoop
                    pla
                    sta ZP1 + 1
                    pla
                    sta ZP1
                    rts

                    ; Bell
NoCDROMMessage:     .byte   $07, $0d, $0a
                    ; CD Remote cannot run
                    .byte   $43, $44, $20, $52, $65, $6d, $6f, $74, $65, $20, $63, $61, $6e, $6e, $6f, $74, $20, $72, $75, $6e, $0d, $0a
                    ; No Apple CD-ROM is attached or the disc is offline
                    .byte   $4e, $6f, $20, $41, $70, $70, $6c, $65, $20, $43, $44, $2d, $52, $4f, $4d, $20, $69, $73, $20, $61, $74, $74, $61, $63, $68, $65, $64, $20, $6f, $72, $0d, $74, $68, $65, $20, $64, $69, $73, $63, $20, $69, $73, $20, $6f, $66, $66, $6c, $69, $6e, $65, $0d, $0a
                    ; Press any key to continue
                    .byte   $50, $72, $65, $73, $73, $20, $61, $6e, $79, $20, $6b, $65, $79, $20, $74, $6f, $20, $63, $6f, $6e, $74, $69, $6e, $75, $65
                    .byte   $00

NoCDROMMsgAddr:     .addr   NoCDROMMessage

SmartPortCallSetup: pha
                    lda CardSlot
                    ora #$c0
                    sta SPCallVector + 2
                    sta SelfModLDA + 2
SelfModLDA:         lda CardROMByte
                    clc
                    adc #$03
                    sta SPCallVector + 1
                    pla
                    rts

MLIQUIT:            jsr MLIEntry
                    ; $65 = QUIT
MLICOMMAND:         .byte   $65
MLIPARMTABLE:       .addr   QuitParms

                    brk

QuitParms:          .byte   $04
                    .byte   $00
                    .addr   0000
                    .byte   $00
                    .addr   0000

SPCallVector:       jsr $0000

SPCommandType:      .byte   $00
SPParmsAddr:        .addr   SPParmCount

                    rts

                    ; SmartPort Parameter Table
SPParmCount:        .byte   $00
SPUnitNumber:       .byte   $00
SPBufferAddr:       .addr   SPBuffer
                    ; Status code for SPCommandType Status ($00), Control code for SPCommandType Control ($04)
SPCode:             .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    ; SP Command-specific data buffer
SPBuffer:           .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00

LargeGlyph0:        .byte   $70, $07, $78, $0f, $1c, $1c, $0c, $18, $0c, $18, $0c, $18, $0c, $18, $0c, $18, $0c, $18, $0c, $18, $0c, $18, $1c, $1c, $78, $0f, $70, $07, $00, $00, $00, $00
LargeGlyph1:        .byte   $40, $01, $60, $01, $70, $01, $70, $01, $40, $01, $40, $01, $40, $01, $40, $01, $40, $01, $40, $01, $40, $01, $40, $01, $70, $07, $70, $07, $00, $00, $00, $00
LargeGlyph2:        .byte   $70, $07, $78, $0f, $1c, $1c, $0c, $18, $00, $18, $00, $1c, $40, $0f, $60, $07, $70, $00, $38, $00, $1c, $00, $0c, $00, $7c, $0f, $7c, $0f, $00, $00, $00, $00
LargeGlyph3:        .byte   $70, $07, $78, $0f, $1c, $1c, $0c, $18, $00, $18, $00, $1c, $40, $0f, $40, $0f, $00, $1c, $00, $18, $0c, $18, $1c, $1c, $78, $0f, $70, $07, $00, $00, $00, $00
LargeGlyph4:        .byte   $00, $06, $00, $07, $40, $07, $60, $07, $70, $06, $38, $06, $1c, $06, $0c, $06, $7c, $1f, $7c, $1f, $00, $06, $00, $06, $00, $06, $00, $06, $00, $00, $00, $00
LargeGlyph5:        .byte   $7c, $0f, $7c, $0f, $0c, $00, $0c, $00, $0c, $00, $7c, $07, $7c, $0f, $00, $1c, $00, $18, $00, $18, $0c, $18, $1c, $1c, $78, $0f, $70, $07, $00, $00, $00, $00
LargeGlyph6:        .byte   $70, $07, $78, $07, $1c, $00, $0c, $00, $0c, $00, $0c, $00, $7c, $07, $7c, $0f, $1c, $1c, $0c, $18, $0c, $18, $1c, $1c, $78, $0f, $70, $07, $00, $00, $00, $00
LargeGlyph7:        .byte   $7c, $1f, $7c, $1f, $00, $18, $00, $1c, $00, $0e, $00, $07, $40, $03, $60, $01, $70, $00, $30, $00, $30, $00, $30, $00, $30, $00, $30, $00, $00, $00, $00, $00
LargeGlyph8:        .byte   $70, $07, $78, $0f, $1c, $1c, $0c, $18, $0c, $18, $1c, $1c, $78, $0f, $78, $0f, $1c, $1c, $0c, $18, $0c, $18, $1c, $1c, $78, $0f, $70, $07, $00, $00, $00, $00
LargeGlyph9:        .byte   $70, $07, $78, $0f, $1c, $1c, $0c, $18, $0c, $18, $1c, $1c, $78, $1f, $70, $1f, $00, $1c, $00, $1c, $00, $0e, $00, $07, $70, $03, $70, $01, $00, $00, $00, $00
LargeGlyphBlank:    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00

Glyph0:             .byte   $1c, $22, $22, $22, $22, $22, $1c, $00
Glyph1:             .byte   $08, $0c, $08, $08, $08, $08, $1c, $00
Glyph2:             .byte   $1c, $22, $20, $18, $04, $02, $1e, $00
Glyph3:             .byte   $1c, $22, $20, $18, $20, $22, $1c, $00
Glyph4:             .byte   $10, $18, $14, $12, $3e, $10, $10, $00
Glyph5:             .byte   $1e, $02, $1e, $20, $20, $22, $1c, $00
Glyph6:             .byte   $1c, $02, $02, $1e, $22, $22, $1c, $00
Glyph7:             .byte   $3e, $20, $10, $08, $04, $04, $04, $00
Glyph8:             .byte   $1c, $22, $22, $1c, $22, $22, $1c, $00
Glyph9:             .byte   $1c, $22, $22, $3c, $20, $10, $0c, $00
GlyphBlank:         .byte   $00, $00, $00, $00, $00, $00, $00, $00
GlyphColon:         .byte   $00, $00, $08, $00, $08, $00, $00, $00

CDRemoteUI:         .byte   $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff
                    .byte   $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff
                    .byte   $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff
                    .byte   $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff
                    .byte   $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff
                    .byte   $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff
                    .byte   $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff
                    .byte   $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff
                    .byte   $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff
                    .byte   $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff
                    .byte   $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff
                    .byte   $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff
                    .byte   $01, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $00, $1c, $1e, $00, $1e, $00, $00, $00, $04, $00, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $00, $22, $22, $00, $22, $00, $00, $00, $1e, $00, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $00, $02, $22, $00, $22, $1c, $36, $1c, $04, $1c, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $00, $02, $22, $00, $1e, $22, $2a, $22, $04, $22, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $00, $02, $22, $00, $0a, $1c, $2a, $22, $04, $1c, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $00, $22, $22, $00, $12, $02, $2a, $22, $24, $02, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $00, $1c, $1e, $00, $22, $1c, $2a, $1c, $18, $1c, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $40, $ff, $ff
                    .byte   $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff
                    .byte   $01, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $1c, $04, $00, $00, $00, $00, $1e, $0c, $00, $00, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $22, $1e, $00, $00, $00, $00, $22, $08, $00, $00, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $02, $04, $1c, $1e, $00, $00, $22, $08, $1c, $22, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $1c, $04, $22, $22, $00, $00, $1e, $08, $20, $22, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $20, $04, $22, $22, $00, $00, $02, $08, $1c, $22, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $22, $24, $22, $1e, $00, $00, $02, $08, $22, $3c, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $1c, $18, $1c, $02, $00, $00, $02, $1c, $1c, $20, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $00, $00, $00, $02, $00, $00, $00, $00, $00, $1c, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $fc, $ff, $ff, $ff, $3f, $00, $fe, $ff, $ff, $ff, $1f, $00, $40, $ff, $ff
                    .byte   $01, $00, $04, $00, $00, $00, $20, $00, $02, $00, $00, $00, $10, $00, $40, $ff, $ff
                    .byte   $01, $00, $04, $00, $3f, $00, $20, $00, $02, $00, $03, $00, $10, $00, $40, $ff, $ff
                    .byte   $01, $00, $04, $00, $3f, $00, $20, $00, $02, $00, $0f, $00, $10, $00, $40, $ff, $ff
                    .byte   $01, $00, $04, $00, $3f, $00, $20, $00, $02, $00, $3f, $00, $10, $00, $40, $ff, $ff
                    .byte   $01, $00, $04, $00, $3f, $00, $20, $00, $02, $00, $0f, $00, $10, $00, $40, $ff, $ff
                    .byte   $01, $00, $04, $00, $3f, $00, $20, $00, $02, $00, $03, $00, $10, $00, $40, $ff, $ff
                    .byte   $01, $00, $04, $00, $00, $00, $20, $00, $02, $00, $00, $00, $10, $00, $40, $ff, $ff
                    .byte   $01, $00, $fc, $ff, $ff, $ff, $3f, $00, $fe, $ff, $ff, $ff, $1f, $00, $40, $ff, $ff
                    .byte   $01, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $3e, $20, $00, $00, $04, $00, $1e, $00, $00, $00, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $02, $00, $00, $00, $1e, $00, $22, $00, $00, $00, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $02, $30, $1c, $3c, $04, $00, $22, $1c, $22, $1c, $1c, $00, $40, $ff, $ff
                    .byte   $01, $00, $1e, $20, $22, $02, $04, $00, $1e, $20, $22, $02, $22, $00, $40, $ff, $ff
                    .byte   $01, $00, $02, $20, $1c, $02, $04, $00, $02, $1c, $22, $1c, $1c, $00, $40, $ff, $ff
                    .byte   $01, $00, $02, $20, $02, $02, $24, $00, $02, $22, $32, $20, $02, $00, $40, $ff, $ff
                    .byte   $01, $00, $3e, $24, $1c, $3c, $18, $00, $02, $1c, $2c, $1c, $1c, $00, $40, $ff, $ff
                    .byte   $01, $00, $00, $18, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $fc, $ff, $ff, $ff, $3f, $00, $fe, $ff, $ff, $ff, $1f, $00, $40, $ff, $ff
                    .byte   $01, $00, $04, $00, $00, $00, $20, $00, $02, $00, $00, $00, $10, $00, $40, $ff, $ff
                    .byte   $01, $00, $04, $00, $3e, $00, $20, $00, $02, $40, $73, $00, $10, $00, $40, $ff, $ff
                    .byte   $01, $00, $04, $00, $00, $00, $20, $00, $02, $40, $73, $00, $10, $00, $40, $ff, $ff
                    .byte   $01, $00, $04, $00, $3e, $00, $20, $00, $02, $40, $73, $00, $10, $00, $40, $ff, $ff
                    .byte   $01, $00, $04, $00, $00, $00, $20, $00, $02, $40, $73, $00, $10, $00, $40, $ff, $ff
                    .byte   $01, $00, $04, $00, $3e, $00, $20, $00, $02, $40, $73, $00, $10, $00, $40, $ff, $ff
                    .byte   $01, $00, $04, $00, $00, $00, $20, $00, $02, $00, $00, $00, $10, $00, $40, $ff, $ff
                    .byte   $01, $00, $fc, $ff, $ff, $ff, $3f, $00, $fe, $ff, $ff, $ff, $1f, $00, $40, $ff, $ff
                    .byte   $01, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $40, $ff, $ff
                    .byte   $01, $fc, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $1f, $40, $ff, $ff
                    .byte   $01, $04, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $10, $40, $ff, $ff
                    .byte   $01, $04, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $10, $40, $ff, $ff
                    .byte   $01, $04, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $10, $40, $ff, $ff
                    .byte   $01, $04, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $10, $40, $ff, $ff
                    .byte   $01, $04, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $10, $40, $ff, $ff
                    .byte   $01, $04, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $10, $40, $ff, $ff
                    .byte   $01, $04, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $10, $40, $ff, $ff
                    .byte   $01, $04, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $10, $40, $ff, $ff
                    .byte   $01, $04, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $10, $40, $ff, $ff
                    .byte   $01, $04, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $10, $40, $ff, $ff
                    .byte   $01, $04, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $10, $40, $ff, $ff
                    .byte   $01, $04, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $10, $40, $ff, $ff
                    .byte   $01, $04, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $10, $40, $ff, $ff
                    .byte   $01, $04, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $10, $40, $ff, $ff
                    .byte   $01, $04, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $10, $40, $ff, $ff
                    .byte   $01, $04, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $10, $40, $ff, $ff
                    .byte   $01, $04, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $10, $40, $ff, $ff
                    .byte   $01, $04, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $10, $40, $ff, $ff
                    .byte   $01, $04, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $10, $40, $ff, $ff
                    .byte   $01, $04, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $10, $40, $ff, $ff
                    .byte   $01, $04, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $10, $40, $ff, $ff
                    .byte   $01, $04, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $10, $40, $ff, $ff
                    .byte   $01, $04, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $10, $40, $ff, $ff
                    .byte   $01, $04, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $10, $40, $ff, $ff
                    .byte   $01, $04, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $10, $40, $ff, $ff
                    .byte   $01, $04, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $10, $40, $ff, $ff
                    .byte   $01, $fc, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $1f, $40, $ff, $ff
                    .byte   $01, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $00, $00, $00, $3e, $00, $00, $00, $02, $00, $00, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $00, $00, $00, $08, $00, $00, $00, $02, $00, $00, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $00, $00, $00, $08, $1a, $1c, $3c, $12, $00, $00, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $00, $00, $00, $08, $06, $20, $02, $0a, $00, $00, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $00, $00, $00, $08, $02, $1c, $02, $06, $00, $00, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $00, $00, $00, $08, $02, $22, $02, $0a, $00, $00, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $00, $00, $00, $08, $02, $1c, $3c, $12, $00, $00, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $fc, $ff, $ff, $ff, $3f, $00, $fe, $ff, $ff, $ff, $1f, $00, $40, $ff, $ff
                    .byte   $01, $00, $04, $00, $00, $00, $20, $00, $02, $00, $00, $00, $10, $00, $40, $ff, $ff
                    .byte   $01, $00, $04, $00, $30, $00, $20, $00, $02, $00, $03, $00, $10, $00, $40, $ff, $ff
                    .byte   $01, $00, $04, $00, $3c, $00, $20, $00, $02, $00, $0f, $00, $10, $00, $40, $ff, $ff
                    .byte   $01, $00, $04, $00, $3f, $00, $20, $00, $02, $00, $3f, $00, $10, $00, $40, $ff, $ff
                    .byte   $01, $00, $04, $00, $3c, $00, $20, $00, $02, $00, $0f, $00, $10, $00, $40, $ff, $ff
                    .byte   $01, $00, $04, $00, $30, $00, $20, $00, $02, $00, $03, $00, $10, $00, $40, $ff, $ff
                    .byte   $01, $00, $04, $00, $00, $00, $20, $00, $02, $00, $00, $00, $10, $00, $40, $ff, $ff
                    .byte   $01, $00, $fc, $ff, $ff, $ff, $3f, $00, $fe, $ff, $ff, $ff, $1f, $00, $40, $ff, $ff
                    .byte   $01, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $00, $00, $00, $1c, $00, $00, $00, $00, $00, $00, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $00, $00, $00, $22, $00, $00, $00, $00, $00, $00, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $00, $00, $00, $02, $3c, $1c, $1e, $00, $00, $00, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $00, $00, $00, $1c, $02, $20, $22, $00, $00, $00, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $00, $00, $00, $20, $02, $1c, $22, $00, $00, $00, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $00, $00, $00, $22, $02, $22, $22, $00, $00, $00, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $00, $00, $00, $1c, $3c, $1c, $22, $00, $00, $00, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $fc, $ff, $ff, $ff, $3f, $00, $fe, $ff, $ff, $ff, $1f, $00, $40, $ff, $ff
                    .byte   $01, $00, $04, $00, $00, $00, $20, $00, $02, $00, $00, $00, $10, $00, $40, $ff, $ff
                    .byte   $01, $00, $04, $00, $06, $06, $20, $00, $02, $30, $30, $00, $10, $00, $40, $ff, $ff
                    .byte   $01, $00, $04, $40, $47, $07, $20, $00, $02, $70, $71, $01, $10, $00, $40, $ff, $ff
                    .byte   $01, $00, $04, $70, $77, $07, $20, $00, $02, $70, $77, $07, $10, $00, $40, $ff, $ff
                    .byte   $01, $00, $04, $40, $47, $07, $20, $00, $02, $70, $71, $01, $10, $00, $40, $ff, $ff
                    .byte   $01, $00, $04, $00, $06, $06, $20, $00, $02, $30, $30, $00, $10, $00, $40, $ff, $ff
                    .byte   $01, $00, $04, $00, $00, $00, $20, $00, $02, $00, $00, $00, $10, $00, $40, $ff, $ff
                    .byte   $01, $00, $fc, $ff, $ff, $ff, $3f, $00, $fe, $ff, $ff, $ff, $1f, $00, $40, $ff, $ff
                    .byte   $01, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $02, $00, $00, $00, $00, $70, $01, $00, $00, $02, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $02, $00, $00, $00, $00, $10, $02, $00, $00, $02, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $02, $1c, $1c, $1e, $00, $10, $62, $71, $61, $63, $31, $03, $40, $ff, $ff
                    .byte   $01, $00, $02, $22, $22, $22, $00, $70, $01, $12, $12, $12, $52, $02, $40, $ff, $ff
                    .byte   $01, $00, $02, $22, $22, $22, $00, $50, $60, $11, $12, $12, $52, $02, $40, $ff, $ff
                    .byte   $01, $00, $02, $22, $22, $1e, $00, $10, $11, $12, $12, $12, $52, $02, $40, $ff, $ff
                    .byte   $01, $00, $3e, $1c, $1c, $02, $00, $10, $62, $11, $62, $63, $51, $02, $40, $ff, $ff
                    .byte   $01, $00, $00, $00, $00, $02, $00, $00, $00, $00, $00, $00, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $fc, $ff, $ff, $ff, $3f, $00, $fe, $ff, $ff, $ff, $1f, $00, $40, $ff, $ff
                    .byte   $01, $00, $04, $00, $00, $00, $20, $00, $02, $00, $00, $00, $10, $00, $40, $ff, $ff
                    .byte   $01, $00, $04, $70, $7f, $03, $20, $00, $02, $70, $1f, $00, $10, $00, $40, $ff, $ff
                    .byte   $01, $00, $04, $00, $00, $04, $20, $00, $02, $00, $7c, $07, $10, $00, $40, $ff, $ff
                    .byte   $01, $00, $04, $00, $18, $04, $20, $00, $02, $70, $1f, $00, $10, $00, $40, $ff, $ff
                    .byte   $01, $00, $04, $00, $7e, $03, $20, $00, $02, $00, $7c, $07, $10, $00, $40, $ff, $ff
                    .byte   $01, $00, $04, $00, $18, $00, $20, $00, $02, $70, $1f, $00, $10, $00, $40, $ff, $ff
                    .byte   $01, $00, $04, $00, $00, $00, $20, $00, $02, $00, $00, $00, $10, $00, $40, $ff, $ff
                    .byte   $01, $00, $fc, $ff, $ff, $ff, $3f, $00, $fe, $ff, $ff, $ff, $1f, $00, $40, $ff, $ff
                    .byte   $01, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $40, $ff, $ff
                    .byte   $01, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $40, $ff, $ff
                    .byte   $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff
                    .byte   $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff
                    .byte   $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff
                    .byte   $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff
                    .byte   $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff
                    .byte   $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff
                    .byte   $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff
                    .byte   $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff
                    .byte   $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff
                    .byte   $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff
                    .byte   $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff
                    .byte   $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff
                    .byte   $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff
                    .byte   $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff
                    .byte   $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff
                    .byte   $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff
                    .byte   $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff
                    .byte   $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff
                    .byte   $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff
                    .byte   $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff
                    .byte   $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff
                    .byte   $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff

StopButtonMask:     .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $f8, $ff, $ff, $ff, $1f, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $f8, $ff, $ff, $ff, $1f, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $f8, $ff, $ff, $ff, $1f, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $f8, $ff, $ff, $ff, $1f, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $f8, $ff, $ff, $ff, $1f, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $f8, $ff, $ff, $ff, $1f, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $f8, $ff, $ff, $ff, $1f, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00

PlayButtonMask:     .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $fc, $ff, $ff, $ff, $0f, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $fc, $ff, $ff, $ff, $0f, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $fc, $ff, $ff, $ff, $0f, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $fc, $ff, $ff, $ff, $0f, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $fc, $ff, $ff, $ff, $0f, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $fc, $ff, $ff, $ff, $0f, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $fc, $ff, $ff, $ff, $0f, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00

EjectButtonMask:    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $f8, $ff, $ff, $ff, $1f, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $f8, $ff, $ff, $ff, $1f, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $f8, $ff, $ff, $ff, $1f, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $f8, $ff, $ff, $ff, $1f, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $f8, $ff, $ff, $ff, $1f, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $f8, $ff, $ff, $ff, $1f, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $f8, $ff, $ff, $ff, $1f, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00

PauseButtonMask:    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $fc, $ff, $ff, $ff, $0f, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $fc, $ff, $ff, $ff, $0f, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $fc, $ff, $ff, $ff, $0f, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $fc, $ff, $ff, $ff, $0f, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $fc, $ff, $ff, $ff, $0f, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $fc, $ff, $ff, $ff, $0f, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $fc, $ff, $ff, $ff, $0f, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00

PrevTrackButtonMask:.byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $f8, $ff, $ff, $ff, $1f, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $f8, $ff, $ff, $ff, $1f, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $f8, $ff, $ff, $ff, $1f, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $f8, $ff, $ff, $ff, $1f, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $f8, $ff, $ff, $ff, $1f, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $f8, $ff, $ff, $ff, $1f, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $f8, $ff, $ff, $ff, $1f, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00

NextTrackButtonMask:.byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $fc, $ff, $ff, $ff, $0f, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $fc, $ff, $ff, $ff, $0f, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $fc, $ff, $ff, $ff, $0f, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $fc, $ff, $ff, $ff, $0f, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $fc, $ff, $ff, $ff, $0f, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $fc, $ff, $ff, $ff, $0f, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $fc, $ff, $ff, $ff, $0f, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00

ScanBackButtonMask: .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $f8, $ff, $ff, $ff, $1f, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $f8, $ff, $ff, $ff, $1f, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $f8, $ff, $ff, $ff, $1f, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $f8, $ff, $ff, $ff, $1f, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $f8, $ff, $ff, $ff, $1f, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $f8, $ff, $ff, $ff, $1f, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $f8, $ff, $ff, $ff, $1f, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00

ScanFwdButtonMask:  .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $fc, $ff, $ff, $ff, $0f, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $fc, $ff, $ff, $ff, $0f, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $fc, $ff, $ff, $ff, $0f, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $fc, $ff, $ff, $ff, $0f, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $fc, $ff, $ff, $ff, $0f, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $fc, $ff, $ff, $ff, $0f, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $fc, $ff, $ff, $ff, $0f, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00

LoopButtonMask:     .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $f8, $ff, $ff, $ff, $1f, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $f8, $ff, $ff, $ff, $1f, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $f8, $ff, $ff, $ff, $1f, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $f8, $ff, $ff, $ff, $1f, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $f8, $ff, $ff, $ff, $1f, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $f8, $ff, $ff, $ff, $1f, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $f8, $ff, $ff, $ff, $1f, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00

RandomButtonMask:   .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $fc, $ff, $ff, $ff, $0f, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $fc, $ff, $ff, $ff, $0f, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $fc, $ff, $ff, $ff, $0f, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $fc, $ff, $ff, $ff, $0f, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $fc, $ff, $ff, $ff, $0f, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $fc, $ff, $ff, $ff, $0f, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $fc, $ff, $ff, $ff, $0f, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00

CDRemoteMenu:       .byte   $00, $00, $00, $1c, $1e, $00, $1e, $00, $00, $00, $04, $00, $00, $22, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $22, $22, $00, $22, $00, $00, $00, $1e, $00, $00, $36, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $02, $22, $00, $22, $1c, $36, $1c, $04, $1c, $00, $2a, $1c, $1e, $22, $00, $00, $00
                    .byte   $00, $00, $00, $02, $22, $00, $1e, $22, $2a, $22, $04, $22, $00, $22, $22, $22, $22, $00, $00, $00
                    .byte   $00, $00, $00, $02, $22, $00, $0a, $3e, $2a, $22, $04, $3e, $00, $22, $3e, $22, $22, $00, $00, $00
                    .byte   $00, $00, $00, $22, $22, $00, $12, $02, $2a, $22, $24, $02, $00, $22, $02, $22, $32, $00, $00, $00
                    .byte   $00, $00, $00, $1c, $1e, $00, $22, $1c, $2a, $1c, $18, $1c, $00, $22, $1c, $22, $2c, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $1c, $00, $00, $1c, $04, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $22, $00, $00, $22, $1e, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $02, $00, $00, $02, $04, $1c, $1e, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $1c, $00, $00, $1c, $04, $22, $22, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $20, $00, $00, $20, $04, $22, $22, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $22, $00, $00, $22, $24, $22, $1e, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $1c, $00, $00, $1c, $18, $1c, $02, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $02, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $1e, $00, $00, $1e, $0c, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $22, $00, $00, $22, $08, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $22, $00, $00, $22, $08, $1c, $22, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $1e, $00, $00, $1e, $08, $20, $22, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $02, $00, $00, $02, $08, $3c, $22, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $02, $00, $00, $02, $08, $22, $3c, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $02, $00, $00, $02, $1c, $3c, $20, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $1c, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $3e, $00, $00, $3e, $20, $00, $00, $04, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $02, $00, $00, $02, $00, $00, $00, $1e, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $02, $00, $00, $02, $30, $1c, $3c, $04, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $1e, $00, $00, $1e, $20, $22, $02, $04, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $02, $00, $00, $02, $20, $3e, $02, $04, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $02, $00, $00, $02, $20, $02, $02, $24, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $3e, $00, $00, $3e, $24, $1c, $3c, $18, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $18, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $1e, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $4c, $11, $32, $00, $22, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $42, $2a, $15, $00, $22, $1c, $22, $1c, $1c, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $4c, $29, $31, $00, $1e, $20, $22, $02, $22, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $50, $38, $15, $00, $02, $3c, $22, $1c, $3e, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $4c, $28, $32, $00, $02, $22, $32, $20, $02, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $02, $3c, $2c, $1c, $1c, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $3e, $00, $00, $00, $02, $00, $22, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $08, $00, $00, $00, $02, $00, $22, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $10, $00, $00, $08, $1a, $1c, $3c, $12, $00, $22, $1e, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $30, $00, $00, $08, $06, $20, $02, $0a, $00, $22, $22, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $7e, $00, $00, $08, $02, $3c, $02, $06, $00, $22, $22, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $30, $00, $00, $08, $02, $22, $02, $0a, $00, $22, $1e, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $10, $00, $00, $08, $02, $3c, $3c, $12, $00, $1c, $02, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $02, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $3e, $00, $00, $00, $02, $00, $1e, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $08, $00, $00, $00, $02, $00, $22, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $08, $00, $00, $08, $1a, $1c, $3c, $12, $00, $22, $1c, $22, $1e, $00, $00, $00, $00, $00
                    .byte   $00, $00, $0c, $00, $00, $08, $06, $20, $02, $0a, $00, $22, $22, $22, $22, $00, $00, $00, $00, $00
                    .byte   $00, $00, $7e, $00, $00, $08, $02, $3c, $02, $06, $00, $22, $22, $2a, $22, $00, $00, $00, $00, $00
                    .byte   $00, $00, $0c, $00, $00, $08, $02, $22, $02, $0a, $00, $22, $22, $2a, $22, $00, $00, $00, $00, $00
                    .byte   $00, $00, $08, $00, $00, $08, $02, $3c, $3c, $12, $00, $1e, $1c, $14, $22, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $10, $00, $00, $1c, $00, $00, $00, $00, $3e, $00, $00, $00, $00, $00, $20, $00, $00, $00
                    .byte   $00, $00, $08, $00, $00, $22, $00, $00, $00, $00, $02, $00, $00, $00, $00, $00, $20, $00, $00, $00
                    .byte   $00, $00, $36, $10, $00, $02, $3c, $1c, $1e, $00, $02, $1c, $1a, $22, $1c, $1a, $3c, $00, $00, $00
                    .byte   $00, $00, $49, $30, $00, $1c, $02, $20, $22, $00, $1e, $22, $06, $22, $20, $06, $22, $00, $00, $00
                    .byte   $00, $00, $21, $7e, $00, $20, $02, $3c, $22, $00, $02, $22, $02, $2a, $3c, $02, $22, $00, $00, $00
                    .byte   $00, $00, $41, $30, $00, $22, $02, $22, $22, $00, $02, $22, $02, $2a, $22, $02, $22, $00, $00, $00
                    .byte   $00, $00, $2a, $10, $00, $1c, $3c, $3c, $22, $00, $02, $1c, $02, $14, $3c, $02, $3c, $00, $00, $00
                    .byte   $00, $00, $14, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $10, $00, $00, $1c, $00, $00, $00, $00, $1e, $00, $00, $02, $00, $00, $00, $20, $00, $00
                    .byte   $00, $00, $08, $00, $00, $22, $00, $00, $00, $00, $22, $00, $00, $02, $00, $00, $00, $20, $00, $00
                    .byte   $00, $00, $36, $08, $00, $02, $3c, $1c, $1e, $00, $22, $1c, $3c, $12, $22, $1c, $1a, $3c, $00, $00
                    .byte   $00, $00, $49, $0c, $00, $1c, $02, $20, $22, $00, $1e, $20, $02, $0a, $22, $20, $06, $22, $00, $00
                    .byte   $00, $00, $21, $7e, $00, $20, $02, $3c, $22, $00, $22, $3c, $02, $06, $2a, $3c, $02, $22, $00, $00
                    .byte   $00, $00, $41, $0c, $00, $22, $02, $22, $22, $00, $22, $22, $02, $0a, $2a, $22, $02, $22, $00, $00
                    .byte   $00, $00, $2a, $08, $00, $1c, $3c, $3c, $22, $00, $1e, $3c, $3c, $12, $14, $3c, $02, $3c, $00, $00
                    .byte   $00, $00, $14, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $02, $00, $00, $1c, $00, $00, $04, $08, $00, $00, $00, $00, $00, $00, $1e, $0c, $00, $00
                    .byte   $00, $00, $02, $00, $00, $22, $00, $00, $1e, $00, $00, $00, $00, $00, $00, $00, $22, $08, $00, $00
                    .byte   $00, $00, $02, $00, $00, $02, $1c, $1e, $04, $08, $1e, $22, $1c, $22, $1c, $00, $22, $08, $1c, $22
                    .byte   $00, $00, $02, $00, $00, $02, $22, $22, $04, $08, $22, $22, $22, $22, $02, $00, $1e, $08, $20, $22
                    .byte   $00, $00, $02, $00, $00, $02, $22, $22, $04, $08, $22, $22, $22, $22, $1c, $00, $02, $08, $3c, $22
                    .byte   $00, $00, $02, $00, $00, $22, $22, $22, $24, $08, $22, $32, $22, $32, $20, $00, $02, $08, $22, $3c
                    .byte   $00, $00, $3e, $00, $00, $1c, $1c, $22, $18, $08, $22, $2c, $1c, $2c, $1c, $00, $02, $1c, $3c, $20
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $1c
                    .byte   $00, $00, $1e, $00, $00, $1e, $00, $00, $20, $00, $00, $00, $1e, $0c, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $22, $00, $00, $22, $00, $00, $20, $00, $00, $00, $22, $08, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $22, $00, $00, $22, $1c, $1e, $3c, $1c, $36, $00, $22, $08, $1c, $22, $00, $00, $00, $00
                    .byte   $00, $00, $1e, $00, $00, $1e, $20, $22, $22, $22, $2a, $00, $1e, $08, $20, $22, $00, $00, $00, $00
                    .byte   $00, $00, $0a, $00, $00, $0a, $3c, $22, $22, $22, $2a, $00, $02, $08, $3c, $22, $00, $00, $00, $00
                    .byte   $00, $00, $12, $00, $00, $12, $22, $22, $22, $22, $2a, $00, $02, $08, $22, $3c, $00, $00, $00, $00
                    .byte   $00, $00, $22, $00, $00, $22, $3c, $22, $3c, $1c, $2a, $00, $02, $1c, $3c, $20, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $1c, $00, $00, $00, $00
                    .byte   $00, $00, $1c, $00, $00, $1c, $00, $08, $04, $00, $1c, $1e, $00, $1e, $00, $00, $00, $04, $00, $00
                    .byte   $00, $00, $22, $00, $00, $22, $00, $00, $1e, $00, $22, $22, $00, $22, $00, $00, $00, $1e, $00, $00
                    .byte   $00, $00, $22, $00, $00, $22, $22, $08, $04, $00, $02, $22, $00, $22, $1c, $36, $1c, $04, $1c, $00
                    .byte   $00, $00, $22, $00, $00, $22, $22, $08, $04, $00, $02, $22, $00, $1e, $22, $2a, $22, $04, $22, $00
                    .byte   $00, $00, $2a, $00, $00, $2a, $22, $08, $04, $00, $02, $22, $00, $0a, $3e, $2a, $22, $04, $3e, $00
                    .byte   $00, $00, $12, $00, $00, $12, $32, $08, $24, $00, $22, $22, $00, $12, $02, $2a, $22, $24, $02, $00
                    .byte   $00, $00, $2c, $00, $00, $2c, $2c, $08, $18, $00, $1c, $1e, $00, $22, $1c, $2a, $1c, $18, $1c, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00

HGRBaseAddrTable:   .byte   $20, $00
                    .byte   $20, $80
                    .byte   $21, $00
                    .byte   $21, $80
                    .byte   $22, $00
                    .byte   $22, $80
                    .byte   $23, $00
                    .byte   $23, $80
                    .byte   $20, $28
                    .byte   $20, $a8
                    .byte   $21, $28
                    .byte   $21, $a8
                    .byte   $22, $28
                    .byte   $22, $a8
                    .byte   $23, $28
                    .byte   $23, $a8
                    .byte   $20, $50
                    .byte   $20, $d0
                    .byte   $21, $50
                    .byte   $21, $d0
                    .byte   $22, $50
                    .byte   $22, $d0
                    .byte   $23, $50
                    .byte   $23, $d0

CDRemoteUIAddr:     .addr   CDRemoteUI
CDRemoteMenuAddr:   .addr   CDRemoteMenu
HGRBaseTableAddr:   .addr   HGRBaseAddrTable

LrgDigitGlyphTable: .addr   LargeGlyph0
                    .addr   LargeGlyph1
                    .addr   LargeGlyph2
                    .addr   LargeGlyph3
                    .addr   LargeGlyph4
                    .addr   LargeGlyph5
                    .addr   LargeGlyph6
                    .addr   LargeGlyph7
                    .addr   LargeGlyph8
                    .addr   LargeGlyph9
LrgBlankGlyphAddr:  .addr   LargeGlyphBlank

DigitGlyphTable:    .addr   Glyph0
                    .addr   Glyph1
                    .addr   Glyph2
                    .addr   Glyph3
                    .addr   Glyph4
                    .addr   Glyph5
                    .addr   Glyph6
                    .addr   Glyph7
                    .addr   Glyph8
                    .addr   Glyph9
BlankGlyphAddr:     .addr   GlyphBlank
ColonGlyphAddr:     .addr   GlyphColon

StopButtonAddr:     .addr   StopButtonMask
PlayButtonAddr:     .addr   PlayButtonMask
EjectButtonAddr:    .addr   EjectButtonMask
PauseButtonAddr:    .addr   PauseButtonMask
PrevTrackButtonAddr:.addr   PrevTrackButtonMask
NextTrackButtonAddr:.addr   NextTrackButtonMask
ScanBackButtonAddr: .addr   ScanBackButtonMask
ScanFwdButtonAddr:  .addr   ScanFwdButtonMask
LoopButtonAddr:     .addr   LoopButtonMask
RandomButtonAddr:   .addr   RandomButtonMask

                    ; Variables used during various UI paint and highlight/unhighlight operations
UIOperationVar1:    .byte   $00
UIOperationVar2:    .byte   $00
UIOperationVar3:    .byte   $00

PaintCDRemoteUI:    pha
                    phx
                    phy

                    ; (ZP1) = CDRemoteUIAddr
                    lda CDRemoteUIAddr
                    sta ZP1
                    lda CDRemoteUIAddr + 1
                    sta ZP1 + 1

                    ; (ZP2) = HGRBaseTable
                    lda HGRBaseTableAddr
                    sta ZP2
                    lda HGRBaseTableAddr + 1
                    sta ZP2 + 1

                    ; Starting offset into HGR base address table
                    ldy #$00
                    ; Number of sets of 8 lines to iterate (24 x 8 = 192)
                    ldx #$18
                    ; Width of paint area
                    lda #$17
                    sta UIOperationVar1

                    ; (ZP3) = HGR Base Address n
PaintUILoop:        lda (ZP2),y
                    sta ZP3 + 1
                    iny
                    lda (ZP2),y
                    sta ZP3
                    iny

                    jsr PaintUISub

                    dex
                    bne PaintUILoop

                    ply
                    plx
                    pla
                    rts

DrawTrack:          pha
                    phx
                    phy

                    ; Draw track tens digit at X offset of $19
                    lda BCDRelTrack
                    and #$f0
                    clc
                    ror a
                    ror a
                    ror a
                    tax
                    lda LrgDigitGlyphTable,x
                    sta ZP1
                    lda LrgDigitGlyphTable + 1,x
                    sta ZP1 + 1
                    ldx #$19
                    jsr DrawLargeGlyph

                    ; Draw track ones digit at X offset of $1B
                    lda BCDRelTrack
                    and #$0f
                    clc
                    rol a
                    tax
                    lda LrgDigitGlyphTable,x
                    sta ZP1
                    lda LrgDigitGlyphTable + 1,x
                    sta ZP1 + 1
                    ldx #$1b
                    jsr DrawLargeGlyph

                    ply
                    plx
                    pla
                    rts

DrawTime:           pha
                    phx
                    phy

                    ; Draw minutes value at X offset of $1E/$1F
                    lda BCDRelMinutes
                    jsr HighDigitIntoZP1
                    ldx #$1e
                    jsr DrawDigitAtX

                    lda BCDRelMinutes
                    jsr LowDigitIntoZP1
                    ldx #$1f
                    jsr DrawDigitAtX

                    ; Draw seconds value at X offset of $21/$22
                    lda BCDRelSeconds
                    jsr HighDigitIntoZP1
                    ldx #$21
                    jsr DrawDigitAtX

                    lda BCDRelSeconds
                    jsr LowDigitIntoZP1
                    ldx #$22
                    jsr DrawDigitAtX

                    ; If there's no minutes, there's no :
                    lda BCDRelMinutes
                    cmp #$aa
                    beq NoColon

                    ; Draw : at X offset $20
                    lda ColonGlyphAddr
                    sta ZP1
                    lda ColonGlyphAddr + 1
                    sta ZP1 + 1
                    ldx #$20
                    jsr DrawDigitAtX

NoColon:            ply
                    plx
                    pla
                    rts

PaintCDRemoteMenu:  pha
                    phx
                    phy

                    ; (ZP1) = CDRemoteMenuAddr
                    lda CDRemoteMenuAddr
                    sta ZP1
                    lda CDRemoteMenuAddr + 1
                    sta ZP1 + 1

                    ; (ZP2) = HGRBaseTable
                    lda HGRBaseTableAddr
                    sta ZP2
                    lda HGRBaseTableAddr + 1
                    sta ZP2 + 1

                    ; Width of Block
                    lda #$14
                    sta UIOperationVar2
                    ; Starting HGR base address
                    ldy #$06
                    ; Number of sets of 8 lines to iterate (13 x 8 = 104)
                    ldx #$0d

                    ; (ZP3) = HGR Base Address n
PaintMenuLoop:      lda (ZP2),y
                    sta ZP3 + 1
                    iny
                    lda (ZP2),y
                    sta ZP3
                    iny

                    jsr MaskInvertSub

                    dex
                    bne PaintMenuLoop

                    ply
                    plx
                    pla
                    rts

DrawLargeGlyph:     clc
                    lda #$28
                    sta ZP3
                    txa
                    adc ZP3
                    sta ZP3
                    lda #$21
                    sta ZP3 + 1
                    phx

LrgGlyphLoop1:      ldy #$00
                    lda (ZP1),y
                    sta (ZP3),y
                    iny
                    lda (ZP1),y
                    sta (ZP3),y
                    clc
                    lda ZP1
                    adc #$02
                    sta ZP1
                    lda ZP1 + 1
                    adc #$00
                    sta ZP1 + 1
                    clc
                    lda ZP3 + 1
                    adc #$04
                    sta ZP3 + 1
                    cmp #$41

                    bne LrgGlyphLoop1
                    plx
                    clc
                    lda #$a8
                    sta ZP3
                    txa
                    adc ZP3
                    sta ZP3
                    lda #$21
                    sta ZP3 + 1

LrgGlyphLoop2:      ldy #$00
                    lda (ZP1),y
                    sta (ZP3),y
                    iny
                    lda (ZP1),y
                    sta (ZP3),y
                    clc
                    lda ZP1
                    adc #$02
                    sta ZP1
                    lda ZP1 + 1
                    adc #$00
                    sta ZP1 + 1
                    clc
                    lda ZP3 + 1
                    adc #$04
                    sta ZP3 + 1
                    cmp #$41
                    bne LrgGlyphLoop2

                    rts

                    ; Points (ZP1) at the glyph for the Tens digit of A
HighDigitIntoZP1:   and #$f0
                    clc
                    ror a
                    ror a
                    ror a
                    tax

                    lda DigitGlyphTable,x
                    sta ZP1
                    lda DigitGlyphTable + 1,x
                    sta ZP1 + 1
                    rts

                    ; Points (ZP1) at the glyph for the Ones digit of A
LowDigitIntoZP1:    and #$0f
                    clc
                    rol a
                    tax
                    lda DigitGlyphTable,x
                    sta ZP1
                    lda DigitGlyphTable + 1,x
                    sta ZP1 + 1
                    rts

DrawDigitAtX:       clc
                    lda #$a8
                    sta ZP3
                    txa
                    adc ZP3
                    sta ZP3
                    lda #$21
                    sta ZP3 + 1

DrawDigitLoop:      ldy #$00
                    lda (ZP1),y
                    sta (ZP3),y
                    clc
                    lda ZP1
                    adc #$01
                    sta ZP1
                    lda ZP1 + 1
                    adc #$00
                    sta ZP1 + 1
                    clc
                    lda ZP3 + 1
                    adc #$04
                    sta ZP3 + 1
                    cmp #$41
                    bne DrawDigitLoop

                    rts

PaintUISub:         pha
                    phx
                    phy

                    ; Calculate offset so UI graphic is right-justified
                    clc
                    lda #$29
                    sbc UIOperationVar1
                    sta UIOperationVar2

                    lda #$08

RawPaintOuterLoop:  pha
                    lda #$00
                    sta UIOperationVar3
                    ldx UIOperationVar1
                    lda UIOperationVar2

RawPaintInnerLoop:  pha
                    ldy UIOperationVar3
                    lda (ZP1),y
                    iny
                    sty UIOperationVar3
                    pha
                    txa
                    tay
                    pla
                    sta (ZP3),y
                    inx
                    pla
                    dec a
                    bne RawPaintInnerLoop

                    clc
                    lda ZP3 + 1
                    adc #$04
                    sta ZP3 + 1
                    clc
                    lda ZP1
                    adc UIOperationVar2
                    sta ZP1
                    lda ZP1 + 1
                    adc #$00
                    sta ZP1 + 1
                    pla
                    dec a
                    bne RawPaintOuterLoop

                    ply
                    plx
                    pla
                    rts

ToggleUIStopButton: pha
                    lda StopButtonAddr
                    sta ZP1
                    lda StopButtonAddr + 1
                    sta ZP1 + 1
                    bra ToggleUIButtonRow1
ToggleUIPlayButton: pha
                    lda PlayButtonAddr
                    sta ZP1
                    lda PlayButtonAddr + 1
                    sta ZP1 + 1
ToggleUIButtonRow1: lda #$28
                    sta UIOperationVar2
                    lda #$22
                    sta ZP3 + 1
                    lda #$00
                    sta ZP3
                    jsr MaskInvertSub
                    lda #$22
                    sta ZP3 + 1
                    lda #$80
                    sta ZP3
                    jsr MaskInvertSub
                    pla
                    rts

ToggleUIEjectButton:pha
                    lda EjectButtonAddr
                    sta ZP1
                    lda EjectButtonAddr + 1
                    sta ZP1 + 1
                    bra ToggleUIButtonRow2
ToggleUIPauseButton:pha
                    lda PauseButtonAddr
                    sta ZP1
                    lda PauseButtonAddr + 1
                    sta ZP1 + 1
ToggleUIButtonRow2: lda #$28
                    sta UIOperationVar2
                    lda #$23
                    sta ZP3 + 1
                    lda #$80
                    sta ZP3
                    jsr MaskInvertSub
                    lda #$20
                    sta ZP3 + 1
                    lda #$28
                    sta ZP3
                    jsr MaskInvertSub
                    pla
                    rts

ToggleUINextButton: pha
                    lda NextTrackButtonAddr
                    sta ZP1
                    lda NextTrackButtonAddr + 1
                    sta ZP1 + 1
                    bra ToggleUIButtonRow3
ToggleUIPrevButton: pha
                    lda PrevTrackButtonAddr
                    sta ZP1
                    lda PrevTrackButtonAddr + 1
                    sta ZP1 + 1
ToggleUIButtonRow3: lda #$28
                    sta UIOperationVar2
                    lda #$23
                    sta ZP3 + 1
                    lda #$28
                    sta ZP3
                    jsr MaskInvertSub
                    lda #$23
                    sta ZP3 + 1
                    lda #$a8
                    sta ZP3
                    jsr MaskInvertSub
                    pla
                    rts

ToggleUIScanBackButton: pha
                    lda ScanBackButtonAddr
                    sta ZP1
                    lda ScanBackButtonAddr + 1
                    sta ZP1 + 1
                    bra ToggleUIButtonRow4
ToggleUIScanFwdButton:  pha
                    lda ScanFwdButtonAddr
                    sta ZP1
                    lda ScanFwdButtonAddr + 1
                    sta ZP1 + 1
ToggleUIButtonRow4: lda #$28
                    sta UIOperationVar2
                    lda #$20
                    sta ZP3 + 1
                    lda #$50
                    sta ZP3
                    jsr MaskInvertSub
                    lda #$20
                    sta ZP3 + 1
                    lda #$d0
                    sta ZP3
                    jsr MaskInvertSub
                    lda #$21
                    sta ZP3 + 1
                    lda #$50
                    sta ZP3
                    jsr MaskInvertSub
                    pla
                    rts

ToggleUILoopButton: pha
                    lda LoopButtonAddr
                    sta ZP1
                    lda LoopButtonAddr + 1
                    sta ZP1 + 1
                    bra ToggleUIButtonRow5
ToggleUIRandButton: pha
                    lda RandomButtonAddr
                    sta ZP1
                    lda RandomButtonAddr + 1
                    sta ZP1 + 1
ToggleUIButtonRow5: lda #$28
                    sta UIOperationVar2
                    lda #$21
                    sta ZP3 + 1
                    lda #$d0
                    sta ZP3
                    jsr MaskInvertSub
                    lda #$22
                    sta ZP3 + 1
                    lda #$50
                    sta ZP3
                    jsr MaskInvertSub
                    pla
                    rts

                    ; Invert a set of 8 lines, using the Mask at (ZP1)
MaskInvertSub:      pha
                    phx
                    phy
                    ldx #$08

MaskInvertOuterLoop:ldy #$00

MaskInvertInnerLoop:lda (ZP1),y
                    eor (ZP3),y
                    sta (ZP3),y
                    iny
                    cpy UIOperationVar2
                    bne MaskInvertInnerLoop

                    clc
                    lda ZP3 + 1
                    adc #$04
                    sta ZP3 + 1
                    clc
                    lda ZP1
                    adc UIOperationVar2
                    sta ZP1
                    lda ZP1 + 1
                    adc #$00
                    sta ZP1 + 1
                    dex
                    bne MaskInvertOuterLoop

                    ply
                    plx
                    pla
                    rts

                    ; TODO: Analysis - Understand the operation of this subroutine better, improve comments
PickARandomTrack:   pha
                    ; Pick a random, unplayed track
                    phx
                    phy

                    ; Try five times to find a Played List element that is $00
                    ldx #$05
FindRandomUnplayed: jsr TrackPseudoRNGSub
                    tay
                    lda (PlayedListPtr),y
                    beq FoundUnplayedTrack
                    dex
                    bne FindRandomUnplayed

                    ; Toggle PLDirection from $01 to $FF (+1 to -1)
                    lda #$fe
                    eor PlayedListDirection
                    sta PlayedListDirection

                    ; Fallback routine to always find an unplayed track by adding "Direction" to the offset until one is found
FallbackTrackSelect:tya
                    clc
                    adc PlayedListDirection
                    tay
                    bne OffsetNotZero
                    ldy HexTrackCount0Base
                    bra TryThisTrack

OffsetNotZero:      cpy HexTrackCount0Base
                    beq TryThisTrack
                    bmi TryThisTrack
                    ldy #$01

TryThisTrack:       lda (PlayedListPtr),y
                    bne FallbackTrackSelect

                    ; Mark the PlayedList element for the selected Track to $FF ("played") and set BCDRandomPickedTrk to the BCD Track number
FoundUnplayedTrack: lda #$ff
                    sta (PlayedListPtr),y
                    tya
                    jsr Hex2BCDSorta
                    sta BCDRandomPickedTrk

                    ply
                    plx
                    pla
                    rts

PlayedListDirection:.byte   $00

                    ; TODO: Analysis - Understand the operation of this subroutine better, improve comments
TrackPseudoRNGSub:  phx
                    ; Return A as (Seed * 253) mod HexMaxTrackOffset
                    phy

                    ; 253 - not sure why?
                    ldx #$fd
                    lda RandomSeed
                    bne PRNGSeedIsValid
                    inc a

                    ; A = RandFuncTempStorage = Seed (adjusted to 1-255)
PRNGSeedIsValid:    sta RandFuncTempStorage
                    dex

                    ; Add the seed to A, 252 times.
PRNGMathLoop1:      clc
                    adc RandFuncTempStorage
                    dex
                    bne PRNGMathLoop1

                    clc
                    adc #$01
                    and #$7f
                    bne PRNGMathLoop2
                    inc a

PRNGMathLoop2:      cmp HexTrackCount0Base
                    bmi ExitMathLoop2
                    clc
                    sbc HexTrackCount0Base
                    bra PRNGMathLoop2

ExitMathLoop2:      inc a

                    ply
                    plx
                    rts

                    ; This just zeroes all 99 elements in the Played List
ClearPlayedList:    lda #$00
                    ldy #$63

CPLLoop:            sta (PlayedListPtr),y
                    dey
                    bpl CPLLoop

                    rts

                    ; Set up the ($1F) Played List ZP pointer and zero all the Played List elements
InitPlayedList:     lda PlayedListAddr
                    sta PlayedListPtr
                    lda PlayedListAddr + 1
                    sta PlayedListPtr + 1

                    jsr ClearPlayedList

                    ; Zero the Played Track Counter
                    lda #$00
                    sta HexPlayedCount0Base

                    ; Set the PLDirection initially to +1
                    lda #$01
                    sta PlayedListDirection
                    rts

                    ; TODO: Analysis - WTF is going on here?? This *seems* like an attempt to convert from BCD to binary, but it's... not.  It's kinda wonky.
Hex2BCDSorta:       phx
                    ; TODO: Analysis - The return values from this function seem bizarre and inexplicable.  Better analysis needs to be done on this code.
                    phy

                    ldx #$00
DivideBy10:         cmp #$0a
                    bmi TenOrLess
                    inx
                    clc
                    sbc #$0a
                    bra DivideBy10

TenOrLess:          sta Hex2BCDTemp
                    txa
                    clc
                    rol a
                    rol a
                    rol a
                    rol a
                    clc
                    adc Hex2BCDTemp

                    ply
                    plx
                    rts

Hex2BCDTemp:        .byte   $00

                    ; UI Button Flags: $00 = "Inactive" button and dim in UI, $FF = "Active" button and highlighted in UI
PlayButtonState:    .byte   $00
StopButtonState:    .byte   $00
PauseButtonState:   .byte   $00
LoopButtonState:    .byte   $00
RandomButtonState:  .byte   $00

                    ; $00 = M/S/F, $FF = Track
TrackOrMSFFlag:     .byte   $00
                    ; $00 = Not Playing, $FF = Playing
DrivePlayingFlag:   .byte   $00
                    ; $00 = TOC has been read and is valid, $FF = TOC has not been read and is invalid
TOCInvalidFlag:     .byte   $00

                    ; SmartPort Unit Number of the CD-ROM
CD_SPDevNum:        .byte   $00
                    ; Slot with the SCSI card
CardSlot:           .byte   $00

                    ; Counter for SmartPort/SCSI operation retries
RetryCount:         .byte   $00

                    ; BCD T/M/S values of the Relative (track-level) current read position as reported by the disc's Q Subcode channel
BCDRelTrack:        .byte   $00
BCDRelMinutes:      .byte   $00
BCDRelSeconds:      .byte   $00
                    ; BCD values of the "First" and "Last" Tracks for the current playback mode (random/sequential)
BCDFirstTrackNow:   .byte   $00
BCDLastTrackNow:    .byte   $00
                    ; BCD value of the randomly picked Track to play
BCDRandomPickedTrk: .byte   $00
                    ; Hex value of the number of tracks played in the current random session, minus 1 (0-based)
HexPlayedCount0Base:.byte   $00
                    ; BCD values of the First and Last Tracks on the disc as read from the TOC
BCDFirstTrackTOC:   .byte   $00
BCDLastTrackTOC:    .byte   $00
                    ; BCD value of the number of Tracks on the disc, minus 1 (0-based)
BCDTrackCount0Base: .byte   $00
                    ; BCD M/S/F values of the Absolute (disc-level) current read position as reported by the disc's Q Subcode channel
BCDAbsMinutes:      .byte   $00
BCDAbsSeconds:      .byte   $00
BCDAbsFrame:        .byte   $00
                    ; Hex value of the number of Tracks on the disc, minus 1 (0-based)
HexTrackCount0Base: .byte   $00
                    ; Random seed, generated by continuously incrementing while iterating the main program loop
RandomSeed:         .byte   $00
                    ; Temporary variable for randomization operations
RandFuncTempStorage:.byte   $00

                    ; List of flags identifying Tracks that have been played in the current random session (provides no-repeat random capability)
PlayedList:         .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
PlayedListAddr:     .addr   PlayedList
