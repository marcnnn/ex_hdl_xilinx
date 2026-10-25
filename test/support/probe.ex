defmodule ExHdlXilinx.Test.Probe do
  @moduledoc false
  # exhdl branch ex/w5-xil: a black box model with several domains on one clock
  # is clocked in every domain (Sim.Flat kept only the last one before).
  use ExHdl.RTL

  defmodule Two do
    @moduledoc false
    @behaviour ExHdl.RTL.Model
    def init(_), do: {0, 0}
    def outputs({a, b}, _), do: %{qa: a, qb: b}
    def clock(:a, {a, b}, _), do: {a + 1, b}
    def clock(:b, {a, b}, _), do: {a, b + 1}
  end

  def shared_clock_models? do
    box =
      black_box "probe_two", model: Two do
        domain(:a, reset: nil)
        domain(:b, reset: nil)
        output(:qa, 1, comb_from: :none)
        output(:qb, 1, comb_from: :none)
      end

    top =
      module "probe_top" do
        domain(:sys, reset: nil)
        qa = output(:qa, 1)
        qb = output(:qb, 1)
        u = instance(:u, box, domains: [a: :sys, b: :sys])
        qa <~ u.qa
        qb <~ u.qb
      end

    sim = ExHdl.RTL.Sim.new(top) |> ExHdl.RTL.Sim.step()
    ExHdl.RTL.Sim.peek(sim, :qa) == 1 and ExHdl.RTL.Sim.peek(sim, :qb) == 1
  end
end
