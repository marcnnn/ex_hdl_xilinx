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
  # `params` carry integers, strings and {:bits, w, v}; `reals` are the
  # real-valued SV parameters, emitted as `{:real, v}` (`10.0`).
  # `clock_outputs` are outputs declared `clock: true`.
  # `ties` are the values the unconnected inputs get in `Primitives.inst/3`
  # (default 0). `comb` lists the inputs an output depends on (default none).

  alias ExHdlXilinx.Primitives.{Models, Ram}

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
        clock_outputs: ~w(O ODIV2)a,
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
        clock_outputs: [:O],
        ports: "c:I o:O",
        model: Models.ClockBuf,
        stub: "assign O = I;",
        drives: ~w(O)
      },
      "BUFGCE" => %{
        clock_outputs: [:O],
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
        clock_outputs: [:O],
        params: [SIM_DEVICE: "ULTRASCALE_PLUS", STARTUP_SYNC: "FALSE"],
        ports: "i:I i:CE i:CEMASK i:CLR i:CLRMASK i:DIV[3] o:O",
        ties: [CE: 1],
        model: Models.ClockBuf,
        # Divides I by DIV + 1 (high for ceil(n / 2) input cycles); CLR holds O low unless
        # CLRMASK; CE gates it, latched while I is low, unless CEMASK. DIV = 0 is a buffer.
        stub: """
        logic [2:0] cnt;
          logic ce_l;
          wire clr_hold = CLR & ~CLRMASK;
          initial begin
            cnt = 3'd0;
            ce_l = 1'b1;
          end
          /* verilator lint_off LATCH */
          always @(*) if (!I) ce_l = CE | CEMASK;
          /* verilator lint_on LATCH */
          always @(posedge I or posedge clr_hold)
            if (clr_hold) cnt <= 3'd0;
            else cnt <= (cnt >= DIV) ? 3'd0 : cnt + 3'd1;
          wire div_hi = 4'(cnt) < ((4'(DIV) + 4'd2) >> 1);
          assign O = clr_hold ? 1'b0 : (DIV == 3'd0) ? (I & ce_l) : (div_hi & ce_l);\
        """,
        drives: ~w(O)
      },
      "MMCME4_ADV" => %{
        clock_outputs: Enum.map(@mmcm_clkout ++ ~w(CLKFBOUT CLKFBOUTB), &String.to_atom/1),
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
        # LOCKED after 16 CLKIN1 cycles (`define EXHDL_LOCK_CYCLES to change) when the VCO is in
        # range. With Verilator --timing (or any other simulator) the outputs are generated
        # from the parameters: VCO = 1000 / CLKIN1_PERIOD * CLKFBOUT_MULT_F / DIVCLK_DIVIDE,
        # CLKOUTn = VCO / divide, phase in degrees, 50 percent duty, started at a CLKIN1 edge
        # after RST falls. Without timing every output follows CLKIN1.
        stub: """
        `ifndef EXHDL_LOCK_CYCLES
          `define EXHDL_LOCK_CYCLES 16
          `endif
          localparam int LOCK_CYCLES = `EXHDL_LOCK_CYCLES;
          localparam real VCO_MHZ = (CLKIN1_PERIOD > 0.0) ?
            1000.0 * CLKFBOUT_MULT_F / (CLKIN1_PERIOD * DIVCLK_DIVIDE) : 1000.0;
          localparam bit VALID = VCO_MHZ >= 800.0 && VCO_MHZ <= 1600.0;
          logic [15:0] cnt;
          initial cnt = 16'd0;
          always_ff @(posedge CLKIN1)
            if (RST | PWRDWN) cnt <= 16'd0;
            else if (cnt != 16'(LOCK_CYCLES)) cnt <= cnt + 16'd1;
          assign LOCKED = VALID && (cnt == 16'(LOCK_CYCLES));
          assign CLKFBOUTB = 1'b0;
        `ifdef VERILATOR
          `ifdef VERILATOR_TIMING
          `define EXHDL_MMCM_TIMED
          `endif
          `else
          `define EXHDL_MMCM_TIMED
          `endif
          `ifdef EXHDL_MMCM_TIMED
          /* verilator lint_off ZERODLY */
          localparam realtime NS = 1ns;
          localparam real VCO_PERIOD = 1000.0 / VCO_MHZ;
          function automatic real out_period(input int i);
            case (i)
              0: return VCO_PERIOD * CLKOUT0_DIVIDE_F;
              1: return VCO_PERIOD * CLKOUT1_DIVIDE;
              2: return VCO_PERIOD * CLKOUT2_DIVIDE;
              3: return VCO_PERIOD * CLKOUT3_DIVIDE;
              4: return VCO_PERIOD * CLKOUT4_DIVIDE;
              5: return VCO_PERIOD * CLKOUT5_DIVIDE;
              6: return VCO_PERIOD * CLKOUT6_DIVIDE;
              default: return VCO_PERIOD * CLKFBOUT_MULT_F;
            endcase
          endfunction
          function automatic real out_phase(input int i);
            case (i)
              0: return CLKOUT0_PHASE;
              1: return CLKOUT1_PHASE;
              2: return CLKOUT2_PHASE;
              3: return CLKOUT3_PHASE;
              4: return CLKOUT4_PHASE;
              5: return CLKOUT5_PHASE;
              6: return CLKOUT6_PHASE;
              default: return 0.0;
            endcase
          endfunction
          logic running;
          logic [7:0] g, st;
          initial begin
            running = 1'b0;
            g = '0;
            st = '0;
          end
          always @(posedge CLKIN1) running <= ~(RST | PWRDWN);
          always @(posedge RST or posedge PWRDWN) running <= 1'b0;
          for (genvar i = 0; i < 8; i++) begin : gen
            real half, ph;
            initial begin
              half = out_period(i) / 2.0;
              ph = out_phase(i) / 360.0 * out_period(i);
            end
            always begin
              @(posedge running);
              #(ph * NS);
              while (running) begin
                st[i] = 1'b1;
                g[i] = 1'b1;
                #(half * NS);
                g[i] = 1'b0;
                #(half * NS);
              end
              st[i] = 1'b0;
            end
          end
          assign CLKOUT0 = g[0];
          assign CLKOUT1 = g[1];
          assign CLKOUT2 = g[2];
          assign CLKOUT3 = g[3];
          assign CLKOUT4 = g[4];
          assign CLKOUT5 = g[5];
          assign CLKOUT6 = g[6];
          assign CLKFBOUT = g[7];
          assign CLKOUT0B = st[0] ? ~g[0] : 1'b0;
          assign CLKOUT1B = st[1] ? ~g[1] : 1'b0;
          assign CLKOUT2B = st[2] ? ~g[2] : 1'b0;
          assign CLKOUT3B = st[3] ? ~g[3] : 1'b0;
          /* verilator lint_on ZERODLY */
        `else
          assign CLKFBOUT = CLKFBIN;
          assign CLKOUT0 = CLKIN1;
          assign CLKOUT1 = CLKIN1;
          assign CLKOUT2 = CLKIN1;
          assign CLKOUT3 = CLKIN1;
          assign CLKOUT4 = CLKIN1;
          assign CLKOUT5 = CLKIN1;
          assign CLKOUT6 = CLKIN1;
          assign CLKOUT0B = 1'b0;
          assign CLKOUT1B = 1'b0;
          assign CLKOUT2B = 1'b0;
          assign CLKOUT3B = 1'b0;
        `endif\
        """,
        drives:
          ~w(LOCKED CLKFBOUT CLKFBOUTB CLKOUT0 CLKOUT0B CLKOUT1 CLKOUT1B CLKOUT2 CLKOUT2B CLKOUT3 CLKOUT3B
             CLKOUT4 CLKOUT5 CLKOUT6)
      },
      "PLLE4_ADV" => %{
        clock_outputs: ~w(CLKOUT0 CLKOUT0B CLKOUT1 CLKOUT1B CLKOUTPHY CLKFBOUT)a,
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
      "RAMB36E2" => %{
        params: [
          CLOCK_DOMAINS: "INDEPENDENT",
          DOA_REG: 1,
          DOB_REG: 1,
          INIT_A: {:bits, 36, 0},
          INIT_B: {:bits, 36, 0},
          READ_WIDTH_A: 0,
          READ_WIDTH_B: 0,
          RSTREG_PRIORITY_A: "RSTREG",
          RSTREG_PRIORITY_B: "RSTREG",
          SIM_COLLISION_CHECK: "ALL",
          SLEEP_ASYNC: "FALSE",
          SRVAL_A: {:bits, 36, 0},
          SRVAL_B: {:bits, 36, 0},
          WRITE_MODE_A: "NO_CHANGE",
          WRITE_MODE_B: "NO_CHANGE",
          WRITE_WIDTH_A: 0,
          WRITE_WIDTH_B: 0
        ],
        ports:
          "c:CLKARDCLK c:CLKBWRCLK i:ADDRARDADDR[15]? i:ADDRBWRADDR[15]? i:ADDRENA i:ADDRENB " <>
            "i:DINADIN[32] i:DINBDIN[32] i:DINPADINP[4] i:DINPBDINP[4] i:ENARDEN i:ENBWREN " <>
            "i:REGCEAREGCE i:REGCEB i:RSTRAMARSTRAM i:RSTRAMB i:RSTREGARSTREG i:RSTREGB i:SLEEP " <>
            "i:WEA[4] i:WEBWE[8] o:DOUTADOUT[32] o:DOUTBDOUT[32] " <>
            "o:DOUTPADOUTP[4] o:DOUTPBDOUTP[4]",
        ties: [ADDRENA: 1, ADDRENB: 1, REGCEAREGCE: 1, REGCEB: 1],
        model: {Ram.Ramb, 36},
        stub: Ram.sv(:ramb36),
        drives: ~w(DOUTADOUT DOUTBDOUT DOUTPADOUTP DOUTPBDOUTP),
        unsure_note:
          "TDP and SDP with the commonly used parameters; no cascade (CAS*), ECC, INIT_xx/INITP_xx, " <>
            "IS_*_INVERTED; address widths (15) from memory"
      },
      "RAMB18E2" => %{
        params: [
          CLOCK_DOMAINS: "INDEPENDENT",
          DOA_REG: 1,
          DOB_REG: 1,
          INIT_A: {:bits, 18, 0},
          INIT_B: {:bits, 18, 0},
          READ_WIDTH_A: 0,
          READ_WIDTH_B: 0,
          RSTREG_PRIORITY_A: "RSTREG",
          RSTREG_PRIORITY_B: "RSTREG",
          SIM_COLLISION_CHECK: "ALL",
          SLEEP_ASYNC: "FALSE",
          SRVAL_A: {:bits, 18, 0},
          SRVAL_B: {:bits, 18, 0},
          WRITE_MODE_A: "NO_CHANGE",
          WRITE_MODE_B: "NO_CHANGE",
          WRITE_WIDTH_A: 0,
          WRITE_WIDTH_B: 0
        ],
        ports:
          "c:CLKARDCLK c:CLKBWRCLK i:ADDRARDADDR[14]? i:ADDRBWRADDR[14]? i:ADDRENA i:ADDRENB " <>
            "i:DINADIN[16] i:DINBDIN[16] i:DINPADINP[2] i:DINPBDINP[2] i:ENARDEN i:ENBWREN " <>
            "i:REGCEAREGCE i:REGCEB i:RSTRAMARSTRAM i:RSTRAMB i:RSTREGARSTREG i:RSTREGB i:SLEEP " <>
            "i:WEA[2] i:WEBWE[4] o:DOUTADOUT[16] o:DOUTBDOUT[16] " <>
            "o:DOUTPADOUTP[2] o:DOUTPBDOUTP[2]",
        ties: [ADDRENA: 1, ADDRENB: 1, REGCEAREGCE: 1, REGCEB: 1],
        model: {Ram.Ramb, 18},
        stub: Ram.sv(:ramb18),
        drives: ~w(DOUTADOUT DOUTBDOUT DOUTPADOUTP DOUTPBDOUTP),
        unsure_note:
          "TDP and SDP with the commonly used parameters; no cascade (CAS*), ECC, INIT_xx/INITP_xx, " <>
            "IS_*_INVERTED; address widths (14) from memory"
      },
      "URAM288_BASE" => %{
        params: [
          AUTO_SLEEP_LATENCY: 8,
          AVG_CONS_INACTIVE_CYCLES: 10,
          BWE_MODE_A: "PARITY_INTERLEAVED",
          BWE_MODE_B: "PARITY_INTERLEAVED",
          EN_AUTO_SLEEP_MODE: "FALSE",
          EN_ECC_RD_A: "FALSE",
          EN_ECC_RD_B: "FALSE",
          EN_ECC_WR_A: "FALSE",
          EN_ECC_WR_B: "FALSE",
          IREG_PRE_A: "FALSE",
          IREG_PRE_B: "FALSE",
          MATRIX_ID: "NONE",
          NUM_UNIQUE_SELF_ADDR_A: 1,
          NUM_UNIQUE_SELF_ADDR_B: 1,
          NUM_URAM_IN_MATRIX: 1,
          OREG_A: "FALSE",
          OREG_B: "FALSE",
          OREG_ECC_A: "FALSE",
          OREG_ECC_B: "FALSE",
          RST_MODE_A: "SYNC",
          RST_MODE_B: "SYNC",
          SELF_ADDR_A: {:bits, 11, 0},
          SELF_ADDR_B: {:bits, 11, 0},
          SELF_MASK_A: {:bits, 11, 0x7FF},
          SELF_MASK_B: {:bits, 11, 0x7FF},
          USE_EXT_CE_A: "FALSE",
          USE_EXT_CE_B: "FALSE"
        ],
        ports:
          "c:CLK i:ADDR_A[23] i:ADDR_B[23] i:BWE_A[9] i:BWE_B[9] i:DIN_A[72] i:DIN_B[72] i:EN_A i:EN_B " <>
            "i:INJECT_DBITERR_A i:INJECT_DBITERR_B i:INJECT_SBITERR_A i:INJECT_SBITERR_B " <>
            "i:OREG_CE_A i:OREG_CE_B i:OREG_ECC_CE_A i:OREG_ECC_CE_B i:RDB_WR_A i:RDB_WR_B i:RST_A i:RST_B i:SLEEP " <>
            "o:DBITERR_A o:DBITERR_B o:DOUT_A[72] o:DOUT_B[72] o:SBITERR_A o:SBITERR_B",
        ties: [OREG_CE_A: 1, OREG_CE_B: 1, OREG_ECC_CE_A: 1, OREG_ECC_CE_B: 1],
        model: {Ram.Uram, :base},
        stub: Ram.sv(:uram288_base),
        drives: ~w(DOUT_A DOUT_B),
        unsure_note:
          "single URAM without cascade (no CAS_*), ECC and INIT_xx not modelled; " <>
            "the parameter list is from memory"
      },
      "URAM288" => %{
        params: [
          AUTO_SLEEP_LATENCY: 8,
          AVG_CONS_INACTIVE_CYCLES: 10,
          BWE_MODE_A: "PARITY_INTERLEAVED",
          BWE_MODE_B: "PARITY_INTERLEAVED",
          EN_AUTO_SLEEP_MODE: "FALSE",
          EN_ECC_RD_A: "FALSE",
          EN_ECC_RD_B: "FALSE",
          EN_ECC_WR_A: "FALSE",
          EN_ECC_WR_B: "FALSE",
          IREG_PRE_A: "FALSE",
          IREG_PRE_B: "FALSE",
          MATRIX_ID: "NONE",
          NUM_UNIQUE_SELF_ADDR_A: 1,
          NUM_UNIQUE_SELF_ADDR_B: 1,
          NUM_URAM_IN_MATRIX: 1,
          OREG_A: "FALSE",
          OREG_B: "FALSE",
          OREG_ECC_A: "FALSE",
          OREG_ECC_B: "FALSE",
          RST_MODE_A: "SYNC",
          RST_MODE_B: "SYNC",
          SELF_ADDR_A: {:bits, 11, 0},
          SELF_ADDR_B: {:bits, 11, 0},
          SELF_MASK_A: {:bits, 11, 0x7FF},
          SELF_MASK_B: {:bits, 11, 0x7FF},
          USE_EXT_CE_A: "FALSE",
          USE_EXT_CE_B: "FALSE"
        ],
        ports:
          "c:CLK i:ADDR_A[23] i:ADDR_B[23] i:BWE_A[9] i:BWE_B[9] i:DIN_A[72] i:DIN_B[72] i:EN_A i:EN_B " <>
            "i:INJECT_DBITERR_A i:INJECT_DBITERR_B i:INJECT_SBITERR_A i:INJECT_SBITERR_B " <>
            "i:OREG_CE_A i:OREG_CE_B i:OREG_ECC_CE_A i:OREG_ECC_CE_B i:RDB_WR_A i:RDB_WR_B i:RST_A i:RST_B i:SLEEP " <>
            "o:DBITERR_A o:DBITERR_B o:DOUT_A[72] o:DOUT_B[72] o:SBITERR_A o:SBITERR_B o:RDACCESS_A o:RDACCESS_B",
        ties: [OREG_CE_A: 1, OREG_CE_B: 1, OREG_ECC_CE_A: 1, OREG_ECC_CE_B: 1],
        model: {Ram.Uram, :full},
        stub: Ram.sv(:uram288),
        drives: ~w(DOUT_A DOUT_B RDACCESS_A RDACCESS_B),
        unsure_note:
          "single URAM without cascade (no CAS_*), ECC and INIT_xx not modelled; " <>
            "the parameter list is from memory"
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
