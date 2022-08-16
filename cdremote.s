.setcpu "65c02"
.org $4000
ZP1                 := $19
ZP2                 := $1B
ZP3                 := $1D
PlayedListPtr       := $1F


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

                    ; "Null" T/M/S values
                    lda #$aa
                    sta BCDTrack
                    sta BCDMinutes
                    sta BCDSeconds

                    ; Locate an Apple SCSI card and CDSC drive
                    jsr FindHardware
                    bcs EXIT

                    ; Setup
                    jsr InitializeScreen
                    jsr InitDriveAndDisc
                    jsr InitPlayedList

                    ; Do everything!
                    jsr MainLoop

                    ; Restore the ZP values and call MLI QUIT
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
                    bcs ExitDriveDiscInit

                    ; Read the TOC for Track numbers - TOC VALUES ARE BCD!!
                    jsr C27ReadTOC

                    sed
                    clc
                    lda BCDLastTrack
                    sbc BCDFirstTrack
                    adc #$01
                    sta BCDTrackCountMinus1
                    cld

                    jsr C24AudioStatus
                    lda SPBuffer
                    ; Audio Status = $00
                    beq Holding
                    dec a
                    ; Audio status = $01
                    beq Playing
                    ; Audio status = anything else
                    jsr DoStopAction
                    bra ExitDriveDiscInit

Playing:            dec PauseButtonState_
                    jsr BLiTPauseButton
                    jsr C28ReadQSubcode
                    jsr DrawTrack
                    jsr DrawTime

Holding:            dec PlayButtonState_
                    dec DrivePlayingFlag
                    jsr BLiTPlayButton
                    bra ExitDriveDiscInit
ExitDriveDiscInit:  rts

                    ; Set Full-Screen HGR Page 1
InitializeScreen:   lda SetFullScreen
                    lda SetGraphics
                    lda SetHiRes
                    lda SetPage1

                    ; Clear to white, initialize the GUI elements
                    jsr ClearHGR1toWhite
                    jsr PaintCDRemoteUI
                    jsr PaintCDRemoteMenu
                    jsr DrawTrack
                    jsr DrawTime
                    rts

MainLoop:           lda ValidTOCFlag
                    beq TOCisValid
                    jsr StatusDrive
                    bcs NoFurtherBGAction
                    jsr Re_ReadTOC_
TOCisValid:         jsr StatusDrive
                    lda DrivePlayingFlag
                    beq NoFurtherBGAction
                    jsr C24AudioStatus
                    lda SPBuffer
                    cmp #$03
                    bne StatusIsNot3_
                    jsr TrackHasEnded_
StatusIsNot3_:      jsr C28ReadQSubcode
                    bcs NoFurtherBGAction
                    jsr DrawTrack
                    jsr DrawTime
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

                    ; All other key operations (Play/Stop/Pause/Next/Prev/Eject) require an online drive/disc
NotR:               jsr StatusDrive
                    bcs MainLoop

                    ; Loop falls through to here only if the drive is online
                    pha
                    lda ValidTOCFlag
                    beq SkipTOCRead
                    jsr Re_ReadTOC_
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
OA_LeftArrow:       jsr ScanBack
                    jmp MainLoop

JustLeftArrow:      jsr PrevTrack
                    jmp MainLoop

                    ; $15 = ^U, RA (Next Track/Scan Forward)
NotCtrlH:           cmp #$15
                    bne NotCtrlU
                    lda OpenApple
                    bpl JustRightArrow
OA_RightArrow:      jsr ScanFwd
                    jmp MainLoop

JustRightArrow:     jsr NextTrack
                    jmp MainLoop

                    ; $45 = E (Eject)
NotCtrlU:           cmp #$45
                    bne UnsupportedKeypress
                    jsr C26Eject
UnsupportedKeypress:jmp MainLoop

DoQuitAction:       rts

TrackHasEnded_:     lda RandomButtonState_
                    beq L41ae

                    lda PlayButtonState_
                    beq ExitThisSubroutine

                    inc HexCurrTrackOffset
                    lda HexCurrTrackOffset
                    cmp HexMaxTrackOffset
                    bne L4192

                    lda #$00
                    sta PlayButtonState_
                    jsr UnRandomize_
                    lda #$ff
                    sta PlayButtonState_
                    lda LoopButtonState_
                    bne L4192

                    lda BCDFirstTrack
                    sta BCDFirstTrackAgain
                    sta BCDTrack
                    lda BCDLastTrack
                    sta BCDLastTrackAgain
                    jsr DoStopAction
                    bra ExitThisSubroutine

