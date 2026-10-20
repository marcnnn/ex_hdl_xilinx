defmodule ExHdlXilinx.Device do
  @moduledoc """
  Device data for ExHdl targets: resource counts, primitive characteristics
  and typical delays per speed grade, as plain data.

  Counts come from the UltraScale+ product tables (DS890 for the Kintex
  family); maximum frequencies from the switching characteristics (DS922);
  both were entered from memory without the datasheets at hand, so
  `verified?` is false everywhere. Check each number against the datasheet
  before relying on it.

  The `delays` are planning estimates in the style of ExHdl's coarse timing
  model: typical logic delays seen in routed UltraScale+ reports, not
  datasheet guarantees. Timing closure is decided by Vivado.

      iex> d = ExHdlXilinx.Device.get("xcku3p")
      iex> d.resources.dsp
      1368
      iex> ExHdlXilinx.Device.delay(d, "-2", :lut_ns)
      0.1
      iex> ExHdlXilinx.Device.timing_options(d, "-1", clock_mhz: 250)[:dsp_latency]
      3
  """

  defstruct [
    :name,
    :family,
    :resources,
    :dsp,
    :bram,
    :uram,
    :gty,
    :delays,
    :fmax_mhz,
    sources: [],
    verified?: false
  ]

  @type t :: %__MODULE__{}

  @sources [
    "DS890 UltraScale Architecture and Product Overview (device table, KU3P column)",
    "DS922 Kintex UltraScale+ FPGAs Data Sheet: DC and AC Switching Characteristics",
    "UG579 UltraScale Architecture DSP Slice (DSP48E2)",
    "UG573 UltraScale Architecture Memory Resources (RAMB36E2, URAM288)",
    "UG576 UltraScale Architecture GTY Transceivers"
  ]

  @doc "Device by base name (`\"xcku3p\"`), or nil."
  @spec get(String.t()) :: t() | nil
  def get("xcku3p"), do: xcku3p()
  def get(_), do: nil

  @doc "Typical delay for `key` at `grade`."
  @spec delay(t(), String.t(), atom()) :: number()
  def delay(%__MODULE__{delays: d}, grade, key), do: d |> Map.fetch!(grade) |> Map.fetch!(key)

  @doc """
  Keyword options for `ExHdl.Target.Timing.new/1` (fields that exist in its
  struct are taken, see NEEDS.md for the fields that are missing), merged
  with `extra`.
  """
  @spec timing_options(t(), String.t(), keyword()) :: keyword()
  def timing_options(%__MODULE__{} = d, grade, extra \\ []) do
    g = Map.fetch!(d.delays, grade)

    Keyword.merge(
      [
        lut_ns: g.lut_ns,
        carry_ns_per_bit: g.carry_ns_per_bit,
        dsp_latency: d.dsp.latency_full,
        bram_latency: d.bram.latency_with_output_reg
      ],
      extra
    )
  end

  defp xcku3p do
    %__MODULE__{
      name: "xcku3p",
      family: :kintex_ultrascale_plus,
      resources: %{
        system_logic_cells: 355_950,
        clb_luts: 162_720,
        clb_ffs: 325_440,
        clb_slices: 20_340,
        lut_ram_kbit: 4_900,
        bram36: 360,
        bram18: 720,
        uram288: 48,
        dsp: 1_368,
        gty: 16,
        mmcm: 4,
        pll: 8,
        pcie4: 1,
        cmac: 1,
        hp_io: 208,
        hd_io: 48
      },
      dsp: %{
        primitive: "DSP48E2",
        multiplier: {27, 18},
        preadder_bits: 27,
        accumulator_bits: 48,
        latency_full: 3,
        latency_min: 1,
        note: "latency_full: A/B, M and P registers; the TARGET timing model counts these"
      },
      bram: %{
        primitive: "RAMB36E2",
        kbit: 36,
        max_width: 72,
        max_depth_at_width_1: 32_768,
        latency_with_output_reg: 2,
        latency_no_output_reg: 1,
        ports: :true_dual,
        splits_into: "2 x RAMB18E2"
      },
      uram: %{
        primitive: "URAM288",
        kbit: 288,
        depth: 4_096,
        width: 72,
        latency_with_output_reg: 2,
        note: "single clock domain per port pair, no byte-wide init; cascadable"
      },
      gty: %{
        primitive: "GTYE4_CHANNEL",
        max_line_rate_gbps: 32.75,
        quads: [224, 225, 226, 227],
        channels_per_quad: 4,
        note: "one PCIE4C hard block, bound to quads 224/225 on the FFVB676 card"
      },
      fmax_mhz: %{
        dsp48e2_all_regs: %{"-1" => 645, "-2" => 775, "-3" => 891},
        bram_all_regs: %{"-1" => 650, "-2" => 737, "-3" => 825},
        uram: %{"-1" => 600, "-2" => 650, "-3" => 700}
      },
      delays: %{
        "-1" => %{
          lut_ns: 0.12,
          carry_ns_per_bit: 0.012,
          ff_clk_to_q_ns: 0.10,
          ff_setup_ns: 0.03,
          net_typ_ns: 0.35
        },
        "-2" => %{
          lut_ns: 0.10,
          carry_ns_per_bit: 0.010,
          ff_clk_to_q_ns: 0.09,
          ff_setup_ns: 0.03,
          net_typ_ns: 0.30
        }
      },
      sources: @sources
    }
  end
end
