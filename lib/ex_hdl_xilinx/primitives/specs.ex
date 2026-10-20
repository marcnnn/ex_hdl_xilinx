defmodule ExHdlXilinx.Primitives.Specs do
  @moduledoc false
  # Data for ExHdlXilinx.Primitives. Port lists are strings of whitespace
  # separated tokens:
  #
  #   i:NAME[w]   input (data, domain :async unless @dom)
  #   o:NAME[w]   output
  #   c:NAME      clock input; its domain is the lowercase name
  #   d:name      internal domain: data ports tagged @name belong to the
  #               domain of a clock the primitive does not take as a port
  #   @dom        port domain, ? marks a port or width I am unsure about
  #
  # `params` carry integers, strings and {:bits, w, v}; `reals` are
  # real-valued SV parameters, which the RTL backend cannot emit as reals,
  # so they hold integer values and the stub declares them as real.
  # `ties` are the values the unconnected inputs get in `Primitives.inst/3`
  # (default 0). `comb` lists the inputs an output depends on (default none).

  alias ExHdlXilinx.Primitives.Models

  @mmcm_clkout ~w(CLKOUT0 CLKOUT0B CLKOUT1 CLKOUT1B CLKOUT2 CLKOUT2B CLKOUT3 CLKOUT3B CLKOUT4 CLKOUT5 CLKOUT6)

  def all do
    %{
      "IBUF" => %{
        params: [IBUF_LOW_PWR: "TRUE"],
        ports: "i:I o:O",
        comb: [O: [:I]],
        model: Models.Ibuf,
        stub: "assign O = I;",
        drives: ~w(O)
      },
      "OBUF" => %{
        ports: "i:I o:O",
        comb: [O: [:I]],
        model: Models.Obuf,
        stub: "assign O = I;",
        drives: ~w(O)
      },
      "IBUFDS" => %{
        params: [DIFF_TERM: "FALSE", IBUF_LOW_PWR: "TRUE", DQS_BIAS: "FALSE"],
        ports: "i:I i:IB o:O",
        comb: [O: [:I, :IB]],
        model: Models.Ibufds,
        stub: "assign O = I;",
        drives: ~w(O)
      },
      "IBUFDS_GTE4" => %{
        params: [
          REFCLK_EN_TX_PATH: {:bits, 1, 0},
          REFCLK_HROW_CK_SEL: {:bits, 2, 0},
          REFCLK_ICNTL_RX: {:bits, 2, 0}
        ],
        ports: "i:I i:IB i:CEB o:O o:ODIV2",
        comb: [O: [:I, :IB, :CEB], ODIV2: [:I, :IB, :CEB]],
        model: Models.IbufdsGte4,
        stub: "assign O = I & ~CEB;\n  assign ODIV2 = I & ~CEB;",
        drives: ~w(O ODIV2)
      },
      "BUFG" => %{
        ports: "c:I o:O",
        model: Models.ClockBuf,
        stub: "assign O = I;",
        drives: ~w(O)
      },
      "BUFGCE" => %{
        params: [
          CE_TYPE: "SYNC",
          IS_CE_INVERTED: {:bits, 1, 0},
          IS_I_INVERTED: {:bits, 1, 0},
          SIM_DEVICE: "ULTRASCALE_PLUS"
        ],
        ports: "c:I i:CE o:O",
        ties: [CE: 1],
        model: Models.ClockBuf,
        stub: "assign O = I & CE;",
        drives: ~w(O)
      },
      "BUFG_GT" => %{
        params: [SIM_DEVICE: "ULTRASCALE_PLUS", STARTUP_SYNC: "FALSE"],
        ports: "i:I i:CE i:CEMASK i:CLR i:CLRMASK i:DIV[3] o:O",
        ties: [CE: 1],
        model: Models.ClockBuf,
        stub: "assign O = I;",
        drives: ~w(O)
      },
      "MMCME4_ADV" => %{
        params: [
          BANDWIDTH: "OPTIMIZED",
          CLKFBOUT_MULT_F: 5,
          CLKFBOUT_PHASE: 0,
          CLKIN1_PERIOD: 0,
          CLKIN2_PERIOD: 0,
          CLKOUT0_DIVIDE_F: 1,
          CLKOUT1_DIVIDE: 1,
          CLKOUT2_DIVIDE: 1,
          CLKOUT3_DIVIDE: 1,
          CLKOUT4_DIVIDE: 1,
          CLKOUT5_DIVIDE: 1,
          CLKOUT6_DIVIDE: 1,
          CLKOUT0_PHASE: 0,
          CLKOUT1_PHASE: 0,
          CLKOUT2_PHASE: 0,
          CLKOUT3_PHASE: 0,
          CLKOUT4_PHASE: 0,
          CLKOUT5_PHASE: 0,
          CLKOUT6_PHASE: 0,
          COMPENSATION: "AUTO",
          DIVCLK_DIVIDE: 1,
          STARTUP_WAIT: "FALSE",
          CLKOUT4_CASCADE: "FALSE"
        ],
        reals: ~w(CLKFBOUT_MULT_F CLKFBOUT_PHASE CLKIN1_PERIOD CLKIN2_PERIOD CLKOUT0_DIVIDE_F
                  CLKOUT0_PHASE CLKOUT1_PHASE CLKOUT2_PHASE CLKOUT3_PHASE CLKOUT4_PHASE
                  CLKOUT5_PHASE CLKOUT6_PHASE)a,
        ports:
          "c:CLKIN1 i:CLKIN2 i:CLKFBIN i:CLKINSEL i:RST i:PWRDWN i:PSCLK i:PSEN i:PSINCDEC " <>
            "i:CDDCREQ c:DCLK i:DEN i:DWE i:DADDR[7]? i:DI[16] " <>
            Enum.map_join(@mmcm_clkout, " ", &"o:#{&1}") <>
            " o:CLKFBOUT o:CLKFBOUTB o:LOCKED o:CLKFBSTOPPED o:CLKINSTOPPED o:PSDONE " <>
            "o:CDDCDONE o:DRDY o:DO[16]",
        ties: [CLKINSEL: 1],
        model: Models.Mmcm,
        stub: """
        logic [4:0] cnt;
          initial cnt = 5'd0;
          always_ff @(posedge CLKIN1)
            if (RST | PWRDWN) cnt <= 5'd0;
            else if (cnt != 5'd16) cnt <= cnt + 5'd1;
          assign LOCKED = (cnt == 5'd16);
          assign CLKFBOUT = CLKFBIN;
          assign CLKOUT0 = CLKIN1;
          assign CLKOUT1 = CLKIN1;
          assign CLKOUT2 = CLKIN1;
          assign CLKOUT3 = CLKIN1;
          assign CLKOUT4 = CLKIN1;
          assign CLKOUT5 = CLKIN1;
          assign CLKOUT6 = CLKIN1;\
        """,
        drives: ~w(LOCKED CLKFBOUT CLKOUT0 CLKOUT1 CLKOUT2 CLKOUT3 CLKOUT4 CLKOUT5 CLKOUT6)
      },
      "PLLE4_ADV" => %{
        params: [
          CLKFBOUT_MULT: 5,
          CLKFBOUT_PHASE: 0,
          CLKIN_PERIOD: 0,
          CLKOUT0_DIVIDE: 1,
          CLKOUT0_PHASE: 0,
          CLKOUT1_DIVIDE: 1,
          CLKOUT1_PHASE: 0,
          CLKOUTPHY_MODE: "VCO_2X",
          COMPENSATION: "AUTO",
          DIVCLK_DIVIDE: 1,
          STARTUP_WAIT: "FALSE"
        ],
        reals: ~w(CLKFBOUT_PHASE CLKIN_PERIOD CLKOUT0_PHASE CLKOUT1_PHASE)a,
        ports:
          "c:CLKIN i:CLKFBIN i:CLKOUTPHYEN i:RST i:PWRDWN c:DCLK i:DEN i:DWE i:DADDR[7]? " <>
            "i:DI[16] o:CLKOUT0 o:CLKOUT0B o:CLKOUT1 o:CLKOUT1B o:CLKOUTPHY o:CLKFBOUT " <>
            "o:LOCKED o:DRDY o:DO[16]",
        model: Models.Plle4,
        stub: """
        logic [4:0] cnt;
          initial cnt = 5'd0;
          always_ff @(posedge CLKIN)
            if (RST | PWRDWN) cnt <= 5'd0;
            else if (cnt != 5'd16) cnt <= cnt + 5'd1;
          assign LOCKED = (cnt == 5'd16);
          assign CLKFBOUT = CLKFBIN;
          assign CLKOUT0 = CLKIN;
          assign CLKOUT1 = CLKIN;\
        """,
        drives: ~w(LOCKED CLKFBOUT CLKOUT0 CLKOUT1)
      },
      "IDELAYE3" => %{
        params: [
          CASCADE: "NONE",
          DELAY_FORMAT: "TIME",
          DELAY_SRC: "IDATAIN",
          DELAY_TYPE: "FIXED",
          DELAY_VALUE: 0,
          IS_CLK_INVERTED: {:bits, 1, 0},
          IS_RST_INVERTED: {:bits, 1, 0},
          REFCLK_FREQUENCY: 300,
          SIM_DEVICE: "ULTRASCALE_PLUS",
          UPDATE_MODE: "ASYNC"
        ],
        reals: [:REFCLK_FREQUENCY],
        ports:
          "c:CLK i:CASC_IN i:CASC_RETURN i:CE i:CNTVALUEIN[9] i:DATAIN i:EN_VTC i:IDATAIN " <>
            "i:INC i:LOAD i:RST o:CASC_OUT o:CNTVALUEOUT[9] o:DATAOUT",
        ties: [EN_VTC: 1],
        comb: [DATAOUT: [:IDATAIN, :DATAIN]],
        model: Models.IdelayE3,
        stub: "assign DATAOUT = IDATAIN;",
        drives: ~w(DATAOUT)
      },
      "ODELAYE3" => %{
        params: [
          CASCADE: "NONE",
          DELAY_FORMAT: "TIME",
          DELAY_TYPE: "FIXED",
          DELAY_VALUE: 0,
          IS_CLK_INVERTED: {:bits, 1, 0},
          IS_RST_INVERTED: {:bits, 1, 0},
          REFCLK_FREQUENCY: 300,
          SIM_DEVICE: "ULTRASCALE_PLUS",
          UPDATE_MODE: "ASYNC"
        ],
        reals: [:REFCLK_FREQUENCY],
        ports:
          "c:CLK i:CASC_IN i:CASC_RETURN i:CE i:CNTVALUEIN[9] i:EN_VTC i:INC i:LOAD " <>
            "i:ODATAIN i:RST o:CASC_OUT o:CNTVALUEOUT[9] o:DATAOUT",
        ties: [EN_VTC: 1],
        comb: [DATAOUT: [:ODATAIN]],
        model: Models.OdelayE3,
        stub: "assign DATAOUT = ODATAIN;",
        drives: ~w(DATAOUT)
      },
      "STARTUPE3" => %{
        params: [PROG_USR: "FALSE", SIM_CCLK_FREQ: 0],
        reals: [:SIM_CCLK_FREQ],
        ports:
          "i:DO[4] i:DTS[4] i:FCSBO i:FCSBTS i:GSR i:GTS i:KEYCLEARB i:PACK i:USRCCLKO " <>
            "i:USRCCLKTS i:USRDONEO i:USRDONETS o:CFGCLK o:CFGMCLK o:DI[4] o:EOS o:PREQ",
        ties: [KEYCLEARB: 1, DTS: 15, FCSBTS: 1, USRCCLKTS: 1],
        model: Models.Startupe3,
        stub: "assign EOS = 1'b1;",
        drives: ~w(EOS)
      },
      "DNA_PORTE2" => %{
        params: [SIM_DNA_VALUE: {:bits, 96, 0}],
        ports: "c:CLK i:DIN i:READ i:SHIFT o:DOUT",
        model: Models.DnaPorte2,
        stub: """
        logic [95:0] sr;
          always_ff @(posedge CLK)
            if (READ) sr <= SIM_DNA_VALUE;
            else if (SHIFT) sr <= {sr[94:0], DIN};
          assign DOUT = sr[95];\
        """,
        drives: ~w(DOUT)
      },
      "SYSMONE4" => %{
        params: [COMMON_N_SOURCE: {:bits, 16, 0xFFFF}, SIM_MONITOR_FILE: "design.txt"],
        ports:
          "c:DCLK i:DEN i:DWE i:DADDR[8]? i:DI[16] i:RESET i:CONVST i:CONVSTCLK i:VP i:VN " <>
            "i:VAUXP[16] i:VAUXN[16] i:I2C_SCLK? i:I2C_SDA? o:DO[16] o:DRDY o:ALM[16] o:OT " <>
            "o:EOC o:EOS o:BUSY o:CHANNEL[6] o:MUXADDR[5] o:JTAGBUSY o:JTAGLOCKED " <>
            "o:JTAGMODIFIED o:I2C_SCLK_TS? o:I2C_SDA_TS? o:SMBALERT_TS? o:ADC_DATA[16]?"
      },
      "GTYE4_COMMON" => %{
        params: [
          QPLL0_FBDIV: 66,
          QPLL0_REFCLK_DIV: 1,
          QPLL1_FBDIV: 66,
          QPLL1_REFCLK_DIV: 1,
          SIM_RESET_SPEEDUP: "TRUE",
          SIM_VERSION: 2
        ],
        ports:
          "c:DRPCLK c:QPLL0LOCKDETCLK c:QPLL1LOCKDETCLK i:GTREFCLK00 i:GTREFCLK01 i:GTREFCLK10 " <>
            "i:GTREFCLK11 i:GTGREFCLK0 i:GTGREFCLK1 i:GTNORTHREFCLK00 i:GTNORTHREFCLK10 " <>
            "i:GTSOUTHREFCLK00 i:GTSOUTHREFCLK10 i:QPLL0REFCLKSEL[3] i:QPLL1REFCLKSEL[3] " <>
            "i:QPLL0LOCKEN i:QPLL1LOCKEN i:QPLL0PD i:QPLL1PD i:QPLL0RESET i:QPLL1RESET " <>
            "i:BGBYPASSB i:BGMONITORENB i:BGPDB i:BGRCALOVRD[5] i:BGRCALOVRDENB i:RCALENB " <>
            "i:DRPADDR[16]? i:DRPDI[16] i:DRPEN i:DRPWE o:DRPDO[16] o:DRPRDY " <>
            "o:QPLL0OUTCLK o:QPLL0OUTREFCLK o:QPLL1OUTCLK o:QPLL1OUTREFCLK o:QPLL0LOCK " <>
            "o:QPLL1LOCK o:QPLL0FBCLKLOST o:QPLL1FBCLKLOST o:QPLL0REFCLKLOST o:QPLL1REFCLKLOST " <>
            "o:REFCLKOUTMONITOR0 o:REFCLKOUTMONITOR1 o:QPLLDMONITOR0[8]? o:QPLLDMONITOR1[8]?",
        ties: [BGBYPASSB: 1, BGMONITORENB: 1, BGPDB: 1, BGRCALOVRDENB: 1, RCALENB: 1],
        unsure_note: "reference clock pairs, BG*/RCAL* tie-offs and DRPADDR width"
      },
      "GTYE4_CHANNEL" => %{
        params: [
          CPLL_FBDIV: 4,
          CPLL_FBDIV_45: 5,
          CPLL_REFCLK_DIV: 1,
          RXOUT_DIV: 1,
          TXOUT_DIV: 1,
          RX_DATA_WIDTH: 64,
          TX_DATA_WIDTH: 64,
          RX_INT_DATAWIDTH: 2,
          TX_INT_DATAWIDTH: 2,
          RX_PROGDIV_CFG: 0,
          TX_PROGDIV_CFG: 0,
          RXGEARBOX_EN: "FALSE",
          TXGEARBOX_EN: "FALSE",
          GEARBOX_MODE: {:bits, 5, 0},
          SIM_RESET_SPEEDUP: "TRUE"
        ],
        reals: [:RX_PROGDIV_CFG, :TX_PROGDIV_CFG],
        ports:
          "c:TXUSRCLK c:TXUSRCLK2 c:RXUSRCLK c:RXUSRCLK2 c:DRPCLK c:CPLLLOCKDETCLK " <>
            "i:GTYRXP i:GTYRXN o:GTYTXP o:GTYTXN " <>
            "i:GTREFCLK0 i:GTREFCLK1 i:GTNORTHREFCLK0 i:GTNORTHREFCLK1 i:GTSOUTHREFCLK0 " <>
            "i:GTSOUTHREFCLK1 i:GTGREFCLK i:QPLL0CLK i:QPLL0REFCLK i:QPLL1CLK i:QPLL1REFCLK " <>
            "i:CPLLREFCLKSEL[3] i:CPLLLOCKEN i:CPLLPD i:CPLLRESET i:TXPLLCLKSEL[2] " <>
            "i:RXPLLCLKSEL[2] i:TXSYSCLKSEL[2] i:RXSYSCLKSEL[2] i:TXOUTCLKSEL[3] " <>
            "i:RXOUTCLKSEL[3] i:TXRATE[3]? i:RXRATE[3]? i:LOOPBACK[3] " <>
            "i:GTTXRESET i:GTRXRESET i:TXPROGDIVRESET i:RXPROGDIVRESET i:TXUSERRDY " <>
            "i:RXUSERRDY i:RESETOVRD i:EYESCANRESET i:RXPMARESET? i:TXPMARESET? " <>
            "i:TXPD[2] i:RXPD[2] i:TXELECIDLE i:TXPOLARITY i:RXPOLARITY i:RXLPMEN " <>
            "i:RXGEARBOXSLIP i:TXDIFFCTRL[5] i:TXPOSTCURSOR[5] i:TXPRECURSOR[5] " <>
            "i:TXDATA[128]@txusrclk2 i:TXCTRL0[16]@txusrclk2 i:TXCTRL1[16]@txusrclk2 " <>
            "i:TXCTRL2[8]@txusrclk2 i:TXHEADER[6]@txusrclk2 i:TXSEQUENCE[7]@txusrclk2 " <>
            "o:RXDATA[128]@rxusrclk2 o:RXCTRL0[16]@rxusrclk2 o:RXCTRL1[16]@rxusrclk2 " <>
            "o:RXCTRL2[8]@rxusrclk2 o:RXCTRL3[8]@rxusrclk2 o:RXHEADER[6]@rxusrclk2 " <>
            "o:RXHEADERVALID[2]@rxusrclk2 o:RXDATAVALID[2]@rxusrclk2 " <>
            "o:RXSTARTOFSEQ[2]@rxusrclk2 " <>
            "i:DRPADDR[10] i:DRPDI[16] i:DRPEN i:DRPWE o:DRPDO[16] o:DRPRDY " <>
            "o:TXOUTCLK o:RXOUTCLK o:TXOUTCLKFABRIC? o:RXOUTCLKFABRIC? " <>
            "o:CPLLLOCK o:CPLLFBCLKLOST o:CPLLREFCLKLOST o:GTPOWERGOOD o:TXRESETDONE " <>
            "o:RXRESETDONE o:TXPMARESETDONE o:RXPMARESETDONE o:TXPROGDIVRESETDONE " <>
            "o:RXPROGDIVRESETDONE o:RXCDRLOCK o:RXELECIDLE o:TXBUFSTATUS[2] o:RXBUFSTATUS[3]",
        unsure_note:
          "channel ports are a working subset of the several hundred in UG578; " <>
            "TXRATE/RXRATE and the PMARESET and OUTCLKFABRIC names need checking"
      },
      "PCIE4CE4" => %{
        ports:
          "d:user i:PIPECLK? i:CORECLK? i:USERCLK? i:MCAPCLK? i:DRPCLK? " <>
            "o:MAXISCQTDATA[512]@user? o:MAXISCQTUSER[183]@user? o:MAXISCQTVALID@user? " <>
            "o:MAXISCQTLAST@user? o:MAXISCQTKEEP[16]@user? i:MAXISCQTREADY@user? " <>
            "o:MAXISRCTDATA[512]@user? o:MAXISRCTUSER[161]@user? o:MAXISRCTVALID@user? " <>
            "o:MAXISRCTLAST@user? o:MAXISRCTKEEP[16]@user? i:MAXISRCTREADY@user? " <>
            "i:SAXISCCTDATA[512]@user? i:SAXISCCTUSER[81]@user? i:SAXISCCTVALID@user? " <>
            "i:SAXISCCTLAST@user? i:SAXISCCTKEEP[16]@user? o:SAXISCCTREADY[4]@user? " <>
            "i:SAXISRQTDATA[512]@user? i:SAXISRQTUSER[137]@user? i:SAXISRQTVALID@user? " <>
            "i:SAXISRQTLAST@user? i:SAXISRQTKEEP[16]@user? o:SAXISRQTREADY[4]@user?",
        unsure_note:
          "only the four AXI4-Stream requester/completer interfaces, from memory and at 512 bits; " <>
            "the PIPE side, configuration and clock ports are not listed. Use the XDMA wrapper " <>
            "(`ExHdlXilinx.Vivado.IP.xdma/1`) for real designs"
      }
    }
  end
end