L4192:              jsr Randomizer_
                    lda PlayedListVar1
                    sta BCDTrack
                    sta BCDFirstTrackAgain
                    sta BCDLastTrackAgain
                    jsr SetStopAtLastTrack
                    lda #$ff
                    sta TrackOrMSFFlag
                    jsr C21AudioPlay
                    bra ExitThisSubroutine

L41ae:              lda LoopButtonState_
                    beq L41c9

                    jsr C23AudioStop
                    lda PlayButtonState_
                    beq ExitThisSubroutine
                    lda BCDFirstTrack
                    sta BCDFirstTrackAgain
                    dec TrackOrMSFFlag
                    jsr C21AudioPlay
                    bra ExitThisSubroutine

L41c9:              lda PlayButtonState_
                    beq ExitThisSubroutine

                    jsr DoStopAction

ExitThisSubroutine: rts

StatusDrive:        pha
                    ; Try three times
                    lda #$03
                    sta RetryCount

                    ; $00 = Status
RetryLoop:          lda #$00
                    sta SPCommandType
                    ; $00 = Code
                    lda #$00
                    sta CodeOrBlkNum
                    jsr SPCallVector
                    bcc GotStatus
                    dec RetryCount
                    bne RetryLoop
                    sec
                    bra StatusDriveExit

                    ; First byte is general status byte
GotStatus:          lda SPBuffer
                    cmp #$b4
                    beq StatusDriveSuccess
                    lda ValidTOCFlag
                    bne StatusDriveFail
                    jsr ForceShutdown_
                    lda #$ff
                    sta ValidTOCFlag
StatusDriveFail:    sec
                    bra StatusDriveExit
StatusDriveSuccess: clc
StatusDriveExit:    pla
                    rts

ForceShutdown_:     jsr DoStopAction
                    lda PauseButtonState_
                    beq NoPauseButtonChange
                    lda #$00
                    sta PauseButtonState_
                    jsr BLiTPauseButton
NoPauseButtonChange:lda PlayButtonState_
                    beq NoPlayButtonChange
                    lda #$00
                    sta PlayButtonState_
                    jsr BLiTPlayButton
NoPlayButtonChange: lda StopButtonState_
                    bne ClearTrackAndTime
                    lda #$ff
                    sta StopButtonState_
                    jsr BLiTStopButton

ClearTrackAndTime:  lda #$aa
                    sta BCDTrack
                    sta BCDMinutes
                    sta BCDSeconds
                    jsr DrawTrack
                    jsr DrawTime
                    lda BlankGlyphAddr
                    sta ZP1
                    lda BlankGlyphAddr + 1
                    sta ZP1 + 1
                    ldx #$20
                    jsr DrawDigitAtX
                    rts

Re_ReadTOC_:        lda #$00
                    sta ValidTOCFlag
                    jsr C27ReadTOC

                    sed
                    clc
                    lda BCDLastTrack
                    sbc BCDFirstTrack
                    adc #$01
                    sta BCDTrackCountMinus1
                    cld

                    jsr C23AudioStop
                    lda #$ff
                    sta TrackOrMSFFlag
                    jsr C28ReadQSubcode
                    jsr DrawTrack
                    jsr DrawTime
                    lda RandomButtonState_
                    beq ExitSub
                    jsr UnRandomize_
ExitSub:            rts

GetKeypress:        inc RandomSeed
                    lda Kbd
                    bpl NoKeyPressed
                    bit KbdStrobe

                    and #$7f
                    cmp #$61
                    bmi NotLowerCase
                    cmp #$7a
                    bpl NotLowerCase
                    and #$5f

NotLowerCase:       clc
                    bra GetKeyReturn
NoKeyPressed:       sec
GetKeyReturn:       rts

KeyReleaseWait:     lda KbdStrobe
                    bmi KeyReleaseWait
                    rts

DoPlayAction:       lda PauseButtonState_
                    beq @NotPaused
                    lda #$00
                    sta PauseButtonState_
                    jsr BLiTPauseButton
                    jsr C22AudioPause
                    bra ExitPlayAction

@NotPaused:          lda PlayButtonState_
                    bne ExitPlayAction
                    lda RandomButtonState_
                    beq L42da
                    jsr UnRandomize_
                    jsr Randomizer_
                    lda PlayedListVar1
                    sta BCDTrack
                    sta BCDFirstTrackAgain
                    sta BCDLastTrackAgain
                    jsr SetStopAtLastTrack
                    jsr C20AudioSearch

L42da:              dec PlayButtonState_
                    jsr BLiTPlayButton
                    lda StopButtonState_
                    beq L42ed
                    lda #$00
                    sta StopButtonState_
                    jsr BLiTStopButton
L42ed:              jsr C21AudioPlay
ExitPlayAction:     rts

