defmodule ExHdlXilinx.Vivado.Runner do
  @moduledoc """
  Stages a build and runs Vivado locally or on a remote host over ssh.

  Staging copies the sources into `<stage_dir>/src/`, writes generated sources
  (`build.generated`) there too, writes `build.tcl` and
  `constraints.xdc`, and creates `out/`. Local runs execute in the stage
  directory. Remote runs `rsync` the stage directory up (without `out/`), run
  Vivado through `ssh`, and `rsync` `out/` back, also when Vivado failed, so
  logs and reports are always local. Output is streamed line by line to
  the `:log` function and copied to `<stage_dir>/run.log`.

  Options:

    * `:stage_dir` - default `_build/ex_hdl_xilinx/<name>`
    * `:mode` - `:auto` (default: local if `vivado` is on PATH, else remote if a
      host is configured), `:local` or `:remote`
    * `:vivado` - executable for local runs, default `vivado`
    * `:remote` - `[host:, dir:, settings:, ssh_opts:, vivado:]`; defaults from
      `config :ex_hdl_xilinx, :remote` and the environment variables
      `EX_HDL_XILINX_HOST`, `EX_HDL_XILINX_DIR`, `EX_HDL_XILINX_SETTINGS`
    * `:log` - one-argument function for output, default `IO.write/1`
    * `:exec` - `fn step, log -> exit_status end`, replaces process spawning

  `plan/2` returns the steps without running anything.

      iex> b = ExHdlXilinx.Vivado.Build.new(name: "d", top: "t", part: "p", sources: ["a.sv"])
      iex> {:ok, steps} = ExHdlXilinx.Vivado.Runner.plan(b, mode: :remote, stage_dir: "/tmp/s",
      ...>   remote: [host: "build1", dir: "/work/d", settings: "/opt/Vivado/settings64.sh"])
      iex> Enum.map(steps, & &1.kind)
      [:rsync_up, :run, :rsync_down]
  """

  alias ExHdlXilinx.Report
  alias ExHdlXilinx.Vivado.{Build, Tcl}

  defmodule Result do
    @moduledoc "Outcome of a run: `status` is the Vivado exit status, `reports` the parsed files."
    defstruct [:mode, :status, :stage_dir, :out_dir, steps: [], reports: %{}]
    @type t :: %__MODULE__{}
  end

  @type step :: %{
          kind: :rsync_up | :run | :rsync_down,
          cmd: String.t(),
          args: [String.t()],
          cd: String.t() | nil
        }

  @doc "Stage `build` into `dir` and return the build with staged relative paths."
  @spec stage(Build.t(), Path.t()) :: Build.t()
  def stage(%Build{} = build, dir) do
    Build.validate!(build)
    File.mkdir_p!(Path.join(dir, "src"))
    File.mkdir_p!(Path.join(dir, build.out_dir))

    {sources, _} =
      Enum.map_reduce(build.sources, MapSet.new(), fn src, used ->
        base = unique(Path.basename(src), used)
        File.cp!(src, Path.join([dir, "src", base]))
        {"src/" <> base, MapSet.put(used, base)}
      end)

    for {name, text} <- build.generated, do: File.write!(Path.join([dir, "src", name]), text)

    xdc =
      for {f, i} <- Enum.with_index(build.xdc) do
        name = "#{i}_#{Path.basename(f)}"
        File.cp!(f, Path.join([dir, "src", name]))
        "src/" <> name
      end

    if build.xdc_text, do: File.write!(Path.join(dir, "constraints.xdc"), build.xdc_text)
    staged = %{build | sources: sources, xdc: xdc}
    File.write!(Path.join(dir, "build.tcl"), Tcl.script(staged))
    staged
  end

  defp unique(base, used) do
    if base in used, do: unique("x_" <> base, used), else: base
  end

  @doc "Steps to run the build, without staging or executing them."
  @spec plan(Build.t(), keyword()) :: {:ok, [step()]} | {:error, term()}
  def plan(%Build{} = build, opts \\ []) do
    stage_dir = stage_dir(build, opts)
    remote = remote_config(opts)

    case mode(opts, remote) do
      :local ->
        exe = Keyword.get(opts, :vivado, System.find_executable("vivado") || "vivado")
        {:ok, [%{kind: :run, cmd: exe, args: vivado_args(build), cd: stage_dir}]}

      :remote ->
        remote_steps(build, stage_dir, remote)

      :none ->
        {:error, :no_vivado}
    end
  end

  defp mode(opts, remote) do
    case Keyword.get(opts, :mode, :auto) do
      :auto ->
        cond do
          System.find_executable(Keyword.get(opts, :vivado, "vivado")) -> :local
          remote[:host] -> :remote
          true -> :none
        end

      m ->
        m
    end
  end

  defp stage_dir(build, opts),
    do:
      Keyword.get_lazy(opts, :stage_dir, fn -> Path.join("_build/ex_hdl_xilinx", build.name) end)

  defp vivado_args(build),
    do:
      ~w(-mode batch -nojournal -notrace -log) ++
        ["#{build.out_dir}/vivado.log", "-source", "build.tcl"]

  defp remote_config(opts) do
    env = [
      host: System.get_env("EX_HDL_XILINX_HOST"),
      dir: System.get_env("EX_HDL_XILINX_DIR"),
      settings: System.get_env("EX_HDL_XILINX_SETTINGS")
    ]

    env
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Keyword.merge(Application.get_env(:ex_hdl_xilinx, :remote, []))
    |> Keyword.merge(Keyword.get(opts, :remote, []))
  end

  defp remote_steps(build, stage_dir, remote) do
    with {:ok, host} <- Keyword.fetch(remote, :host) |> or_error(:no_remote_host) do
      dir = Keyword.get(remote, :dir, "ex_hdl_xilinx/#{build.name}")
      ssh = Keyword.get(remote, :ssh_opts, [])
      vivado = Keyword.get(remote, :vivado, "vivado")
      rsh = ["-e", Enum.join(["ssh" | ssh], " ")]
      src = String.trim_trailing(stage_dir, "/") <> "/"

      settings =
        case remote[:settings] do
          nil -> ""
          s -> ". #{shell_quote(s)} && "
        end

      command =
        "mkdir -p #{shell_quote(dir)}/#{build.out_dir} && cd #{shell_quote(dir)} && " <>
          settings <>
          Enum.join([vivado | Enum.map(vivado_args(build), &shell_quote/1)], " ")

      {:ok,
       [
         %{
           kind: :rsync_up,
           cmd: "rsync",
           args:
             ["-az", "--delete", "--exclude", "/#{build.out_dir}/"] ++
               rsh ++ [src, "#{host}:#{dir}/"],
           cd: nil
         },
         %{kind: :run, cmd: "ssh", args: ssh ++ [host, command], cd: nil},
         %{
           kind: :rsync_down,
           cmd: "rsync",
           args:
             ["-az"] ++ rsh ++ ["#{host}:#{dir}/#{build.out_dir}/", "#{src}#{build.out_dir}/"],
           cd: nil
         }
       ]}
    end
  end

  defp or_error({:ok, v}, _), do: {:ok, v}
  defp or_error(:error, e), do: {:error, e}

  @doc "Single-quote a string for a POSIX shell."
  def shell_quote(s) do
    if s =~ ~r/\A[A-Za-z0-9_\/.:=@%+-]+\z/,
      do: s,
      else: "'" <> String.replace(s, "'", "'\\''") <> "'"
  end

  @doc "Stage and run. Returns the `Result` even when Vivado fails (see `status`)."
  @spec run(Build.t(), keyword()) :: {:ok, Result.t()} | {:error, term()}
  def run(%Build{} = build, opts \\ []) do
    stage_dir = stage_dir(build, opts)
    log = Keyword.get(opts, :log, &IO.write/1)
    exec = Keyword.get(opts, :exec, &spawn_step/2)

    with {:ok, steps} <- plan(build, opts) do
      staged = stage(build, stage_dir)
      log_file = File.open!(Path.join(stage_dir, "run.log"), [:write])
      tee = fn line -> IO.write(log_file, line) && log.(line) end

      statuses = Enum.map(steps, fn s -> {s.kind, exec.(s, tee)} end)
      File.close(log_file)

      out_dir = Path.join(stage_dir, staged.out_dir)

      {:ok,
       %Result{
         mode: if(Enum.any?(steps, &(&1.kind == :rsync_up)), do: :remote, else: :local),
         status: statuses[:run],
         stage_dir: stage_dir,
         out_dir: out_dir,
         steps: steps,
         reports: Report.load(out_dir)
       }}
    end
  end

  defp spawn_step(%{cmd: cmd, args: args, cd: cd}, log) do
    exe = System.find_executable(cmd) || cmd
    port_opts = [:binary, :exit_status, :stderr_to_stdout, {:line, 8192}, {:args, args}]
    port_opts = if cd, do: [{:cd, cd} | port_opts], else: port_opts

    try do
      port = Port.open({:spawn_executable, exe}, port_opts)
      stream(port, log)
    rescue
      e in ErlangError ->
        log.("cannot start #{cmd}: #{inspect(e.original)}\n")
        127
    end
  end

  defp stream(port, log, partial \\ "") do
    receive do
      {^port, {:data, {:eol, line}}} ->
        log.(partial <> line <> "\n")
        stream(port, log)

      {^port, {:data, {:noeol, part}}} ->
        stream(port, log, partial <> part)

      {^port, {:exit_status, status}} ->
        status
    end
  end
end
