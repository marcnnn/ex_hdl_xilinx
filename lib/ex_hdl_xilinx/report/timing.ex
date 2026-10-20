defmodule ExHdlXilinx.Report.Timing do
  @moduledoc """
  Parser for `report_timing_summary` text.

  Returns a struct with the design totals (`wns`, `tns`, `whs`, `ths`, pulse
  width slacks and endpoint counts; `nil` where Vivado prints `NA`), whether
  constraints are met, the clock table, the intra and inter clock tables, and
  every path block of the details section (`paths`, with slack, source,
  destination, clocks, requirement, delay and logic levels).

      iex> text = File.read!("test/fixtures/timing_failed.rpt")
      iex> t = ExHdlXilinx.Report.Timing.parse(text)
      iex> {t.wns, t.tns, t.tns_failing, t.met?}
      {-0.412, -3.871, 14, false}
      iex> Enum.map(ExHdlXilinx.Report.Timing.failing_endpoints(t), & &1.endpoint)
      ["dsp/acc_reg[41]/D"]
  """

  defstruct [
    :wns,
    :tns,
    :tns_failing,
    :tns_total,
    :whs,
    :ths,
    :ths_failing,
    :ths_total,
    :wpws,
    :tpws,
    :tpws_failing,
    :tpws_total,
    :met?,
    :device,
    :speed_file,
    :design_state,
    :tool_version,
    clocks: [],
    intra: [],
    inter: [],
    paths: []
  ]

  @type t :: %__MODULE__{}

  @intra_keys ~w(wns tns tns_failing tns_total whs ths ths_failing ths_total wpws tpws tpws_failing tpws_total)a
  @inter_keys ~w(wns tns tns_failing tns_total whs ths ths_failing ths_total)a

  @spec parse(String.t()) :: t()
  def parse(text) do
    lines = String.split(text, "\n")
    sections = sections(lines)

    summary =
      case sections["Design Timing Summary"] do
        nil -> %{}
        body -> design_values(body)
      end

    struct!(
      __MODULE__,
      Map.merge(summary, %{
        met?: met(text),
        device: header(text, "Device"),
        speed_file: header(text, "Speed File"),
        design_state: header(text, "Design State"),
        tool_version: header(text, "Tool Version"),
        clocks: clocks(sections["Clock Summary"] || []),
        intra: table(sections["Intra Clock Table"] || [], 1, @intra_keys),
        inter: table(sections["Inter Clock Table"] || [], 2, @inter_keys),
        paths: paths(text)
      })
    )
  end

  @doc "Violated setup or hold paths, worst first, one entry per endpoint."
  @spec failing_endpoints(t()) :: [map()]
  def failing_endpoints(%__MODULE__{paths: paths}) do
    paths
    |> Enum.filter(& &1.violated?)
    |> Enum.sort_by(& &1.slack)
    |> Enum.uniq_by(&{&1.endpoint, &1.type})
  end

  @doc "Failing and total endpoint counts for the clock `name` from the intra clock table."
  @spec clock(t(), String.t()) :: map() | nil
  def clock(%__MODULE__{intra: intra}, name), do: Enum.find(intra, &(&1.clock == name))

  # -- sections -----------------------------------------------------------

  defp sections(lines) do
    lines
    |> Enum.chunk_every(3, 1, [""])
    |> Enum.reduce({nil, %{}}, fn
      [<<"----", _::binary>>, "| " <> title, "| " <> _], {_, acc} ->
        {String.trim(title), Map.put(acc, String.trim(title), [])}

      [line | _], {nil, acc} ->
        _ = line
        {nil, acc}

      [line | _], {cur, acc} ->
        {cur, Map.update!(acc, cur, &[line | &1])}
    end)
    |> elem(1)
    |> Map.new(fn {k, v} -> {k, Enum.reverse(v)} end)
  end

  defp design_values(body) do
    rows = data_rows(body)

    case rows do
      [row | _] ->
        keys = @intra_keys
        vals = String.split(row) |> Enum.map(&num/1)
        if length(vals) == length(keys), do: Map.new(Enum.zip(keys, vals)), else: %{}

      [] ->
        %{}
    end
  end

  # Rows following a header line and its dashes underline, up to a blank line.
  defp data_rows(lines) do
    lines
    |> Enum.drop_while(&(not String.match?(&1, ~r/^\s*-+\s+-+/)))
    |> Enum.drop(1)
    |> Enum.take_while(&(String.trim(&1) != ""))
  end

  defp table(body, nnames, keys) do
    for row <- data_rows(body),
        toks = String.split(row),
        length(toks) == nnames + length(keys) do
      {names, vals} = Enum.split(toks, nnames)
      base = Map.new(Enum.zip(keys, Enum.map(vals, &num/1)))

      case names do
        [c] -> Map.put(base, :clock, c)
        [f, t] -> base |> Map.put(:from, f) |> Map.put(:to, t)
      end
    end
  end

  defp clocks(body) do
    for line <- body,
        [_, name, wave, period, freq] <-
          [Regex.run(~r/^\s*(\S+)\s+\{([\d.\s-]+)\}\s+([\d.]+)\s+([\d.]+)/, line)] do
      %{
        name: name,
        waveform: wave |> String.split() |> Enum.map(&num/1),
        period_ns: num(period),
        frequency_mhz: num(freq)
      }
    end
  end

  defp met(text) do
    cond do
      text =~ "All user specified timing constraints are met" -> true
      text =~ "Timing constraints are not met" -> false
      true -> nil
    end
  end

  defp header(text, key) do
    case Regex.run(~r/^\| #{key}\s*:\s*(.+)$/m, text) do
      [_, v] -> String.trim(v)
      _ -> nil
    end
  end

  # -- path blocks --------------------------------------------------------

  defp paths(text) do
    ~r/^(?=Slack \((?:VIOLATED|MET)\))/m
    |> Regex.split(text)
    |> Enum.drop(1)
    |> Enum.map(&path/1)
  end

  defp path(block) do
    [_, status, slack] = Regex.run(~r/^Slack \((VIOLATED|MET)\)\s*:\s*(-?[\d.]+)ns/, block)
    endpoint = field(block, "Destination")
    clocks = Regex.scan(~r/clocked by (\S+)/, block) |> Enum.map(&List.last/1)

    %{
      violated?: status == "VIOLATED",
      slack: num(slack),
      type: if(block =~ ~r/Path Type:\s+Hold/, do: :hold, else: :setup),
      source: field(block, "Source"),
      endpoint: endpoint,
      source_clock: Enum.at(clocks, 0),
      endpoint_clock: Enum.at(clocks, 1),
      path_group: field(block, "Path Group"),
      requirement_ns: block |> field("Requirement") |> first_num(),
      data_path_delay_ns: block |> field("Data Path Delay") |> first_num(),
      logic_levels: block |> field("Logic Levels") |> first_int()
    }
  end

  defp field(block, key) do
    case Regex.run(~r/^\s+#{key}:\s+(\S.*)$/m, block) do
      [_, v] -> String.trim(v)
      _ -> nil
    end
  end

  defp first_num(nil), do: nil

  defp first_num(s) do
    case Regex.run(~r/-?[\d.]+/, s) do
      [n] -> num(n)
      _ -> nil
    end
  end

  defp first_int(nil), do: nil

  defp first_int(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp num("NA"), do: nil

  defp num(s) do
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