DoStopAction:       lda StopButtonState_
                    bne ExitStopAction

                    lda BCDFirstTrack
                    sta BCDFirstTrackAgain
                    lda BCDLastTrack
                    sta BCDLastTrackAgain

                    lda PlayButtonState_
                    beq L430f

                    lda #$00
                    sta PlayButtonState_
                    jsr BLiTPlayButton
L430f:              lda PauseButtonState_
                    beq L431c
                    lda #$00
                    sta PauseButtonState_
                    jsr BLiTPauseButton

L431c:              lda #$ff
                    sta StopButtonState_
                    dec TrackOrMSFFlag
                    jsr BLiTStopButton
                    lda BCDFirstTrackAgain
                    sta BCDTrack
                    jsr C20AudioSearch
                    jsr C23AudioStop
                    jsr C28ReadQSubcode
                    jsr DrawTrack
                    jsr DrawTime
ExitStopAction:     rts

DoPauseAction:      lda StopButtonState_
                    bne ExitDoPause
                    lda #$ff
                    eor PauseButtonState_
                    sta PauseButtonState_
                    jsr BLiTPauseButton
                    jsr C22AudioPause
                    jsr KeyReleaseWait
ExitDoPause:        rts

ToggleLoopMode:     lda #$ff
                    eor LoopButtonState_
                    sta LoopButtonState_
                    jsr BLiTLoopButton
                    jsr KeyReleaseWait
                    rts

ToggleRandomMode:   lda #$ff
                    eor RandomButtonState_
                    sta RandomButtonState_
                    beq RandomButtonIsZero
                    jsr UnRandomize_
                    bra UpdateRandomButton

RandomButtonIsZero: lda BCDLastTrack
                    sta BCDLastTrackAgain
                    lda BCDFirstTrack
                    sta BCDFirstTrackAgain
                    jsr SetStopAtLastTrack

UpdateRandomButton: jsr BLiTRandomButton
                    jsr KeyReleaseWait
                    rts

UnRandomize_:       lda #$00
                    sta HexCurrTrackOffset
                    jsr ClearPlayedList

                    ; Low nibble of TrackCount into PLVar3
                    lda BCDTrackCountMinus1
                    and #$0f
                    sta HexMaxTrackOffset

                    ; Upper nibble of TrackCount/2 into PLVar4
                    lda BCDTrackCountMinus1
                    and #$f0
                    lsr a
                    sta PlayedListVar4

                    lsr a
                    lsr a
                    clc
                    adc PlayedListVar4
                    clc
                    adc HexMaxTrackOffset
                    sta HexMaxTrackOffset

                    lda PlayButtonState_
                    beq S4388Exit

                    lda BCDTrack
                    sta PlayedListVar1
                    sta BCDFirstTrackAgain
                    sta BCDLastTrackAgain
                    jsr SetStopAtLastTrack

                    ; Set "Track"th element of PlayedList to $FF
                    phy
                    ldy BCDTrack
                    lda #$ff
                    sta (PlayedListPtr),y
                    ply

S4388Exit:          rts

ScanBack:           lda PlayButtonState_
                    beq ScanBackExit
                    lda PauseButtonState_
                    bne ScanBackExit
                    jsr BLiTScanBackButton
                    jsr C25AudioScanBack

ScanBackLoop:       jsr C28ReadQSubcode
                    bcs SBQSubReadErr
                    jsr DrawTrack
                    jsr DrawTime
SBQSubReadErr:      lda KbdStrobe
                    bmi ScanBackLoop

                    jsr BLiTScanBackButton
                    jsr C22AudioPause
ScanBackExit:       rts

ScanFwd:            lda PlayButtonState_
                    beq ScanFwdExit
                    lda PauseButtonState_
                    bne ScanFwdExit
                    jsr BLiTScanFwdButton
                    jsr C25AudioScanFwd

ScanFwdLoop:        jsr C28ReadQSubcode
                    bcs SFQSubReadErr
                    jsr DrawTrack
                    jsr DrawTime
SFQSubReadErr:      lda KbdStrobe
                    bmi ScanFwdLoop

                    jsr BLiTScanFwdButton
                    jsr C22AudioPause
ScanFwdExit:        rts

PrevTrack:          jsr BLiTPrevTrackButton
                    lda #$00
                    sta BCDMinutes
                    sta BCDSeconds
                    jsr DrawTime
WrapToLast_:        lda BCDTrack
                    cmp BCDFirstTrack
                    bne JustPrev
                    lda BCDLastTrack
                    sta BCDTrack
                    bra L4442

JustPrev:           sed
                    lda BCDTrack
                    sbc #$01
                    sta BCDTrack
                    cld

L4442:              lda RandomButtonState_
                    beq L445b

                    lda BCDTrack
                    sta BCDFirstTrackAgain
                    sta BCDLastTrackAgain
                    sta PlayedListVar1
                    jsr SetStopAtLastTrack
                    lda PlayButtonState_

                    ; Huh?  This does ABSOLUTELY NOTHING
                    beq L445b

