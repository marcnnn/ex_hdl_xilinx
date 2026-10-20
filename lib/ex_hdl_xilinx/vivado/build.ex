defmodule ExHdlXilinx.Vivado.Build do
  @moduledoc """
  A build spec for the non-project Vivado flow.

  Fields:

    * `name`, `top`, `part`
    * `sources` - `.sv`, `.v`, `.vhd` paths; `xdc` - constraint files;
      `xdc_text` - generated constraints, written to `constraints.xdc`
    * `generics`, `defines` - maps passed to `synth_design`
    * `directives` - `[synth: "...", opt: "...", place: "...", phys_opt: "...", route: "..."]`
    * `phys_opt` - run `phys_opt_design` after placement (default true)
    * `reports` - any of `:timing_summary`, `:utilization`, `:drc`,
      `:methodology`, `:clock_interaction`, `:power`, `:cdc`
    * `bitstream` - write the bitstream (default true)
    * `cfgmem` - nil or `%{interface: "SPIx4", size_mb: 32, format: :mcs}`
    * `timing_gate` - `:warn` (default), `:error` or `:ignore` when WNS or WHS
      is negative after routing
    * `jobs`, `pre_tcl`, `post_tcl` (raw Tcl lines)
    * `generated` - `%{filename => text}` of generated sources, written to `src/`
    * `ips` - `ExHdlXilinx.Vivado.IP` structs, created before `synth_design`

  `new/1` takes a `:board` module and `:signals` to derive `part` and
  `xdc_text` with `ExHdlXilinx.XDC`, and an `:rtl` module (an elaborated
  `ExHdl.RTL` top) to take `top` and `generated` from
  `ExHdl.Backends.SystemVerilog.RTL.generate/1`. The ports of the top are
  checked against the signals: a constrained port the top lacks, a top port
  without a constraint (unless listed in `unconstrained:`), a width or
  direction mismatch are errors (`ArgumentError` listing all of them).

      iex> b = ExHdlXilinx.Vivado.Build.new(name: "demo", top: "top", part: "xcku3p-ffvb676-1-e")
      iex> b.out_dir
      "out"
  """

  alias ExHdl.RTL.Module, as: RTLModule
  alias ExHdlXilinx.{Board, XDC}

  defstruct [
    :name,
    :top,
    :part,
    :xdc_text,
    :cfgmem,
    generated: %{},
    ips: [],
    sources: [],
    xdc: [],
    generics: %{},
    defines: %{},
    directives: [],
    phys_opt: true,
    reports: [:timing_summary, :utilization, :drc, :clock_interaction],
    bitstream: true,
    timing_gate: :warn,
    jobs: 4,
    out_dir: "out",
    pre_tcl: [],
    post_tcl: []
  ]

  @type t :: %__MODULE__{}

  @callback build() :: t()

  @doc """
  Build from keyword options. With `board: Module` the part (and `:speed_grade`)
  come from the board and, when `signals:` is given, `xdc_text` is generated
  with `xdc_opts:`. Raises on XDC errors.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    {board_mod, opts} = Keyword.pop(opts, :board)
    {signals, opts} = Keyword.pop(opts, :signals)
    {xdc_opts, opts} = Keyword.pop(opts, :xdc_opts, [])
    {grade, opts} = Keyword.pop(opts, :speed_grade)
    {rtl, opts} = Keyword.pop(opts, :rtl)
    {unconstrained, opts} = Keyword.pop(opts, :unconstrained, [])

    opts =
      if board_mod do
        board = board_mod.board()
        part_opts = if grade, do: [speed_grade: grade], else: []

        opts
        |> Keyword.put_new(:part, Board.part(board, part_opts))
        |> then(fn o ->
          if signals,
            do: Keyword.put(o, :xdc_text, XDC.generate!(board, signals, xdc_opts)),
            else: o
        end)
      else
        opts
      end

    opts = if rtl, do: with_rtl(opts, rtl, board_mod, signals, unconstrained), else: opts
    struct!(__MODULE__, opts)
  end

  defp with_rtl(opts, %RTLModule{kind: :module} = rtl, board_mod, signals, unconstrained) do
    if board_mod && signals do
      case check_ports(rtl, board_mod.board(), signals, unconstrained) do
        [] ->
          :ok

        errors ->
          raise ArgumentError,
                "top #{rtl.name} does not match the board signals:\n" <> Enum.join(errors, "\n")
      end
    end

    opts
    |> Keyword.put_new(:top, rtl.name)
    |> Keyword.update(:generated, generated(rtl), &Map.merge(generated(rtl), &1))
  end

  defp with_rtl(_, other, _, _, _),
    do: raise(ArgumentError, "rtl: needs an elaborated module, got #{inspect(other)}")

  defp generated(rtl), do: ExHdl.Backends.SystemVerilog.RTL.generate(rtl)

  @doc """
  Mismatches between the ports of `rtl` and the XDC ports of `signals` on
  `board`, as strings (empty when they agree).
  """
  @spec check_ports(RTLModule.t(), Board.t(), list(), [String.t() | atom()]) :: [String.t()]
  def check_ports(%RTLModule{} = rtl, %Board{} = board, signals, unconstrained \\ []) do
    case XDC.port_list(board, signals) do
      {:error, errs} ->
        for {_, m} <- errs, do: m

      {:ok, list} ->
        bound =
          Enum.group_by(list, &base/1)
          |> Map.new(fn {b, es} ->
            {b, {length(es), es |> Enum.map(& &1.dir) |> Enum.uniq(), hd(es).signal}}
          end)

        have = Map.new(rtl.ports, &{Atom.to_string(&1.name), &1})
        skip = Enum.map(unconstrained, &to_string/1)

        missing =
          for {b, {_, _, sig}} <- bound,
              not Map.has_key?(have, b),
              do:
                "port #{b} (board signal #{inspect(sig)}) is constrained but the top has no such port"

        loose =
          for {n, _} <- have,
              not Map.has_key?(bound, n),
              n not in skip,
              do:
                "top port #{n} has no constraint (bind a board signal or list it in unconstrained:)"

        bad =
          for {n, p} <- have, b = bound[n], do: port_error(n, p, b)

        Enum.sort(missing ++ loose ++ Enum.reject(bad, &is_nil/1))
    end
  end

  defp port_error(n, p, {w, dirs, sig}) do
    width = elem(p.type, 1)

    cond do
      width != w ->
        "port #{n} is #{width} bit(s) wide, board signal #{inspect(sig)} binds #{w}"

      p.dir == :input and dirs not in [[:in], [:inout]] ->
        "port #{n} is an input but #{inspect(sig)} is #{hd(dirs)}"

      p.dir == :output and dirs not in [[:out], [:inout]] ->
        "port #{n} is an output but #{inspect(sig)} is #{hd(dirs)}"

      true ->
        nil
    end
  end

  defp base(%{port: p}), do: p |> String.split("[") |> hd()

  @doc "Raises unless the spec has a name, top, part and at least one source."
  @spec validate!(t()) :: t()
  def validate!(%__MODULE__{} = b) do
    for f <- [:name, :top, :part], is_nil(Map.fetch!(b, f)) do
      raise ArgumentError, "build spec needs #{f}"
    end

    if b.sources == [] and b.generated == %{},
      do: raise(ArgumentError, "build spec has no sources")

    b
  end
end
