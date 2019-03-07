; ROTATION ENCODER DECODER + MOTOR CONTROLLER WITH MICROCHIP PIC 16F648A
; (C) 2013 IDEHARA Lab. TAMA UNIVERSITY
;
; CONNECTION
;	A0, A1	: ENCODER INPUT
;	A2	: RESET ENCODER COUNT SW (NEGATIVE)
;	A3	: MISSLE SHOT SW (NEGATIVE) / Tension Trigger
;	B1, B2	: SERIAL PORT
;	B3      : PWM
;	B4, B5  : MOTOR CONTROL
;	B7, B6	: ROTATION INDICATOR LED (CURRENT DRAIN)
;
; SERIAL PORT SETTINGS
;	DESIGNED FOR INTERNAL 4MHZ CLOCK
;	19200, NO STOP BIT, NO PARITY
;	REFER TO DOCUMENT 40044F P.71
;

; ***** PROGRAM *****
;
; IF TXREADY
; 	IF ROTATION_COUNT > 0
; 		SEND "A" AND DECREMENT RC
;	IF ROTATION_COUNT < 0
;		SEND "B" AND INCREMENT RC
; END
; IF STATUS(SW-A2,SW-A3) IS CHANGED
;	IF SW-A2 IS PRESSED
;		WAIT FOR TXREADY AND SEND "R"
;	IF SW-A3 IS PRESSED
;		WAIT FOR TXREADY AND SEND "S"
; END
; STAT[-1] := STAT[0]
; STATC := STAT[0] << 2 | PORTA
; STAT[0] := PORTA
; SWITCH STATC OF
; 	CASE 0001, 0111, 1110, 1000 :
;		INCREMENT ROTATION_COUNT
;		TURN ON INDICATOR_LED AND RESET INDICATOR_LED_TIMER
;	END
; 	CASE 0010, 1011, 1101, 0100 :
;		DECREMENT ROTATION_COUNT
;		TURN ON INDICATOR_LED AND RESET INDICATOR_LED_TIMER
;	END
;	OTHERWISE
;		DECREMENT LED_INDICATOR_COUNT AND IF 0 THEN TURN OFF LEDS
;	END
; END

	list p=16f648a
	include "p16f648a.inc"

	__CONFIG _BODEN_OFF & _CP_OFF & _MCLRE_OFF & _WDT_OFF & _PWRTE_ON & _LVP_OFF & _INTOSC_OSC_NOCLKOUT

	ORG     0000H
	GOTO    MAIN

	ORG     0004H
	RETFIE

;	FIELDS (20H - 7FH for 648A)
STATN   EQU     20H             ; State now	00 - 11
STATM1  EQU     21H             ; State n-1	00 - 11
STATC   EQU     22H             ; State Combined ST(n-1):ST(n) 0000 - 1111
ROTATE  EQU     23H             ; ROTATION {00, 01, 10}
SLEEPC	EQU	24H		; Sleep Counter
LEDT1	EQU	25H		; LED Timer 1
LEDT2	EQU	26H		; LED Timer 2
LASTSW	EQU	27H		; LAST SWITCH STATE
DIRC	EQU	28H		; DIRECTION COUNTER (*SIGNED* INT)
MTRSPD	EQU	29H		; MOTOR SPEED (INT of 0-9)
MTRCNT	EQU	2AH		; Motor Control xxab xxxx (ab=00 free, ab=11 break, ab=10/01 rotation)
RTMPD	EQU	2BH		; Received data temporal storage
BRKLVL	EQU	2CH		; Brake Force 0=free, 0ffh=full
BRKCNT	EQU	2DH		; Brake Counter
BRKFLG	EQU	2EH		; Brake Flag (0 : free, 1 : brake)
CSTAT	EQU	2FH		; current system STATUS
				; 0 : normal free
				; 1 : normal pull out
				; 2 : normal keep tension
				; 3 : throw init
				; 4 : throw brake
				; 5 : throw string end
				; 6 : reinitialize

;	BITS
LEDON1	EQU	7
LEDON2	EQU	6
MOTORA	EQU	5
MOTORB	EQU	4
motormask	EQU	b'11001111'
motorbreak	EQU	b'00110000'

MAIN
	MOVLW	07H		; Turn comparators off and
	MOVWF	CMCON		; enable pins for I/O functions

	BSF     STATUS,RP0	; switch bank
	MOVLW   0FH		; 0000 1111	A0,A1=Encoder INPUT
				;		A2 = Reset Encoder (NEG)
	MOVWF   TRISA		; 		A3 = Shot (NEG)
				;
	MOVLW   06H		; 0000 0110
	MOVWF   TRISB		; 0000 011x

