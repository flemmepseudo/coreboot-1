/*
 * This file is part of the coreboot project.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include <soc/iomap.h>

/*
 * Type C Subsystem(TCSS) topology provides Runtime D3 support for USB host controller(xHCI),
 * USB device controller(xDCI), Thunderbolt DMA devices and Thunderbolt PCIe controllers.
 * PCIe RP0/RP1 is grouped with DMA0 and PCIe RP2/RP3 is grouped with DMA1.
 */
#define TCSS_TBT_PCIE0_RP0			0
#define TCSS_TBT_PCIE0_RP1			1
#define TCSS_TBT_PCIE0_RP2			2
#define TCSS_TBT_PCIE0_RP3			3
#define TCSS_XHCI				4
#define TCSS_XDCI				5
#define TCSS_DMA0				6
#define TCSS_DMA1				7

/*
 * MAILBOX_BIOS_CMD_TCSS_DEVEN_INTERFACE
 * Command code 0x15
 * Description: Gateway command for handling TCSS DEVEN clear/restore.
 * Field PARAM1[15:8] of the _INTERFACE register is used in this command to select from
 * a pre-defined set of subcommands.
 */
#define MAILBOX_BIOS_CMD_TCSS_DEVEN_INTERFACE		0x00000015
#define TCSS_DEVEN_MAILBOX_SUBCMD_GET_STATUS		0  /* Sub-command 0 */
#define TCSS_DEVEN_MAILBOX_SUBCMD_TCSS_CHANGE_REQ	1  /* Sub-command 1 */

#define TCSS_IOM_ACK_TIMEOUT_IN_MS			100

Scope (\_SB)
{
	/* Device base address */
	Method (BASE, 1)
	{
		Local0 = Arg0 & 0x7             /* Function number */
		Local1 = (Arg0 >> 16) & 0x1F   /* Device number */
		Local2 = (Local0 << 12) + (Local1 << 15)
		Local3 = \_SB.PCI0.GPCB() + Local2
		Return (Local3)
	}

	/*
	 * Define PCH ACPIBASE I/O as an ACPI operating region. The base address can be
	 * found in Device 31, Function 2, Offset 40h.
	 */
	OperationRegion (PMIO, SystemIO, PCH_PWRM_BASE_ADDRESS, 0x80)
	Field (PMIO, ByteAcc, NoLock, Preserve) {
		Offset(0x6C),   /* 0x6C, General Purpose Event 0 Status [127:96] */
		    ,  19,
		CPWS,  1,       /* CPU WAKE STATUS */
		Offset(0x7C),   /* 0x7C, General Purpose Event 0 Enable [127:96] */
		    ,  19,
		CPWE,  1        /* CPU WAKE EN */
	}

	Name (C2PW, 0)  /* Set default value to 0. */

	/*
	 * C2PM (CPU to PCH Method)
	 *
	 * This object is Enable/Disable GPE_CPU_WAKE_EN.
	 * Arguments: (4)
	 * Arg0 - An Integer containing the device wake capability
	 * Arg1 - An Integer containing the target system state
	 * Arg2 - An Integer containing the target device state
	 * Arg3 - An Integer containing the request device type
	 * Return Value:
	 * return 0
	 */
	Method (C2PM, 4, NotSerialized)
	{
		Local0 = 0x1 << Arg3
		/* This method is used to enable/disable wake from Tcss Device (WKEN). */
		If (Arg0 && Arg1)
		{  /* If entering Sx and enabling wake, need to enable WAKE capability. */
			If (CPWE == 0) {  /* If CPU WAKE EN is not set, Set it. */
				If (CPWS) {  /* If CPU WAKE STATUS is set, Clear it. */
					/* Clear CPU WAKE STATUS by writing 1. */
					CPWS = 1
				}
				CPWE = 1  /* Set CPU WAKE EN by writing 1. */
			}
			If ((C2PW & Local0) == 0) {
				/* Set Corresponding Device En BIT in C2PW. */
				C2PW |= Local0
			}
		} Else {  /* If Staying in S0 or Disabling Wake. */
			If (Arg0 || Arg2) {  /* Check if Exiting D0 and arming for wake. */
				/* If CPU WAKE EN is not set, Set it. */
				If (CPWE == 0) {
					/* If CPU WAKE STATUS is set, Clear it. */
					If (CPWS) {
						/* Clear CPU WAKE STATUS by writing 1. */
						CPWS = 1
					}
					CPWE = 1  /* Set CPU WAKE EN by writing 1. */
				}
				If ((C2PW & Local0) == 0) {
					/* Set Corresponding Device En BIT in C2PW. */
					C2PW |= Local0
				}
			} Else {
				/*
				 * Disable runtime PME, either because staying in D0 or
				 * disabling wake.
				 */
				If ((C2PW & Local0) != 0) {
					/*
					 * Clear Corresponding Device En BIT in C2PW.
					 */
					C2PW &= ~Local0
				}
				If ((CPWE != 0) && (C2PW == 0)) {
					/*
					 * If CPU WAKE EN is set, Clear it. Clear CPU WAKE EN
					 * by writing 0.
					 */
					CPWE = 0
				}
			}
		}
		Return (0)
	}
}

