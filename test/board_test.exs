defmodule ExHdlXilinx.BoardTest do
  use ExUnit.Case, async: true
  doctest ExHdlXilinx.Board
  doctest ExHdlXilinx.Boards.AS02MC04

  alias ExHdlXilinx.Board
  alias ExHdlXilinx.Boards.AS02MC04

  setup do: {:ok, b: AS02MC04.board()}

  test "board data is consistent", %{b: b} do
    assert Board.validate(b) == :ok
  end

  test "part strings follow the speed grade", %{b: b} do
    assert Board.part(b) == "xcku3p-ffvb676-1-e"
    assert Board.part(b, speed_grade: "-2") == "xcku3p-ffvb676-2-e"
  end

  test "clocks", %{b: b} do
    assert Board.clock(b, :clk100).frequency_hz == 100_000_000
    assert_in_delta ExHdlXilinx.Board.Clock.period_ns(Board.clock(b, :sfp_refclk)), 6.4, 1.0e-9
    assert Board.clock(b, :pcie_refclk).kind == :gt_ref
  end

  test "bank voltages come from the measurements", %{b: b} do
    assert b.bank_voltages[87] == 3.3
    assert b.bank_voltages[67] == 1.8
    assert Board.pin!(b, :led0).io_standard == "LVCMOS33"
    assert Board.pin!(b, :led0).alt_io_standards == ["LVCMOS18"]
  end

  test "pcie lanes are reversed to match the AES67 XDC order", %{b: b} do
    rx = for l <- Board.Pcie.logical_lanes(b.pcie), do: Board.pin!(b, l.rx).pin
    assert rx == ~w(AF2 AE4 AD2 AB2 Y2 V2 T2 P2)
    assert Board.pin!(b, :pcie_refclk).pin == "T7"
    assert Board.pin!(b, :pcie_refclk).gt.index == 1
  end

  test "sfp cages", %{b: b} do
    [c1, c2] = b.sfps
    assert Board.pin!(b, c1.tx).pin == "B7"
    assert Board.pin!(b, c2.rx).pin_n == "B1"
    assert c1.tx_disable == nil and c2.gt_quad == 227
    assert Board.pin!(b, c2.mod_abs).bank == 86
  end

  test "only the independently confirmed pins are verified", %{b: b} do
    verified = for p <- b.pins, p.verified?, do: p.name
    assert Enum.sort(verified) == [:clk100, :led0, :led1, :led2, :led3]
    assert :pcie_perst in Board.unverified(b)
  end

  test "every pin has a known source", %{b: b} do
    for p <- b.pins, s <- p.source, do: assert(is_map_key(b.sources, s))
  end

  test "flash properties", %{b: b} do
    assert b.flash.part =~ "MT25QU256"
    assert b.flash.cfgmem_part == "mt25qu256-spi-x1_x2_x4"
  end

  test "validate reports duplicate balls and missing standards" do
    p = %Board.Pin{name: :a, pin: "A1", source: [:s]}
    q = %Board.Pin{name: :b, pin: "A1", io_standard: "LVCMOS18", source: [:s]}

    b = %Board{
      name: "t",
      device: "xc",
      package: "P",
      speed_grade: "-1",
      temp: "E",
      pins: [p, q],
      sources: %{s: "x"}
    }

    assert {:error, errs} = Board.validate(b)
    assert "duplicate ball \"A1\"" in errs
    assert "pin a (A1) has no IO standard" in errs
  end

  test "pin! raises for unknown pins", %{b: b} do
    assert_raise ArgumentError, fn -> Board.pin!(b, :nope) end
  end
end
