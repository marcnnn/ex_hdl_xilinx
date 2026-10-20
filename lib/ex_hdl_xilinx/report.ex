defmodule ExHdlXilinx.Report do
  @moduledoc """
  Loads and parses the files a build leaves in its `out` directory:
  `timing_summary.rpt`, `utilization.rpt` and `vivado.log`.

  Missing files are simply absent from the result map.
  """

  alias ExHdlXilinx.Report.{Log, Timing, Utilization}

  @spec load(Path.t()) :: %{optional(:timing | :utilization | :log) => struct()}
  def load(dir) do
    for {key, file, parser} <- [
          {:timing, "timing_summary.rpt", &Timing.parse/1},
          {:utilization, "utilization.rpt", &Utilization.parse/1},
          {:log, "vivado.log", &Log.parse/1}
        ],
        path = Path.join(dir, file),
        File.regular?(path),
        into: %{},
        do: {key, parser.(File.read!(path))}
  end
end
