	list p=16f648a
	#include <16f648a.h>

__CONFIG _BODEN_OFF & _CP_OFF & _MCLRE_OFF & _WDT_OFF & _PWRTE_ON & _LVP_OFF & _INTOSC_OSC_NOCLKOUT

	ORG	0000H
	GOTO	MAIN

	ORG	0004H
	RETFIE

MAIN
	BSF	STATUS,RP0
	MOVLW	0FFH
	MOVWF	TRISA
	MOVLW	0FBH
	MOVWF	TRISB
	BCF	STATUS,RP0

	MOVLW	07H
	MOVWF	CMCON

	BSF	STATUS,RP0
	MOVLW	19H		; set bps
	MOVWF	SPBRG
	MOVLW	B'00100100'
	MOVWF	TXSTA
	BCF	STATUS,RP0
	MOVLW	B'10010000'
	MOVWF	RCSTA

MAINLOOP
	BTFSS	PIR1,	5
	GOTO	MAINLOOP
	MOVF	RCREG,	W	;	data	in

	BSF	STATUS, RP0
LOOP1
	BTFSS	TXSTA, 1
	GOTO	LOOP1
	BCF	STATUS, RP0

	MOVWF	TXREG	;	data	out
	GOTO	MAINLOOP
