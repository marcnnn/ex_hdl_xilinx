defmodule ExHdlXilinx.Primitives.Models do
  @moduledoc """
  `ExHdl.RTL.Model` implementations for the primitives in
  `ExHdlXilinx.Primitives`.

  The BEAM simulator drives every clock of a design ideally and cannot
  generate one from a model, so clock buffers and the MMCM/PLL clock outputs
  return 0: the clocks of the design are the (internal) clock signals of the
  top module, whatever drives them. What the models do provide is the
  control behaviour that gates logic: `LOCKED` goes high after
  `config :ex_hdl_xilinx, :lock_cycles` (default 16) cycles of the input
  clock, and `RST` or `PWRDWN` clear it.
  """

  defmodule Wire do
    @moduledoc false
    # Pass-through buffers: output = input.
    defmacro __using__(map) do
      quote do
        @behaviour ExHdl.RTL.Model
        @impl true
        def init(_), do: nil
        @impl true
        def outputs(_, ins) do
          for {out, inp} <- unquote(map), into: %{}, do: {out, Map.fetch!(ins, inp)}
        end

        @impl true
        def clock(_, s, _), do: s
      end
    end
  end

  defmodule Ibuf do
    @moduledoc false
    use Wire, [{:O, :I}]
  end

  defmodule Ibufds do
    @moduledoc false
    use Wire, [{:O, :I}]
  end

  defmodule Obuf do
    @moduledoc false
    use Wire, [{:O, :I}]
  end

  defmodule IbufdsGte4 do
    @moduledoc false
    use Wire, [{:O, :I}, {:ODIV2, :I}]
  end

  defmodule IdelayE3 do
    @moduledoc false
    # Zero delay: DATAOUT follows IDATAIN.
    @behaviour ExHdl.RTL.Model
    @impl true
    def init(_), do: nil
    @impl true
    def outputs(_, ins), do: %{DATAOUT: ins[:IDATAIN], CASC_OUT: 0, CNTVALUEOUT: 0}
    @impl true
    def clock(_, s, _), do: s
  end

  defmodule OdelayE3 do
    @moduledoc false
    @behaviour ExHdl.RTL.Model
    @impl true
    def init(_), do: nil
    @impl true
    def outputs(_, ins), do: %{DATAOUT: ins[:ODATAIN], CASC_OUT: 0, CNTVALUEOUT: 0}
    @impl true
    def clock(_, s, _), do: s
  end

  defmodule ClockBuf do
    @moduledoc false
    # BUFG, BUFGCE, BUFG_GT: the output clock is not modelled.
    @behaviour ExHdl.RTL.Model
    @impl true
    def init(_), do: nil
    @impl true
    def outputs(_, _), do: %{O: 0}
    @impl true
    def clock(_, s, _), do: s
  end

  defmodule Mmcm do
    @moduledoc false
    # State: cycles of CLKIN1 since RST/PWRDWN were last released, capped.
    @behaviour ExHdl.RTL.Model
    @outs ~w(CLKOUT0 CLKOUT0B CLKOUT1 CLKOUT1B CLKOUT2 CLKOUT2B CLKOUT3 CLKOUT3B CLKOUT4 CLKOUT5 CLKOUT6)

    @impl true
    def init(_), do: 0

    @impl true
    def outputs(n, _) do
      zero = Map.new(@outs ++ ["CLKFBOUT", "CLKFBOUTB"], &{String.to_atom(&1), 0})

      Map.merge(zero, %{
        LOCKED: lock(n),
        CLKFBSTOPPED: 0,
        CLKINSTOPPED: 0,
        CDDCDONE: 0,
        DO: 0,
        DRDY: 0,
        PSDONE: 0
      })
    end

    @impl true
    def clock(_, n, ins) do
      if ins[:RST] == 1 or ins[:PWRDWN] == 1, do: 0, else: min(n + 1, cycles())
    end

    defp lock(n), do: if(n >= cycles(), do: 1, else: 0)
    defp cycles, do: Application.get_env(:ex_hdl_xilinx, :lock_cycles, 16)
  end

  defmodule Plle4 do
    @moduledoc false
    @behaviour ExHdl.RTL.Model
    @impl true
    defdelegate init(p), to: Mmcm

    @impl true
    def outputs(n, ins) do
      m = Mmcm.outputs(n, ins)

      %{CLKOUTPHY: 0, CLKOUT1: 0, CLKOUT1B: 0}
      |> Map.merge(Map.take(m, [:CLKOUT0, :CLKOUT0B, :CLKFBOUT, :LOCKED, :DO, :DRDY]))
    end

    @impl true
    defdelegate clock(d, n, ins), to: Mmcm
  end

  defmodule Startupe3 do
    @moduledoc false
    # Configuration finished: EOS high, global set/reset and tristate released.
    @behaviour ExHdl.RTL.Model
    @impl true
    def init(_), do: nil
    @impl true
    def outputs(_, _) do
      %{CFGCLK: 0, CFGMCLK: 0, DI: 0, EOS: 1, PREQ: 0}
    end

    @impl true
    def clock(_, s, _), do: s
  end

  defmodule DnaPorte2 do
    @moduledoc false
    # READ=1 loads SIM_DNA_VALUE, SHIFT=1 shifts left with DIN into bit 0; DOUT is
    # the MSB. Bit order on silicon is unverified.
    @behaviour ExHdl.RTL.Model
    import Bitwise

    # The simulator hands a model the black box's default parameters, not the
    # instance's, so the value comes from `config :ex_hdl_xilinx, :sim_dna`.
    @impl true
    def init(params) do
      case Application.get_env(:ex_hdl_xilinx, :sim_dna, params[:SIM_DNA_VALUE]) do
        {:bits, _, v} -> v
        v when is_integer(v) -> v
        _ -> 0
      end
      |> then(&%{sr: &1, value: &1})
    end

    @impl true
    def outputs(%{sr: sr}, _), do: %{DOUT: sr >>> 95 &&& 1}

    @impl true
    def clock(_, %{sr: sr, value: v} = s, ins) do
      cond do
        ins[:READ] == 1 -> %{s | sr: v}
        ins[:SHIFT] == 1 -> %{s | sr: (sr <<< 1 ||| ins[:DIN]) &&& (1 <<< 96) - 1}
        true -> s
      end
    end
  end
end