L445b:              jsr C20AudioSearch
                    jsr DrawTrack
                    ldx #$ff
L4463:              lda KbdStrobe
                    bpl L4475
                    dex
                    bne L4463
L446b:              lda Kbd
                    bpl WrapToLast_
                    bit KbdStrobe
                    bra L446b
L4475:              jsr BLiTPrevTrackButton
                    rts

NextTrack:          jsr BLiTNextTrackButton
                    lda #$00
                    sta BCDMinutes
                    sta BCDSeconds
                    jsr DrawTime
WrapToFirst_:       lda BCDTrack
                    cmp BCDLastTrack
                    bne JustNext
                    lda BCDFirstTrack
                    sta BCDTrack
                    bra L44a1

JustNext:           sed
                    lda BCDTrack
                    adc #$01
                    sta BCDTrack
                    cld

L44a1:              lda RandomButtonState_
                    beq L44ba

                    lda BCDTrack
                    sta BCDFirstTrackAgain
                    sta BCDLastTrackAgain
                    sta PlayedListVar1
                    jsr SetStopAtLastTrack
                    lda PlayButtonState_

                    ; Huh?  This does ABSOLUTELY NOTHING
                    beq L44ba

L44ba:              jsr C20AudioSearch
                    jsr DrawTrack
                    ldx #$ff
L44c2:              lda KbdStrobe
                    bpl L44d4
                    dex
                    bne L44c2
L44ca:              lda Kbd
                    bpl WrapToFirst_
                    bit KbdStrobe
                    bra L44ca
L44d4:              jsr BLiTNextTrackButton
                    rts

C26Eject:           jsr BLiTEjectButton
                    ; $26 = Eject
                    lda #$26
                    sta CodeOrBlkNum
                    ; $04 = Control
                    lda #$04
                    sta SPCommandType

                    jsr SPCallVector
                    jsr KeyReleaseWait
                    jsr BLiTEjectButton
                    lda StopButtonState_
                    bne ClearTrackTime_TOC
                    lda PauseButtonState_
                    beq @NotPaused
                    lda #$00
                    sta PauseButtonState_
                    jsr BLiTPauseButton

@NotPaused:          lda PlayButtonState_
                    beq L450d
                    lda #$00
                    sta PlayButtonState_
                    jsr BLiTPlayButton

L450d:              lda #$00
                    sta DrivePlayingFlag
                    dec a
                    sta StopButtonState_
                    jsr BLiTStopButton

ClearTrackTime_TOC: lda #$aa
                    sta BCDTrack
                    sta BCDMinutes
                    sta BCDSeconds
                    jsr DrawTrack
                    jsr DrawTime
                    lda BlankGlyphAddr
                    sta ZP1
                    lda BlankGlyphAddr + 1
                    sta ZP1 + 1
                    ldx #$20
                    jsr DrawDigitAtX
                    lda #$ff
                    sta ValidTOCFlag
                    rts

C21AudioPlay:       lda #$ff
                    sta DrivePlayingFlag
                    ; $04 = Control
                    lda #$04
                    sta SPCommandType
                    ; $21 = AudioPlay
                    lda #$21
                    sta CodeOrBlkNum
                    jsr ZeroOutSPBuffer

                    ; Stop flag = $00 (stop address in 2-5)
                    lda #$00
                    sta SPBuffer
                    ; Play mode = $09 (Standard stereo)
                    lda #$09
                    sta SPBuffer + 1

                    lda TrackOrMSFFlag
                    beq StopAtMSF

StopAtTrack:        lda BCDFirstTrackAgain
                    sta SPBuffer + 2
                    ; Address Type = $02 (Track)
                    lda #$02
                    sta SPBuffer + 6
                    lda #$00
                    sta TrackOrMSFFlag
                    bra CallAudioPlay

StopAtMSF:          lda BCDCurrMinute
                    sta SPBuffer + 4
                    lda BCDCurrSec
                    sta SPBuffer + 3
                    lda BCDCurrFrame
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
                    sta CodeOrBlkNum
                    jsr ZeroOutSPBuffer

                    lda PlayButtonState_
                    beq HoldAfterSearch
                    lda #$ff
                    sta DrivePlayingFlag
                    ; $01 = Play after search
                    lda #$01
                    bra PlayAfterSearch
                    ; $00 = Hold after search
HoldAfterSearch:    lda #$00
PlayAfterSearch:    sta SPBuffer
                    ; $09 = Play mode (??)
                    lda #$09
                    sta SPBuffer + 1
                    ; Search address = Track
                    lda BCDTrack
                    sta SPBuffer + 2
                    ; Address Type = $02 (Track)
                    lda #$02
                    sta SPBuffer + 6
                    jsr SPCallVector
                    bra SkipDeadCode

