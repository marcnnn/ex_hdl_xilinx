defmodule ExHdlXilinx.Test.VSim do
  @moduledoc false
  # Builds a SystemVerilog testbench with `verilator --binary --timing` against the
  # simulation sources of a design's primitives and returns the simulator output.

  def run(tb_file, sources, top \\ "tb", args \\ []) do
    dir = Path.join(System.tmp_dir!(), "vsim_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    paths =
      for {name, text} <- sources do
        path = Path.join(dir, name)
        File.write!(path, text)
        path
      end

    {out, status} =
      System.cmd(
        "verilator",
        ["--binary", "--timing", "-Wno-fatal", "-Wno-lint", "-Wno-style", "--top-module", top] ++
          args ++ ["-Mdir", Path.join(dir, "obj"), tb_file | Enum.sort(paths)],
        stderr_to_stdout: true
      )

    result =
      if status == 0 do
        {sim, _} = System.cmd(Path.join([dir, "obj", "V#{top}"]), [], stderr_to_stdout: true)
        {:ok, sim}
      else
        {:error, out}
      end

    File.rm_rf!(dir)
    result
  end
end
