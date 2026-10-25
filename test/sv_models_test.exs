defmodule ExHdlXilinx.SvModelsTest do
  use ExUnit.Case, async: false

  alias ExHdlXilinx.Primitives, as: P
  alias ExHdlXilinx.Test.VSim

  @moduletag :verilator
  @moduletag timeout: 300_000

  @fixtures Path.expand("fixtures/sv", __DIR__)

  defp sources(names), do: Map.new(names, &{"#{&1}_sim.sv", P.stub(&1)})

  test "MMCME4_ADV model: output clocks from the parameters, lock delay, reset" do
    assert {:ok, out} = VSim.run(Path.join(@fixtures, "tb_mmcm.sv"), sources(["MMCME4_ADV"]))
    assert out =~ "PASS", out
    refute out =~ "FAIL", out
  end

  test "BUFG_GT model: DIV divides by DIV + 1, CE gates, CLR clears" do
    assert {:ok, out} = VSim.run(Path.join(@fixtures, "tb_bufg_gt.sv"), sources(["BUFG_GT"]))
    assert out =~ "PASS", out
    refute out =~ "FAIL", out
  end
end
