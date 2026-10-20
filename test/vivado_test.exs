defmodule ExHdlXilinx.VivadoTest do
  use ExUnit.Case, async: true
  doctest ExHdlXilinx.Vivado.Build
  doctest ExHdlXilinx.Vivado.Tcl
  doctest ExHdlXilinx.Vivado.Runner
  doctest ExHdlXilinx.Device

  alias ExHdlXilinx.Device
  alias ExHdlXilinx.Vivado.{Build, Runner, Tcl}
  alias ExHdlXilinx.Test.DemoBuild

  setup do
    dir = Path.join(System.tmp_dir!(), "viv_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  describe "Build" do
    test "board derives part and constraints" do
      b = DemoBuild.build()
      assert b.part == "xcku3p-ffvb676-1-e"
      assert b.xdc_text =~ "create_clock -name clk100"
      assert Build.new(board: ExHdlXilinx.Boards.AS02MC04, speed_grade: "-2").part =~ "-2-e"
    end

    test "board errors propagate" do
      assert_raise ExHdlXilinx.XDC.Error, fn ->
        Build.new(board: ExHdlXilinx.Boards.AS02MC04, signals: [:nope])
      end
    end

    test "validate!" do
      assert_raise ArgumentError, ~r/top/, fn -> Build.validate!(%Build{name: "a", part: "p"}) end

      assert_raise ArgumentError, ~r/no sources/, fn ->
        Build.validate!(%Build{name: "a", top: "t", part: "p"})
      end
    end
  end

  describe "Tcl" do
    test "full flow in order" do
      tcl = DemoBuild.build() |> Tcl.script()

      order = [
        "set_part xcku3p-ffvb676-1-e",
        "read_verilog -sv",
        "read_xdc {constraints.xdc}",
        "synth_design -top top -part xcku3p-ffvb676-1-e",
        "write_checkpoint -force out/post_synth.dcp",
        "opt_design",
        "place_design",
        "phys_opt_design",
        "route_design",
        "report_timing_summary",
        "report_utilization -file out/utilization.rpt",
        "write_bitstream -force out/demo.bit",
        "write_cfgmem -force -format mcs -size 32 -interface SPIx4"
      ]

      idx = Enum.map(order, fn s -> {s, :binary.match(tcl, s)} end)
      assert Enum.all?(idx, fn {_, m} -> m != :nomatch end), inspect(idx)
      pos = for {_, {p, _}} <- idx, do: p
      assert pos == Enum.sort(pos)
      assert tcl =~ ~s|-loadbit "up 0x0 out/demo.bit" out/demo.mcs|
    end

    test "options" do
      b =
        Build.new(
          name: "n",
          top: "t",
          part: "p",
          sources: ["a.sv", "b.v", "c.vhd"],
          xdc: ["x.xdc"],
          generics: %{W: 8, A: 1},
          defines: %{SYNTH: 1},
          directives: [synth: "PerformanceOptimized", route: "Explore"],
          phys_opt: false,
          bitstream: false,
          timing_gate: :error,
          reports: [:power, :cdc]
        )

      tcl = Tcl.script(b)
      assert tcl =~ "read_verilog {b.v}"
      assert tcl =~ "read_vhdl -vhdl2008 {c.vhd}"
      assert tcl =~ "read_xdc {x.xdc}"

      assert tcl =~
               "-directive PerformanceOptimized -generic A=1 -generic W=8 -verilog_define SYNTH=1"

      assert tcl =~ "route_design -directive Explore"
      refute tcl =~ "phys_opt_design"
      refute tcl =~ "write_bitstream"
      refute tcl =~ "read_xdc {constraints.xdc}"
      assert tcl =~ ~s|error "timing not met|
      assert tcl =~ "report_power -file out/power.rpt"
      assert tcl =~ "report_cdc -details -file out/cdc.rpt"
      refute tcl =~ "report_utilization"
    end

    test "timing gate ignore and unsupported source" do
      b = Build.new(name: "n", top: "t", part: "p", sources: ["a.sv"], timing_gate: :ignore)
      refute Tcl.script(b) =~ "get_timing_paths"
      bad = %{b | sources: ["a.txt"]}
      assert_raise ArgumentError, ~r/unsupported/, fn -> Tcl.script(bad) end
    end
  end

  describe "Runner" do
    test "stage copies sources, resolving name clashes", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, "a"))
      File.mkdir_p!(Path.join(dir, "b"))
      for d <- ~w(a b), do: File.write!(Path.join([dir, d, "m.sv"]), "module m; endmodule")

      b = %{DemoBuild.build() | sources: [Path.join(dir, "a/m.sv"), Path.join(dir, "b/m.sv")]}
      stage = Path.join(dir, "stage")
      staged = Runner.stage(b, stage)
      assert staged.sources == ["src/m.sv", "src/x_m.sv"]
      assert File.regular?(Path.join(stage, "src/x_m.sv"))
      assert File.read!(Path.join(stage, "build.tcl")) =~ "read_verilog -sv {src/x_m.sv}"
      assert File.read!(Path.join(stage, "constraints.xdc")) =~ "PACKAGE_PIN E18"
      assert File.dir?(Path.join(stage, "out"))
    end

    test "remote plan" do
      {:ok, [up, run, down]} =
        Runner.plan(DemoBuild.build(),
          mode: :remote,
          stage_dir: "/tmp/stage",
          remote: [
            host: "build1",
            dir: "/work/my demo",
            settings: "/opt/Xilinx/Vivado/2023.2/settings64.sh",
            ssh_opts: ["-p", "2222"]
          ]
        )

      assert up.cmd == "rsync"

      assert up.args ==
               ~w(-az --delete --exclude /out/ -e) ++
                 ["ssh -p 2222", "/tmp/stage/", "build1:/work/my demo/"]

      assert run.cmd == "ssh"
      assert Enum.take(run.args, 3) == ["-p", "2222", "build1"]
      cmd = List.last(run.args)

      assert cmd =~
               "cd '/work/my demo' && . /opt/Xilinx/Vivado/2023.2/settings64.sh && vivado -mode batch"

      assert cmd =~ "-source build.tcl"
      assert down.args |> Enum.take(-2) == ["build1:/work/my demo/out/", "/tmp/stage/out/"]
    end

    test "no vivado and no host" do
      assert Runner.plan(DemoBuild.build(), mode: :auto, vivado: "no-such-vivado-xyz", remote: []) ==
               {:error, :no_vivado}
    end

    test "auto picks remote when a host is given and vivado is missing" do
      {:ok, steps} =
        Runner.plan(DemoBuild.build(), vivado: "no-such-vivado-xyz", remote: [host: "h"])

      assert Enum.map(steps, & &1.kind) == [:rsync_up, :run, :rsync_down]
    end

    test "remote run with an injected executor still fetches results after a failure", %{dir: dir} do
      test = self()

      exec = fn step, log ->
        send(test, {:step, step.kind})
        log.("output of #{step.kind}\n")
        if step.kind == :run, do: 3, else: 0
      end

      {:ok, r} =
        Runner.run(DemoBuild.build(),
          mode: :remote,
          remote: [host: "h", dir: "d"],
          stage_dir: Path.join(dir, "s"),
          exec: exec,
          log: fn l -> send(test, {:log, l}) end
        )

      assert_received {:step, :rsync_up}
      assert_received {:step, :run}
      assert_received {:step, :rsync_down}
      assert_received {:log, "output of run\n"}
      assert r.status == 3 and r.mode == :remote
      assert File.read!(Path.join(r.stage_dir, "run.log")) =~ "output of rsync_down"
    end

    test "local run streams output and parses reports", %{dir: dir} do
      fake = Path.join(dir, "vivado")
      fx = Path.expand("fixtures", __DIR__)

      File.write!(fake, """
      #!/bin/sh
      echo "args: $@"
      echo "INFO: [Common 17-83] Releasing license"
      cp #{fx}/timing_met.rpt out/timing_summary.rpt
      cp #{fx}/utilization.rpt out/utilization.rpt
      cp #{fx}/vivado.log out/vivado.log
      exit 0
      """)

      File.chmod!(fake, 0o755)
      test = self()

      {:ok, r} =
        Runner.run(DemoBuild.build(),
          mode: :local,
          vivado: fake,
          stage_dir: Path.join(dir, "s"),
          log: fn l -> send(test, {:log, l}) end
        )

      assert r.status == 0 and r.mode == :local

      assert_received {:log,
                       "args: -mode batch -nojournal -notrace -log out/vivado.log -source build.tcl\n"}

      assert_received {:log, "INFO: [Common 17-83] Releasing license\n"}
      assert r.reports.timing.met?
      assert r.reports.utilization.dsp.used == 128
      refute r.reports.log.ok?
    end

    test "a missing executable is a clean failure status", %{dir: dir} do
      {:ok, r} =
        Runner.run(DemoBuild.build(),
          mode: :local,
          vivado: Path.join(dir, "nope"),
          stage_dir: Path.join(dir, "s"),
          log: fn _ -> :ok end
        )

      assert r.status == 127
    end

    test "shell_quote" do
      assert Runner.shell_quote("a/b-c.sh") == "a/b-c.sh"
      assert Runner.shell_quote("it's here") == "'it'\\''s here'"
    end
  end

  describe "Device" do
    test "KU3P resources" do
      d = Device.get("xcku3p")

      assert %{clb_luts: 162_720, clb_ffs: 325_440, bram36: 360, uram288: 48, gty: 16} =
               d.resources

      assert d.resources.bram18 == 2 * d.resources.bram36
      assert d.resources.clb_luts == 8 * d.resources.clb_slices
      assert d.resources.clb_ffs == 2 * d.resources.clb_luts
      assert d.dsp.multiplier == {27, 18}
      assert d.uram.kbit * d.resources.uram288 == 13_824
      assert Device.get("nope") == nil
      assert d.sources != [] and d.verified? == false
    end

    test "speed grades" do
      d = Device.get("xcku3p")
      assert Device.delay(d, "-1", :lut_ns) > Device.delay(d, "-2", :lut_ns)
      assert d.fmax_mhz.dsp48e2_all_regs["-2"] > d.fmax_mhz.dsp48e2_all_regs["-1"]
    end

    test "timing options match the fields of ExHdl.Target.Timing" do
      opts = Device.timing_options(Device.get("xcku3p"), "-2", clock_mhz: 300)
      assert opts[:clock_mhz] == 300
      t = ExHdl.Target.Timing.new(opts)
      assert t.lut_ns == 0.10 and t.dsp_latency == 3
    end
  end
end
