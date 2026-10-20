defmodule ExHdlXilinx.Test.Lint do
  @moduledoc false
  # Writes a `%{name => text}` source map to a temp dir and runs
  # `verilator --lint-only -Wall`. Returns `{ok?, output}`.

  def run(files, top, args \\ []) do
    dir = Path.join(System.tmp_dir!(), "lint_#{System.unique_integer([:positive])}")

    paths =
      for {name, text} <- files do
        path = Path.join(dir, name)
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, text)
        path
      end

    {out, status} =
      System.cmd(
        "verilator",
        ["--lint-only", "-Wall", "--top-module", top] ++ args ++ Enum.sort(paths),
        stderr_to_stdout: true
      )

    File.rm_rf!(dir)
    {status == 0, out}
  end

  @doc "Warning lines of a lint output."
  def warnings(out), do: for(l <- String.split(out, "\n"), l =~ ~r/^%(Warning|Error)/, do: l)
end
