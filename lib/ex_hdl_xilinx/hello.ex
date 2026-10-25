defmodule ExHdlXilinx.Hello do
  @moduledoc """
  "Hello card": the smallest design that proves clocking, reset and the LEDs
  of the AS02MC04, written with `ExHdl.RTL` and the primitives of
  `ExHdlXilinx.Primitives`.

      clk100_p/n -> IBUFDS -> MMCME4_ADV (VCO 1000 MHz) -> BUFG -> 250 MHz
                        |                              `-> BUFG -> 125 MHz
                        `-> BUFG -> 100 MHz
      MMCM LOCKED -> reset synchroniser per clock (no external reset)
      one free-running counter per clock; its top bit goes to a LED

  The LED output is a register on the 100 MHz clock, so the 250 and 125 MHz
  heartbeats cross through `ExHdl.RTL.CDC.sync_ff/1`:

  | LED | Source |
  |---|---|
  | `led[0]` | 100 MHz counter bit `blink_bit` (about 0.75 Hz toggle for 26) |
  | `led[1]` | 250 MHz counter, same bit |
  | `led[2]` | 125 MHz counter, same bit |
  | `led[3]` | MMCM `LOCKED` (steady on once the clocks run) |

  `top/1` returns the module (`blink_bit:` default 26, small values for
  simulation), `signals/0` the board signals for `ExHdlXilinx.XDC`,
  `build/1` the `ExHdlXilinx.Vivado.Build`, `write/2` the whole build
  directory, `sim/1` a BEAM simulator with the three clocks at their
  frequency ratio (periods 10, 4, 8).
  """
  use ExHdl.RTL

  alias ExHdl.RTL.{CDC, Sim}
  alias ExHdlXilinx.Primitives, as: P
  alias ExHdlXilinx.Primitives.Clocking
  alias ExHdlXilinx.Vivado.{Build, Runner}

  @signals [:clk100, {:leds, "led"}]

  @mmcm [
    CLKIN1_PERIOD: 10,
    CLKFBOUT_MULT_F: 10,
    DIVCLK_DIVIDE: 1,
    CLKOUT0_DIVIDE_F: 4,
    CLKOUT1_DIVIDE: 8
  ]

  @doc "Parameters of the MMCM instance."
  def mmcm_params, do: @mmcm

  @doc """
  The `clocks:` option of `ExHdl.RTL.Sim.new/2` and `ExHdl.RTL.Cosim`: the
  100 MHz input clock (period 10) and the MMCM outputs from its parameters
  (`ExHdlXilinx.Primitives.Clocking.sim_clocks/3`, 1 unit = 1 ns).
  """
  def clocks do
    inputs = for d <- [:ibuf, :c100], do: {d, [period: 10]}

    outs =
      Clocking.sim_clocks(@mmcm,
        CLKOUT0: :c250_raw,
        CLKOUT0: :c250,
        CLKOUT1: :c125_raw,
        CLKOUT1: :c125
      )

    inputs ++ outs
  end

  @doc "Board signals used by the top: `[:clk100, {:leds, \"led\"}]`."
  def signals, do: @signals

  @doc "The top module `hello_card` (`blink_bit:` selects the counter bit, default 26)."
  def top(opts \\ []) do
    bit = Keyword.get(opts, :blink_bit, 26)
    w = bit + 1

    module "hello_card_b#{bit}" do
      clk_p = input(:clk100_p, 1, domain: :async)
      clk_n = input(:clk100_n, 1, domain: :async)

      # clock domains: raw wires (primitive outputs), buffered clocks, and one
      # reset-synchroniser domain per buffered clock (reset = MMCM lock)
      domain(:ibuf, clock: :clk_ibuf, clock_port: false, reset: nil)

      for d <- [:c100, :c250, :c125] do
        domain(d, clock: :"clk_#{d}", clock_port: false, reset: :"rst_#{d}_n", reset_port: false)

        domain(:"#{d}_rs",
          clock: :"clk_#{d}",
          clock_port: false,
          reset: :locked_n,
          reset_kind: :async,
          reset_port: false
        )
      end

      for d <- [:c250, :c125],
          do: domain(:"#{d}_raw", clock: :"clk_#{d}_raw", clock_port: false, reset: nil)

      led = output(:led, 4, reset: 0, domain: :c100)

      ibufds =
        P.inst(:ibufds, P.ibufds(), connect: [I: clk_p, IB: clk_n], params: [DIFF_TERM: "TRUE"])

      signal(:clk_ibuf) <~ ibufds[:O]

      mmcm =
        P.inst(:mmcm, P.mmcme4_adv(),
          clocks: [clkin1: :ibuf],
          clock: :c100,
          open: [:CLKFBIN],
          params: @mmcm
        )

      mmcm[:CLKFBIN] <~ mmcm[:CLKFBOUT]
      signal(:clk_c250_raw) <~ mmcm[:CLKOUT0]
      signal(:clk_c125_raw) <~ mmcm[:CLKOUT1]
      signal(:locked_n) <~ mmcm[:LOCKED]

      # BUFGs: 100 MHz straight from the input buffer, the MMCM outputs
      for {d, src} <- [c100: :ibuf, c250: :c250_raw, c125: :c125_raw] do
        buf = P.inst(:"bufg_#{d}", P.bufg(), clocks: [i: src])
        signal(:"clk_#{d}") <~ buf[:O]
      end

      # reset: asynchronous assertion while the MMCM is unlocked, synchronous release
      for d <- [:c100, :c250, :c125] do
        rs = instance(:"rst_sync_#{d}", CDC.reset_sync(), domains: [dst: :"#{d}_rs"])
        signal(:"rst_#{d}_n") <~ rs.rst_n
      end

      # heartbeat counters
      counters =
        for d <- [:c100, :c250, :c125] do
          cnt = reg(:"cnt_#{d}", w, domain: d)
          sync(d, do: cnt <~ add_wrap(cnt, 1))
          cnt[bit]
        end

      [ref_b, c250_b, c125_b] = counters

      beats =
        for {d, b} <- [c250: c250_b, c125: c125_b] do
          s = instance(:"beat_#{d}", CDC.sync_ff(), domains: [dst: :c100])
          s.d <~ b
          s.q
        end

      lock = instance(:lock_sync, CDC.sync_ff(), domains: [dst: :c100])
      lock.d <~ mmcm[:LOCKED]

      sync :c100 do
        led <~ cat([lock.q, Enum.at(beats, 1), Enum.at(beats, 0), ref_b])
      end
    end
  end

  @doc """
  The build spec: board `AS02MC04`, signals `signals/0`, sources from the
  generated SystemVerilog. Options: those of `top/1`, `speed_grade:`.
  """
  @spec build(keyword()) :: Build.t()
  def build(opts \\ []) do
    Build.new(
      name: "hello_card",
      board: ExHdlXilinx.Boards.AS02MC04,
      signals: @signals,
      rtl: top(Keyword.take(opts, [:blink_bit])),
      speed_grade: opts[:speed_grade]
    )
  end

  @doc """
  Writes the build directory: `src/*.sv` (the design), `constraints.xdc`,
  `build.tcl`, an empty `out/`, and `sim/*.sv` (simulation stubs for lint, not
  part of the build). Returns the sorted list of files below `dir`.
  """
  @spec write(Path.t(), keyword()) :: [Path.t()]
  def write(dir, opts \\ []) do
    build = build(opts)
    Runner.stage(build, dir)

    for {name, text} <- P.sim_sources(top(Keyword.take(opts, [:blink_bit]))) do
      File.mkdir_p!(Path.join(dir, "sim"))
      File.write!(Path.join([dir, "sim", name]), text)
    end

    Path.join(dir, "**/*") |> Path.wildcard() |> Enum.reject(&File.dir?/1) |> Enum.sort()
  end

  @doc """
  A BEAM simulator of the top with the clocks at 100, 250 and 125 MHz
  (periods 10, 4 and 8). The simulator drives every internal clock
  ideally; the reset releases when the MMCM model reports `LOCKED`.
  """
  @spec sim(keyword()) :: Sim.t()
  def sim(opts \\ []) do
    Sim.new(top(opts), clocks: clocks())
  end
end

defmodule ExHdlXilinx.Hello.Spec do
  @moduledoc "`ExHdlXilinx.Hello.build/0` as a build-spec module for `mix ex_hdl_xilinx.build`."
  @behaviour ExHdlXilinx.Vivado.Build

  @impl true
  def build, do: ExHdlXilinx.Hello.build()
end
