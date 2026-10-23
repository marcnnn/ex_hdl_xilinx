defmodule ExHdlXilinx.GoldenTest do
  # Golden text for the hello card build: the Tcl script and the XDC that
  # `ExHdlXilinx.Hello.build/0` produces from the AS02MC04 board data. A
  # change in either is a change in what Vivado sees, so it has to show up
  # in review. Regenerate with `GOLDEN=update mix test test/golden_test.exs`.
  use ExUnit.Case, async: true

  alias ExHdlXilinx.{Hello, XDC}
  alias ExHdlXilinx.Vivado.Tcl

  @dir Path.expand("fixtures/golden", __DIR__)

  defp golden(name, text) do
    path = Path.join(@dir, name)

    if System.get_env("GOLDEN") == "update" do
      File.write!(path, text)
    else
      assert File.exists?(path), "missing #{path}; run with GOLDEN=update"
      assert text == File.read!(path), "#{name} differs from the golden file"
    end
  end

  test "hello build.tcl" do
    golden("hello_build.tcl", Tcl.script(Hello.build()))
  end

  test "hello constraints.xdc" do
    golden("hello_constraints.xdc", Hello.build().xdc_text)
  end

  test "XDC for every board signal, unverified pins flagged" do
    b = ExHdlXilinx.Boards.AS02MC04.board()
    xdc = XDC.generate!(b, Enum.map(b.pins, & &1.name))

    for name <- ExHdlXilinx.Board.unverified(b),
        do: assert(xdc =~ "# unverified: #{name} ", "#{name} not flagged")

    golden("as02mc04_all.xdc", xdc)
  end
end
