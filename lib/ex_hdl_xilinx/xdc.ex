defmodule ExHdlXilinx.XDC do
  @moduledoc """
  XDC text from a board and the list of signals a design uses.

  `used` entries bind a board pin (or group) to a top-level port name:

    * `:led0` - port `led0`
    * `{:led0, "status"}` - port `status`
    * `{:led0, {"led", 0}}` - port bit `led[0]`
    * `{:leds, "led"}` - a group becomes the bus `led[0]`, `led[1]`, ...

  Differential pairs get `_p`/`_n` suffixes before the index (`clk100_p`,
  `pcie_rx_p[0]`). Board clocks that are used get a `create_clock` named after
  the clock. Pins with a `timing` hint are false-pathed. Unverified pins are
  flagged in a comment above the line.

  Options:

    * `:io_standard` - `%{pin_name => "LVCMOS18"}` overrides
    * `:clocks` - extra clocks `%{name:, port:, period_ns: | frequency_hz:}`
    * `:clock_groups` - `[[:clk100, "sys"], [:pcie_refclk]]`, each inner list
      is a group, all groups are declared asynchronous to each other
      (with generated clocks); names must be created clocks
    * `:false_paths` - `%{from: tcl, to: tcl}` with Tcl object expressions
    * `:max_delay` - `%{ns:, from:, to:, datapath_only: true, quiet: false}`
    * `:bitstream_properties` - extra or overriding `%{"BITSTREAM..." => v}`
    * `:flash` - `false` to omit the board's configuration properties
    * `:check_banks` - `false` to skip VCCO checks (default `true`)

  Errors (unknown pin, a pin used twice, duplicate ports, missing IO standard,
  bank voltage conflicts, unknown clocks) come back together as
  `{:error, [{kind, message}]}`; `generate!/3` raises `ExHdlXilinx.XDC.Error`.

      iex> b = ExHdlXilinx.Boards.AS02MC04.board()
      iex> {:ok, xdc} = ExHdlXilinx.XDC.generate(b, [{:clk100, "clk"}, {:leds, "led"}], flash: false)
      iex> xdc =~ "set_property -dict {PACKAGE_PIN E18 IOSTANDARD LVDS} [get_ports clk_p]"
      true
      iex> xdc =~ "create_clock -name clk100 -period 10.000 [get_ports clk_p]"
      true
      iex> ExHdlXilinx.XDC.generate(b, [:nope], [])
      {:error, [{:unknown_signal, "unknown board signal :nope"}]}
  """

  defmodule Error do
    defexception [:errors]
    def message(%{errors: e}), do: Enum.map_join(e, "\n", fn {k, m} -> "#{k}: #{m}" end)
  end

  alias ExHdlXilinx.Board
  alias ExHdlXilinx.Board.Clock

  @voltage %{
    "LVCMOS33" => 3.3,
    "LVTTL" => 3.3,
    "LVCMOS25" => 2.5,
    "LVCMOS18" => 1.8,
    "LVCMOS15" => 1.5,
    "LVCMOS12" => 1.2,
    "LVDS" => 1.8,
    "HSTL_I" => 1.8,
    "SSTL18_I" => 1.8
  }

  @type used :: atom() | {atom(), String.t() | {String.t(), non_neg_integer()}}

  @spec generate(Board.t(), [used()], keyword()) ::
          {:ok, String.t()} | {:error, [{atom(), String.t()}]}
  def generate(%Board{} = board, used, opts \\ []) do
    {entries, errs1} = resolve(board, used)
    errs = errs1 ++ check_entries(board, entries, opts)
    clocks = clocks(board, entries, opts)
    errs = errs ++ check_groups(clocks, opts)

    if errs == [] do
      {:ok, render(board, entries, clocks, opts)}
    else
      {:error, errs}
    end
  end

  @spec generate!(Board.t(), [used()], keyword()) :: String.t()
  def generate!(board, used, opts \\ []) do
    case generate(board, used, opts) do
      {:ok, text} -> text
      {:error, errors} -> raise Error, errors: errors
    end
  end

  @doc """
  The top-level ports the signals produce, without generating anything:
  `[%{port: "led[0]", dir: :out, signal: :led0}, ...]` (differential pairs give
  `clk100_p` and `clk100_n`). `{:error, errors}` for unknown signals.

      iex> b = ExHdlXilinx.Boards.AS02MC04.board()
      iex> {:ok, ports} = ExHdlXilinx.XDC.port_list(b, [:clk100, {:leds, "led"}])
      iex> Enum.map(ports, & &1.port) |> Enum.take(3)
      ["clk100_p", "clk100_n", "led[0]"]
  """
  @spec port_list(Board.t(), [used()]) ::
          {:ok, [%{port: String.t(), dir: atom(), signal: atom()}]} | {:error, list()}
  def port_list(%Board{} = board, used) do
    case resolve(board, used) do
      {entries, []} ->
        {:ok,
         for e <- entries, {_, port} <- ports(e) do
           %{port: port, dir: e.pin.dir, signal: e.pin.name}
         end}

      {_, errs} ->
        {:error, errs}
    end
  end

  # -- resolution ---------------------------------------------------------

  defp resolve(board, used) do
    pins = Board.pins(board)

    Enum.reduce(used, {[], []}, fn item, {ok, err} ->
      {name, port} = split(item)

      cond do
        Map.has_key?(pins, name) ->
          {ok ++ [entry(pins[name], port || Atom.to_string(name))], err}

        Map.has_key?(board.groups, name) ->
          base = port || Atom.to_string(name)

          es =
            for {n, i} <- Enum.with_index(board.groups[name]), do: entry(pins[n], {base, i})

          {ok ++ es, err}

        true ->
          {ok, err ++ [{:unknown_signal, "unknown board signal #{inspect(name)}"}]}
      end
    end)
  end

  defp split({name, port}), do: {name, port}
  defp split(name) when is_atom(name), do: {name, nil}

  defp entry(pin, port), do: %{pin: pin, port: port}

  defp ports(%{pin: pin, port: port}) do
    {base, idx} = if is_tuple(port), do: port, else: {port, nil}
    suffix = if idx, do: "[#{idx}]", else: ""

    if pin.pin_n do
      [{pin.pin, "#{base}_p#{suffix}"}, {pin.pin_n, "#{base}_n#{suffix}"}]
    else
      [{pin.pin, "#{base}#{suffix}"}]
    end
  end

  # -- checks -------------------------------------------------------------

  defp check_entries(board, entries, opts) do
    over = Keyword.get(opts, :io_standard, %{})
    port_names = Enum.flat_map(entries, &ports/1)

    dup_signals =
      for {name, n} <- Enum.frequencies(Enum.map(entries, & &1.pin.name)),
          n > 1,
          do: {:duplicate_signal, "board signal #{inspect(name)} is bound #{n} times"}

    dup_ports =
      for {port, n} <- Enum.frequencies(Enum.map(port_names, &elem(&1, 1))),
          n > 1,
          do: {:duplicate_port, "port #{port} is used #{n} times"}

    dup_pins =
      for {ball, ps} <- Enum.group_by(port_names, &elem(&1, 0), &elem(&1, 1)),
          length(Enum.uniq(ps)) > 1,
          do: {:duplicate_pin, "ball #{ball} assigned to ports #{Enum.join(ps, ", ")}"}

    missing =
      for %{pin: p} <- entries,
          is_nil(p.gt) and is_nil(over[p.name] || p.io_standard),
          do: {:missing_io_standard, "pin #{p.name} (#{p.pin}) has no IO standard"}

    dup_signals ++ dup_ports ++ dup_pins ++ missing ++ check_banks(board, entries, over, opts)
  end

  defp check_banks(board, entries, over, opts) do
    if Keyword.get(opts, :check_banks, true) do
      for {bank, es} <- Enum.group_by(entries, & &1.pin.bank), bank != nil, reduce: [] do
        acc ->
          vs =
            es
            |> Enum.reject(& &1.pin.gt)
            |> Enum.map(&{&1.pin.name, std(&1.pin, over)})
            |> Enum.flat_map(fn {n, s} ->
              case @voltage[s] do
                nil -> []
                v -> [{n, s, v}]
              end
            end)

          acc ++ bank_errors(board, bank, vs)
      end
    else
      []
    end
  end

  defp bank_errors(board, bank, vs) do
    volts = vs |> Enum.map(&elem(&1, 2)) |> Enum.uniq()

    mix =
      if length(volts) > 1 do
        desc = Enum.map_join(vs, ", ", fn {n, s, _} -> "#{n}=#{s}" end)
        [{:bank_conflict, "bank #{bank} mixes VCCO levels: #{desc}"}]
      else
        []
      end

    case board.bank_voltages[bank] do
      nil ->
        mix

      vcco ->
        bad = for {n, s, v} <- vs, v != vcco, do: "#{n}=#{s}"

        mix ++
          if bad == [],
            do: [],
            else: [{:bank_conflict, "bank #{bank} runs at #{vcco} V but #{Enum.join(bad, ", ")}"}]
    end
  end

  defp std(pin, over), do: over[pin.name] || pin.io_standard

  defp check_groups(clocks, opts) do
    known = MapSet.new(clocks, & &1.name)

    for g <- Keyword.get(opts, :clock_groups, []), n <- g, to_string(n) not in known do
      {:unknown_clock, "clock group names #{inspect(n)}, which is not a created clock"}
    end
  end

  # -- rendering ----------------------------------------------------------

  defp clocks(board, entries, opts) do
    from_board =
      for c <- board.clocks, e <- entries, e.pin.name == c.signal do
        [{_, port} | _] = ports(e)
        %{name: to_string(c.name), port: port, period_ns: Clock.period_ns(c)}
      end

    extra =
      for c <- Keyword.get(opts, :clocks, []) do
        period = c[:period_ns] || 1.0e9 / c.frequency_hz
        %{name: to_string(c.name), port: c.port, period_ns: period}
      end

    from_board ++ extra
  end

  defp render(board, entries, clocks, opts) do
    over = Keyword.get(opts, :io_standard, %{})

    [
      "# Generated by ExHdlXilinx.XDC for #{board.name} (#{Board.part(board)})\n",
      section("Pins", Enum.flat_map(entries, &pin_lines(&1, over))),
      section("Clocks", Enum.map(clocks, &clock_line/1)),
      section("Static signals", timing_lines(entries)),
      section("Clock groups", group_lines(opts)),
      section("False paths", Enum.map(Keyword.get(opts, :false_paths, []), &false_path/1)),
      section("CDC bounds", Enum.map(Keyword.get(opts, :max_delay, []), &max_delay/1)),
      section("Configuration", config_lines(board, opts))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp section(_title, []), do: nil
  defp section(title, lines), do: "# #{title}\n" <> Enum.join(lines, "\n") <> "\n"

  defp pin_lines(%{pin: p} = e, over) do
    flag =
      if p.verified?,
        do: [],
        else: ["# unverified: #{p.name} (#{Enum.join(p.source, ", ")})"]

    flag ++
      for {ball, port} <- ports(e) do
        props =
          [{"PACKAGE_PIN", ball}] ++
            if(p.gt, do: [], else: [{"IOSTANDARD", std(p, over)}]) ++
            if(p.pull == :up, do: [{"PULLUP", "true"}], else: []) ++
            if(p.pull == :down, do: [{"PULLDOWN", "true"}], else: []) ++
            if(p.drive, do: [{"DRIVE", p.drive}], else: []) ++
            if(p.slew, do: [{"SLEW", p.slew |> to_string() |> String.upcase()}], else: [])

        dict = Enum.map_join(props, " ", fn {k, v} -> "#{k} #{v}" end)
        "set_property -dict {#{dict}} [get_ports #{tcl(port)}]"
      end
  end

  defp tcl(port), do: if(String.contains?(port, "["), do: "{#{port}}", else: port)

  defp clock_line(c),
    do: "create_clock -name #{c.name} -period #{ns(c.period_ns)} [get_ports #{tcl(c.port)}]"

  defp ns(x), do: :erlang.float_to_binary(x * 1.0, decimals: 3)

  defp timing_lines(entries) do
    for {dir, flag} <- [async_in: "-from", async_out: "-to"],
        names = for(e <- entries, e.pin.timing == dir, {_, p} <- Enum.take(ports(e), 1), do: p),
        names != [] do
      "set_false_path #{flag} [get_ports {#{Enum.join(names, " ")}}]"
    end
  end

  defp group_lines(opts) do
    case Keyword.get(opts, :clock_groups, []) do
      [] ->
        []

      groups ->
        gs =
          Enum.map_join(groups, " \\\n", fn g ->
            names = Enum.map_join(g, " ", &to_string/1)
            "    -group [get_clocks -include_generated_clocks {#{names}}]"
          end)

        ["set_clock_groups -asynchronous \\\n" <> gs]
    end
  end

  defp false_path(fp) do
    "set_false_path" <>
      if(fp[:from], do: " -from #{fp.from}", else: "") <>
      if(fp[:through], do: " -through #{fp.through}", else: "") <>
      if(fp[:to], do: " -to #{fp.to}", else: "")
  end

  defp max_delay(%{ns: v} = m) do
    "set_max_delay" <>
      if(Map.get(m, :datapath_only, true), do: " -datapath_only", else: "") <>
      if(Map.get(m, :quiet, false), do: " -quiet", else: "") <>
      " #{ns(v)} -from #{m.from} -to #{m.to}"
  end

  defp config_lines(board, opts) do
    flash = if Keyword.get(opts, :flash, true), do: board.flash
    extra = Keyword.get(opts, :bitstream_properties, %{})

    base = if flash, do: flash_props(flash), else: []
    keys = Enum.map(base, &elem(&1, 0))

    merged =
      Enum.map(base, fn {k, v} -> {k, Map.get(extra, k, v)} end) ++
        for {k, v} <- extra, k not in keys, do: {k, v}

    for {k, v} <- merged, do: "set_property #{k} #{v} [current_design]"
  end

  defp flash_props(f) do
    [
      {"CONFIG_VOLTAGE", f.config_voltage},
      {"CFGBVS", f.cfgbvs},
      {"BITSTREAM.CONFIG.SPI_BUSWIDTH", f.buswidth},
      {"BITSTREAM.CONFIG.CONFIGRATE",
       f.config_rate_mhz && :erlang.float_to_binary(f.config_rate_mhz, decimals: 1)},
      {"BITSTREAM.CONFIG.EXTMASTERCCLK_EN", f.extmastercclk_en},
      {"BITSTREAM.CONFIG.SPI_FALL_EDGE", f.spi_fall_edge && "YES"},
      {"BITSTREAM.GENERAL.COMPRESS", f.compress && "TRUE"},
      {"BITSTREAM.CONFIG.UNUSEDPIN", f.unusedpin}
    ]
    |> Enum.reject(fn {_, v} -> is_nil(v) or v == false end)
  end
end
