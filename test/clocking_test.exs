defmodule ExHdlXilinx.ClockingTest do
  use ExUnit.Case, async: true
  use ExHdl.RTL

  alias ExHdl.RTL.Sim
  alias ExHdlXilinx.Hello
  alias ExHdlXilinx.Primitives, as: P
  alias ExHdlXilinx.Primitives.Clocking

  @card [CLKIN1_PERIOD: 10.0, CLKFBOUT_MULT_F: 10.0, CLKOUT0_DIVIDE_F: 4.0, CLKOUT1_DIVIDE: 8]

  test "MMCM outputs from the multiply and divide parameters" do
    m = Clocking.mmcm(@card)
    assert m.vco_mhz == 1000.0
    assert m.errors == []
    assert m.outputs[:CLKOUT0].freq_mhz == 250.0
    assert m.outputs[:CLKOUT1].period_ns == 8.0
    assert m.outputs[:CLKFBOUT].freq_mhz == 100.0
    assert m.outputs[:CLKOUT0B].invert()
  end

  test "fractional dividers, DIVCLK_DIVIDE, real parameters and phase" do
    p = [
      CLKIN1_PERIOD: {:real, 8.0},
      CLKFBOUT_MULT_F: {:real, 9.125},
      DIVCLK_DIVIDE: 1,
      CLKOUT0_DIVIDE_F: {:real, 2.5},
      CLKOUT2_DIVIDE: 4,
      CLKOUT2_PHASE: {:real, 90.0}
    ]

    m = Clocking.mmcm(p)
    assert_in_delta m.vco_mhz, 1140.625, 1.0e-9
    assert_in_delta m.outputs[:CLKOUT0].freq_mhz, 456.25, 1.0e-9
    assert_in_delta m.outputs[:CLKOUT2].phase_ns, 0.25 * m.outputs[:CLKOUT2].period_ns, 1.0e-9

    d = Clocking.mmcm(CLKIN1_PERIOD: 5.0, CLKFBOUT_MULT_F: 8.0, DIVCLK_DIVIDE: 2)
    assert d.vco_mhz == 800.0
    assert d.outputs[:CLKFBOUT].freq_mhz == 100.0
  end

  test "parameters out of range are reported" do
    assert ["VCO frequency 2000.0 outside 800.0 - 1600.0"] =
             Clocking.mmcm(CLKIN1_PERIOD: 10.0, CLKFBOUT_MULT_F: 20.0).errors

    assert Enum.any?(
             Clocking.mmcm(CLKIN1_PERIOD: 10.0, CLKFBOUT_MULT_F: 1.0).errors,
             &(&1 =~ "CLKFBOUT_MULT_F")
           )

    assert Enum.any?(
             Clocking.mmcm(@card ++ [CLKOUT3_DIVIDE: 200]).errors,
             &(&1 =~ "CLKOUT3_DIVIDE 200")
           )

    refute Clocking.mmcm_valid?(CLKIN1_PERIOD: 10.0, CLKFBOUT_MULT_F: 20.0)
    # period 0 means not given: only the range checks without a frequency run
    assert Clocking.mmcm_valid?([])
    assert Clocking.mmcm([]).outputs == %{}
  end

  test "sim_clocks yields the clocks: option of the simulators" do
    assert Clocking.sim_clocks(@card, CLKOUT0: :c250, CLKOUT1: :c125) ==
             [c250: [period: 4, phase: 0], c125: [period: 8, phase: 0]]

    p = [CLKIN1_PERIOD: 10.0, CLKFBOUT_MULT_F: 10.0, CLKOUT0_DIVIDE_F: 2.5, CLKOUT1_PHASE: 90.0]

    assert_raise ArgumentError, ~r/not a whole number/, fn ->
      Clocking.sim_clocks(p, CLKOUT0: :a)
    end

    assert Clocking.sim_clocks(p, [CLKOUT0: :a, CLKOUT1: :b], unit_ns: 0.001) ==
             [a: [period: 2500, phase: 0], b: [period: 1000, phase: 250]]

    assert_raise ArgumentError, ~r/CLKIN1_PERIOD is not set/, fn ->
      Clocking.sim_clocks([], CLKOUT0: :a)
    end
  end

  test "BUFG_GT divides by DIV + 1" do
    assert Clocking.bufg_gt_period(4.0, 0) == 4.0
    assert Clocking.bufg_gt_period(4.0, 7) == 32.0
    assert Clocking.bufg_gt_clock(4, 3) == [period: 16, phase: 0]
  end

  test "the card top runs at the ratios of its MMCM parameters" do
    assert Hello.clocks() == [
             ibuf: [period: 10],
             c100: [period: 10],
             c250_raw: [period: 4, phase: 0],
             c250: [period: 4, phase: 0],
             c125_raw: [period: 8, phase: 0],
             c125: [period: 8, phase: 0]
           ]
  end

  defp mmcm_top(params) do
    module "mmcm_lock_top" do
      domain(:c100, reset: nil, clock: :clk_c100)
      locked = output(:locked, 1)
      m = P.inst(:m, P.mmcme4_adv(), clock: :c100, params: params, open: [:CLKFBIN])
      m[:CLKFBIN] <~ m[:CLKFBOUT]
      locked <~ m[:LOCKED]
    end
  end

  @tag :shared_clock
  test "the MMCM model reads the instance parameters: an out-of-range VCO never locks" do
    good = Sim.new(mmcm_top(@card)) |> Sim.step(20)
    assert Sim.peek(good, :locked) == 1
    bad = Sim.new(mmcm_top(CLKIN1_PERIOD: 10.0, CLKFBOUT_MULT_F: 20.0)) |> Sim.step(40)
    assert Sim.peek(bad, :locked) == 0
  end
end