; 	B2 = TxD, B1 = RxD (both should be **INPUT** (ref. P.78))
;	Output drive, when required, is controlled by the peripheral circuitry.
;
; 	B7, B6 = rotation indicator
;	B5, B4 = MOTOR
;	B3     = MOTOR PWM

	BCF     STATUS,RP0	; switchback bank


; START UART CONFIGURATION: DOCUMENT 40044F P.71
	BSF	STATUS,RP0
	MOVLW	B'00100100'	; CLOCK-N/A, TX9-OFF, TXENABLE=1, ASYNC
				; N/A, BAUDRATE-HIGH, TR.SR-FULL, TX9D=0
	MOVWF	TXSTA
	MOVLW	0CH		; 4MHz / 16 / (12+1) = 19230
;	MOVLW	19H		; 4MHz / 16 / (12+1) = 19230

	MOVWF	SPBRG		; F/16/(X+1)
	BCF	STATUS,RP0

	CALL	WAIT

	MOVLW	B'10010000'	; SERIAL-ON, 9BIT-OFF, SNGLE-N/A, CONTRCV=ON
				; ADEN-N/A, (FRAMEERR, OVERERR, RX9D)
	MOVWF	RCSTA
; END UART CONFIGURATION


; INITIALISE FIELDS
	CLRF    PORTA
	CLRF    PORTB
	CLRF    STATN
	CLRF    STATM1
	CLRF    STATC
	CLRF    ROTATE
	CLRF	MTRSPD
	CLRF	MTRCNT
	MOVLW	B'00001100'
	MOVWF	LASTSW
	CLRF	DIRC
	CLRF	BRKLVL
	CLRF	BRKCNT
	CLRF	BRKFLG
	CLRF	CSTAT
; END INITIALISATION

; MAIN LOOP
MAINLOOP

; CHECK DIRECTION COUNTER, IF NOT ZERO AND IF TXREADY, SEND ONE
	; CHECK IF DIR COUNTER=0
	MOVFW	DIRC		; DIRC->W, AFFECTS ZERO FLAG!!
	BTFSC	STATUS, Z	; If dirc<>0, try to send one data. if not, skip the proc.
	GOTO	END_OF_SEND

	; CHECK IF TX-READY AND SKIP IF TX-BUSY (DO NOT SEND DATA IN THIS LOOP)
	BSF	STATUS, RP0	; **** SWITCH TO BANK1 ****
	BTFSS	TXSTA, 1
	GOTO	TXBUSY		; IMPORTANT: STILL IN BANK 1!!!!

	; HERE, TX-READY. START SENDING DIR(A/B)
	BCF	STATUS, RP0	; RETURN TO BANK 0
	; CHECK THE SIGN OF DIR
	BTFSS	DIRC, 7		; CHECK THE SIGN BIT, SKIP IF MINUS
	GOTO	SENDPLUS

SENDMINUS			; SEND B, INCREMENT DIR
	MOVLW	10
	ADDWF	DIRC, W		; dirc+10 -> W, set carry(**POSITIVE**)
	BTFSS	STATUS, C	; if carry(-10<dirc), skip
	GOTO	SENDM10		; here, dirc<-10, so send -10 CODE

	INCF	DIRC, F		; just increment one
	MOVLW	'b'
	GOTO	SENDWREG

SENDM10
	MOVWF	DIRC		; W(dirc+10) -> DIRC
	MOVLW	'B'
	GOTO	SENDWREG

SENDPLUS			; SEND A, DECREMENT DIR
	MOVLW	10
	SUBWF	DIRC, W		; dirc-10 -> W, set borrow(**NEGATIVE**)
	BTFSC	STATUS, C	; if borrow(dirc<10), skip
	GOTO	SENDP10		; here, dirc>10, so send +10 code

	DECF	DIRC, F		; just decrement one
	MOVLW	'a'
	GOTO	SENDWREG

SENDP10
	MOVWF	DIRC		; W(dirc-10) -> DIRC
	MOVLW	'A'

SENDWREG
	MOVWF	TXREG

TXBUSY
	BCF	STATUS, RP0	; RETURN TO BANK 0.
				; IMPORTANT: THERE IS A PATH TO REACH HERE ON BANK 1!!!!
END_OF_SEND
; END CHECK DIRECTION COUNTER


; BEGIN RECEIVE DATA FROM SERIAL
	BTFSS	PIR1, RCIF	; if data is ready, go on to receiving code. if not, jump to next block
	GOTO	ENDOFRECEIVE
	MOVFW	RCREG		; move the data
	MOVWF	RTMPD		; to RTMPD

	CLRF	MTRSPD		; if something is sent, clear the motorspeed
	CLRF	MTRCNT		; and set motor free