DeadCode_:          phx
                    ldx #$03
DeadCodeLoop:       jsr C24AudioStatus
                    lda SPBuffer
                    cmp #$03
                    beq DeadCodeExit
                    dex
                    bne DeadCodeLoop
                    .byte   $00, $00
DeadCodeExit:       plx

SkipDeadCode:       lda PauseButtonState_
                    beq L45e0
                    inc PauseButtonState_
                    jsr BLiTPauseButton
L45e0:              lda BCDTrack
                    sta BCDFirstTrackAgain
                    rts

                    ; $04 = Control
C24AudioStatus:     lda #$04
                    sta SPCommandType
                    ; $24 = Audio Status
                    lda #$24
                    sta CodeOrBlkNum

                    lda #$03
                    sta RetryCount
AudioStatusRetry:   jsr SPCallVector
                    bcc AudioStatusExit
                    dec RetryCount
                    bne AudioStatusRetry
AudioStatusExit:    rts

                    ; $04 = Control
C27ReadTOC:         lda #$04
                    sta SPCommandType
                    ; $27 = ReadTOC
                    lda #$27
                    sta CodeOrBlkNum
                    ; Start Track # = $00 (First Track), Type = $00
                    jsr ZeroOutSPBuffer
                    ; Allocation Length = $0A
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
                    bra ReadTOCExit

                    ; First Track #
ReadTOCSuccess:     lda SPBuffer
                    sta BCDFirstTrack
                    sta BCDFirstTrackAgain
                    ; Last Track #
                    lda SPBuffer + 1
                    sta BCDLastTrack
                    sta BCDLastTrackAgain
                    clc
ReadTOCExit:        rts

                    ; $04 = Control
C28ReadQSubcode:    lda #$04
                    sta SPCommandType
                    ; $28 = ReadQSubcode
                    lda #$28
                    sta CodeOrBlkNum

                    lda #$03
                    sta RetryCount
RetryReadQSubcode:  jsr SPCallVector
                    bcc ReadQSubcodeSuccess
                    dec RetryCount
                    bne RetryReadQSubcode
                    bra ReadQSubcodeExit

ReadQSubcodeSuccess:lda SPBuffer + 1
                    sta BCDTrack
                    lda SPBuffer + 3
                    sta BCDMinutes
                    lda SPBuffer + 4
                    sta BCDSeconds
                    lda SPBuffer + 6
                    sta BCDCurrMinute
                    lda SPBuffer + 7
                    sta BCDCurrSec
                    lda SPBuffer + 8
                    sta BCDCurrFrame
                    lda SPBuffer + 2
                    beq ReadQSubcodeFail

                    clc
                    bra ReadQSubcodeExit

ReadQSubcodeFail:   sec
ReadQSubcodeExit:   rts

C23AudioStop:       lda #$00
                    sta DrivePlayingFlag

                    ; $04 = Control
                    lda #$04
                    sta SPCommandType
                    ; $23 = AudioStop
                    lda #$23
                    sta CodeOrBlkNum
                    ; Address type = $00 (??)
                    jsr ZeroOutSPBuffer
                    jsr SPCallVector

                    ; $04 = Control
SetStopAtLastTrack: lda #$04
                    sta SPCommandType
                    ; $23 = AudioStop
                    lda #$23
                    sta CodeOrBlkNum
                    jsr ZeroOutSPBuffer
                    ; Address = Last Track
                    lda BCDLastTrackAgain
                    sta SPBuffer
                    ; Address Type = $02 (Track)
                    lda #$02
                    sta SPBuffer + 4
                    jsr SPCallVector
                    rts

                    ; $04 = Control
C22AudioPause:      lda #$04
                    sta SPCommandType
                    ; $22 = AudoPause
                    lda #$22
                    sta CodeOrBlkNum
                    jsr ZeroOutSPBuffer

                    lda PauseButtonState_
                    eor #$ff
                    sta DrivePlayingFlag
                    and #$01
                    ; $00 = Pause, $01 = UnPause/Resume (Button $00 = Paused, $FF = Unpaused)
                    sta SPBuffer
                    jsr SPCallVector
                    rts

                    ; $25 = AudioScan
C25AudioScanFwd:    lda #$25
                    sta CodeOrBlkNum
                    ; $04 = Control
                    lda #$04
                    sta SPCommandType
                    jsr ZeroOutSPBuffer

                    ; $00 = Forward
                    lda #$00
                    sta SPBuffer
                    lda BCDCurrMinute
                    sta SPBuffer + 4
                    lda BCDCurrSec
                    sta SPBuffer + 3
                    lda BCDCurrFrame
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
                    sta CodeOrBlkNum
                    jsr ZeroOutSPBuffer

                    ; $01 = Backward
                    lda #$01
                    sta SPBuffer
                    lda BCDCurrMinute
                    sta SPBuffer + 4
                    lda BCDCurrSec
                    sta SPBuffer + 3
                    lda BCDCurrFrame
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

