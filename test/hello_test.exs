defmodule ExHdlXilinx.HelloTest do
  use ExUnit.Case, async: true
  use ExHdl.RTL

  alias ExHdl.Backends.SystemVerilog.RTL, as: SV
  alias ExHdl.RTL.{Module, Sim}
  alias ExHdlXilinx.Boards.AS02MC04
  alias ExHdlXilinx.Test.Lint
  alias ExHdlXilinx.Vivado.{Build, Runner, Tcl}
  alias ExHdlXilinx.{Hello, Primitives}

  setup do
    dir = Path.join(System.tmp_dir!(), "hello_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  test "top-level ports are the board's names" do
    top = Hello.top(blink_bit: 3)

    assert Enum.map(top.ports, &{&1.name, &1.dir, elem(&1.type, 1)}) ==
             [{:clk100_p, :input, 1}, {:clk100_n, :input, 1}, {:led, :output, 4}]

    names = for m <- Module.hierarchy(top), m.kind == :black_box, do: m.name
    assert Enum.sort(names) == ["BUFG", "IBUFDS", "MMCME4_ADV"]
  end

  test "generated SV instantiates the clocking primitives" do
    sv = SV.generate(Hello.top(blink_bit: 3))["hello_card_b3.sv"]
    assert sv =~ "IBUFDS #("
    assert sv =~ ".DIFF_TERM(\"TRUE\")"
    assert sv =~ "MMCME4_ADV #("
    assert sv =~ ".CLKFBOUT_MULT_F(10)"
    assert sv =~ ".CLKOUT0_DIVIDE_F(4)"
    assert sv =~ ".CLKOUT1_DIVIDE(8)"
    assert sv =~ ".CLKIN1_PERIOD(10)"
    assert sv =~ "assign mmcm_CLKFBIN = mmcm_CLKFBOUT;"
    assert length(Regex.scan(~r/^  BUFG bufg_/m, sv)) == 3
    assert sv =~ "always_ff @(posedge clk_c250)"
    assert sv =~ "always_ff @(posedge clk_c125)"
    assert sv =~ "always_ff @(posedge clk_c100)"
  end

  @tag :verilator
  test "generated SV lints with the simulation stubs" do
    top = Hello.top(blink_bit: 3)
    files = Map.merge(SV.generate(top), Primitives.sim_sources(top))
    assert Map.keys(files) |> Enum.count(&String.starts_with?(&1, "sim/")) == 3

    # no warnings but unread instance output wires (exhdl does not wrap those; see NEEDS.md)
    {_, out} = Lint.run(files, "hello_card_b3")

    for w <- Lint.warnings(out), w =~ "%Warning" do
      assert w =~ ~r/UNUSEDSIGNAL: .*Signal is not used: '(mmcm|ibufds|bufg_\w+)_[A-Za-z0-9]+'/, w
    end

    assert {true, _} = Lint.run(files, "hello_card_b3", ["-Wno-UNUSEDSIGNAL"])
  end

  describe "BEAM simulation" do
    test "LEDs stay off until the MMCM locks, then heartbeat bits toggle" do
      sim = Hello.sim(blink_bit: 2)
      assert Sim.peek(sim, :led) == 0

      {leds, _} =
        Enum.map_reduce(1..400, sim, fn _, s ->
          s = Sim.step(s)
          {Sim.peek(s, :led), s}
        end)

      # nothing before lock (16 input cycles = 16 events of the 100 MHz clock)
      assert Enum.all?(Enum.take(leds, 20), &(&1 == 0))

      for bit <- 0..3 do
        values = leds |> Enum.map(&Bitwise.band(Bitwise.bsr(&1, bit), 1)) |> Enum.uniq()
        assert values == [0, 1] or values == [1], "led[#{bit}] values #{inspect(values)}"
      end

      # the three heartbeats toggle (not stuck), led[3] (locked) ends up high and stays
      for bit <- 0..2 do
        edges =
          leds
          |> Enum.map(&Bitwise.band(Bitwise.bsr(&1, bit), 1))
          |> Enum.chunk_every(2, 1, :discard)
          |> Enum.count(fn [a, b] -> a != b end)

        assert edges >= 4, "led[#{bit}] toggled #{edges} times"
      end

      assert leds |> Enum.drop(100) |> Enum.all?(&(Bitwise.band(Bitwise.bsr(&1, 3), 1) == 1))
    end

    test "the 250 MHz heartbeat runs at 2.5 times the 100 MHz one" do
      sim = Hello.sim(blink_bit: 3)
      {_, s} = Enum.map_reduce(1..200, sim, fn _, s -> {nil, Sim.step(s)} end)
      c100 = Sim.peek(s, "cnt_c100")
      c250 = Sim.peek(s, "cnt_c250")
      c125 = Sim.peek(s, "cnt_c125")
      assert {c100, c250, c125} != {0, 0, 0}
      assert_in_delta Sim.cycles(s, :c250) / Sim.cycles(s, :c100), 2.5, 0.02
      assert_in_delta Sim.cycles(s, :c125) / Sim.cycles(s, :c100), 1.25, 0.02
    end
  end

  describe "build directory" do
    test "XDC from the board data", %{dir: dir} do
      Hello.write(dir, blink_bit: 3)
      xdc = File.read!(Path.join(dir, "constraints.xdc"))
      assert xdc =~ "set_property -dict {PACKAGE_PIN E18 IOSTANDARD LVDS} [get_ports clk100_p]"
      assert xdc =~ "set_property -dict {PACKAGE_PIN D18 IOSTANDARD LVDS} [get_ports clk100_n]"

      assert xdc =~
               "set_property -dict {PACKAGE_PIN B11 IOSTANDARD LVCMOS33} [get_ports {led[0]}]"

      assert xdc =~
               "set_property -dict {PACKAGE_PIN B10 IOSTANDARD LVCMOS33} [get_ports {led[3]}]"

      assert xdc =~ "create_clock -name clk100 -period 10.000 [get_ports clk100_p]"
      assert xdc =~ "set_false_path -to [get_ports {led[0] led[1] led[2] led[3]}]"
      assert xdc =~ "set_property CFGBVS GND [current_design]"
    end

    test "Vivado Tcl", %{dir: dir} do
      Hello.write(dir, blink_bit: 3)
      tcl = File.read!(Path.join(dir, "build.tcl"))
      assert tcl =~ "set_part xcku3p-ffvb676-1-e"
      assert tcl =~ "read_verilog -sv {src/hello_card_b3.sv}"
      assert tcl =~ "read_verilog -sv {src/exhdl_cdc_reset_sync_s2.sv}"
      assert tcl =~ "read_xdc {constraints.xdc}"
      assert tcl =~ "synth_design -top hello_card_b3 -part xcku3p-ffvb676-1-e"
      assert tcl =~ "write_bitstream -force out/hello_card.bit"
      refute tcl =~ "sim/"
      refute tcl =~ "create_ip"
    end

    test "files: design under src/, stubs under sim/ only", %{dir: dir} do
      files = Hello.write(dir, blink_bit: 3) |> Enum.map(&Path.relative_to(&1, dir))
      assert "build.tcl" in files and "constraints.xdc" in files
      assert "src/hello_card_b3.sv" in files
      assert "sim/MMCME4_ADV.sv" in files
      refute Enum.any?(files, &(String.starts_with?(&1, "src/") and &1 =~ "MMCME4"))
      assert File.dir?(Path.join(dir, "out"))
    end

    test "mix task writes the directory", %{dir: dir} do
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
      Mix.Tasks.ExHdlXilinx.Hello.run(["--dir", dir, "--blink-bit", "5", "--speed-grade", "-2"])
      assert File.read!(Path.join(dir, "build.tcl")) =~ "xcku3p-ffvb676-2-e"
      assert File.regular?(Path.join(dir, "src/hello_card_b5.sv"))
      assert_received {:mix_shell, :info, [_]}
    end

    test "the spec module works with the build task's --tcl-only", %{dir: dir} do
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

      Mix.Tasks.ExHdlXilinx.Build.run([
        "ExHdlXilinx.Hello.Spec",
        "--tcl-only",
        "--stage-dir",
        dir
      ])

      assert File.regular?(Path.join(dir, "src/hello_card_b26.sv"))
    end
  end

  describe "Build with an ExHdl.RTL top" do
    defp spec(rtl, signals \\ Hello.signals(), opts \\ []) do
      Build.new([board: AS02MC04, signals: signals, rtl: rtl] ++ opts)
    end

    test "sources and top come from the generated SV" do
      b = Hello.build(blink_bit: 3)
      assert b.top == "hello_card_b3"

      assert Map.keys(b.generated) |> Enum.sort() == [
               "exhdl_cdc_reset_sync_s2.sv",
               "exhdl_cdc_sync_w1_s2.sv",
               "hello_card_b3.sv"
             ]

      assert b.sources == []
      assert Build.validate!(b) == b
      assert b.xdc_text =~ "led[0]"
      assert Tcl.script(b) =~ "read_verilog -sv {src/hello_card_b3.sv}"
    end

    test "a constrained port the top lacks is an error" do
      rtl =
        module("m1",
          do:
            (
              y = output(:led, 4)
              y <~ 0
            )
        )

      e = assert_raise ArgumentError, fn -> spec(rtl) end

      assert e.message =~
               "port clk100_p (board signal :clk100) is constrained but the top has no such port"

      assert e.message =~ "port clk100_n"
    end

    test "a top port without a constraint is an error unless listed" do
      rtl = Hello.top(blink_bit: 3)

      extra =
        module "m2" do
          a = input(:clk100_p, 1, domain: :async)
          b = input(:clk100_n, 1, domain: :async)
          s = input(:spare, 1, domain: :async)
          y = output(:led, 4)
          y <~ cat([a, b, s, a])
        end

      e = assert_raise ArgumentError, fn -> spec(extra) end
      assert e.message =~ "top port spare has no constraint"
      assert spec(extra, Hello.signals(), unconstrained: [:spare]).top == "m2"
      assert spec(rtl).top == "hello_card_b3"
    end

    test "width and direction mismatches are errors" do
      narrow =
        module "m3" do
          a = input(:clk100_p, 1, domain: :async)
          b = input(:clk100_n, 1, domain: :async)
          y = output(:led, 3)
          y <~ cat([a, b, a])
        end

      e = assert_raise ArgumentError, fn -> spec(narrow) end
      assert e.message =~ "port led is 3 bit(s) wide, board signal :led0 binds 4"

      flipped =
        module "m4" do
          a = input(:clk100_p, 1, domain: :async)
          b = output(:clk100_n, 1)
          y = input(:led, 4, domain: :async)
          b <~ a
          _ = y
        end

      e = assert_raise ArgumentError, fn -> spec(flipped) end
      assert e.message =~ "port clk100_n is an output but :clk100 is in"
      assert e.message =~ "port led is an input but :led0 is out"
    end

    test "unknown board signals are reported" do
      assert_raise ExHdlXilinx.XDC.Error, ~r/unknown board signal :nope/, fn ->
        spec(Hello.top(blink_bit: 3), [:nope])
      end
    end

    test "staging writes the generated files", %{dir: dir} do
      staged = Runner.stage(Hello.build(blink_bit: 3), dir)
      assert File.read!(Path.join(dir, "src/hello_card_b3.sv")) =~ "module hello_card_b3"
      assert staged.top == "hello_card_b3"
    end
  end
end
