defmodule ExHdlXilinx.Primitives do
  @moduledoc """
  UltraScale+ primitives as `ExHdl.RTL` black boxes, with typed ports,
  parameters, Elixir simulation models and SystemVerilog simulation stubs.

  Each primitive is a function returning an `ExHdl.RTL.Module` of kind
  `:black_box` named like the Vivado primitive (`ibufds/0`, `mmcme4_adv/0`,
  ...). Instantiate it with `inst/3`, which maps clock domains and ties every
  unconnected input to its default (0 unless the primitive needs 1, e.g.
  `BUFGCE.CE`, `MMCME4_ADV.CLKINSEL`):

      u = Primitives.inst(:ibufds, Primitives.ibufds(), connect: [I: clk_p, IB: clk_n])
      u.O

  | Primitive | Ports | Model | Confidence in the port list |
  |---|---|---|---|
  | `IBUF`, `OBUF`, `IBUFDS` | complete | pass-through | high |
  | `IBUFDS_GTE4` | complete | pass-through | high |
  | `BUFG`, `BUFGCE`, `BUFG_GT` | complete | O = 0 (clocks are ideal in the simulator; `Clocking.bufg_gt_clock/2` for `DIV`) | high |
  | `MMCME4_ADV` | complete, `DADDR` width 7 unsure | LOCKED after N cycles if the VCO is in range; `Clocking.sim_clocks/3` for the output clocks | high / medium |
  | `PLLE4_ADV` | complete, `DADDR` width unsure | LOCKED after N cycles | medium |
  | `IDELAYE3`, `ODELAYE3` | complete | zero delay | high |
  | `RAMB36E2`, `RAMB18E2` | TDP and SDP without cascade and ECC, `ADDR` widths unsure | `Ram.Ramb`: widths 1 - 72, latency, write modes | medium |
  | `URAM288_BASE`, `URAM288` | without cascade and ECC | `Ram.Uram`: 4096 x 72, OREG, IREG_PRE | medium |
  | `STARTUPE3` | complete | EOS = 1 | high |
  | `DNA_PORTE2` | complete | shift register (bit order unverified) | high |
  | `SYSMONE4` | complete? `DADDR` width, I2C and `ADC_DATA` names unsure | none | medium |
  | `GTYE4_COMMON` | subset: PLL clocks, resets, locks, DRP | none | medium |
  | `GTYE4_CHANNEL` | subset (about 120 of several hundred ports) | none | medium |
  | `PCIE4CE4` | four AXI4-Stream interfaces only | none | low |

  `unsure/1` lists the ports marked uncertain; `notes/1` the scope notes.
  Parameters are the commonly used ones, not the full list. Real-valued
  parameters (`CLKIN1_PERIOD`, `CLKFBOUT_MULT_F`, `REFCLK_FREQUENCY`, ...)
  default to `{:real, v}` and are emitted as SV reals (`10.0`); instances
  may pass floats (`CLKOUT0_DIVIDE_F: 2.5`). Duty cycles and jitter keep
  their Vivado defaults.

  Ports that are clocks of the design (`MMCME4_ADV.CLKIN1`, `BUFG.I`,
  `GTYE4_CHANNEL.TXUSRCLK2`, `DCLK`) are clock inputs of a black box domain
  named like the port in lower case (`:clkin1`); `inst/3` maps them with
  `clocks:` / `clock:`. Primitive outputs that are clocks (`BUFG.O`,
  `MMCME4_ADV.CLKOUT0`) are declared `clock: true` (`Module.clock_outputs`)
  and assigned to the clock of an internal domain (`domain :c250, clock: :clk250, clock_port: false`).
  The BEAM simulator drives every clock of the top module ideally, whatever
  drives it, so models return 0 on clock outputs; MMCM `LOCKED` and `RST`
  behave (`ExHdlXilinx.Primitives.Models`).

  ## Simulation stubs

  Every primitive carries its stub as `sim_sources:` (`"<NAME>_sim.sv"`, flat because `ExHdl.Sim.Verilator` does not create subdirectories):
  minimal behavioural SystemVerilog for Verilator lint and simulation.
  `ExHdl.Backends.SystemVerilog.RTL.generate(top, sim: true)` and
  `ExHdl.RTL.Cosim` include them; plain `generate/1` (and so Vivado, which
  owns these modules) does not. `sim_sources/1` collects them. The MMCM/PLL stub passes
  `CLKIN1` to every output without timing (wrong frequency) and raises `LOCKED` after 16
  cycles (with Verilator `--timing`, or any other simulator, the MMCM stub
  generates its outputs from the parameters and the BUFG_GT stub divides
  by `DIV + 1`; `ExHdlXilinx.Primitives.Clocking` has the same arithmetic for
  the BEAM `clocks:` option). The memories simulate the same behaviour as their
  BEAM models (`ExHdlXilinx.Primitives.Ram`). The others tie outputs to 0
  except buffers and delays (`O = I`).
  """

  alias ExHdl.RTL.Module
  alias ExHdlXilinx.Primitives.Specs

  @specs Specs.all()

  @doc "Names of all primitives."
  def names, do: @specs |> Map.keys() |> Enum.sort()

  for name <- Map.keys(@specs) do
    fun = name |> String.downcase() |> String.to_atom()

    @doc "The `#{name}` black box."
    def unquote(fun)(), do: module(unquote(name))
  end

  @doc """
  The black box of primitive `name` (case-insensitive). Its simulation stub
  is attached as `sim_sources:` (`"<NAME>_sim.sv"`, flat because `ExHdl.Sim.Verilator` does not create subdirectories), so
  `ExHdl.Backends.SystemVerilog.RTL.generate(top, sim: true)` and
  `ExHdl.RTL.Cosim` pick it up while synthesis never sees it.
  """
  @spec module(String.t()) :: Module.t()
  def module(name) do
    {name, spec} = fetch!(name)

    box(
      name,
      Keyword.fetch!(spec, :ports),
      spec
      |> Keyword.take([:params, :model, :comb, :clock_outputs])
      |> Keyword.update(:params, [], &realify(&1, Keyword.get(spec, :reals, [])))
      |> Keyword.put(:sim_sources, %{"#{name}_sim.sv" => stub(name)})
    )
  end

  # Real-valued parameters as `{:real, v}`, so the SV backend emits `10.0`.
  defp realify(params, reals) do
    for {k, v} <- params, do: {k, if(k in reals and is_number(v), do: {:real, v}, else: v)}
  end

  @doc """
  A black box from a port string (grammar in `ExHdlXilinx.Primitives.Specs`:
  `i:NAME[w] o:NAME[w] c:CLOCK d:domain`, `@domain` and `?` suffixes).
  Options: `params:`, `model:`, `comb:` (output => input list),
  `clock_outputs:` (outputs declared `clock: true`), `sim_sources:`. Used
  for IP cores by `ExHdlXilinx.Vivado.IP`.
  """
  @spec box(String.t(), String.t(), keyword()) :: Module.t()
  def box(name, ports, opts \\ []) do
    toks = tokens(ports)
    comb = Keyword.get(opts, :comb, [])
    clock_outputs = Keyword.get(opts, :clock_outputs, [])

    domains =
      for(%{kind: :c, name: n} <- toks, do: {dom(n), clock: n, reset: nil}) ++
        for %{kind: :d, name: n} <- toks,
            do: {n, clock: :"clk_#{n}", reset: nil, clock_port: false}

    ports =
      for t <- toks, t.kind in [:i, :o] do
        case t.kind do
          :i ->
            {:input, t.name, t.width, domain: t.domain}

          :o ->
            {:output, t.name, t.width,
             [domain: t.domain, comb_from: Keyword.get(comb, t.name, :none)] ++
               if(t.name in clock_outputs, do: [clock: true], else: [])}
        end
      end

    ExHdl.RTL.black_box_from(name, ports,
      domains: domains,
      params: Keyword.get(opts, :params, []),
      model: opts[:model],
      sim_sources: Keyword.get(opts, :sim_sources, %{})
    )
  end

  defp fetch!(name) do
    key = String.upcase(to_string(name))

    case @specs do
      %{^key => spec} ->
        {key, Map.to_list(spec)}

      _ ->
        raise ArgumentError,
              "unknown primitive #{inspect(name)}; known: #{Enum.join(names(), ", ")}"
    end
  end

  # -- ports -----------------------------------------------------------------------------

  @token ~r/^([icod]):([A-Za-z0-9_]+)(?:\[(\d+)\])?(?:@([a-z0-9_]+))?(\?)?$/

  defp tokens(ports) do
    ports
    |> String.split()
    |> Enum.map(fn t ->
      [_, kind, name, w, dom, unsure] = Regex.run(@token, t, capture: :all) |> pad(6)

      %{
        kind: String.to_atom(kind),
        name: String.to_atom(name),
        width: if(w == "", do: 1, else: String.to_integer(w)),
        domain: if(dom == "", do: :async, else: String.to_atom(dom)),
        unsure: unsure == "?"
      }
    end)
  end

  defp pad(l, n), do: l ++ List.duplicate("", n - length(l))

  defp dom(clock_port),
    do: clock_port |> Atom.to_string() |> String.downcase() |> String.to_atom()

  @doc "Ports of primitive `name` that are marked uncertain."
  @spec unsure(String.t()) :: [atom()]
  def unsure(name) do
    {_, spec} = fetch!(name)
    for %{unsure: true, name: n} <- tokens(spec[:ports]), do: n
  end

  @doc "Scope note of a primitive with partial coverage (nil when complete)."
  @spec notes(String.t()) :: String.t() | nil
  def notes(name) do
    {_, spec} = fetch!(name)
    spec[:unsure_note]
  end

  # -- instantiation ---------------------------------------------------------------------

  @doc """
  Instantiates a primitive (or any black box) inside `ExHdl.RTL.module/3`.

  Options: `connect:` (port => expression), `params:`, `clocks:` (child
  domain => parent domain, e.g. `[clkin1: :ibuf]`), `clock:` (parent domain
  for every child domain not in `clocks:`; without it `ExHdl.RTL.instance/3`
  maps a single domain to the parent's default and demands `clocks:` for
  several), `open:` (inputs the caller drives afterwards, as in
  `u.CLKFBIN <~ u.CLKFBOUT`). Every other data input not in `connect:` gets
  its default (0, or the primitive's tie-off).
  """
  @spec inst(atom(), Module.t(), keyword()) :: map()
  def inst(name, %Module{} = m, opts \\ []) do
    connect = Keyword.get(opts, :connect, [])
    clocks = Keyword.get(opts, :clocks, [])
    default = opts[:clock]

    domains =
      for d <- m.domains, parent = clocks[d.name] || default, do: {d.name, parent}

    ties = tie_values(m)

    open = Keyword.get(opts, :open, [])

    tied =
      for p <- Module.data_inputs(m),
          not Keyword.has_key?(connect, p.name) and p.name not in open do
        {p.name, Map.get(ties, p.name, 0)}
      end

    ExHdl.RTL.instance(name, m,
      domains: domains,
      params: Keyword.get(opts, :params, []),
      connect: connect ++ tied
    )
  end

  defp tie_values(%Module{name: n}) do
    case @specs do
      %{^n => spec} -> Map.new(Map.get(spec, :ties, []))
      _ -> %{}
    end
  end

  # -- simulation stubs ------------------------------------------------------------------

  @doc """
  Simulation stubs for the primitives in the hierarchy of `module` (or of
  every module of a list): `%{"<NAME>_sim.sv" => text}`, the union of the
  black boxes' `sim_sources`. The same files as the `_sim.sv` entries of
  `ExHdl.Backends.SystemVerilog.RTL.generate(module, sim: true)`.
  """
  @spec sim_sources(Module.t() | [Module.t()]) :: %{String.t() => String.t()}
  def sim_sources(modules) do
    modules
    |> List.wrap()
    |> Enum.flat_map(&Module.hierarchy/1)
    |> Enum.filter(&(&1.kind == :black_box))
    |> Enum.reduce(%{}, &Map.merge(&2, &1.sim_sources))
  end

  @doc """
  The SystemVerilog simulation stub of primitive `name`, or, for any other
  black box (an `ExHdlXilinx.Vivado.IP`), a stub with all outputs tied to 0.
  """
  @spec stub(String.t() | Module.t()) :: String.t()
  def stub(%Module{kind: :black_box} = m) do
    toks =
      for p <- m.ports,
          do: %{
            kind: if(p.dir == :output, do: :o, else: :i),
            name: p.name,
            width: elem(p.type, 1)
          }

    render_stub(m.name, toks, m.params, [], [], nil)
  end

  def stub(name) do
    {name, spec} = fetch!(name)
    toks = Enum.filter(tokens(spec[:ports]), &(&1.kind in [:i, :o, :c]))

    render_stub(
      name,
      toks,
      realify(Keyword.get(spec, :params, []), Keyword.get(spec, :reals, [])),
      Keyword.get(spec, :reals, []),
      Keyword.get(spec, :drives, []),
      spec[:stub]
    )
  end

  defp render_stub(name, toks, params, reals, drives, body) do
    params =
      for {k, v} <- params do
        "parameter #{ptype(k in reals, v)} #{k} = #{pval(v)}"
      end

    ports =
      for t <- toks do
        dir = if t.kind == :o, do: "output", else: "input "
        "#{dir} logic#{range(t.width)} #{t.name}"
      end

    zero =
      for %{kind: :o, name: n} <- toks, Atom.to_string(n) not in drives do
        "  assign #{n} = '0;"
      end

    """
    // SIMULATION STUB of the #{name} primitive for lint and Verilator. Not for
    // synthesis: Vivado owns this module. Generated by ExHdlXilinx.Primitives.
    /* verilator lint_off UNUSEDSIGNAL */
    /* verilator lint_off UNUSEDPARAM */
    /* verilator lint_off DECLFILENAME */
    /* verilator lint_off UNDRIVEN */
    /* verilator lint_off MULTIDRIVEN */
    /* verilator lint_off SYNCASYNCNET */
    `default_nettype none
    module #{name}#{if params == [], do: "", else: " #(\n  " <> Enum.join(params, ",\n  ") <> "\n)"} (
      #{Enum.join(ports, ",\n  ")}
    );
    #{Enum.join(zero, "\n")}#{if body, do: "\n  " <> body, else: ""}
    endmodule
    `default_nettype wire
    /* verilator lint_on SYNCASYNCNET */
    /* verilator lint_on MULTIDRIVEN */
    /* verilator lint_on UNDRIVEN */
    /* verilator lint_on DECLFILENAME */
    /* verilator lint_on UNUSEDPARAM */
    /* verilator lint_on UNUSEDSIGNAL */
    """
  end

  defp range(1), do: ""
  defp range(w), do: " [#{w - 1}:0]"

  defp ptype(true, _), do: "real"
  defp ptype(_, {:bits, w, _}), do: "logic [#{w - 1}:0]"
  defp ptype(_, {:real, _}), do: "real"
  defp ptype(_, v) when is_float(v), do: "real"
  defp ptype(_, v) when is_integer(v), do: "integer"
  defp ptype(_, v) when is_binary(v), do: "string"

  defp pval({:bits, w, v}), do: "#{w}'h#{Integer.to_string(v, 16)}"
  defp pval({:real, v}), do: pval(v / 1)
  defp pval(v) when is_float(v), do: :erlang.float_to_binary(v, [:short])
  defp pval(v) when is_integer(v), do: Integer.to_string(v)
  defp pval(v) when is_binary(v), do: inspect(v)
end
