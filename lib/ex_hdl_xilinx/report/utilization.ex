defmodule ExHdlXilinx.Report.Utilization do
  @moduledoc """
  Parser for `report_utilization` text (UltraScale+ and 7-series layouts).

  Every `Site Type` table row becomes a map with `used`, `fixed`,
  `prohibited`, `available`, `util` and `depth` (indentation level, so
  `LUT as Memory` is a child of `CLB LUTs`). `resources` indexes the rows by
  name, first occurrence winning, `sections` keeps them by section title, and
  `primitives` has the `Ref Name` table. `lut`, `ff`, `bram` (tiles), `uram`,
  `dsp` and `gt` are shortcuts of `%{used:, available:, util:}`.

      iex> u = ExHdlXilinx.Report.Utilization.parse(File.read!("test/fixtures/utilization.rpt"))
      iex> {u.lut.used, u.lut.available, u.dsp.used, u.uram.available, u.gt.used}
      {12345, 162720, 128, 48, 2}
      iex> u.bram.used
      20.5
  """

  defstruct [
    :device,
    :lut,
    :ff,
    :bram,
    :uram,
    :dsp,
    :gt,
    resources: %{},
    sections: %{},
    primitives: %{}
  ]

  @type t :: %__MODULE__{}

  @aliases %{
    lut: ["CLB LUTs", "Slice LUTs"],
    ff: ["CLB Registers", "Slice Registers"],
    bram: ["Block RAM Tile"],
    uram: ["URAM"],
    dsp: ["DSPs"],
    gt: ["GTYE4_CHANNEL", "GTHE4_CHANNEL", "GTPE2_CHANNEL", "GTXE2_CHANNEL"]
  }

  @spec parse(String.t()) :: t()
  def parse(text) do
    st =
      text
      |> String.split("\n")
      |> Enum.chunk_every(2, 1, [""])
      |> Enum.reduce(%{sec: nil, table: nil, rows: [], prims: %{}}, &step/2)

    rows = Enum.reverse(st.rows)

    resources = Enum.reduce(rows, %{}, fn r, acc -> Map.put_new(acc, r.name, r) end)

    base = %__MODULE__{
      device: header(text, "Device"),
      resources: resources,
      sections: Enum.group_by(rows, & &1.section),
      primitives: st.prims
    }

    Enum.reduce(@aliases, base, fn {key, names}, u ->
      case Enum.find_value(names, &resources[&1]) do
        nil -> u
        r -> Map.put(u, key, Map.take(r, [:used, :available, :util]))
      end
    end)
  end

  @doc "Row by name, or nil."
  def get(%__MODULE__{resources: r}, name), do: r[name]

  defp step([line, next], st) do
    cond do
      String.match?(next, ~r/^-{3,}\s*$/) and heading(line) ->
        %{st | sec: heading(line), table: nil}

      String.starts_with?(line, "|") ->
        cells = line |> String.trim() |> String.trim("|") |> String.split("|")
        first = cells |> hd() |> String.trim()
        row(first, cells, st)

      true ->
        st
    end
  end

  defp row("Site Type", _, st), do: %{st | table: :resources}
  defp row("Ref Name", _, st), do: %{st | table: :primitives}
  defp row("Total", _, st), do: %{st | table: nil}

  defp row(_, cells, %{table: :resources} = st),
    do: %{st | rows: [resource(cells, st.sec) | st.rows]}

  defp row(_, cells, %{table: :primitives} = st), do: %{st | prims: primitive(cells, st.prims)}
  defp row(_, _, st), do: st

  defp heading(line) do
    case Regex.run(~r/^(\d+(?:\.\d+)*)\.?\s+(\S.*)$/, line) do
      [_, n, title] -> "#{n}. #{String.trim(title)}"
      _ -> nil
    end
  end

  defp resource([name | rest], sec) do
    lead = String.length(name) - String.length(String.trim_leading(name))
    [used, fixed, proh, avail, util] = pad(rest)

    %{
      name: String.trim(name),
      depth: div(max(lead - 1, 0), 2),
      used: num(used),
      fixed: num(fixed),
      prohibited: num(proh),
      available: num(avail),
      util: num(util),
      section: sec
    }
  end

  # 7-series reports have no Prohibited column
  defp pad([u, f, a, p]), do: [u, f, "", a, p]
  defp pad([_, _, _, _, _] = l), do: l
  defp pad(l), do: Enum.take(l ++ List.duplicate("", 5), 5)

  defp primitive([name, used | _], prims) do
    case num(used) do
      nil -> prims
      n -> Map.put(prims, String.trim(name), n)
    end
  end

  defp header(text, key) do
    case Regex.run(~r/^\| #{key}\s*:\s*(.+)$/m, text) do
      [_, v] -> String.trim(v)
      _ -> nil
    end
  end

  defp num(s) do
    s = s |> String.trim() |> String.trim_leading("<")

    case Integer.parse(s) do
      {n, ""} ->
        n

      _ ->
        case Float.parse(s) do
          {f, ""} -> f
          _ -> nil
        end
    end
  end
end