Scope (\_SB.PCI0)
{
	/*
	 * Operation region defined to access the IOM REGBAR. Get the MCHBAR in offset
	 * 0x48 in B0:D0:F0. REGBAR Base address is in offset 0x7110 of MCHBAR.
	 */
	OperationRegion (MBAR, SystemMemory, (GMHB() + 0x7100), 0x1000)
	Field (MBAR, ByteAcc, NoLock, Preserve)
	{
		Offset(0x10),
		RBAR, 64        /* RegBar, offset 0x7110 in MCHBAR */
	}
	Field (MBAR, DWordAcc, NoLock, Preserve)
	{
		Offset(0x304),  /* PRIMDN_MASK1_0_0_0_MCHBAR_IMPH, offset 0x7404 */
		,     31,
		TCD3, 1         /* [31:31] TCSS IN D3 bit */
	}

	/*
	 * Operation region defined to access the pCode mailbox interface. Get the MCHBAR
	 * in offset 0x48 in B0:D0:F0. MMIO address is in offset 0x5DA0 of MCHBAR.
	 */
	OperationRegion (PBAR, SystemMemory, (GMHB() + 0x5DA0), 0x08)
	Field (PBAR, DWordAcc, NoLock, Preserve)
	{
		PMBD, 32,  /* pCode MailBox Data, offset 0x5DA0 in MCHBAR */
		PMBC, 8,   /* pCode MailBox Command, [7:0] of offset 0x5DA4 in MCHBAR */
		PSCM, 8,   /* pCode MailBox Sub-Command, [15:8] of offset 0x5DA4 in MCHBAR */
		,     15,  /* Reserved */
		PMBR, 1    /* pCode MailBox RunBit, [31:31] of offset 0x5DA4 in MCHBAR */
	}

	/*
	 * Poll pCode MailBox Ready
	 *
	 * Return 0xFF - Timeout
	 * 	  0x00 - Ready
	 */
	Method (PMBY, 0)
	{
		Local0 = 0
		While (PMBR && (Local0 < 1000)) {
			Local0++
			Stall (1)
		}
		If (Local0 == 1000) {
			Printf("Timeout occurred.")
			Return (0xFF)
		}
		Return (0)
	}

	/*
	 * Method to send pCode MailBox command TCSS_DEVEN_MAILBOX_SUBCMD_GET_STATUS
	 *
	 * Result will be updated in DATA[1:0]
	 * DATA[0:0] TCSS_DEVEN_CURRENT_STATE:
	 *	0 - TCSS Deven in normal state.
	 *	1 - TCSS Deven is cleared by BIOS Mailbox request.
	 * DATA[1:1] TCSS_DEVEN_REQUEST_STATUS:
	 *	0 - IDLE. TCSS DEVEN has reached its final requested state.
	 *	1 - In Progress. TCSS DEVEN is currently in progress of switching state
	 *     	    according to given request (bit 0 reflects source state).
	 *
	 * Return 0x00 - TCSS Deven in normal state
	 * 	  0x01 - TCSS Deven is cleared by BIOS Mailbox request
	 * 	  0x1x - TCSS Deven is in progress of switching state according to given request
	 * 	  0xFE - Command timeout
	 * 	  0xFF - Command corrupt
	 */
	Method (DSGS, 0)
	{
		If ((PMBY () == 0)) {
			PMBC = MAILBOX_BIOS_CMD_TCSS_DEVEN_INTERFACE
			PSCM = TCSS_DEVEN_MAILBOX_SUBCMD_GET_STATUS
			PMBR = 1
			If (PMBY () == 0) {
				Local0 = PMBD
				Local1 = PMBC
				Stall (10)
				If ((Local0 != PMBD) || (Local1 != PMBC)) {
					Printf("pCode MailBox is corrupt.")
					Return (0xFF)
				}
				Return (Local0)
			} Else {
				Printf("pCode MailBox is not ready.")
				Return (0xFE)
			}
		} Else {
			Printf("pCode MailBox is not ready.")
			Return (0xFE)
		}
	}

	/*
	 * Method to send pCode MailBox command TCSS_DEVEN_MAILBOX_SUBCMD_TCSS_CHANGE_REQ
	 *
	 * Arg0 : 0 - Restore to previously saved value of TCSS DEVEN
	 *	  1 - Save current TCSS DEVEN value and clear it
	 *
	 * Return 0x00 - MAILBOX_BIOS_CMD_CLEAR_TCSS_DEVEN command completed
	 *	  0xFD - Input argument is invalid
	 *	  0xFE - Command timeout
	 *	  0xFF - Command corrupt
	 */
	Method (DSCR, 1)
	{
		If (Arg0 > 1) {
			Printf("pCode MailBox is corrupt.")
			Return (0xFD)
		}
		If ((PMBY () == 0)) {
			PMBC = MAILBOX_BIOS_CMD_TCSS_DEVEN_INTERFACE
			PSCM = TCSS_DEVEN_MAILBOX_SUBCMD_TCSS_CHANGE_REQ
			PMBD = Arg0
			PMBR = 1
			If ((PMBY () == 0)) {
				Local0 = PMBD
				Local1 = PMBC
				Stall (10)
				If ((Local0 != PMBD) || (Local1 != PMBC)) {
					Printf("pCode MailBox is corrupt.")
					Return (0xFF)
				}
				/* Poll TCSS_DEVEN_REQUEST_STATUS, timeout value is 10ms. */
				Local0 = 0
				While ((DSGS () & 0x10) && (Local0 < 100)) {
					Stall (100)
					Local0++
				}
				If (Local0 == 100) {
					Printf("pCode MailBox is not ready.")
					Return (0xFE)
				} Else {
					Return (0x00)
				}
			} Else {
				Printf("pCode MailBox is not ready.")
				Return (0xFE)
			}
		} Else {
			Printf("pCode MailBox is not ready.")
			Return (0xFE)
		}
	}

	/*
	 * IOM REG BAR Base address is in offset 0x7110 in MCHBAR.
	 */
	Method (IOMA, 0)
	{
		Return (^RBAR & ~0x1)
	}

	/*
	 * From RegBar Base, IOM_TypeC_SW_configuration_1 is in offset 0xC10040, where
	 * 0x40 is the register offset.
	 */
	OperationRegion (IOMR, SystemMemory, (IOMA() + 0xC10000), 0x100)
	Field (IOMR, DWordAcc, NoLock, Preserve)
	{
		Offset(0x40),
		,     15,
		TD3C, 1,          /* [15:15] Type C D3 cold bit */
		TACK, 1,          /* [16:16] IOM Acknowledge bit */
		DPOF, 1,          /* [17:17] Set 1 to indicate IOM, all the */
				  /* display is OFF, clear otherwise */
		Offset(0x70),     /* Pyhsical addr is offset 0x70. */
		IMCD, 32,         /* R_SA_IOM_BIOS_MAIL_BOX_CMD */
		IMDA, 32          /* R_SA_IOM_BIOS_MAIL_BOX_DATA */
	}

	/*
	 * Below is a variable to store devices connect state for TBT PCIe RP before
	 * entering D3 cold.
	 * Value 0 - no device connected before enter D3 cold, no need to send
	 * CONNECT_TOPOLOGY in D3 cold exit.
	 * Value 1 - has device connected before enter D3 cold, need to send
	 * CONNECT_TOPOLOGY in D3 cold exit.
	 */
	Name (CTP0, 0)  /* Variable of device connecet status for TBT0 group. */
	Name (CTP1, 0)  /* Variable of device connecet status for TBT1 group. */

	/*
	 * TBT Group0 ON method
	 */
	Method (TG0N, 0)
	{
		If (\_SB.PCI0.TDM0.VDID == 0xFFFFFFFF) {
			Printf("TDM0 does not exist.")
		}

		If (\_SB.PCI0.TDM0.STAT == 0) {
			/* DMA0 is in D3Cold early. */
			\_SB.PCI0.TDM0.D3CX()  /* RTD3 Exit */

			Printf("Bring TBT RPs out of D3Code.")
			If (\_SB.PCI0.TRP0.VDID != 0xFFFFFFFF) {
				/* RP0 D3 cold exit. */
				\_SB.PCI0.TRP0.D3CX()
			}
			If (\_SB.PCI0.TRP1.VDID != 0xFFFFFFFF) {
				/* RP1 D3 cold exit. */
				\_SB.PCI0.TRP1.D3CX()
			}

			/*
			 * Need to send Connect-Topology command when TBT host
			 * controller back to D0 from D3.
			 */
			If (\_SB.PCI0.TDM0.ALCT == 1) {
				If (CTP0 == 1) {
					/*
					 * Send Connect-Topology command if there is
					 * device present on PCIe RP.
					 */
					\_SB.PCI0.TDM0.CNTP()

					/* Indicate to wait Connect-Topology command. */
					\_SB.PCI0.TDM0.WACT = 1

					/* Clear the connect states. */
					CTP0 = 0
				}
				/* Disallow to send Connect-Topology command. */
				\_SB.PCI0.TDM0.ALCT = 0
			}
		} Else {
			Printf("Drop TG0N due to it is already exit D3 cold.")
		}
		/* TBT RTD3 exit 10ms delay. */
		Sleep (10)
	}

	/*
	 * TBT Group0 OFF method
	 */
	Method (TG0F, 0)
	{
		If (\_SB.PCI0.TDM0.VDID == 0xFFFFFFFF) {
			Printf("TDM0 does not exist.")
		}

		If (\_SB.PCI0.TDM0.STAT == 1) {
			/* DMA0 is not in D3Cold now. */
			\_SB.PCI0.TDM0.D3CE()  /* Enable DMA RTD3 */

			Printf("Push TBT RPs to D3Cold together")
			If (\_SB.PCI0.TRP0.VDID != 0xFFFFFFFF) {
				If (\_SB.PCI0.TRP0.PDSX == 1) {
					CTP0 = 1
				}
				/* Put RP0 to D3 cold. */
				\_SB.PCI0.TRP0.D3CE()
			}
			If (\_SB.PCI0.TRP1.VDID != 0xFFFFFFFF) {
				If (\_SB.PCI0.TRP1.PDSX == 1) {
					CTP0 = 1
				}
				/* Put RP1 to D3 cold. */
				\_SB.PCI0.TRP1.D3CE()
			}
		}
	}

	/*
	 * TBT Group1 ON method
	 */
	Method (TG1N, 0)
	{
		If (\_SB.PCI0.TDM1.VDID == 0xFFFFFFFF) {
			Printf("TDM1 does not exist.")
		}

		If (\_SB.PCI0.TDM1.STAT == 0) {
			/* DMA1 is in D3Cold early. */
			\_SB.PCI0.TDM1.D3CX()  /* RTD3 Exit */

			Printf("Bring TBT RPs out of D3Code.")
			If (\_SB.PCI0.TRP2.VDID != 0xFFFFFFFF) {
				/* RP2 D3 cold exit. */
				\_SB.PCI0.TRP2.D3CX()
			}
			If (\_SB.PCI0.TRP3.VDID != 0xFFFFFFFF) {
				/* RP3 D3 cold exit. */
				\_SB.PCI0.TRP3.D3CX()
			}

			/*
			 * Need to send Connect-Topology command when TBT host
			 * controller back to D0 from D3.
			 */
			If (\_SB.PCI0.TDM1.ALCT == 1) {
				If (CTP1 == 1) {
					/*
					 * Send Connect-Topology command if there is
					 * device present on PCIe RP.
					 */
					\_SB.PCI0.TDM1.CNTP()

					/* Indicate to wait Connect-Topology command. */
					\_SB.PCI0.TDM1.WACT = 1

					/* Clear the connect states. */
					CTP1 = 0
				}
				/* Disallow to send Connect-Topology cmd. */
				\_SB.PCI0.TDM1.ALCT = 0
			}
		} Else {
			Printf("Drop TG1N due to it is already exit D3 cold.")
		}
		/* TBT RTD3 exit 10ms delay. */
		Sleep (10)
	}

	/*
	 * TBT Group1 OFF method
	 */
	Method (TG1F, 0)
	{
		If (\_SB.PCI0.TDM1.VDID == 0xFFFFFFFF) {
			 Printf("TDM1 does not exist.")
		}

		If (\_SB.PCI0.TDM1.STAT == 1) {
			/* DMA1 is not in D3Cold now */
			\_SB.PCI0.TDM1.D3CE()  /* Enable DMA RTD3. */

			Printf("Push TBT RPs to D3Cold together")
			If (\_SB.PCI0.TRP2.VDID != 0xFFFFFFFF) {
				If (\_SB.PCI0.TRP2.PDSX == 1) {
					CTP1 = 1
				}
				/* Put RP2 to D3 cold. */
				\_SB.PCI0.TRP2.D3CE()
			}
			If (\_SB.PCI0.TRP3.VDID != 0xFFFFFFFF) {
				If (\_SB.PCI0.TRP3.PDSX == 1) {
					CTP1 = 1
				}
				/* Put RP3 to D3 cold */
				\_SB.PCI0.TRP3.D3CE()
			}
		}
	}

	PowerResource (TBT0, 5, 1)
	{
		Method (_STA, 0)
		{
			Return (\_SB.PCI0.TDM0.STAT)
		}

		Method (_ON, 0)
		{
			TG0N()
		}

		Method (_OFF, 0)
		{
			If (\_SB.PCI0.TDM0.SD3C == 0) {
				TG0F()
			}
		}
	}

	PowerResource (TBT1, 5, 1)
	{
		Method (_STA, 0)
		{
			Return (\_SB.PCI0.TDM1.STAT)
		}

		Method (_ON, 0)
		{
			TG1N()
		}

		Method (_OFF, 0)
		{
			If (\_SB.PCI0.TDM1.SD3C == 0) {
				TG1F()
			}
		}
	}

	Method (TCON, 0)
	{
		/* Reset IOM D3 cold bit if it is in D3 cold now. */
		If (TD3C == 1)  /* It was in D3 cold before. */
		{
			/* Reset IOM D3 cold bit. */
			TD3C = 0    /* Request IOM for D3 cold exit sequence. */
			Local0 = 0  /* Time check counter variable */
			/* Wait for ack, the maximum wait time for the ack is 100 msec. */
			While ((TACK != 0) && (Local0 < TCSS_IOM_ACK_TIMEOUT_IN_MS)) {
				/*
				 * Wait in this loop until TACK becomes 0 with timeout
				 * TCSS_IOM_ACK_TIMEOUT_IN_MS by default.
				 */
				Sleep (1)  /* Delay of 1ms. */
				Local0++
			}

			If (Local0 == TCSS_IOM_ACK_TIMEOUT_IN_MS) {
				Printf("Error: Error: Timeout occurred.")
			}
			Else
			{
				/*
				 * Program IOP MCTP Drop (TCSS_IN_D3) after D3 cold exit and
				 * acknowledgement by IOM.
				 */
				TCD3 = 0
				/*
				 * If the TCSS Deven is cleared by BIOS Mailbox request, then
				 * restore to previously saved value of TCSS DEVNE.
				 */
				Local0 = 0
				While (\_SB.PCI0.TXHC.VDID == 0xFFFFFFFF) {
					If (DSGS () == 1) {
						DSCR (0)
					}
					Local0++
					If (Local0 == 5) {
						Printf("pCode mailbox command failed.")
						Break
					}
				}
			}
		}
		Else {
			Printf("Drop TCON due to it is already exit D3 cold.")
		}
	}

	Method (TCOF, 0)
	{
		If ((\_SB.PCI0.TXHC.SD3C != 0) || (\_SB.PCI0.TDM0.SD3C != 0)
					       || (\_SB.PCI0.TDM1.SD3C != 0))
		{
			Printf("Skip D3C entry.")
			Return
		}

		/*
		 * If the TCSS Deven in normal state, then Save current TCSS DEVEN value and
		 * clear it.
		 */
		Local0 = 0
		While (\_SB.PCI0.TXHC.VDID != 0xFFFFFFFF) {
			If (DSGS () == 0) {
				DSCR (1)
			}
			Local0++
			If (Local0 == 5) {
				Printf("pCode mailbox command failed.")
				Break
			}
		}

		/*
		 * Program IOM MCTP Drop (TCSS_IN_D3) in D3Cold entry before entering D3 cold.
		 */
		TCD3 = 1

		/* Request IOM for D3 cold entry sequence. */
		TD3C = 1
	}

	PowerResource (D3C, 5, 0)
	{
		/*
		 * Variable to save power state
		 * 1 - TC Cold request cleared.
		 * 0 - TC Cold request sent.
		 */
		Name (STAT, 0x1)

		Method (_STA, 0)
		{
			Return (STAT)
		}

		Method (_ON, 0)
		{
			\_SB.PCI0.TCON()
			STAT = 1
		}

		Method (_OFF, 0)
		{
			\_SB.PCI0.TCOF()
			STAT = 0
		}
	}

	/*
	 * TCSS xHCI device
	 */
	Device (TXHC)
	{
		Name (_ADR, 0x000D0000)
		Name (_DDN, "North XHCI controller")
		Name (_STR, Unicode ("North XHCI controller"))
		Name (DCPM, TCSS_XHCI)

		Method (_STA, 0x0, NotSerialized)
		{
			Return (0x0F)
		}
		#include "tcss_xhci.asl"
	}

	/*
	 * TCSS DMA0 device
	 */
	Device (TDM0)
	{
		Name (_ADR, 0x000D0002)
		Name (_DDN, "TBT DMA0 controller")
		Name (_STR, Unicode ("TBT DMA0 controller"))
		Name (DUID, 0)  /* TBT DMA number */
		Name (DCPM, TCSS_DMA0)

		Method (_STA, 0x0, NotSerialized)
		{
			Return (0x0F)
		}
		#include "tcss_dma.asl"
	}

	/*
	 * TCSS DMA1 device
	 */
	Device (TDM1)
	{
		Name (_ADR, 0x000D0003)
		Name (_DDN, "TBT DMA1 controller")
		Name (_STR, Unicode ("TBT DMA1 controller"))
		Name (DUID, 1)  /* TBT DMA number */
		Name (DCPM, TCSS_DMA1)

		Method (_STA, 0x0, NotSerialized)
		{
			Return (0x0F)
		}
		#include "tcss_dma.asl"
	}

	/*
	 * TCSS PCIE Root Port #00
	 */
	Device (TRP0)
	{
		Name (_ADR, 0x00070000)
		Name (TUID, 0)  /* TBT PCIE RP Number 0 for RP00 */
		Name (LTEN, 0)  /* Latency Tolerance Reporting Mechanism, 0:Disable, 1:Enable */
		Name (LMSL, 0)  /* PCIE LTR max snoop Latency */
		Name (LNSL, 0)  /* PCIE LTR max no snoop Latency */
		Name (DCPM, TCSS_TBT_PCIE0_RP0)

		Method (_STA, 0x0, NotSerialized)
		{
			Return (0x0F)
		}
		Method (_INI)
		{
			LTEN = 0
			LMSL = 0x88C8
			LNSL = 0x88C8
		}
		#include "tcss_pcierp.asl"
	}

	/*
	 * TCSS PCIE Root Port #01
	 */
	Device (TRP1)
	{
		Name (_ADR, 0x00070001)
		Name (TUID, 1)  /* TBT PCIE RP Number 1 for RP01 */
		Name (LTEN, 0)  /* Latency Tolerance Reporting Mechanism, 0:Disable, 1:Enable */
		Name (LMSL, 0)  /* PCIE LTR max snoop Latency */
		Name (LNSL, 0)  /* PCIE LTR max no snoop Latency */
		Name (DCPM, TCSS_TBT_PCIE0_RP1)

		Method (_STA, 0x0, NotSerialized)
		{
			Return (0x0F)
		}
		Method (_INI)
		{
			LTEN = 0
			LMSL = 0x88C8
			LNSL = 0x88C8
		}
		#include "tcss_pcierp.asl"
	}

	/*
	 * TCSS PCIE Root Port #02
	 */
	Device (TRP2)
	{
		Name (_ADR, 0x00070002)
		Name (TUID, 2)  /* TBT PCIE RP Number 2 for RP02 */
		Name (LTEN, 0)  /* Latency Tolerance Reporting Mechanism, 0:Disable, 1:Enable */
		Name (LMSL, 0)  /* PCIE LTR max snoop Latency */
		Name (LNSL, 0)  /* PCIE LTR max no snoop Latency */
		Name (DCPM, TCSS_TBT_PCIE0_RP2)

		Method (_STA, 0x0, NotSerialized)
		{
			Return (0x0F)
		}
		Method (_INI)
		{
			LTEN = 0
			LMSL = 0x88C8
			LNSL = 0x88C8
		}
		#include "tcss_pcierp.asl"
	}

	/*
	 * TCSS PCIE Root Port #03
	 */
	Device (TRP3)
	{
		Name (_ADR, 0x00070003)
		Name (TUID, 3)  /* TBT PCIE RP Number 3 for RP03 */
		Name (LTEN, 0)  /* Latency Tolerance Reporting Mechanism, 0:Disable, 1:Enable */
		Name (LMSL, 0)  /* PCIE LTR max snoop Latency */
		Name (LNSL, 0)  /* PCIE LTR max no snoop Latency */
		Name (DCPM, TCSS_TBT_PCIE0_RP3)

		Method (_STA, 0x0, NotSerialized)
		{
			Return (0x0F)
		}
		Method (_INI)
		{
			LTEN = 0
			LMSL = 0x88C8
			LNSL = 0x88C8
		}
		#include "tcss_pcierp.asl"
	}
}