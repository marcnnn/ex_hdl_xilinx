defmodule ExHdlXilinx.Test.DemoBuild do
  @moduledoc false
  @behaviour ExHdlXilinx.Vivado.Build

  @impl true
  def build do
    ExHdlXilinx.Vivado.Build.new(
      name: "demo",
      top: "top",
      board: ExHdlXilinx.Boards.AS02MC04,
      signals: [:clk100, {:leds, "led"}],
      sources: [Path.expand("fixtures/top.sv", __DIR__ |> Path.dirname())],
      cfgmem: %{interface: "SPIx4", size_mb: 32}
    )
  end
end