; start the CHECK
; candidates are "="(break), "+"(positive rot), "-"(negative rot), "[0-9]"(speed)
; "K" (keep tension)
	MOVLW	'='
	XORWF	RTMPD, W
	BTFSS	STATUS, Z	; skip when data = "=" (break)
	GOTO	RCH_IFPLUS

	BSF	BRKFLG, 1
	GOTO	ENDOFRECEIVE

RCH_IFPLUS
	MOVLW	'+'
	XORWF	RTMPD, W
	BTFSS	STATUS, Z	; skip if received data = '+'
	GOTO	RCH_IFMINUS
	BCF	MTRCNT, MOTORB	; set bit5 = 0
	BSF	MTRCNT, MOTORA	; set bit4 = 1
	CLRF	MTRSPD		; clear the motor speed (avoid sudden reverse)
	CLRF	BRKFLG
	GOTO	ENDOFRECEIVE

RCH_IFMINUS
	MOVLW	'-'
	XORWF	RTMPD, W
	BTFSS	STATUS, Z	; skip if received data = '-'
	GOTO	RCV_DIGIT
	BSF	MTRCNT, MOTORB	; set bit5 = 1
	BCF	MTRCNT, MOTORA	; set bit4 = 0
	CLRF	MTRSPD		; clear the motor speed (avoid sudden reverse)
	CLRF	BRKFLG
	GOTO	ENDOFRECEIVE

RCV_DIGIT
	MOVLW	'0'
	SUBWF	RTMPD, W	; W = ['0'-'9'] - '0'
	MOVWF	MTRSPD		; set it to motor speed
	MOVWF	BRKLVL		; and to brake level
	BCF	STATUS, C	; clear CARRY
	SWAPF	BRKLVL, F	; Brake level *= 16

	IORWF	MTRSPD, W	; check if motor_speed is 0
	BTFSS	STATUS, Z	; if it is 0
	GOTO	ENDOFRECEIVE
	CLRF	MTRCNT		; set the motor free
	CLRF	BRKFLG		; reset BrakeFlag

ENDOFRECEIVE

; begin set motor
	BTFSS	BRKFLG, 1	; if brake_mode, skip into brake SETTINGS
	GOTO	MOTORSET
BRAKE
	DECF	BRKCNT, F
	MOVFW	BRKCNT
	SUBWF	BRKLVL		; Brake_Level - Brake_Counter
	MOVLW	00H		; does not affect any FLAGS
	BTFSC	STATUS, C	; CARRY IS NEGATIVE LOGIC. C is set = Level>Counter = Brake ON
	MOVLW	motorbreak
	MOVWF	MTRCNT
BRAKEEND

MOTORSET
	MOVFW	PORTB
	ANDLW	motormask	; b'11001111' for Final version, b'00111111' for Testing
	IORWF	MTRCNT, W
	MOVWF	PORTB
ENDOFMOTORSET


; STATUS BUTTONS CHECK
CHECKSTAT
	; Move STATE-NOW to STATE-MINUS1
	; AND TO STATE-COMBINED
	MOVFW   STATN
	MOVWF   STATM1
	MOVWF   STATC

	; CHECK IF SWITCH STATE IS CHANGED
	MOVFW	PORTA
	ANDLW	B'00001100'
	XORWF	LASTSW, F	; 0 IF NOT CHANGED
	MOVWF	LASTSW		; ZERO FLAG IS NOT CHANGED WITH "MOVWF"
	BTFSC	STATUS, Z	; IF NOT ZERO, JMP TO CHECK
	GOTO	ENDOFCHECKSTAT	; IF ZERO, SKIP CHECKSWITCH

	; CHECK RESET ENCODER
	MOVLW	'R'
	BTFSS	PORTA, 2		; NEGATIVE LOGIC. 0=PRESSED
	CALL	SENDW

	; CHECK SHOT BUTTON
	MOVLW	'S'
	BTFSS	PORTA, 3		; NEGATIE LOGIC. 0=PRESSED
	CALL	SENDW
ENDOFCHECKSTAT
; END STATUS CHECK

; STATE BASED PROCEDURES
	MOVFW	CSTAT
	CALL	STATEPROCS

; ENCODER INPUT CHECK
SKIPSW
	; STORE LAST 2 BITS FROM PORTA TO STATE-NOW
	MOVFW   PORTA
	ANDLW   B'00000011'
	MOVWF   STATN

	; ROTATE STAT-COMBINED 2 BITS -> GET IT TO WORK
	; 000000XX -> 0000XX00
	CLRC
	RLF     STATC, F
	RLF     STATC, W

	; OR WITH STATE-NOW (NOTE THAT STATE-NOW IS 0000 00YY)
	; 0000XX00 -> 0000XXYY
	IORWF   STATN, W
	; STORE IT TO STATE-COMBINED
	; 0000XXYY
	MOVWF   STATC

	; CALL TURNCHECK WITH W REGISTER -> STORE TO ROTATE
	CALL    TURNCHECK
	MOVWF   ROTATE

