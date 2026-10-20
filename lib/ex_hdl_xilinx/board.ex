defmodule ExHdlXilinx.Board do
  @moduledoc """
  A board as plain data: part, clocks, PCIe, SFP cages, LEDs, buttons, flash.

  Every pin is a `ExHdlXilinx.Board.Pin` that carries its provenance
  (`source`, a list of keys of `sources`) and a `verified?` flag. `verified?`
  means: the ball was seen working on real hardware, with the sources agreeing.
  Everything else is a lead to check with `get_property PIN_FUNC` first.

  A board module implements the behaviour:

      defmodule MyBoard do
        @behaviour ExHdlXilinx.Board
        def board, do: %ExHdlXilinx.Board{...}
      end

  Entries are addressed by pin name (an atom such as `:led0`), groups
  (`:leds`, `:pcie_rx`) by name in `groups`.

      iex> b = ExHdlXilinx.Boards.AS02MC04.board()
      iex> ExHdlXilinx.Board.part(b)
      "xcku3p-ffvb676-1-e"
      iex> ExHdlXilinx.Board.pin!(b, :clk100).pin
      "E18"
      iex> ExHdlXilinx.Board.group(b, :leds)
      [:led0, :led1, :led2, :led3]
  """

  defmodule Pin do
    @moduledoc """
    One logical signal on one or two balls (`pin_n` for differential pairs).

    `gt` is `%{quad: 227, kind: :tx | :rx | :refclk, index: nil | integer}`
    for transceiver balls, which carry no IOSTANDARD. `timing` is `:async_in`
    or `:async_out` for static signals that XDC generation false-paths.
    """
    @enforce_keys [:name, :pin]
    defstruct [
      :name,
      :pin,
      :pin_n,
      :io_standard,
      :pull,
      :drive,
      :slew,
      :bank,
      :gt,
      :timing,
      :note,
      dir: :in,
      alt_io_standards: [],
      source: [],
      verified?: false
    ]

    @type t :: %__MODULE__{}
  end

  defmodule Clock do
    @moduledoc "A board oscillator: `signal` is the pin name, `kind` is `:fabric` or `:gt_ref`."
    @enforce_keys [:name, :signal, :frequency_hz]
    defstruct [:name, :signal, :frequency_hz, kind: :fabric]
    @type t :: %__MODULE__{}

    @doc "Period in ns."
    def period_ns(%__MODULE__{frequency_hz: f}), do: 1.0e9 / f
  end

  defmodule Sfp do
    @moduledoc "An SFP cage. Fields other than `index` and `gt_quad` are pin names or nil."
    defstruct [
      :index,
      :gt_quad,
      :tx,
      :rx,
      :refclk,
      :tx_disable,
      :los,
      :mod_abs,
      :tx_fault,
      :i2c_scl,
      :i2c_sda,
      :led
    ]

    @type t :: %__MODULE__{}
  end

  defmodule Pcie do
    @moduledoc """
    PCIe edge connector. `lanes` are in physical GT order; `lane_order: :reversed`
    means logical lane N sits on physical lane `width - 1 - N`.
    """
    defstruct [:refclk, :perst, :gen, :lane_order, :reported_width, lanes: [], note: nil]
    @type t :: %__MODULE__{}

    @doc "Lanes in logical order."
    def logical_lanes(%__MODULE__{lanes: l, lane_order: :reversed}), do: Enum.reverse(l)
    def logical_lanes(%__MODULE__{lanes: l}), do: l
  end

  defmodule Flash do
    @moduledoc "Configuration flash and the bitstream properties that go with it."
    defstruct [
      :part,
      :cfgmem_part,
      :size_mbit,
      :interface,
      :buswidth,
      :config_voltage,
      :cfgbvs,
      :config_rate_mhz,
      :spi_fall_edge,
      :compress,
      :unusedpin,
      :extmastercclk_en,
      source: [],
      verified?: false
    ]

    @type t :: %__MODULE__{}
  end

  @enforce_keys [:name, :device, :package, :speed_grade, :temp]
  defstruct [
    :name,
    :device,
    :package,
    :speed_grade,
    :temp,
    :flash,
    :pcie,
    speed_grades: [],
    pins: [],
    clocks: [],
    sfps: [],
    groups: %{},
    bank_voltages: %{},
    sources: %{},
    notes: []
  ]

  @type t :: %__MODULE__{}

  @callback board() :: t()

  @doc "Vivado part string, optionally for another `:speed_grade` (e.g. `\"-2\"`)."
  @spec part(t(), keyword()) :: String.t()
  def part(%__MODULE__{} = b, opts \\ []) do
    grade = Keyword.get(opts, :speed_grade, b.speed_grade)
    "#{b.device}-#{String.downcase(b.package)}#{grade}-#{String.downcase(b.temp)}"
  end

  @doc "Pins by name."
  @spec pins(t()) :: %{atom() => Pin.t()}
  def pins(%__MODULE__{pins: pins}), do: Map.new(pins, &{&1.name, &1})

  @spec pin(t(), atom()) :: {:ok, Pin.t()} | :error
  def pin(b, name), do: Map.fetch(pins(b), name)

  @spec pin!(t(), atom()) :: Pin.t()
  def pin!(b, name) do
    case pin(b, name) do
      {:ok, p} -> p
      :error -> raise ArgumentError, "board #{b.name} has no pin #{inspect(name)}"
    end
  end

  @doc "Pin names of a group, or `[]`."
  def group(%__MODULE__{groups: g}, name), do: Map.get(g, name, [])

  @doc "Pins that are not verified on hardware."
  def unverified(%__MODULE__{pins: pins}), do: for(p <- pins, not p.verified?, do: p.name)

  @doc "Clock by name."
  def clock(%__MODULE__{clocks: cs}, name), do: Enum.find(cs, &(&1.name == name))

  @doc """
  Consistency checks on the board data itself: duplicate names or balls,
  missing IO standard on non-GT pins, unknown sources, unknown references.
  """
  @spec validate(t()) :: :ok | {:error, [String.t()]}
  def validate(%__MODULE__{} = b) do
    names = Enum.map(b.pins, & &1.name)
    balls = Enum.flat_map(b.pins, &[&1.pin, &1.pin_n]) |> Enum.reject(&is_nil/1)

    errors =
      dup_errors("duplicate pin name", names) ++
        dup_errors("duplicate ball", balls) ++
        Enum.flat_map(b.pins, &pin_errors(&1, b)) ++
        ref_errors(b, names)

    if errors == [], do: :ok, else: {:error, errors}
  end

  defp dup_errors(what, list),
    do: for({x, n} <- Enum.frequencies(list), n > 1, do: "#{what} #{inspect(x)}")

  defp pin_errors(p, b) do
    [
      if(is_nil(p.gt) and is_nil(p.io_standard),
        do: "pin #{p.name} (#{p.pin}) has no IO standard"
      ),
      if(p.source == [], do: "pin #{p.name} has no source"),
      for(s <- p.source, not is_map_key(b.sources, s), do: "pin #{p.name}: unknown source #{s}")
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  defp ref_errors(b, names) do
    refs =
      Enum.map(b.clocks, & &1.signal) ++
        Enum.flat_map(b.sfps, fn s ->
          [s.tx, s.rx, s.refclk, s.tx_disable, s.los, s.mod_abs, s.tx_fault, s.i2c_scl] ++
            [s.i2c_sda, s.led]
        end) ++
        if(b.pcie,
          do:
            [b.pcie.refclk, b.pcie.perst] ++
              Enum.flat_map(b.pcie.lanes, &[&1.tx, &1.rx]),
          else: []
        ) ++ List.flatten(Map.values(b.groups))

    for r <- refs, r != nil, r not in names, do: "reference to unknown pin #{inspect(r)}"
  end
end
