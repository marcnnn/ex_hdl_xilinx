defmodule ExHdlXilinx.RamTest do
  use ExUnit.Case, async: false
  use ExHdl.RTL

  alias ExHdl.RTL.{Cosim, Module, Sim}
  alias ExHdlXilinx.Primitives, as: P

  # A top that exposes every data port of one primitive, all on the clock `clk`.
  defp top(prim, params, name) do
    m = P.module(prim)

    module name do
      domain(:sys, reset: nil)

      u =
        P.inst(:u, m,
          clock: :sys,
          params: params,
          open: Enum.map(Module.data_inputs(m), & &1.name)
        )

      expose(u)
    end
  end

  defp tick(sim, inputs), do: sim |> Sim.poke(Map.new(inputs)) |> Sim.step()
  defp out(sim, names), do: for(n <- names, do: Sim.peek(sim, n))

  # -- RAMB36E2 --------------------------------------------------------------------------

  describe "RAMB36E2 model" do
    @describetag :shared_clock

    # DOUTADOUT `k` idle edges after a read of address 32 (a word written before)
    defp ramb_after_read(reg, k) do
      sim =
        top("RAMB36E2", [READ_WIDTH_A: 36, WRITE_WIDTH_A: 36, DOA_REG: reg], "ram_lat#{reg}")
        |> Sim.new()
        |> tick(ENARDEN: 1, WEA: 15, ADDRARDADDR: 32, DINADIN: 0xDEADBEEF, DINPADINP: 5)
        |> tick(WEA: 0, REGCEAREGCE: 1)

      sim = Enum.reduce(1..k//1, sim, fn _, s -> tick(s, ENARDEN: 0) end)
      out(sim, [:DOUTADOUT, :DOUTPADOUTP])
    end

    test "read latency is 1, or 2 with the output register" do
      # the read is issued at the second edge, so the data is there after it (latency 1)
      assert ramb_after_read(0, 0) == [0xDEADBEEF, 5]
      assert ramb_after_read(1, 0) == [0, 0]
      assert ramb_after_read(1, 1) == [0xDEADBEEF, 5]
    end

    test "REGCE low keeps the output register; RSTREG loads SRVAL, RSTRAM the latch" do
      p = [
        READ_WIDTH_A: 18,
        WRITE_WIDTH_A: 18,
        DOA_REG: 1,
        INIT_A: {:bits, 36, 0x12},
        SRVAL_A: {:bits, 36, 0x3_0000_0077}
      ]

      sim = top("RAMB36E2", p, "ram_rst") |> Sim.new()
      assert out(sim, [:DOUTADOUT, :DOUTPADOUTP]) == [0x12, 0]
      sim = tick(sim, ENARDEN: 1, WEA: 3, ADDRARDADDR: 16, DINADIN: 0xABCD, DINPADINP: 3)
      sim = tick(sim, WEA: 0, REGCEAREGCE: 0)
      sim = tick(sim, [])
      assert out(sim, [:DOUTADOUT]) == [0x12]
      sim = tick(sim, REGCEAREGCE: 1)
      assert out(sim, [:DOUTADOUT, :DOUTPADOUTP]) == [0xABCD, 3]
      # RSTREG beats REGCE by default
      sim = tick(sim, RSTREGARSTREG: 1)
      assert out(sim, [:DOUTADOUT, :DOUTPADOUTP]) == [0x77, 3]
      # RSTRAM resets the latch; the register still takes the old latch value at that edge
      # and the SRVAL one edge later
      sim = tick(sim, RSTREGARSTREG: 0, RSTRAMARSTRAM: 1)
      assert out(sim, [:DOUTADOUT]) == [0xABCD]
      sim = tick(sim, RSTRAMARSTRAM: 0)
      assert out(sim, [:DOUTADOUT, :DOUTPADOUTP]) == [0x77, 3]
    end

    test "write modes decide the output of a write cycle" do
      for {mode, expect} <- [
            {"READ_FIRST", [0, 0x11]},
            {"WRITE_FIRST", [0x11, 0x22]},
            {"NO_CHANGE", [0, 0]}
          ] do
        sim =
          top(
            "RAMB36E2",
            [READ_WIDTH_A: 9, WRITE_WIDTH_A: 9, DOA_REG: 0, WRITE_MODE_A: mode],
            "ram_wm_#{mode}"
          )
          |> Sim.new()
          |> tick(ENARDEN: 1, WEA: 1, ADDRARDADDR: 8, DINADIN: 0x11)

        w1 = Sim.peek(sim, :DOUTADOUT)
        sim = tick(sim, DINADIN: 0x22)
        assert [w1, Sim.peek(sim, :DOUTADOUT)] == expect, mode
      end
    end

    test "byte write enables" do
      sim =
        top("RAMB36E2", [READ_WIDTH_A: 36, WRITE_WIDTH_A: 36, DOA_REG: 0], "ram_be")
        |> Sim.new()
        |> tick(ENARDEN: 1, WEA: 15, ADDRARDADDR: 0, DINADIN: 0x11223344, DINPADINP: 0)
        |> tick(WEA: 0b0101, DINADIN: 0xAABBCCDD, DINPADINP: 0b1111)
        |> tick(WEA: 0)

      assert out(sim, [:DOUTADOUT, :DOUTPADOUTP]) == [0x11BB33DD, 0b0101]
    end

    test "mixed widths address the same cells; parity is its own array" do
      sim =
        top(
          "RAMB36E2",
          [READ_WIDTH_B: 9, WRITE_WIDTH_A: 36, DOB_REG: 0],
          "ram_mixed"
        )
        |> Sim.new()
        |> tick(ENARDEN: 1, WEA: 15, ADDRARDADDR: 0, DINADIN: 0xAABBCCDD, DINPADINP: 0b1010)

      bytes =
        for k <- 0..3 do
          s = tick(sim, ENARDEN: 0, WEA: 0, ENBWREN: 1, ADDRBWRADDR: Bitwise.bsl(k, 3))
          out(s, [:DOUTBDOUT, :DOUTPBDOUTP])
        end

      assert bytes == [[0xDD, 0], [0xCC, 1], [0xBB, 0], [0xAA, 1]]

      bits =
        for k <- 0..7 do
          s = top("RAMB36E2", [READ_WIDTH_B: 1, WRITE_WIDTH_A: 36, DOB_REG: 0], "ram_bits")
          s = s |> Sim.new() |> tick(ENARDEN: 1, WEA: 15, DINADIN: 0xA5)
          s = tick(s, ENARDEN: 0, WEA: 0, ENBWREN: 1, ADDRBWRADDR: k)
          Sim.peek(s, :DOUTBDOUT)
        end

      assert bits == [1, 0, 1, 0, 0, 1, 0, 1]
    end

    test "simple dual port, 72 bits: write on B, read on A with the upper half on the B pins" do
      sim =
        top(
          "RAMB36E2",
          [READ_WIDTH_A: 72, WRITE_WIDTH_B: 72, DOA_REG: 0],
          "ram_sdp"
        )
        |> Sim.new()
        |> tick(
          ENBWREN: 1,
          WEBWE: 0xFF,
          ADDRBWRADDR: 64,
          DINADIN: 0x01234567,
          DINBDIN: 0x89ABCDEF,
          DINPADINP: 0x5,
          DINPBDINP: 0xA
        )
        |> tick(ENBWREN: 0, WEBWE: 0, ENARDEN: 1, ADDRARDADDR: 64)

      assert out(sim, [:DOUTADOUT, :DOUTBDOUT, :DOUTPADOUTP, :DOUTPBDOUTP]) ==
               [0x01234567, 0x89ABCDEF, 0x5, 0xA]
    end

    test "RAMB18E2: 18 bit write, 4 bit read, registered" do
      sim =
        top(
          "RAMB18E2",
          [READ_WIDTH_B: 4, WRITE_WIDTH_A: 18, DOB_REG: 1],
          "ram18"
        )
        |> Sim.new()
        |> tick(ENARDEN: 1, WEA: 3, ADDRARDADDR: 16, DINADIN: 0x4321, DINPADINP: 0)

      nibbles =
        for k <- 0..3 do
          s = tick(sim, ENARDEN: 0, WEA: 0, ENBWREN: 1, ADDRBWRADDR: 16 + 4 * k)
          s = tick(s, REGCEB: 1)
          Sim.peek(s, :DOUTBDOUT)
        end

      assert nibbles == [1, 2, 3, 4]
    end

    test "an invalid width is rejected" do
      assert_raise ArgumentError, ~r/READ_WIDTH_A 5 is not a valid width/, fn ->
        top("RAMB18E2", [READ_WIDTH_A: 5], "ram_bad") |> Sim.new()
      end

      assert_raise ArgumentError, ~r/READ_WIDTH_A 72/, fn ->
        top("RAMB18E2", [READ_WIDTH_A: 72], "ram_bad2") |> Sim.new()
      end
    end
  end

  # -- URAM288 ---------------------------------------------------------------------------

  describe "URAM288_BASE model" do
    @describetag :shared_clock

    defp uram(params \\ [], name \\ "uram_t", prim \\ "URAM288_BASE"),
      do: top(prim, params, name) |> Sim.new() |> tick(OREG_CE_A: 1, OREG_CE_B: 1)

    defp write(sim, port, addr, data, bwe \\ 0x1FF),
      do:
        tick(sim, %{
          :"EN_#{other(port)}" => 0,
          :"EN_#{port}" => 1,
          :"RDB_WR_#{port}" => 1,
          :"ADDR_#{port}" => addr,
          :"DIN_#{port}" => data,
          :"BWE_#{port}" => bwe
        })

    defp read(sim, port, addr),
      do:
        tick(sim, %{
          :"EN_#{other(port)}" => 0,
          :"EN_#{port}" => 1,
          :"RDB_WR_#{port}" => 0,
          :"ADDR_#{port}" => addr
        })

    defp other(:A), do: :B
    defp other(:B), do: :A

    defp idle(sim, port), do: tick(sim, %{:"EN_#{port}" => 0})

    @word 0x123456789ABCDEF012

    # DOUT_A `k` idle edges after the edge that issues a read
    defp uram_after_read(params, k) do
      sim =
        uram(params, "uram_lat") |> write(:A, 7, @word) |> idle(:A) |> read(:A, 7)

      sim = Enum.reduce(1..k//1, sim, fn _, s -> idle(s, :A) end)
      Sim.peek(sim, :DOUT_A)
    end

    test "read latency is 1, 2 with OREG, 3 with IREG_PRE as well" do
      assert uram_after_read([], 0) == @word
      assert uram_after_read([OREG_A: "TRUE"], 0) == 0
      assert uram_after_read([OREG_A: "TRUE"], 1) == @word
      assert uram_after_read([OREG_A: "TRUE", IREG_PRE_A: "TRUE"], 1) == 0
      assert uram_after_read([OREG_A: "TRUE", IREG_PRE_A: "TRUE"], 2) == @word
      assert uram_after_read([IREG_PRE_A: "TRUE"], 0) == 0
      assert uram_after_read([IREG_PRE_A: "TRUE"], 1) == @word
    end

    test "byte enables and the two ports" do
      sim =
        uram()
        |> write(:A, 5, 0x1111111111111111, 0x1FF)
        |> write(:B, 5, 0xFFFFFFFFFFFFFFFFFF, 0b000000101)
        |> read(:B, 5)

      assert Sim.peek(sim, :DOUT_B) == 0x1111111111FF11FF
      sim = read(sim, :A, 5)
      assert Sim.peek(sim, :DOUT_A) == 0x1111111111FF11FF
    end

    test "DOUT holds during a write, RST clears the output, both ports read before writing" do
      sim = uram() |> write(:A, 1, 0xAA) |> read(:A, 1)
      assert Sim.peek(sim, :DOUT_A) == 0xAA
      sim = write(sim, :A, 1, 0xBB)
      assert Sim.peek(sim, :DOUT_A) == 0xAA
      sim = tick(sim, %{EN_A: 0, RST_A: 1}) |> tick(%{RST_A: 0})
      assert Sim.peek(sim, :DOUT_A) == 0

      # same edge: A writes address 3, B reads it: B sees the old word
      sim = uram() |> write(:A, 3, 0x11)

      sim =
        tick(sim, %{
          EN_A: 1,
          RDB_WR_A: 1,
          ADDR_A: 3,
          DIN_A: 0x22,
          BWE_A: 0x1FF,
          EN_B: 1,
          RDB_WR_B: 0,
          ADDR_B: 3
        })

      assert Sim.peek(sim, :DOUT_B) == 0x11
    end

    test "URAM288 adds RDACCESS: high for the cycle after a read" do
      sim = uram([], "uram_full", "URAM288") |> write(:A, 2, 5)
      assert Sim.peek(sim, :RDACCESS_A) == 0
      sim = read(sim, :A, 2)
      assert Sim.peek(sim, :RDACCESS_A) == 1
      sim = idle(sim, :A)
      assert Sim.peek(sim, :RDACCESS_A) == 0
    end
  end

  # -- BEAM against Verilator ------------------------------------------------------------

  describe "Verilator against the BEAM model" do
    @describetag :verilator
    @describetag :shared_clock
    @describetag timeout: 600_000

    # random events; the two ports of a block RAM never touch the same cell in an
    # event when one of them writes (the device leaves that undefined)
    defp ramb_stimulus(m, n, seed) do
      :rand.seed(:exsss, {seed, seed, seed})
      r = fn k -> :rand.uniform(k) - 1 end
      names = for p <- Module.data_inputs(m), do: p
      zero = Map.new(names, &{&1.name, 0})

      for _ <- 1..n do
        who = Enum.random([:a, :b, :a, :b, :both_read])

        ev = %{
          ENARDEN: if(who in [:a, :both_read], do: r.(4) |> min(1), else: 0),
          ENBWREN: if(who in [:b, :both_read], do: r.(4) |> min(1), else: 0),
          ADDRARDADDR: r.(Bitwise.bsl(1, 6)) * 8,
          ADDRBWRADDR: r.(Bitwise.bsl(1, 6)) * 8,
          WEA: if(who == :a, do: r.(16), else: 0),
          WEBWE: if(who == :b, do: r.(256), else: 0),
          DINADIN: r.(Bitwise.bsl(1, 32)),
          DINBDIN: r.(Bitwise.bsl(1, 32)),
          DINPADINP: r.(16),
          DINPBDINP: r.(16),
          REGCEAREGCE: r.(2),
          REGCEB: r.(2),
          RSTRAMARSTRAM: if(r.(12) == 0, do: 1, else: 0),
          RSTRAMB: if(r.(12) == 0, do: 1, else: 0),
          RSTREGARSTREG: if(r.(12) == 0, do: 1, else: 0),
          RSTREGB: if(r.(12) == 0, do: 1, else: 0)
        }

        width = Map.new(names, &{&1.name, elem(&1.type, 1)})

        ev
        |> Map.take(Enum.map(names, & &1.name))
        |> Map.new(fn {k, v} -> {k, Bitwise.band(v, Bitwise.bsl(1, width[k]) - 1)} end)
        |> then(&Map.merge(zero, &1))
      end
    end

    for {name, prim, params} <- [
          {"eq_tdp36", "RAMB36E2",
           [
             READ_WIDTH_A: 36,
             WRITE_WIDTH_A: 36,
             READ_WIDTH_B: 9,
             WRITE_WIDTH_B: 9,
             DOA_REG: 1,
             DOB_REG: 0,
             WRITE_MODE_A: "WRITE_FIRST",
             WRITE_MODE_B: "READ_FIRST",
             INIT_A: {:bits, 36, 0x5_0000_0001},
             SRVAL_A: {:bits, 36, 0xA_0000_0002}
           ]},
          {"eq_tdp36_narrow", "RAMB36E2",
           [
             READ_WIDTH_A: 4,
             WRITE_WIDTH_A: 4,
             READ_WIDTH_B: 18,
             WRITE_WIDTH_B: 18,
             DOA_REG: 0,
             DOB_REG: 1,
             WRITE_MODE_B: "NO_CHANGE",
             RSTREG_PRIORITY_B: "REGCE"
           ]},
          {"eq_sdp36", "RAMB36E2",
           [READ_WIDTH_A: 72, WRITE_WIDTH_B: 72, DOA_REG: 1, SRVAL_B: {:bits, 36, 0x7}]},
          {"eq_tdp18", "RAMB18E2",
           [
             READ_WIDTH_A: 18,
             WRITE_WIDTH_A: 18,
             READ_WIDTH_B: 2,
             WRITE_WIDTH_B: 2,
             DOA_REG: 1,
             DOB_REG: 1,
             WRITE_MODE_A: "READ_FIRST",
             WRITE_MODE_B: "WRITE_FIRST"
           ]},
          {"eq_sdp18", "RAMB18E2", [READ_WIDTH_A: 36, WRITE_WIDTH_B: 36, DOA_REG: 0]}
        ] do
      test "#{prim} #{name}: random stimulus gives the same outputs" do
        top = top(unquote(prim), unquote(Macro.escape(params)), unquote(name))
        stim = ramb_stimulus(top, 400, 7)
        assert :ok = Cosim.compare(top, stim)
        # the stimulus reaches the outputs, so the comparison is not vacuous
        {_, outs} = Sim.run(Sim.new(top), stim)
        assert Enum.count(outs, fn o -> o[:DOUTADOUT] != 0 or o[:DOUTBDOUT] != 0 end) > 20
      end
    end

    defp uram_stimulus(n, seed) do
      :rand.seed(:exsss, {seed, seed, seed})
      r = fn k -> :rand.uniform(k) - 1 end

      for _ <- 1..n do
        a_write = r.(2)

        %{
          EN_A: min(r.(4), 1),
          EN_B: min(r.(4), 1),
          RDB_WR_A: a_write,
          RDB_WR_B: 1 - a_write,
          ADDR_A: r.(8),
          ADDR_B: r.(8) + 8,
          BWE_A: r.(512),
          BWE_B: r.(512),
          DIN_A: r.(Bitwise.bsl(1, 72)),
          DIN_B: r.(Bitwise.bsl(1, 72)),
          OREG_CE_A: r.(2),
          OREG_CE_B: r.(2),
          RST_A: if(r.(15) == 0, do: 1, else: 0),
          RST_B: if(r.(15) == 0, do: 1, else: 0)
        }
      end
    end

    for {name, prim, params} <- [
          {"eq_uram_plain", "URAM288_BASE", []},
          {"eq_uram_regs", "URAM288_BASE",
           [OREG_A: "TRUE", IREG_PRE_B: "TRUE", OREG_B: "TRUE", IREG_PRE_A: "TRUE"]},
          {"eq_uram_full", "URAM288", [OREG_B: "TRUE"]}
        ] do
      test "#{prim} #{name}: random stimulus gives the same outputs" do
        top = top(unquote(prim), unquote(Macro.escape(params)), unquote(name))
        full = Module.data_inputs(P.module(unquote(prim)))
        zero = Map.new(full, &{&1.name, 0})
        stim = for ev <- uram_stimulus(400, 11), do: Map.merge(zero, ev)
        assert :ok = Cosim.compare(top, stim)
        {_, outs} = Sim.run(Sim.new(top), stim)
        assert Enum.count(outs, fn o -> o[:DOUT_A] != 0 or o[:DOUT_B] != 0 end) > 20
      end
    end
  end
end