; CHECK Bit0, Bit1 OF ROTATION AND JUMP
	; CHECK CODE
	BTFSC   ROTATE, 0
	GOTO    ROTCW
	BTFSC   ROTATE, 1
	GOTO    ROTCCW

; IF NO ROTATION, COUNT DOWN THE LED TIMER (DURATION 0FFH*020h)
	; NO ROTATION
	DECFSZ	LEDT1, F
	GOTO	MAINLOOP
	MOVLW	020H
	MOVWF	LEDT1
	DECFSZ	LEDT2, F
	GOTO	MAINLOOP

	; TIMER IS OVER
	BSF	PORTB, LEDON1
	BSF	PORTB, LEDON2
	GOTO    MAINLOOP

; ROTATION DETECTED -> INCREMENT DIRECTION COUNTER
; �@Note:	If the rotation character is sent directly, it drops some characters
;		when the rotation is too fast.
;		So we count the rotations and send out one by one for one loop.
ROTCW
	BSF     PORTB, LEDON1	; TURN ON/OFF THE INDICATOR LED
	BCF     PORTB, LEDON2
	INCF	DIRC, F		; COUNT UP DIR COUNTER
	GOTO    RESETTIMER

ROTCCW
	BCF     PORTB, LEDON1	; TURN ON/OFF THE INDICATOR LED
	BSF     PORTB, LEDON2
	DECF	DIRC, F		; COUNT DOWN DIR COUNTER
	GOTO    RESETTIMER

RESETTIMER
	MOVLW	0FFH
	MOVWF	LEDT1
	MOVWF	LEDT2
	GOTO	MAINLOOP
; END ENCODER CHECK

; PROCEDURE SENDW : WAIT FOR TX-READY, SEND W REGISTER
SENDW
	;WAIT FOR TX-READY
	BSF	STATUS, RP0
LOOP1
	BTFSS	TXSTA, 1
	GOTO	LOOP1
	BCF	STATUS, RP0
	MOVWF	TXREG
	RETURN
; END PROCEDURE

; FUNCTION TURNCHECK: DECIDES ROTATION DIRECTION FROM W REGISTER
TURNCHECK
	; INPUT:        W 0000XXYY X:FORMER ENC. Y:CURRENT ENC.
	; OUTPUT:       W 00000001 CW   00000010 CCW    0 NO ROT

	; ADD W=STATC TO PROGRAM-COUNTER, MULTIPLE JUMP
	ADDWF   PCL, F		; PATTERN
	RETLW   0               ; 0000
	RETLW   1               ; 0001
	RETLW   2               ; 0010
	RETLW   0               ; 0011

	RETLW   2               ; 0100
	RETLW   0               ; 0101
	RETLW   0               ; 0110
	RETLW   1               ; 0111

	RETLW   1               ; 1000
	RETLW   0               ; 1001
	RETLW   0               ; 1010
	RETLW   2               ; 1011

	RETLW   0               ; 1100
	RETLW   2               ; 1101
	RETLW   1               ; 1110
	RETLW   0               ; 1111
; END TURNCHECK


; PROCEDURE WAIT FOR 0FFH LOOPS
WAIT
	MOVLW	0FFH
	MOVWF	SLEEPC
SLOOP	DECFSZ	SLEEPC, F
	GOTO	SLOOP
	RETURN
; END WAIT

; STATE BASED PROCEDURES
STATEPROCS
	ADDWF	PCL, F
	GOTO	STATE0
	GOTO	STATE1
	GOTO	STATE2
	GOTO	STATE3
	GOTO	STATE4
	GOTO	STATE5
	GOTO	STATE6

STATE0
	CLRF	MTRCNT
	BTFSC	PORTB, LEDON2
	GOTO	ST1
	BTFSC	PORTA, 3	; A3:clear = button is pressed = no tension
	RETURN
	GOTO	ST2

ST0
	CLRF	MTRCNT
	MOVLW	0
	MOVWF	CSTAT
	RETURN

ST1
	CLRF	MTRCNT
	MOVLW	1
	MOVWF	CSTAT
	RETURN

ST2
	BSF	MTRCNT, MOTORB	; set bit5 = 1
	BCF	MTRCNT, MOTORA	; set bit4 = 0
	MOVLW	2
	MOVWF	CSTAT
	RETURN

STATE1
	BTFSC	PORTB, LEDON2
	RETURN
	GOTO	ST2

STATE2
	BTFSC	PORTB, LEDON2
	GOTO	ST1

	BTFSS	PORTA, 3	; A3:set = button is not pressed = tension full
	RETURN

;	BTFSC	PORTB, LEDON1
;	RETURN
	GOTO	ST0

STATE3
STATE4
STATE5
STATE6
	RETURN

	

	END
