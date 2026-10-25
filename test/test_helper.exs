# :verilator - co-simulation, needs verilator in PATH
# :shared_clock - needs exhdl branch ex/w5-xil (models with two domains on one clock)
exclude =
  if(System.find_executable("verilator"), do: [], else: [verilator: true]) ++
    if ExHdlXilinx.Test.Probe.shared_clock_models?(), do: [], else: [shared_clock: true]

ExUnit.start(exclude: exclude)
