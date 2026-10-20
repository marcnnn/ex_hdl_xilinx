defmodule ExHdlXilinx.Report.Log do
  @moduledoc """
  Parser for a Vivado log: errors, critical warnings and warnings with
  message id and source location.

  Messages look like `ERROR: [Synth 8-439] module 'x' not found [top.sv:42]`.
  Lines without an id (Tcl `error` output) are kept with `id: nil`.

      iex> log = ExHdlXilinx.Report.Log.parse(File.read!("test/fixtures/vivado.log"))
      iex> {length(log.errors), length(log.critical_warnings), log.ok?}
      {3, 2, false}
      iex> hd(log.errors)
      %{severity: :error, id: "Synth 8-439", message: "module 'fifo_sync' not found", file: "src/top.sv", line: 42}
  """

  defstruct errors: [],
            critical_warnings: [],
            warnings: [],
            infos: 0,
            summary: nil,
            finished?: false,
            ok?: true

  @type t :: %__MODULE__{}

  @re ~r/^(INFO|WARNING|CRITICAL WARNING|ERROR): (?:\[([^\]]+)\] )?(.*)$/

  @spec parse(String.t()) :: t()
  def parse(text) do
    msgs =
      for line <- String.split(text, "\n"),
          [_, sev, id, rest] <- [Regex.run(@re, String.trim_trailing(line))],
          do: message(sev, id, rest)

    by = Enum.group_by(msgs, & &1.severity)
    errors = Map.get(by, :error, [])

    %__MODULE__{
      errors: errors,
      critical_warnings: Map.get(by, :critical_warning, []),
      warnings: Map.get(by, :warning, []),
      infos: length(Map.get(by, :info, [])),
      summary: summary(text),
      finished?: text =~ ~r/Exiting Vivado/,
      ok?: errors == []
    }
  end

  @doc "Messages (any severity above info) grouped by id with counts, most frequent first."
  @spec ids(t()) :: [{String.t() | nil, non_neg_integer()}]
  def ids(%__MODULE__{} = l) do
    (l.errors ++ l.critical_warnings ++ l.warnings)
    |> Enum.frequencies_by(& &1.id)
    |> Enum.sort_by(&elem(&1, 1), :desc)
  end

  defp message(sev, id, rest) do
    {msg, file, line} =
      case Regex.run(~r/^(.*?)\s*\[([^\[\]]+?):(\d+)\]$/, rest) do
        [_, m, f, l] -> {m, f, String.to_integer(l)}
        _ -> {rest, nil, nil}
      end

    %{severity: severity(sev), id: if(id != "", do: id), message: msg, file: file, line: line}
  end

  defp severity("INFO"), do: :info
  defp severity("WARNING"), do: :warning
  defp severity("CRITICAL WARNING"), do: :critical_warning
  defp severity("ERROR"), do: :error

  defp summary(text) do
    ~r/(\d+) Infos?, (\d+) Warnings?, (\d+) Critical Warnings? and (\d+) Errors? encountered/
    |> Regex.scan(text)
    |> List.last()
    |> case do
      [_, i, w, c, e] ->
        %{
          infos: String.to_integer(i),
          warnings: String.to_integer(w),
          critical_warnings: String.to_integer(c),
          errors: String.to_integer(e)
        }

      _ ->
        nil
    end
  end
end
