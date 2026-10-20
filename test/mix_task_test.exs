defmodule Mix.Tasks.ExHdlXilinx.BuildTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.ExHdlXilinx.Build, as: Task

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    dir = Path.join(System.tmp_dir!(), "mt_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  test "dry run prints the remote commands" do
    Task.run(["ExHdlXilinx.Test.DemoBuild", "--dry-run", "--remote", "h1", "--remote-dir", "/w"])
    assert_received {:mix_shell, :info, ["rsync " <> _]}
    assert_received {:mix_shell, :info, ["ssh h1 " <> _]}
  end

  test "tcl-only stages and prints the script", %{dir: dir} do
    Task.run(["ExHdlXilinx.Test.DemoBuild", "--tcl-only", "--stage-dir", dir])
    assert File.regular?(Path.join(dir, "build.tcl"))
    assert_received {:mix_shell, :info, ["staged " <> _]}
    assert_received {:mix_shell, :info, [tcl]}
    assert tcl =~ "synth_design"
  end

  test "usage and unknown module" do
    assert_raise Mix.Error, ~r/usage/, fn -> Task.run([]) end
    assert_raise Mix.Error, ~r/cannot load/, fn -> Task.run(["No.Such.Module"]) end
  end

  test "full run with a failing fake vivado raises", %{dir: dir} do
    File.mkdir_p!(dir)
    fake = Path.join(dir, "vivado")

    File.write!(
      fake,
      "#!/bin/sh\nmkdir -p out\ncp #{Path.expand("fixtures/vivado.log", __DIR__)} out/vivado.log\nexit 1\n"
    )

    File.chmod!(fake, 0o755)

    capture_io(fn ->
      assert_raise Mix.Error, ~r/exit status 1.*3 errors/, fn ->
        Task.run([
          "ExHdlXilinx.Test.DemoBuild",
          "--local",
          "--vivado",
          fake,
          "--stage-dir",
          Path.join(dir, "s")
        ])
      end
    end)

    assert_received {:mix_shell, :error, ["Synth 8-439: module 'fifo_sync' not found"]}
  end
end
