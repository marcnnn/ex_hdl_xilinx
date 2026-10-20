defmodule Mix.Tasks.ExHdlXilinx.Build do
  @shortdoc "Run the Vivado flow for a build-spec module"

  @moduledoc """
  Runs the non-project Vivado flow for a module that implements
  `ExHdlXilinx.Vivado.Build` (`build/0` returns the spec).

      mix ex_hdl_xilinx.build MyApp.Build
      mix ex_hdl_xilinx.build MyApp.Build --remote build1 --remote-dir /work/aes67
      mix ex_hdl_xilinx.build MyApp.Build --tcl-only

  Runs locally when `vivado` is in PATH, otherwise over ssh to the host from
  `--remote`, `config :ex_hdl_xilinx, :remote` or `EX_HDL_XILINX_HOST`.

  Options:

    * `--remote HOST`, `--remote-dir DIR`, `--settings FILE` - remote run
      (`--settings` is the `settings64.sh` to source there)
    * `--local` / `--ssh` - force the mode
    * `--vivado PATH` - local executable
    * `--stage-dir DIR` - default `_build/ex_hdl_xilinx/<name>`
    * `--tcl-only` - stage and write the script, run nothing
    * `--dry-run` - print the commands, run nothing

  Exits with an error when Vivado fails, the log has errors or timing is
  not met.
  """
  use Mix.Task

  alias ExHdlXilinx.Vivado.{Runner, Tcl}

  @switches [
    remote: :string,
    remote_dir: :string,
    settings: :string,
    local: :boolean,
    ssh: :boolean,
    vivado: :string,
    stage_dir: :string,
    tcl_only: :boolean,
    dry_run: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    {opts, rest} = OptionParser.parse!(args, strict: @switches)
    mod = module(rest)
    Mix.Task.run("compile")

    unless Code.ensure_loaded?(mod), do: Mix.raise("cannot load #{inspect(mod)}")
    build = mod.build()

    run_opts = run_opts(opts)

    cond do
      opts[:tcl_only] ->
        dir = Keyword.get(run_opts, :stage_dir, Path.join("_build/ex_hdl_xilinx", build.name))
        staged = Runner.stage(build, dir)
        Mix.shell().info("staged #{dir}/build.tcl (#{length(staged.sources)} sources)")
        Mix.shell().info(Tcl.script(staged))

      opts[:dry_run] ->
        case Runner.plan(build, run_opts) do
          {:ok, steps} ->
            for s <- steps, do: Mix.shell().info(Enum.join([s.cmd | s.args], " "))

          {:error, e} ->
            Mix.raise(explain(e))
        end

      true ->
        execute(build, run_opts)
    end
  end

  defp module([name]), do: Module.concat([name])
  defp module(_), do: Mix.raise("usage: mix ex_hdl_xilinx.build BuildSpecModule [options]")

  defp run_opts(opts) do
    remote =
      Enum.reject(
        [host: opts[:remote], dir: opts[:remote_dir], settings: opts[:settings]],
        fn {_, v} -> is_nil(v) end
      )

    [
      remote: remote,
      stage_dir: opts[:stage_dir],
      vivado: opts[:vivado],
      mode:
        cond do
          opts[:local] -> :local
          opts[:ssh] || opts[:remote] -> :remote
          true -> :auto
        end
    ]
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
  end

  defp execute(build, run_opts) do
    case Runner.run(build, run_opts) do
      {:error, e} ->
        Mix.raise(explain(e))

      {:ok, r} ->
        report(r)
        problems = problems(r)
        if problems != [], do: Mix.raise("build failed: " <> Enum.join(problems, "; "))
        Mix.shell().info("build ok, output in #{r.out_dir}")
    end
  end

  defp problems(r) do
    log = r.reports[:log]
    timing = r.reports[:timing]

    [
      r.status != 0 && "vivado exit status #{r.status}",
      log && not log.ok? && "#{length(log.errors)} errors in the log",
      timing && timing.met? == false && "timing not met (WNS #{timing.wns} ns)"
    ]
    |> Enum.filter(& &1)
  end

  defp report(r) do
    if t = r.reports[:timing],
      do: Mix.shell().info("timing: WNS #{t.wns} TNS #{t.tns} WHS #{t.whs} THS #{t.ths}")

    if u = r.reports[:utilization] do
      for k <- [:lut, :ff, :bram, :uram, :dsp, :gt], v = Map.get(u, k) do
        Mix.shell().info("#{k}: #{v.used} / #{v.available}")
      end
    end

    if l = r.reports[:log] do
      for e <- Enum.take(l.errors, 10), do: Mix.shell().error("#{e.id}: #{e.message}")
    end
  end

  defp explain(:no_vivado),
    do: "no vivado in PATH and no remote host (use --remote or EX_HDL_XILINX_HOST)"

  defp explain(:no_remote_host), do: "remote mode needs a host (--remote or EX_HDL_XILINX_HOST)"
  defp explain(e), do: inspect(e)
end
