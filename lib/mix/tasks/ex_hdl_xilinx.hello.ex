defmodule Mix.Tasks.ExHdlXilinx.Hello do
  @shortdoc "Write the hello-card build directory (SV, XDC, Tcl)"

  @moduledoc """
  Writes the build directory of `ExHdlXilinx.Hello` for the AS02MC04.

      mix ex_hdl_xilinx.hello                    # _build/ex_hdl_xilinx/hello_card
      mix ex_hdl_xilinx.hello --dir /tmp/hello --blink-bit 24 --speed-grade -2

  The directory holds `src/`, `constraints.xdc`, `build.tcl` and `sim/`
  (lint stubs). To build it, run `mix ex_hdl_xilinx.build ExHdlXilinx.Hello.Spec`
  with `--remote`; see the README.
  """
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, []} =
      OptionParser.parse!(args,
        strict: [dir: :string, blink_bit: :integer, speed_grade: :string]
      )

    Mix.Task.run("compile")
    dir = Keyword.get(opts, :dir, "_build/ex_hdl_xilinx/hello_card")
    files = ExHdlXilinx.Hello.write(dir, Keyword.take(opts, [:blink_bit, :speed_grade]))
    for f <- files, do: Mix.shell().info(f)
  end
end
