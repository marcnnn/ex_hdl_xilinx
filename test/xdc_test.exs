defmodule ExHdlXilinx.XDCTest do
  use ExUnit.Case, async: true
  doctest ExHdlXilinx.XDC

  alias ExHdlXilinx.Boards.AS02MC04
  alias ExHdlXilinx.XDC

  setup do: {:ok, b: AS02MC04.board()}

  defp gen(b, used, opts \\ []), do: XDC.generate!(b, used, opts)

  test "differential clock with create_clock", %{b: b} do
    xdc = gen(b, [{:clk100, "clk"}], flash: false)
    assert xdc =~ "set_property -dict {PACKAGE_PIN E18 IOSTANDARD LVDS} [get_ports clk_p]"
    assert xdc =~ "set_property -dict {PACKAGE_PIN D18 IOSTANDARD LVDS} [get_ports clk_n]"
    assert xdc =~ "create_clock -name clk100 -period 10.000 [get_ports clk_p]"
    refute xdc =~ "unverified"
  end

  test "groups become buses, static outputs are false-pathed", %{b: b} do
    xdc = gen(b, [{:leds, "led"}], flash: false)
    assert xdc =~ "{PACKAGE_PIN B11 IOSTANDARD LVCMOS33} [get_ports {led[0]}]"
    assert xdc =~ "set_false_path -to [get_ports {led[0] led[1] led[2] led[3]}]"
  end

  test "bit ports and unverified flags", %{b: b} do
    xdc = gen(b, [{:led_r, {"stat", 1}}, {:pcie_perst, "perst_n"}], flash: false)
    assert xdc =~ "# unverified: led_r (gillon, essenceia)"
    assert xdc =~ "[get_ports {stat[1]}]"
    assert xdc =~ "{PACKAGE_PIN A9 IOSTANDARD LVCMOS33 PULLUP true} [get_ports perst_n]"
    assert xdc =~ "set_false_path -from [get_ports {perst_n}]"
  end

  test "transceiver pins carry no IO standard", %{b: b} do
    xdc = gen(b, [{:sfp1_tx, "sfp_tx"}, {:pcie_rx0, {"rx", 3}}], flash: false)
    assert xdc =~ "set_property -dict {PACKAGE_PIN B7} [get_ports sfp_tx_p]"
    assert xdc =~ "set_property -dict {PACKAGE_PIN P2} [get_ports {rx_p[3]}]"
    assert xdc =~ "set_property -dict {PACKAGE_PIN P1} [get_ports {rx_n[3]}]"
  end

  test "flash configuration properties", %{b: b} do
    xdc = gen(b, [])
    assert xdc =~ "set_property CONFIG_VOLTAGE 1.8 [current_design]"
    assert xdc =~ "set_property CFGBVS GND [current_design]"
    assert xdc =~ "set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]"
    assert xdc =~ "set_property BITSTREAM.CONFIG.CONFIGRATE 51.0 [current_design]"
    assert xdc =~ "set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]"

    xdc = gen(b, [], bitstream_properties: %{"BITSTREAM.CONFIG.CONFIGRATE" => "25.5", "X" => 1})
    assert xdc =~ "CONFIGRATE 25.5"
    assert xdc =~ "set_property X 1 [current_design]"
  end

  test "clock groups, extra clocks, false paths and max delay", %{b: b} do
    xdc =
      gen(b, [{:clk100, "clk"}, {:pcie_refclk, "pcie_refclk"}],
        flash: false,
        clocks: [%{name: "aux", port: "aux_clk", frequency_hz: 125_000_000}],
        clock_groups: [[:clk100, "aux"], [:pcie_refclk]],
        false_paths: [%{from: "[get_ports rst]", to: "[get_cells sync*]"}],
        max_delay: [
          %{ns: 8, from: "[get_cells a*]", to: "[get_cells b*]", quiet: true}
        ]
      )

    assert xdc =~ "create_clock -name aux -period 8.000 [get_ports aux_clk]"

    assert xdc =~
             "set_clock_groups -asynchronous \\\n    -group [get_clocks -include_generated_clocks {clk100 aux}] \\\n    -group [get_clocks -include_generated_clocks {pcie_refclk}]"

    assert xdc =~ "set_false_path -from [get_ports rst] -to [get_cells sync*]"

    assert xdc =~
             "set_max_delay -datapath_only -quiet 8.000 -from [get_cells a*] -to [get_cells b*]"
  end

  test "unknown signal", %{b: b} do
    assert {:error, [{:unknown_signal, msg}]} = XDC.generate(b, [:nope])
    assert msg =~ ":nope"
  end

  test "signal and port duplicates", %{b: b} do
    assert {:error, errs} = XDC.generate(b, [{:led0, "x"}, {:led1, "x"}, {:led0, "y"}])
    kinds = Enum.map(errs, &elem(&1, 0))
    assert :duplicate_signal in kinds
    assert :duplicate_port in kinds
  end

  test "two ports on one ball", %{b: b} do
    assert {:error, errs} = XDC.generate(b, [{:led0, "a"}, {:led0, {"b", 0}}])
    assert Enum.any?(errs, &match?({:duplicate_pin, _}, &1))
  end

  test "missing IO standard is reported and can be overridden" do
    pin = %ExHdlXilinx.Board.Pin{name: :x, pin: "A1", source: [:s], bank: 12}

    b = %ExHdlXilinx.Board{
      name: "t",
      device: "xc",
      package: "P",
      speed_grade: "-1",
      temp: "E",
      pins: [pin],
      sources: %{s: "s"}
    }

    assert {:error, [{:missing_io_standard, msg}]} = XDC.generate(b, [:x])
    assert msg =~ "x (A1)"
    assert {:ok, xdc} = XDC.generate(b, [:x], io_standard: %{x: "LVCMOS18"})
    assert xdc =~ "IOSTANDARD LVCMOS18"
  end

  test "bank voltage conflicts", %{b: b} do
    assert {:error, [{:bank_conflict, msg} | _]} =
             XDC.generate(b, [:led0, :led1], io_standard: %{led0: "LVCMOS18"})

    assert msg =~ "bank 86 mixes"

    assert {:error, [{:bank_conflict, m2}]} =
             XDC.generate(b, [:led0], io_standard: %{led0: "LVCMOS18"})

    assert m2 =~ "runs at 3.3 V"

    assert {:ok, _} =
             XDC.generate(b, [:led0], io_standard: %{led0: "LVCMOS18"}, check_banks: false)
  end

  test "unknown clock in a clock group", %{b: b} do
    assert {:error, [{:unknown_clock, _}]} = XDC.generate(b, [], clock_groups: [[:clk100]])
  end

  test "generate! raises with all messages", %{b: b} do
    e = assert_raise XDC.Error, fn -> XDC.generate!(b, [:a, :b]) end
    assert Exception.message(e) =~ "unknown_signal"
    assert length(e.errors) == 2
  end
end
