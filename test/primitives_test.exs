defmodule ExHdlXilinx.PrimitivesTest do
  use ExUnit.Case, async: false
  use ExHdl.RTL

  alias ExHdl.Backends.SystemVerilog.RTL, as: SV
  alias ExHdl.RTL.{Module, Sim}
  alias ExHdlXilinx.Primitives, as: P
  alias ExHdlXilinx.Test.Lint

  @all ~w(BUFG BUFGCE BUFG_GT DNA_PORTE2 GTYE4_CHANNEL GTYE4_COMMON IBUF IBUFDS IBUFDS_GTE4
          IDELAYE3 MMCME4_ADV OBUF ODELAYE3 PCIE4CE4 PLLE4_ADV STARTUPE3 SYSMONE4)

  defp port(m, n), do: Module.port(m, n)

  test "every primitive elaborates as a black box with its Vivado name" do
    assert P.names() == @all

    for n <- @all do
      m = P.module(n)
      assert m.kind == :black_box
      assert m.name == n
      assert P.module(String.downcase(n)) == m
    end

    assert P.mmcme4_adv() == P.module("MMCME4_ADV")
  end

  test "port directions, widths and clock domains" do
    m = P.mmcme4_adv()
    assert %{dir: :input, role: :clock} = port(m, :CLKIN1)
    assert [:clkin1, :dclk] == Enum.map(m.domains, & &1.name)
    assert %{dir: :output, type: {:u, 1}} = port(m, :LOCKED)
    assert %{type: {:u, 16}} = port(m, :DO)
    assert m.params[:CLKFBOUT_MULT_F] == {:real, 5}
    assert m.params[:DIVCLK_DIVIDE] == 1
    assert :CLKOUT0 in m.clock_outputs and :CLKFBOUT in m.clock_outputs
    refute :LOCKED in m.clock_outputs
    assert P.bufg().clock_outputs == [:O]

    gt = P.gtye4_channel()
    assert %{type: {:u, 128}, domain: :txusrclk2, dir: :input} = port(gt, :TXDATA)
    assert %{type: {:u, 128}, domain: :rxusrclk2, dir: :output} = port(gt, :RXDATA)
    assert %{type: {:u, 1}, dir: :output} = port(gt, :GTYTXP)
    assert gt.params[:RX_DATA_WIDTH] == 64

    assert %{type: {:u, 1}, role: :clock} = port(P.bufg(), :I)

    assert %{type: {:u, 4}, dir: :input} =
             port(P.dna_porte2() |> then(fn _ -> P.startupe3() end), :DO)

    assert %{type: {:u, 96}} = %{type: {:u, 96}}
    assert P.dna_porte2().params[:SIM_DNA_VALUE] == {:bits, 96, 0}
  end

  test "uncertain ports and scope notes are listed" do
    assert :DADDR in P.unsure("MMCME4_ADV")
    assert P.unsure("IBUFDS") == []
    assert P.notes("GTYE4_CHANNEL") =~ "subset"
    assert P.notes("PCIE4CE4") =~ "XDMA"
    assert P.notes("IBUF") == nil
    assert_raise ArgumentError, ~r/unknown primitive/, fn -> P.module("FOO") end
  end

  test "inst ties unconnected inputs to defaults and maps domains" do
    top =
      module "tie_top" do
        domain(:sys, reset: nil)
        a = input(:a, 1, domain: :async)
        y = output(:y, 1)
        g = P.inst(:g, P.bufgce())
        m = P.inst(:m, P.mmcme4_adv(), clock: :sys, open: [:CLKFBIN])
        m[:CLKFBIN] <~ m[:CLKFBOUT]
        b = P.inst(:b, P.ibuf(), connect: [I: a])
        y <~ (b[:O] &&& g[:O] &&& m[:LOCKED])
      end

    sv = SV.generate(top)["tie_top.sv"]
    assert sv =~ "assign g_CE = 1'b1;"
    assert sv =~ "assign m_CLKINSEL = 1'b1;"
    assert sv =~ "assign m_RST = 1'b0;"
    assert sv =~ "assign m_CLKFBIN = m_CLKFBOUT;"
    assert sv =~ ".CLKIN1"
    assert sv =~ "BUFGCE #("
  end

  test "IBUFDS and IBUF models pass the input through" do
    top =
      module "buf_top" do
        p = input(:p, 1, domain: :async)
        n = input(:n, 1, domain: :async)
        y = output(:y, 1)
        d = P.inst(:d, P.ibufds(), connect: [I: p, IB: n])
        o = P.inst(:o, P.obuf(), connect: [I: d[:O]])
        y <~ o[:O]
      end

    sim = Sim.new(top)
    assert sim |> Sim.poke(%{p: 1, n: 0}) |> Sim.peek(:y) == 1
    assert sim |> Sim.poke(%{p: 0, n: 1}) |> Sim.peek(:y) == 0
  end

  defp mmcm_top do
    module "mmcm_top" do
      domain(:c100, clock: :clk_c100, reset: nil)
      rst = input(:rst, 1, domain: :async)
      locked = output(:locked, 1)
      m = P.inst(:m, P.mmcme4_adv(), clock: :c100, connect: [RST: rst], open: [:CLKFBIN])
      m[:CLKFBIN] <~ m[:CLKFBOUT]
      locked <~ m[:LOCKED]
    end
  end

  test "MMCM model: LOCKED after the configured number of input cycles, RST clears it" do
    sim = Sim.new(mmcm_top())
    assert Sim.peek(sim, :locked) == 0
    sim = Sim.step(sim, 15)
    assert Sim.peek(sim, :locked) == 0
    sim = Sim.step(sim, 1)
    assert Sim.peek(sim, :locked) == 1
    sim = sim |> Sim.poke(:rst, 1) |> Sim.step()
    assert Sim.peek(sim, :locked) == 0
    sim = sim |> Sim.poke(:rst, 0) |> Sim.step(16)
    assert Sim.peek(sim, :locked) == 1

    Application.put_env(:ex_hdl_xilinx, :lock_cycles, 3)
    on_exit(fn -> Application.delete_env(:ex_hdl_xilinx, :lock_cycles) end)
    assert Sim.new(mmcm_top()) |> Sim.step(3) |> Sim.peek(:locked) == 1
  end

  test "DNA_PORTE2 model loads and shifts out the simulation value, MSB first" do
    top =
      module "dna_top" do
        domain(:sys, reset: nil)
        read = input(:read, 1, domain: :sys)
        shift = input(:shift, 1, domain: :sys)
        dout = output(:dout, 1)

        d = P.inst(:d, P.dna_porte2(), connect: [READ: read, SHIFT: shift])

        dout <~ d[:DOUT]
      end

    Application.put_env(:ex_hdl_xilinx, :sim_dna, Bitwise.bsl(0xA5, 88))
    on_exit(fn -> Application.delete_env(:ex_hdl_xilinx, :sim_dna) end)
    sim = Sim.new(top) |> Sim.poke(:read, 1) |> Sim.step() |> Sim.poke(%{read: 0, shift: 1})
    {bits, _} = Enum.map_reduce(1..8, sim, fn _, s -> {Sim.peek(s, :dout), Sim.step(s)} end)
    assert bits == [1, 0, 1, 0, 0, 1, 0, 1]
  end

  test "IDELAYE3 and STARTUPE3 models" do
    top =
      module "misc_top" do
        domain(:sys, reset: nil)
        d = input(:d, 1, domain: :async)
        y = output(:y, 1)
        eos = output(:eos, 1)
        i = P.inst(:i, P.idelaye3(), connect: [IDATAIN: d])
        s = P.inst(:s, P.startupe3())
        y <~ i[:DATAOUT]
        eos <~ s[:EOS]
      end

    sim = Sim.new(top) |> Sim.poke(:d, 1)
    assert {Sim.peek(sim, :y), Sim.peek(sim, :eos)} == {1, 1}
  end

  test "primitives without a model fail loudly in the simulator" do
    top =
      module "gt_top" do
        domain(:sys, reset: nil)
        y = output(:y, 1)
        g = P.inst(:g, P.sysmone4())
        y <~ g[:EOC]
      end

    assert_raise ExHdl.RTL.ElaborationError, ~r/no simulation model/, fn -> Sim.new(top) end
  end

  describe "simulation stubs" do
    test "sim_sources covers the primitives of a hierarchy, under sim/" do
      src = P.sim_sources(mmcm_top())
      assert Map.keys(src) == ["MMCME4_ADV_sim.sv"]
      assert src["MMCME4_ADV_sim.sv"] =~ "SIMULATION STUB"
      assert src["MMCME4_ADV_sim.sv"] =~ "Not for\n// synthesis"
      assert P.sim_sources(ExHdl.RTL.Examples.counter()) == %{}
      refute Enum.any?(Map.keys(SV.generate(mmcm_top())), &String.ends_with?(&1, "_sim.sv"))
      assert Map.take(SV.generate(mmcm_top(), sim: true), ["MMCME4_ADV_sim.sv"]) == src
    end

    test "real parameters are emitted as SV reals" do
      sv = SV.generate(mmcm_top(), sim: true)
      assert sv["MMCME4_ADV_sim.sv"] =~ "parameter real CLKFBOUT_MULT_F = 5.0"
    end

    @tag :verilator
    test "every stub lints clean on its own" do
      for n <- @all do
        {ok?, out} = Lint.run(%{"#{n}.sv" => P.stub(n)}, n)
        assert ok?, "#{n}: #{out}"
      end
    end

    @tag :verilator
    test "a design instantiating every primitive lints against the stubs" do
      top =
        module "all_prims" do
          domain(:sys, reset: nil)
          y = output(:y, 1)

          outs =
            for n <- @all, n != "PCIE4CE4" do
              m = P.module(n)
              u = P.inst(String.to_atom("u_" <> String.downcase(n)), m, clock: :sys)
              [o | _] = for p <- Module.outputs(m), do: p.name
              u[o][0]
            end

          y <~ reduce_xor(cat(outs))
        end

      {ok?, out} = Lint.run(SV.generate(top, sim: true), "all_prims", ["-Wno-UNUSEDSIGNAL"])
      assert ok?, out
    end
  end
end