ClearHGR1toWhite:   pha
                    phx
                    phy
                    lda ZP1
                    pha
                    lda ZP1 + 1
                    pha
                    ; (ZP1) = $2000, X = $20 pages
                    lda #$00
                    sta ZP1
                    lda #$20
                    sta ZP1 + 1
                    ldx #$20

Loop8K:             ldy #$00
                    lda #$ff

Loop256:            sta (ZP1),y
                    iny
                    bne Loop256

                    clc
                    lda ZP1 + 1
                    adc #$01
                    sta ZP1 + 1
                    dex
                    bne Loop8K

                    pla
                    sta ZP1 + 1
                    pla
                    sta ZP1
                    ply
                    plx
                    pla
                    rts

FindHardware:       jsr FindSCSICard
                    bcs ExitSetup
                    jsr SmartPortCallSetup
                    jsr FindCDROM
ExitSetup:          rts

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
                    sec
                    bra FindSCSICardDone
YesFound:           clc
FindSCSICardDone:   rts

NoSCSICardError:    lda ZP1
                    pha
                    lda ZP1 + 1
                    pha
                    lda NoSCSIMsgAddr
                    sta ZP1
                    lda NoSCSIMsgAddr + 1
                    sta ZP1 + 1
                    ldy #$00
PrintLoop1:         lda (ZP1),y
                    beq KeyPressLoop1
                    iny
                    ora #$80
                    jsr $fded
                    bra PrintLoop1
                    .byte   $8d, $10, $c0
KeyPressLoop1:      lda KbdStrobe
                    bpl KeyPressLoop1
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
                    sta CodeOrBlkNum

                    ; ParmCount = 3
                    lda #$03
                    sta SPParmCount

                    jsr SPCallVector

                    ; Byte offset $00 = Number of devices connected
                    ldx SPBuffer
                    ; $03 = Return Device Information Block (DIB), 25 bytes
                    lda #$03
                    sta CodeOrBlkNum

NextDevice:         stx CD_SPDevNum
                    stx SPUnitNumber
                    ; Make DIB call for current device
                    jsr SPCallVector

                    ; Byte 1 = Device status
                    lda SPBuffer
                    ; Force "online" bit true
                    ora #$10
                    ; $B4 = 10110100 = Block device, Not writeable, Readable, Can't format, Write protected
                    cmp #$b4
                    beq CDROMFound

                    ldx CD_SPDevNum
                    dex
                    bne NextDevice
                    jsr NoCDROMError
                    sec
                    bra FindCDROMDone
CDROMFound:         clc
FindCDROMDone:      rts

NoCDROMError:       lda ZP1
                    pha
                    lda ZP1 + 1
                    pha
                    lda NoCDROMMsgAddr
                    sta ZP1
                    lda NoCDROMMsgAddr + 1
                    sta ZP1 + 1
                    ldy #$00
PrintLoop2:         lda (ZP1),y
                    beq KeyPressLoop2
                    iny
                    ora #$80
                    jsr $fded
                    bra PrintLoop2
                    .byte   $8d, $10, $c0
KeyPressLoop2:      lda KbdStrobe
                    bpl KeyPressLoop2
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
                    .byte   $65
                    .addr   QuitParms

                    brk

QuitParms:          .byte   $04
                    .byte   $00
                    .addr   0000
                    .byte   $00
                    .addr   0000

SPCallVector:       jsr $0000

SPCommandType:      .byte   $00
SPParms:            .addr   SPParmCount

                    rts

                    ; SmartPort Parameter Table
SPParmCount:        .byte   $00
SPUnitNumber:       .byte   $00
                    .addr   SPBuffer
CodeOrBlkNum:       .byte   $00, $00, $00

                    .byte   $00, $00, $00, $00, $00, $00, $00, $00, $00

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

