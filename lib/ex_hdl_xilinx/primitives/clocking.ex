defmodule ExHdlXilinx.Primitives.Clocking do
  @moduledoc """
  Clock arithmetic of the MMCME4_ADV and BUFG_GT primitives, from the
  instance parameters.

  The BEAM simulator drives the clocks of a design from the `clocks:` option
  of `ExHdl.RTL.Sim.new/2` (integer periods and phases) and cannot take a
  clock from a model, so these functions compute what the black boxes
  generate and `sim_clocks/3` turns it into that option:

      params = [CLKIN1_PERIOD: 10.0, CLKFBOUT_MULT_F: 10.0, CLKOUT0_DIVIDE_F: 4.0,
                CLKOUT1_DIVIDE: 8]
      Clocking.mmcm(params).outputs[:CLKOUT0].freq_mhz         #=> 250.0
      Clocking.sim_clocks(params, [CLKOUT0: :c250, CLKOUT1: :c125])
      #=> [c250: [period: 4, phase: 0], c125: [period: 8, phase: 0]]

  The SystemVerilog models (`ExHdlXilinx.Primitives.sim_sources/1`) compute
  the same numbers with real arithmetic when Verilator runs with
  `--timing`.

  ## Limits

  Duty cycles are 50 percent (`CLKOUTn_DUTY_CYCLE` is not a parameter of the
  black box), `CLKFBOUT_PHASE` and `CLKOUT4_CASCADE` are ignored, the
  fractional-divider jitter and the dynamic reconfiguration port are not
  modelled. Parameters are checked against the ranges of the UltraScale+
  data sheet that do not depend on the speed grade: VCO 800 - 1600 MHz,
  `CLKFBOUT_MULT_F` 2 - 64, `DIVCLK_DIVIDE` 1 - 106, output dividers 1 - 128,
  input 10 - 933 MHz. A `CLKIN1_PERIOD` of 0 (not given) skips the checks
  that need a frequency.
  """

  @vco_mhz {800.0, 1600.0}
  @outs ~w(CLKOUT0 CLKOUT0B CLKOUT1 CLKOUT1B CLKOUT2 CLKOUT2B CLKOUT3 CLKOUT3B CLKOUT4 CLKOUT5 CLKOUT6)a

  @type out :: %{period_ns: float(), freq_mhz: float(), phase_ns: float(), invert: boolean()}

  @doc """
  Frequencies of an MMCME4_ADV with instance `params` (a keyword list; values
  may be `{:real, v}`): `%{vco_mhz:, outputs: %{name => out}, errors: [String.t()]}`.
  Outputs are `CLKOUT0` - `CLKOUT6`, the inverted `CLKOUT0B` - `CLKOUT3B`
  and `CLKFBOUT`; all are empty when `CLKIN1_PERIOD` is 0.
  """
  @spec mmcm(keyword()) :: %{
          vco_mhz: float() | nil,
          outputs: %{atom() => out()},
          errors: [String.t()]
        }
  def mmcm(params) do
    p = fn k, default -> num(params[k], default) end
    tin = p.(:CLKIN1_PERIOD, 0.0)
    mult = p.(:CLKFBOUT_MULT_F, 5.0)
    div = p.(:DIVCLK_DIVIDE, 1.0)

    dividers =
      for o <- @outs, base = String.replace_suffix(Atom.to_string(o), "B", ""), into: %{} do
        k = if base == "CLKOUT0", do: :CLKOUT0_DIVIDE_F, else: :"#{base}_DIVIDE"
        {o, {p.(k, 1.0), p.(:"#{base}_PHASE", 0.0)}}
      end

    errors =
      range("CLKFBOUT_MULT_F", mult, 2.0, 64.0) ++
        range("DIVCLK_DIVIDE", div, 1.0, 106.0) ++
        for({o, {d, _}} <- dividers, e <- range(divider_name(o), d, 1.0, 128.0), do: e)

    if tin <= 0 do
      %{vco_mhz: nil, outputs: %{}, errors: errors}
    else
      fin = 1000.0 / tin
      vco = fin * mult / div
      {lo, hi} = @vco_mhz

      errors =
        errors ++
          range("input frequency", fin, 10.0, 933.0) ++
          range("VCO frequency", vco, lo, hi)

      outs =
        for {o, {d, ph}} <- dividers, into: %{} do
          period = 1000.0 / vco * d
          {o, out(period, ph / 360.0 * period, String.ends_with?(Atom.to_string(o), "B"))}
        end

      fb = 1000.0 / fin * div
      %{vco_mhz: vco, outputs: Map.put(outs, :CLKFBOUT, out(fb, 0.0, false)), errors: errors}
    end
  end

  defp divider_name(o) do
    base = o |> Atom.to_string() |> String.replace_suffix("B", "")
    if base == "CLKOUT0", do: "CLKOUT0_DIVIDE_F", else: "#{base}_DIVIDE"
  end

  defp out(period, phase, invert),
    do: %{period_ns: period, freq_mhz: 1000.0 / period, phase_ns: phase, invert: invert}

  defp range(name, v, lo, hi) do
    if v >= lo - 1.0e-9 and v <= hi + 1.0e-9,
      do: [],
      else: ["#{name} #{fmt(v)} outside #{fmt(lo)} - #{fmt(hi)}"]
  end

  defp fmt(v), do: :erlang.float_to_binary(v / 1, [{:decimals, 6}, :compact])

  @doc "Whether an MMCME4_ADV with `params` can lock (`mmcm/1` reports no errors)."
  @spec mmcm_valid?(keyword()) :: boolean()
  def mmcm_valid?(params), do: mmcm(params).errors == []

  @doc """
  The `clocks:` option for `ExHdl.RTL.Sim.new/2` and `ExHdl.RTL.Cosim.run/3`
  of the MMCM outputs in `map` (`[CLKOUT0: :c250]`, output => domain or clock
  name). Times are in units of `unit_ns` (default 1.0 ns); a period or phase
  that is not a whole number of units raises `ArgumentError`, so pick a
  finer unit (`unit_ns: 0.001`).
  """
  @spec sim_clocks(keyword(), keyword(), keyword()) :: keyword()
  def sim_clocks(params, map, opts \\ []) do
    unit = Keyword.get(opts, :unit_ns, 1.0)
    %{outputs: outs} = mmcm(params)

    if outs == %{}, do: raise(ArgumentError, "CLKIN1_PERIOD is not set, no output frequency")

    for {o, name} <- map do
      out = Map.get(outs, o) || raise ArgumentError, "unknown MMCM output #{inspect(o)}"
      {name, [period: units(out.period_ns, unit, o), phase: units(out.phase_ns, unit, o)]}
    end
  end

  defp units(ns, unit, o) do
    n = round(ns / unit)

    if abs(ns - n * unit) > unit * 1.0e-6,
      do: raise(ArgumentError, "#{o}: #{fmt(ns)} ns is not a whole number of #{fmt(unit)} ns")

    n
  end

  @doc """
  Frequency division of a BUFG_GT: `DIV` (0 - 7) divides by `DIV + 1`.
  `period_ns` is the input period; `div` the value on the `DIV` port.
  """
  @spec bufg_gt_period(number(), 0..7) :: float()
  def bufg_gt_period(period_ns, div) when div in 0..7, do: period_ns * (div + 1)

  @doc "`sim_clocks/3` for a BUFG_GT: `[period: input_period * (div + 1), phase: 0]` in simulator units."
  @spec bufg_gt_clock(pos_integer(), 0..7) :: keyword()
  def bufg_gt_clock(period, div) when div in 0..7 and is_integer(period),
    do: [period: period * (div + 1), phase: 0]

  defp num({:real, v}, _), do: v / 1
  defp num({:bits, _, v}, _), do: v / 1
  defp num(v, _) when is_number(v), do: v / 1
  defp num(_, default), do: default
end
