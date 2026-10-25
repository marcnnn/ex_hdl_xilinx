defmodule ExHdlXilinx.Primitives.Ram do
  @moduledoc """
  Behavioural models of RAMB36E2, RAMB18E2, URAM288_BASE and URAM288: an
  Elixir `ExHdl.RTL.Model` for the BEAM simulator and the SystemVerilog
  simulation source of the same behaviour (`sv/1`), so that Verilator and
  the BEAM simulator agree cycle by cycle (`test/ram_test.exs` compares them
  with random stimulus).

  ## RAMB36E2 and RAMB18E2

  True dual port with independent widths, and simple dual port.

    * Widths `READ_WIDTH_A/B`, `WRITE_WIDTH_A/B`: 0 (port does not read or
      write), 1, 2, 4, 9, 18, 36; RAMB36E2 also 72, RAMB18E2 36, in simple
      dual port: `READ_WIDTH_A` wide with the second half on the `B` output
      pins, `WRITE_WIDTH_B` wide with the second half on the `B` input pins,
      `READ_WIDTH_B` and `WRITE_WIDTH_A` 0.
    * The memory is a data array and a parity array, as on the device. A
      word of `W >= 9` bits has `W / 9` parity bits; the address drops
      `log2(W)` (`log2(W / 9) + 3` from 9 bits up) low bits, so mixed-width
      access to the same cells works. `WEA`/`WEBWE` bit `i` writes byte `i`
      of the word (data bits `8i+7:8i` and parity bit `i`); widths below 9
      use bit 0.
    * A clock edge with `EN` high reads (and writes) at the address. The
      read goes to the output latch after one edge; with `DOA_REG` or
      `DOB_REG` 1 a second register follows (loaded when `REGCE` is high), for
      two edges of latency. `WRITE_MODE_A/B` (`NO_CHANGE`, the Vivado
      default, `READ_FIRST`, `WRITE_FIRST`) gives the output on a write
      cycle: held, old word, new word.
    * `RSTRAM` (with `EN`) loads `SRVAL` into the latch, `RSTREG` loads it
      into the output register (priority over `REGCE`). `INIT_A/B` is the
      power-up output value. 36 bits (18 for RAMB18E2) are `{parity, data}`;
      in simple dual port with a wide read, `INIT`/`SRVAL` of `B` is the
      upper half.
    * The memory content starts at 0.

  ## URAM288_BASE and URAM288

  4096 x 72 bit, two ports on one `CLK`, address bits 11:0 (the upper bits
  select a URAM in a cascade and are ignored). `EN` and `RDB_WR` select a
  read (0) or a write (1) with the byte enables `BWE` (bit `i` writes data
  bits `8i+7:8i`, for both `BWE_MODE`s). A read gives `DOUT` after one edge,
  `OREG` TRUE adds an output register (clock enable `OREG_CE`) and
  `IREG_PRE` TRUE an input register in front, so latency is 1 + OREG +
  IREG_PRE edges. `RST` clears the last output stage, synchronously. Both
  ports read the memory as it was before the edge; writes then apply A, then
  B (B wins on the same address). `DOUT` holds during a write.

  ## Accuracy limits

  Not modelled: ECC (`DBITERR`, `SBITERR` are 0 and injection is ignored),
  cascades (RAMB36E2 `CAS*`, URAM `CAS_*`, `CASCADE_ORDER`), `SLEEP` and
  auto sleep, `RDACCESS` beyond "a read reached the array last edge",
  asynchronous `RST_MODE` (treated as synchronous), `IS_*_INVERTED`, the
  `INIT_xx`/`INITP_xx` memory contents of the block RAMs (not parameters of
  the black box here: 144 hex parameters per instance), `ADDREN`, address
  collisions between ports of a block RAM (undefined on the device; here the
  result depends on the simulator, keep the addresses apart or use one
  port), and timing violations. Behaviour the data sheet leaves to me and
  that is unverified on silicon: reset gated by `EN`, `NO_CHANGE` as the
  Vivado default, `DOUT` holding during a URAM write, `RST` acting on the
  last stage only, B winning an A/B write collision on a URAM.
  """

  import Bitwise

  @ramb %{
    36 => %{
      dbits: 32,
      pbits: 4,
      mem_d: 32768,
      mem_p: 4096,
      aw: 15,
      max: 36,
      sdp: 72,
      wea: 4,
      web: 8
    },
    18 => %{
      dbits: 16,
      pbits: 2,
      mem_d: 16384,
      mem_p: 2048,
      aw: 14,
      max: 18,
      sdp: 36,
      wea: 2,
      web: 4
    }
  }

  @doc "Geometry of RAMB36E2 (`36`) or RAMB18E2 (`18`)."
  def geometry(size), do: Map.fetch!(@ramb, size)

  @doc "Valid widths of a block RAM."
  def widths(size), do: [0, 1, 2, 4, 9, 18, 36] ++ if(size == 36, do: [72], else: [])

  # -- helpers shared by the models -----------------------------------------------------

  @doc false
  def mask(n), do: (1 <<< n) - 1

  @doc false
  def lo_bits(w) when w in [1, 2, 4], do: round(:math.log2(w))
  def lo_bits(w) when w in [9, 18, 36, 72], do: round(:math.log2(div(w, 9))) + 3
  def lo_bits(_), do: 0

  # -- SystemVerilog ---------------------------------------------------------------------

  @doc """
  The module body (between the port list and `endmodule`) that simulates
  `:ramb36`, `:ramb18`, `:uram288_base` or `:uram288` in SystemVerilog.
  """
  @spec sv(:ramb36 | :ramb18 | :uram288_base | :uram288) :: String.t()
  def sv(:ramb36), do: ramb_sv(36)
  def sv(:ramb18), do: ramb_sv(18)
  def sv(:uram288_base), do: uram_sv(false)
  def sv(:uram288), do: uram_sv(true)

  defp ramb_sv(size) do
    g = geometry(size)

    head = """
    /* verilator lint_off WIDTH */
      /* verilator lint_off BLKSEQ */
      /* verilator lint_off INITIALDLY */
      /* verilator lint_off LATCH */
      localparam int DB = #{g.dbits};
      localparam int PB = #{g.pbits};
      localparam int MAXW = #{g.max};
      logic md [0:#{g.mem_d - 1}];
      logic mp [0:#{g.mem_p - 1}];
      logic [71:0] lat_a, lat_b, reg_a, reg_b;
      initial begin
        for (int i = 0; i < #{g.mem_d}; i++) md[i] = 1'b0;
        for (int i = 0; i < #{g.mem_p}; i++) mp[i] = 1'b0;
      end

      function automatic int lo_bits(input int w);
        case (w)
          1: return 0;
          2: return 1;
          4: return 2;
          9: return 3;
          18: return 4;
          36: return 5;
          72: return 6;
          default: return 0;
        endcase
      endfunction

      function automatic int dw(input int w);
        return w - w / 9;
      endfunction

      // {parity[7:0], data[63:0]} of the word at addr, w bits wide
      function automatic logic [71:0] rd(input logic [14:0] addr, input int w);
        logic [71:0] r;
        int word;
        r = '0;
        word = int'(addr) >> lo_bits(w);
        for (int i = 0; i < dw(w); i++) r[i] = md[word * dw(w) + i];
        for (int i = 0; i < w / 9; i++) r[64 + i] = mp[word * (w / 9) + i];
        return r;
      endfunction

      task automatic wr(input logic [14:0] addr, input int w, input logic [7:0] we,
                        input logic [63:0] din, input logic [7:0] dinp);
        int word, lanes, lb;
        word = int'(addr) >> lo_bits(w);
        lanes = (w >= 9) ? w / 9 : 1;
        lb = (w >= 9) ? 8 : w;
        for (int l = 0; l < lanes; l++)
          if (we[l]) begin
            for (int i = 0; i < lb; i++) md[word * dw(w) + l * lb + i] = din[l * lb + i];
            if (w >= 9) mp[word * (w / 9) + l] = dinp[l];
          end
      endtask

      function automatic logic [7:0] lane_mask(input int w);
        return (w >= 9) ? 8'((1 << (w / 9)) - 1) : 8'd1;
      endfunction

      // INIT or SRVAL of the ports as {parity, data}; the B half joins in simple dual port
      function automatic logic [71:0] pack(input logic [35:0] a, input logic [35:0] b, input bit sdp);
        logic [71:0] r;
        r = '0;
        r[DB - 1:0] = a[DB - 1:0];
        r[64 + PB - 1:64] = a[DB + PB - 1:DB];
        if (sdp) begin
          r[2 * DB - 1:DB] = b[DB - 1:0];
          r[64 + 2 * PB - 1:64 + PB] = b[DB + PB - 1:DB];
        end
        return r;
      endfunction

      localparam bit SDP = READ_WIDTH_A > MAXW;
      localparam logic [71:0] INIT_VEC_A = pack(36'(INIT_A), 36'(INIT_B), SDP);
      localparam logic [71:0] INIT_VEC_B = SDP ? 72'd0 : pack(36'(INIT_B), 36'd0, 1'b0);
      localparam logic [71:0] SRVAL_VEC_A = pack(36'(SRVAL_A), 36'(SRVAL_B), SDP);
      localparam logic [71:0] SRVAL_VEC_B = SDP ? 72'd0 : pack(36'(SRVAL_B), 36'd0, 1'b0);
      initial begin
        lat_a = INIT_VEC_A;
        reg_a = INIT_VEC_A;
        lat_b = INIT_VEC_B;
        reg_b = INIT_VEC_B;
      end

      wire [71:0] out_a = (DOA_REG != 0) ? reg_a : lat_a;
      wire [71:0] out_b = (DOB_REG != 0) ? reg_b : lat_b;
      assign DOUTADOUT = out_a[DB - 1:0];
      assign DOUTPADOUTP = out_a[64 + PB - 1:64];
      assign DOUTBDOUT = SDP ? out_a[2 * DB - 1:DB] : out_b[DB - 1:0];
      assign DOUTPBDOUTP = SDP ? out_a[64 + 2 * PB - 1:64 + PB] : out_b[64 + PB - 1:64];

      logic [71:0] rv_a, rv_b;
      logic wen_a, wen_b;
      logic [7:0] we_a, we_b;
      logic [63:0] din_b;
      logic [7:0] dinp_b;
    """

    port_a = """

      always @(posedge CLKARDCLK) begin
        if (ENARDEN) begin
          we_a = 8'(WEA) & lane_mask(WRITE_WIDTH_A);
          wen_a = (WRITE_WIDTH_A != 0) && (we_a != 0);
          rv_a = (READ_WIDTH_A != 0) ? rd(ADDRARDADDR, READ_WIDTH_A) : lat_a;
          if (wen_a) wr(ADDRARDADDR, WRITE_WIDTH_A, we_a, 64'(DINADIN), 8'(DINPADINP));
          if (READ_WIDTH_A != 0) begin
            if (wen_a && WRITE_MODE_A == "NO_CHANGE") ;
            else if (wen_a && WRITE_MODE_A == "WRITE_FIRST") lat_a <= rd(ADDRARDADDR, READ_WIDTH_A);
            else lat_a <= rv_a;
          end
          if (RSTRAMARSTRAM) lat_a <= SRVAL_VEC_A;
        end
        if (DOA_REG != 0) begin
          if (RSTREGARSTREG && (RSTREG_PRIORITY_A == "RSTREG" || REGCEAREGCE)) reg_a <= SRVAL_VEC_A;
          else if (REGCEAREGCE && !RSTREGARSTREG) reg_a <= lat_a;
        end
      end
    """

    port_b = """

      always @(posedge CLKBWRCLK) begin
        if (ENBWREN) begin
          we_b = 8'(WEBWE) & lane_mask(WRITE_WIDTH_B);
          wen_b = (WRITE_WIDTH_B != 0) && (we_b != 0);
          din_b = (WRITE_WIDTH_B > MAXW) ? {DINBDIN, DINADIN} : 64'(DINBDIN);
          dinp_b = (WRITE_WIDTH_B > MAXW) ? {DINPBDINP, DINPADINP} : 8'(DINPBDINP);
          rv_b = (READ_WIDTH_B != 0) ? rd(ADDRBWRADDR, READ_WIDTH_B) : lat_b;
          if (wen_b) wr(ADDRBWRADDR, WRITE_WIDTH_B, we_b, din_b, dinp_b);
          if (READ_WIDTH_B != 0) begin
            if (wen_b && WRITE_MODE_B == "NO_CHANGE") ;
            else if (wen_b && WRITE_MODE_B == "WRITE_FIRST") lat_b <= rd(ADDRBWRADDR, READ_WIDTH_B);
            else lat_b <= rv_b;
          end
          if (RSTRAMB) lat_b <= SRVAL_VEC_B;
        end
        if (DOB_REG != 0) begin
          if (RSTREGB && (RSTREG_PRIORITY_B == "RSTREG" || REGCEB)) reg_b <= SRVAL_VEC_B;
          else if (REGCEB && !RSTREGB) reg_b <= lat_b;
        end
      end
      /* verilator lint_on LATCH */
      /* verilator lint_on INITIALDLY */
      /* verilator lint_on BLKSEQ */
      /* verilator lint_on WIDTH */\
    """

    String.trim_trailing(head) <> port_a <> port_b
  end

  defp uram_sv(full?) do
    rd_access =
      if full?,
        do: "\n  assign RDACCESS_A = vld_a;\n  assign RDACCESS_B = vld_b;",
        else: ""

    """
    /* verilator lint_off WIDTH */
      /* verilator lint_off BLKSEQ */
      /* verilator lint_off INITIALDLY */
      logic [71:0] mem [0:4095];
      logic [71:0] lat_a, lat_b, out_a, out_b;
      logic vld_a, vld_b;
      // input registers (IREG_PRE)
      logic pen_a, pwr_a, pen_b, pwr_b;
      logic [11:0] pad_a, pad_b;
      logic [8:0] pbw_a, pbw_b;
      logic [71:0] pdi_a, pdi_b;
      initial begin
        for (int i = 0; i < 4096; i++) mem[i] = '0;
        lat_a = '0; lat_b = '0; out_a = '0; out_b = '0; vld_a = 1'b0; vld_b = 1'b0;
        pen_a = 1'b0; pwr_a = 1'b0; pen_b = 1'b0; pwr_b = 1'b0;
        pad_a = '0; pad_b = '0; pbw_a = '0; pbw_b = '0; pdi_a = '0; pdi_b = '0;
      end

      wire ia = (IREG_PRE_A == "TRUE");
      wire ib = (IREG_PRE_B == "TRUE");
      wire ea = ia ? pen_a : EN_A;
      wire wa = ia ? pwr_a : RDB_WR_A;
      wire [11:0] aa = ia ? pad_a : ADDR_A[11:0];
      wire [8:0] ba = ia ? pbw_a : BWE_A;
      wire [71:0] da = ia ? pdi_a : DIN_A;
      wire eb = ib ? pen_b : EN_B;
      wire wb = ib ? pwr_b : RDB_WR_B;
      wire [11:0] ab = ib ? pad_b : ADDR_B[11:0];
      wire [8:0] bb = ib ? pbw_b : BWE_B;
      wire [71:0] db = ib ? pdi_b : DIN_B;

      assign DOUT_A = (OREG_A == "TRUE") ? out_a : lat_a;
      assign DOUT_B = (OREG_B == "TRUE") ? out_b : lat_b;#{rd_access}

      always @(posedge CLK) begin
        // both ports read the memory as it was before the edge
        vld_a <= ea && !wa;
        vld_b <= eb && !wb;
        if (ea && !wa) lat_a <= mem[aa];
        if (eb && !wb) lat_b <= mem[ab];
        if (ea && wa)
          for (int i = 0; i < 9; i++) if (ba[i]) mem[aa][8 * i +: 8] = da[8 * i +: 8];
        if (eb && wb)
          for (int i = 0; i < 9; i++) if (bb[i]) mem[ab][8 * i +: 8] = db[8 * i +: 8];
        // output stage
        if (OREG_A == "TRUE") begin
          if (RST_A) out_a <= '0;
          else if (OREG_CE_A) out_a <= lat_a;
        end else if (RST_A) lat_a <= '0;
        if (OREG_B == "TRUE") begin
          if (RST_B) out_b <= '0;
          else if (OREG_CE_B) out_b <= lat_b;
        end else if (RST_B) lat_b <= '0;
        pen_a <= EN_A; pwr_a <= RDB_WR_A; pad_a <= ADDR_A[11:0]; pbw_a <= BWE_A; pdi_a <= DIN_A;
        pen_b <= EN_B; pwr_b <= RDB_WR_B; pad_b <= ADDR_B[11:0]; pbw_b <= BWE_B; pdi_b <= DIN_B;
      end
      /* verilator lint_on INITIALDLY */
      /* verilator lint_on BLKSEQ */
      /* verilator lint_on WIDTH */\
    """
  end

  defmodule Ramb do
    @moduledoc false
    @behaviour ExHdl.RTL.Model
    import Bitwise
    alias ExHdlXilinx.Primitives.Ram

    # state: %{size, g, d, p, a: port, b: port}; port: %{rw, ww, mode, reg?, init, srval, lat, reg}
    # lat and reg are {data, parity}.
    @impl true
    def init(_), do: raise(ArgumentError, "the RAMB models need `model: {Ramb, 36 | 18}`")

    @impl true
    def init(params, size) do
      g = Ram.geometry(size)

      for k <- [:READ_WIDTH_A, :READ_WIDTH_B, :WRITE_WIDTH_A, :WRITE_WIDTH_B],
          params[k] not in Ram.widths(size),
          do:
            raise(ArgumentError, "RAMB#{size}E2 #{k} #{inspect(params[k])} is not a valid width")

      ra = params[:READ_WIDTH_A]
      sdp? = ra > g.max
      ia = split(num(params[:INIT_A]), g)
      ib = split(num(params[:INIT_B]), g)
      sa = split(num(params[:SRVAL_A]), g)
      sb = split(num(params[:SRVAL_B]), g)

      port = fn rw, ww, mode, reg, init, srval, prio ->
        %{
          rw: rw,
          ww: ww,
          mode: mode,
          reg?: reg != 0,
          prio: prio,
          init: init,
          srval: srval,
          lat: init,
          reg: init
        }
      end

      {ia, sa} = if sdp?, do: {join(ia, ib, g), join(sa, sb, g)}, else: {ia, sa}
      {ib, sb} = if sdp?, do: {{0, 0}, {0, 0}}, else: {ib, sb}

      %{
        size: size,
        g: g,
        sdp: sdp?,
        d: 0,
        p: 0,
        a:
          port.(
            ra,
            params[:WRITE_WIDTH_A],
            params[:WRITE_MODE_A],
            params[:DOA_REG],
            ia,
            sa,
            params[:RSTREG_PRIORITY_A]
          ),
        b:
          port.(
            params[:READ_WIDTH_B],
            params[:WRITE_WIDTH_B],
            params[:WRITE_MODE_B],
            params[:DOB_REG],
            ib,
            sb,
            params[:RSTREG_PRIORITY_B]
          )
      }
    end

    defp num({:bits, _, v}), do: v
    defp num(v) when is_integer(v), do: v
    defp num(_), do: 0

    defp split(v, g), do: {v &&& Ram.mask(g.dbits), v >>> g.dbits &&& Ram.mask(g.pbits)}

    defp join({da, pa}, {db, pb}, g), do: {da ||| db <<< g.dbits, pa ||| pb <<< g.pbits}

    @impl true
    def outputs(s, _) do
      g = s.g
      {da, pa} = out(s.a)
      {db, pb} = out(s.b)

      {db, pb} =
        if s.sdp,
          do: {da >>> g.dbits &&& Ram.mask(g.dbits), pa >>> g.pbits &&& Ram.mask(g.pbits)},
          else: {db, pb}

      %{
        DOUTADOUT: da &&& Ram.mask(g.dbits),
        DOUTPADOUTP: pa &&& Ram.mask(g.pbits),
        DOUTBDOUT: db,
        DOUTPBDOUTP: pb
      }
    end

    defp out(%{reg?: true, reg: r}), do: r
    defp out(%{lat: l}), do: l

    @impl true
    def clock(:clkardclk, s, ins) do
      port = [en: ins[:ENARDEN], we: ins[:WEA], addr: ins[:ADDRARDADDR], rst: ins[:RSTRAMARSTRAM]]

      din = {ins[:DINADIN], ins[:DINPADINP]}
      step(s, :a, port, din, {ins[:REGCEAREGCE], ins[:RSTREGARSTREG]})
    end

    def clock(:clkbwrclk, s, ins) do
      port = [en: ins[:ENBWREN], we: ins[:WEBWE], addr: ins[:ADDRBWRADDR], rst: ins[:RSTRAMB]]

      g = s.g

      din =
        if s.b.ww > g.max,
          do:
            {ins[:DINADIN] ||| ins[:DINBDIN] <<< g.dbits,
             ins[:DINPADINP] ||| ins[:DINPBDINP] <<< g.pbits},
          else: {ins[:DINBDIN], ins[:DINPBDINP]}

      step(s, :b, port, din, {ins[:REGCEB], ins[:RSTREGB]})
    end

    defp step(s, which, port, {din, dinp}, {regce, rstreg}) do
      p = Map.fetch!(s, which)
      addr = port[:addr]
      lanes = max(1, div(p.ww, 9))
      we = port[:we] &&& Ram.mask(lanes)
      wen = p.ww != 0 and we != 0

      {lat, s} =
        if port[:en] == 1 do
          old = if p.rw != 0, do: read(s, addr, p.rw), else: p.lat
          s = if wen, do: write(s, addr, p.ww, we, din, dinp), else: s

          lat =
            cond do
              p.rw == 0 -> p.lat
              wen and p.mode == "NO_CHANGE" -> p.lat
              wen and p.mode == "WRITE_FIRST" -> read(s, addr, p.rw)
              true -> old
            end

          {if(port[:rst] == 1, do: p.srval, else: lat), s}
        else
          {p.lat, s}
        end

      reg =
        cond do
          not p.reg? -> p.reg
          rstreg == 1 and (p.prio == "RSTREG" or regce == 1) -> p.srval
          regce == 1 and rstreg != 1 -> p.lat
          regce == 1 -> p.reg
          true -> p.reg
        end

      Map.put(s, which, %{p | lat: lat, reg: reg})
    end

    defp read(s, addr, w) do
      word = addr >>> Ram.lo_bits(w)
      d = w - div(w, 9)
      pb = div(w, 9)
      {s.d >>> (word * d) &&& Ram.mask(d), s.p >>> (word * pb) &&& Ram.mask(pb)}
    end

    defp write(s, addr, w, we, din, dinp) do
      word = addr >>> Ram.lo_bits(w)
      d = w - div(w, 9)
      pb = div(w, 9)
      lanes = max(1, pb)
      lb = if w >= 9, do: 8, else: w

      Enum.reduce(0..(lanes - 1), s, fn l, s ->
        if (we >>> l &&& 1) == 1 do
          at = word * d + l * lb

          s = %{
            s
            | d:
                (s.d &&& bnot(Ram.mask(lb) <<< at)) ||| (din >>> (l * lb) &&& Ram.mask(lb)) <<< at
          }

          if pb > 0 do
            bit = word * pb + l
            %{s | p: (s.p &&& bnot(1 <<< bit)) ||| (dinp >>> l &&& 1) <<< bit}
          else
            s
          end
        else
          s
        end
      end)
    end
  end

  defmodule Uram do
    @moduledoc false
    @behaviour ExHdl.RTL.Model
    import Bitwise
    alias ExHdlXilinx.Primitives.Ram

    @impl true
    def init(params), do: init(params, :base)

    @impl true
    def init(params, kind) do
      port = fn x ->
        %{
          ireg: params[:"IREG_PRE_#{x}"] == "TRUE",
          oreg: params[:"OREG_#{x}"] == "TRUE",
          pre: nil,
          lat: 0,
          out: 0,
          valid: 0
        }
      end

      %{kind: kind, mem: %{}, a: port.("A"), b: port.("B")}
    end

    @impl true
    def outputs(s, _) do
      base = %{
        DOUT_A: dout(s.a),
        DOUT_B: dout(s.b),
        DBITERR_A: 0,
        DBITERR_B: 0,
        SBITERR_A: 0,
        SBITERR_B: 0
      }

      if s.kind == :full,
        do: Map.merge(base, %{RDACCESS_A: s.a.valid, RDACCESS_B: s.b.valid}),
        else: base
    end

    defp dout(%{oreg: true, out: o}), do: o
    defp dout(%{lat: l}), do: l

    @impl true
    def clock(_, s0, ins) do
      ops = for x <- [:a, :b], do: {x, op(ins, x)}

      # inputs for the array: this edge's, or the input register's
      work =
        for {x, cur} <- ops do
          p = Map.fetch!(s0, x)
          {x, if(p.ireg, do: p.pre, else: cur)}
        end

      # both ports read before either writes
      s =
        Enum.reduce(work, s0, fn {x, w}, s ->
          p = Map.fetch!(s, x)
          read? = w != nil and w.en == 1 and w.wr == 0
          lat = if read?, do: Map.get(s0.mem, w.addr, 0), else: p.lat
          Map.put(s, x, %{p | lat: lat, valid: if(read?, do: 1, else: 0)})
        end)

      mem =
        Enum.reduce(work, s0.mem, fn
          {_, %{en: 1, wr: 1} = w}, mem -> write(mem, w)
          _, mem -> mem
        end)

      Enum.reduce(ops, %{s | mem: mem}, fn {x, cur}, s ->
        p = Map.fetch!(s, x)
        before = Map.fetch!(s0, x)

        p =
          cond do
            p.oreg and cur.rst == 1 -> %{p | out: 0}
            p.oreg and cur.oce == 1 -> %{p | out: before.lat}
            cur.rst == 1 -> %{p | lat: 0}
            true -> p
          end

        Map.put(s, x, %{p | pre: if(p.ireg, do: cur, else: nil)})
      end)
    end

    defp op(ins, x) do
      u = x |> Atom.to_string() |> String.upcase()
      k = fn n -> ins[:"#{n}_#{u}"] end

      %{
        en: k.(:EN),
        wr: k.(:RDB_WR),
        addr: k.(:ADDR) &&& 0xFFF,
        bwe: k.(:BWE),
        din: k.(:DIN),
        rst: k.(:RST),
        oce: k.(:OREG_CE)
      }
    end

    defp write(mem, w) do
      word = Map.get(mem, w.addr, 0)

      new =
        Enum.reduce(0..8, word, fn i, acc ->
          if (w.bwe >>> i &&& 1) == 1,
            do: (acc &&& bnot(0xFF <<< (8 * i))) ||| (w.din >>> (8 * i) &&& 0xFF) <<< (8 * i),
            else: acc
        end)

      Map.put(mem, w.addr, new)
    end
  end
end