BLiTVar1:           .byte   $00
BLiTVar2:           .byte   $00
BLiTVar3:           .byte   $00

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

                    ; Starting HGR base address
                    ldy #$00
                    ; Batches of 8 lines to BLiT_(24 x 8 = 192)
                    ldx #$18
                    ; Starting offset into HGR lines
                    lda #$17
                    sta BLiTVar1

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

                    lda BCDTrack
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

                    lda BCDTrack
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

                    lda BCDMinutes
                    jsr HighDigitIntoZP1
                    ldx #$1e
                    jsr DrawDigitAtX

                    lda BCDMinutes
                    jsr LowDigitIntoZP1
                    ldx #$1f
                    jsr DrawDigitAtX

                    lda BCDSeconds
                    jsr HighDigitIntoZP1
                    ldx #$21
                    jsr DrawDigitAtX

                    lda BCDSeconds
                    jsr LowDigitIntoZP1
                    ldx #$22
                    jsr DrawDigitAtX

                    lda BCDMinutes
                    cmp #$aa
                    beq NoColon

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
                    sta BLiTVar2
                    ; Starting HGR base address
                    ldy #$06
                    ; Batches of 8 lines to BLiT_(13 x 8 = 104)
                    ldx #$0d

                    ; (ZP3) = HGR Base Address n
PaintMenuLoop:      lda (ZP2),y
                    sta ZP3 + 1
                    iny
                    lda (ZP2),y
                    sta ZP3
                    iny

                    jsr MaskPaintSub

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

                    clc
                    lda #$29
                    sbc BLiTVar1
                    sta BLiTVar2
                    lda #$08

RawPaintOuterLoop:  pha
                    lda #$00
                    sta BLiTVar3
                    ldx BLiTVar1
                    lda BLiTVar2

RawPaintInnerLoop:  pha
                    ldy BLiTVar3
                    lda (ZP1),y
                    iny
                    sty BLiTVar3
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
                    adc BLiTVar2
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

BLiTStopButton:     pha
                    lda StopButtonAddr
                    sta ZP1
                    lda StopButtonAddr + 1
                    sta ZP1 + 1
                    bra DoBLiTRow1
BLiTPlayButton:     pha
                    lda PlayButtonAddr
                    sta ZP1
                    lda PlayButtonAddr + 1
                    sta ZP1 + 1
DoBLiTRow1:         lda #$28
                    sta BLiTVar2
                    lda #$22
                    sta ZP3 + 1
                    lda #$00
                    sta ZP3
                    jsr MaskPaintSub
                    lda #$22
                    sta ZP3 + 1
                    lda #$80
                    sta ZP3
                    jsr MaskPaintSub
                    pla
                    rts

BLiTEjectButton:    pha
                    lda EjectButtonAddr
                    sta ZP1
                    lda EjectButtonAddr + 1
                    sta ZP1 + 1
                    bra DoBLiTRow2
BLiTPauseButton:    pha
                    lda PauseButtonAddr
                    sta ZP1
                    lda PauseButtonAddr + 1
                    sta ZP1 + 1
DoBLiTRow2:         lda #$28
                    sta BLiTVar2
                    lda #$23
                    sta ZP3 + 1
                    lda #$80
                    sta ZP3
                    jsr MaskPaintSub
                    lda #$20
                    sta ZP3 + 1
                    lda #$28
                    sta ZP3
                    jsr MaskPaintSub
                    pla
                    rts

BLiTNextTrackButton:pha
                    lda NextTrackButtonAddr
                    sta ZP1
                    lda NextTrackButtonAddr + 1
                    sta ZP1 + 1
                    bra DoBLiTRow3
BLiTPrevTrackButton:pha
                    lda PrevTrackButtonAddr
                    sta ZP1
                    lda PrevTrackButtonAddr + 1
                    sta ZP1 + 1
DoBLiTRow3:         lda #$28
                    sta BLiTVar2
                    lda #$23
                    sta ZP3 + 1
                    lda #$28
                    sta ZP3
                    jsr MaskPaintSub
                    lda #$23
                    sta ZP3 + 1
                    lda #$a8
                    sta ZP3
                    jsr MaskPaintSub
                    pla
                    rts

BLiTScanBackButton: pha
                    lda ScanBackButtonAddr
                    sta ZP1
                    lda ScanBackButtonAddr + 1
                    sta ZP1 + 1
                    bra DoBLiTRow4
BLiTScanFwdButton:  pha
                    lda ScanFwdButtonAddr
                    sta ZP1
                    lda ScanFwdButtonAddr + 1
                    sta ZP1 + 1
DoBLiTRow4:         lda #$28
                    sta BLiTVar2
                    lda #$20
                    sta ZP3 + 1
                    lda #$50
                    sta ZP3
                    jsr MaskPaintSub
                    lda #$20
                    sta ZP3 + 1
                    lda #$d0
                    sta ZP3
                    jsr MaskPaintSub
                    lda #$21
                    sta ZP3 + 1
                    lda #$50
                    sta ZP3
                    jsr MaskPaintSub
                    pla
                    rts

BLiTLoopButton:     pha
                    lda LoopButtonAddr
                    sta ZP1
                    lda LoopButtonAddr + 1
                    sta ZP1 + 1
                    bra DoBLiTRow5
