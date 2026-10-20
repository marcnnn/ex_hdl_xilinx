defmodule ExHdlXilinx.ReportTest do
  use ExUnit.Case, async: true
  doctest ExHdlXilinx.Report.Timing
  doctest ExHdlXilinx.Report.Utilization
  doctest ExHdlXilinx.Report.Log

  alias ExHdlXilinx.Report
  alias ExHdlXilinx.Report.{Log, Timing, Utilization}

  defp fixture(name), do: File.read!(Path.join("test/fixtures", name))

  describe "timing" do
    test "failed report: totals" do
      t = Timing.parse(fixture("timing_failed.rpt"))

      assert %{wns: -0.412, tns: -3.871, tns_failing: 14, tns_total: 12044} = t
      assert %{whs: 0.011, ths: +0.0, ths_failing: 0, wpws: 0.264, tpws_total: 5210} = t
      assert t.met? == false
      assert t.device == "xcku3p-ffvb676"
      assert t.design_state == "Routed"
      assert t.tool_version =~ "Vivado v.2023.2"
    end

    test "met report" do
      t = Timing.parse(fixture("timing_met.rpt"))
      assert t.met? == true
      assert {t.wns, t.tns_failing} == {0.512, 0}
      assert t.paths == []
      assert Timing.failing_endpoints(t) == []
    end

    test "clock summary with generated clocks" do
      t = Timing.parse(fixture("timing_failed.rpt"))

      assert Enum.map(t.clocks, & &1.name) ==
               ~w(clk100 clk_out1_sysmmcm clk_out2_sysmmcm pcie_refclk sfp_refclk)

      c = Enum.find(t.clocks, &(&1.name == "clk_out2_sysmmcm"))
      assert c.period_ns == 4.0 and c.frequency_mhz == 250.0 and c.waveform == [0.0, 2.0]
    end

    test "per-clock tables" do
      t = Timing.parse(fixture("timing_failed.rpt"))
      assert length(t.intra) == 5
      c = Timing.clock(t, "clk_out2_sysmmcm")
      assert %{wns: -0.412, tns_failing: 14, tns_total: 3900, whs: 0.02} = c
      assert %{wns: nil, wpws: 2.6} = Timing.clock(t, "sfp_refclk")

      assert [%{from: "clk_out1_sysmmcm", to: "clk_out2_sysmmcm", wns: 0.8}, %{wns: 0.65}] =
               t.inter
    end

    test "path blocks and failing endpoints" do
      t = Timing.parse(fixture("timing_failed.rpt"))
      assert length(t.paths) == 3

      assert [fail] = Timing.failing_endpoints(t)

      assert %{
               slack: -0.412,
               type: :setup,
               source: "dsp/mac_reg[3]/C",
               endpoint: "dsp/acc_reg[41]/D",
               source_clock: "clk_out2_sysmmcm",
               endpoint_clock: "clk_out2_sysmmcm",
               path_group: "clk_out2_sysmmcm",
               requirement_ns: 4.0,
               data_path_delay_ns: 3.998,
               logic_levels: 9
             } = fail

      hold = Enum.find(t.paths, &(&1.type == :hold))
      assert hold.slack == 0.02 and not hold.violated?

      cross = List.last(t.paths)

      assert cross.source_clock == "clk_out2_sysmmcm" and
               cross.endpoint_clock == "clk_out1_sysmmcm"
    end

    test "garbage in gives an empty struct" do
      t = Timing.parse("nothing here")
      assert t.wns == nil and t.met? == nil and t.paths == []
    end
  end

  describe "utilization" do
    setup do: {:ok, u: Utilization.parse(fixture("utilization.rpt"))}

    test "shortcuts", %{u: u} do
      assert u.lut == %{used: 12345, available: 162_720, util: 7.59}
      assert u.ff.used == 20011 and u.ff.available == 325_440
      assert u.bram == %{used: 20.5, available: 360, util: 5.69}
      assert u.uram == %{used: 16, available: 48, util: 33.33}
      assert u.dsp.used == 128 and u.dsp.available == 1368
      assert u.gt == %{used: 2, available: 16, util: 12.5}
      assert u.device == "xcku3p-ffvb676-1"
    end

    test "rows keep their hierarchy", %{u: u} do
      assert %{depth: 0, used: 12345} = Utilization.get(u, "CLB LUTs")
      assert %{depth: 1, used: 345, available: 99840} = Utilization.get(u, "LUT as Memory")
      assert %{depth: 2, used: 300, available: nil} = Utilization.get(u, "LUT as Distributed RAM")
      assert Utilization.get(u, "RAMB36/FIFO*").used == 18
      assert Utilization.get(u, "MMCM").available == 2
      assert Utilization.get(u, "nope") == nil
    end

    test "sections and primitives", %{u: u} do
      assert Map.has_key?(u.sections, "3. BLOCKRAM")
      assert Enum.map(u.sections["4. ARITHMETIC"], & &1.name) == ["DSPs", "DSP48E2 only"]
      assert u.primitives["FDRE"] == 20011
      assert u.primitives["MMCME4_ADV"] == 1
      assert map_size(u.primitives) == 8
    end

    test "7-series layout without Prohibited column" do
      text = """
      1. Slice Logic
      --------------

      +-------------------------+------+-------+-----------+-------+
      |        Site Type        | Used | Fixed | Available | Util% |
      +-------------------------+------+-------+-----------+-------+
      | Slice LUTs              | 1200 |     0 |     53200 |  2.26 |
      | Slice Registers         |  900 |     0 |    106400 |  0.85 |
      +-------------------------+------+-------+-----------+-------+
      """

      u = Utilization.parse(text)
      assert u.lut == %{used: 1200, available: 53_200, util: 2.26}
      assert u.ff.available == 106_400
    end
  end

  describe "log" do
    setup do: {:ok, l: Log.parse(fixture("vivado.log"))}

    test "counts and severities", %{l: l} do
      assert length(l.errors) == 3
      assert length(l.critical_warnings) == 2
      assert length(l.warnings) == 2
      assert l.infos == 4
      assert l.summary == %{infos: 4, warnings: 4, critical_warnings: 2, errors: 2}
      assert l.finished? and not l.ok?
    end

    test "ids and locations", %{l: l} do
      assert Enum.map(l.errors, & &1.id) == ["Synth 8-439", "Synth 8-6156", "Common 17-69"]
      [cw | _] = l.critical_warnings
      assert cw.id == "Vivado 12-4739"
      assert cw.file == "/work/d/constraints.xdc" and cw.line == 31
      assert cw.message =~ "set_clock_groups:No valid object(s)"
      assert List.last(l.errors).file == nil
      assert {"Synth 8-439", 1} in Log.ids(l)
    end

    test "clean log" do
      l = Log.parse("INFO: [Common 17-83] Releasing license\nExiting Vivado at now\n")
      assert l.ok? and l.finished? and l.errors == []
    end

    test "message without id" do
      l = Log.parse("ERROR: timing not met (WNS -0.1 ns, WHS 0.0 ns)\n")
      assert [%{id: nil, message: "timing not met" <> _}] = l.errors
    end
  end

  test "load/1 reads what exists" do
    dir = Path.join(System.tmp_dir!(), "rep_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.cp!("test/fixtures/utilization.rpt", Path.join(dir, "utilization.rpt"))
    assert Map.keys(Report.load(dir)) == [:utilization]
    File.cp!("test/fixtures/vivado.log", Path.join(dir, "vivado.log"))
    assert Report.load(dir) |> Map.keys() |> Enum.sort() == [:log, :utilization]
    File.rm_rf!(dir)
  end
end