BLiTRandomButton:   pha
                    lda RandomButtonAddr
                    sta ZP1
                    lda RandomButtonAddr + 1
                    sta ZP1 + 1
DoBLiTRow5:         lda #$28
                    sta BLiTVar2
                    lda #$21
                    sta ZP3 + 1
                    lda #$d0
                    sta ZP3
                    jsr MaskPaintSub
                    lda #$22
                    sta ZP3 + 1
                    lda #$50
                    sta ZP3
                    jsr MaskPaintSub
                    pla
                    rts

MaskPaintSub:       pha
                    phx
                    phy
                    ldx #$08

MaskPaintOuterLoop: ldy #$00

MaskPaintInnerLoop: lda (ZP1),y
                    eor (ZP3),y
                    sta (ZP3),y
                    iny
                    cpy BLiTVar2
                    bne MaskPaintInnerLoop

                    clc
                    lda ZP3 + 1
                    adc #$04
                    sta ZP3 + 1
                    clc
                    lda ZP1
                    adc BLiTVar2
                    sta ZP1
                    lda ZP1 + 1
                    adc #$00
                    sta ZP1 + 1
                    dex
                    bne MaskPaintOuterLoop

                    ply
                    plx
                    pla
                    rts

Randomizer_:        pha
                    phx
                    phy

                    ; Try five times to find a PL element that is $00
                    ldx #$05
FindRandomUnplayed: jsr RTG_
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
                    ldy HexMaxTrackOffset
                    bra TryThisTrack

OffsetNotZero:      cpy HexMaxTrackOffset
                    beq TryThisTrack
                    bmi TryThisTrack
                    ldy #$01

TryThisTrack:       lda (PlayedListPtr),y
                    bne FallbackTrackSelect

                    ; Mark the PL element with $FF and set PLVar1 to the BCD Track number
FoundUnplayedTrack: lda #$ff
                    sta (PlayedListPtr),y
                    tya
                    jsr Hex2BCD
                    sta PlayedListVar1

                    ply
                    plx
                    pla
                    rts

PlayedListDirection:.byte   $00

                    ; Return A as (Seed * 253) mod HexMaxTrackOffset
RTG_:               phx
                    phy

                    ; 253 - not sure why?
                    ldx #$fd
                    lda RandomSeed
                    bne SeedIsValid
                    inc a

                    ; A = PLVar4 = Seed (adjusted to 1-255)
SeedIsValid:        sta PlayedListVar4
                    dex

                    ; Add the seed to A, 252 times.
MathLoop1:          clc
                    adc PlayedListVar4
                    dex
                    bne MathLoop1

                    clc
                    adc #$01
                    and #$7f
                    bne MathLoop2
                    inc a

MathLoop2:          cmp HexMaxTrackOffset
                    bmi ExitMathLoop2
                    clc
                    sbc HexMaxTrackOffset
                    bra MathLoop2

ExitMathLoop2:      inc a

                    ply
                    plx
                    rts

ClearPlayedList:    lda #$00
                    ldy #$63

CPLLoop:            sta (PlayedListPtr),y
                    dey
                    bpl CPLLoop

                    rts

                    ; ($1F) = PlayedList
InitPlayedList:     lda PlayedListAddr
                    sta PlayedListPtr
                    lda PlayedListAddr + 1
                    sta PlayedListPtr + 1

                    jsr ClearPlayedList

                    lda #$00
                    sta HexCurrTrackOffset

                    ; PLDirection initially is +1
                    lda #$01
                    sta PlayedListDirection
                    rts

Hex2BCD:            phx
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

                    ; Global variables and flags start here
PlayButtonState_:   .byte   $00
StopButtonState_:   .byte   $00
PauseButtonState_:  .byte   $00
LoopButtonState_:   .byte   $00
RandomButtonState_: .byte   $00

TrackOrMSFFlag:     .byte   $00
DrivePlayingFlag:   .byte   $00
ValidTOCFlag:       .byte   $00
CD_SPDevNum:        .byte   $00
CardSlot:           .byte   $00
RetryCount:         .byte   $00
BCDTrack:           .byte   $00
BCDMinutes:         .byte   $00
BCDSeconds:         .byte   $00
BCDFirstTrackAgain: .byte   $00
BCDLastTrackAgain:  .byte   $00
PlayedListVar1:     .byte   $00
HexCurrTrackOffset: .byte   $00
BCDFirstTrack:      .byte   $00
BCDLastTrack:       .byte   $00
BCDTrackCountMinus1:.byte   $00
BCDCurrMinute:      .byte   $00
BCDCurrSec:         .byte   $00
BCDCurrFrame:       .byte   $00
HexMaxTrackOffset:  .byte   $00
RandomSeed:         .byte   $00
PlayedListVar4:     .byte   $00

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



