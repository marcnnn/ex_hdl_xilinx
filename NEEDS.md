# Wishes for ../exhdl

Nothing here blocks the current deliverables; they are what the second wave
(primitives) and the target model will need.

## Black boxes (second wave)

- A way to declare a vendor primitive as a typed black box: port list with
  direction and width, parameters (string, integer, real, bit-vector literals)
  and attributes, emitted as an instantiation in SystemVerilog without a body.
  Needed for MMCME4_ADV, IBUFDS_GTE4, GTYE4_CHANNEL/COMMON, PCIE4C, BUFG_GT.
- Differential and bidirectional top-level ports (`clk_p`/`clk_n`, `inout`
  for I2C) with names the generated top module keeps verbatim, since XDC
  generation binds ports by name (`ExHdlXilinx.XDC` uses `<base>_p`/`_n` and
  `base[i]` for buses).
- Vector top-level ports with stable names (`led[3:0]`, `pcie_rx_p[7:0]`) and a
  query that lists the top module's ports, so a build spec can check that every
  port has a constraint and every constrained port exists.
- Generics/parameters on the top module that the Tcl flow can override
  (`synth_design -generic`).

## Target API

`ExHdl.Target.Timing` models Zynq-7000 only. `ExHdlXilinx.Device` provides data
for UltraScale+ (`ExHdlXilinx.Device.timing_options/3` returns a keyword list
for `Timing.new/1` with `lut_ns`, `carry_ns_per_bit`, `dsp_latency`,
`bram_latency` today). The target API should accept:

- a target as data, not a module of constants: `family`, `speed_grade`,
  `clock_mhz`, and these per-grade delays: `lut_ns`, `carry_ns_per_bit`,
  `ff_clk_to_q_ns`, `ff_setup_ns`, `net_typ_ns` (all present in
  `Device.delays`);
- primitive characteristics per kind: DSP multiplier size (`{27, 18}` for
  DSP48E2 against `{25, 18}` for DSP48E1), accumulator width, pre-adder,
  latency with all registers; block RAM kind (RAMB36, URAM288) with width,
  depth and output register latency; `Device.dsp`, `Device.bram`, `Device.uram`;
- Fmax limits per primitive and grade (`Device.fmax_mhz`), so the scheduler
  can warn when `clock_mhz` exceeds what a DSP or BRAM can do;
- URAM as a memory target next to BRAM and LUT ROM (the intercom matrix needs
  it), chosen by depth and width thresholds;
- a resource budget (`Device.resources`) that `mix ex_hdl.gen.sv` style
  estimates can be compared against, with the same names as the keys of
  `ExHdlXilinx.Report.Utilization` (`lut`, `ff`, `bram`, `uram`, `dsp`, `gt`).

## Misc

- `mix ex_hdl.gen.sv` should print the list of written files in a form a build
  spec can consume (the `sources` of `ExHdlXilinx.Vivado.Build`), ideally as a
  function returning the paths, not only as a Mix task.
- Yosys resource estimates (already in exhdl) use 7-series names; a Xilinx
  UltraScale+ cell mapping (`synth_xilinx -family xcup`) would let the
  estimate be compared to `report_utilization` numbers.

## Findings from the primitives and hello-card work

The black-box mechanism covers most of the first wave above (typed ports,
parameters, domains, `sources:`, `model:`). What is still missing, each with
a reproducer checked against the current exhdl. In every snippet `use
ExHdl.RTL` is in effect.

1. **Real-valued parameters.** MMCME4_ADV, IDELAYE3 and GTYE4_CHANNEL take
   reals (`CLKFBOUT_MULT_F`, `CLKIN1_PERIOD`, `REFCLK_FREQUENCY`, duty
   cycles). `param_value/1` in the SV backend has no float clause.

       bb = black_box "BR", params: [P: 1.5] do input :I, 1 end
       t = module "t" do a = input :a, 1; instance :u, bb, connect: [I: a] end
       ExHdl.Backends.SystemVerilog.RTL.generate(t)
       #=> FunctionClauseError in param_value/1

   Workaround here: integer values (`CLKIN1_PERIOD: 10`), duty cycles and
   jitter omitted. Fractional dividers (`CLKOUT0_DIVIDE_F: 2.5`) and
   `CLKOUT0_DUTY_CYCLE` are impossible. Wish: `{:real, 2.5}` or plain floats,
   emitted as `2.500`.

2. **Models do not see the instance's parameters.** `Sim.Flat` calls
   `model.init(m.params)` with the black box's defaults.

       bb = black_box "BB", params: [W: 1], model: M do ... end   # M.init/1 prints its argument
       module "t" do ... instance :u, bb, params: [W: 7], connect: [I: a] ... end |> Sim.new()
       #=> model init params: [W: 1]

   Hence `DNA_PORTE2` (`SIM_DNA_VALUE`) and the MMCM lock delay are read from
   `Application.get_env(:ex_hdl_xilinx, ...)` instead. Wish: `init/1` receives
   the merged instance parameters, one model state per instance (it already is).

3. **Unread instance outputs trip `UNUSEDSIGNAL`.** The SV backend marks
   every instance output wire as used (`use_all/2` in `instance/2`), so no
   pragma is emitted.

       bb = black_box "B3" do input :I, 1; output :O, 1; output :Q, 1 end
       t = module "t3" do
         a = input :a, 1; y = output :y, 1
         u = instance :u, bb, connect: [I: a]
         y <~ u[:O]
       end
       # verilator --lint-only -Wall: %Warning-UNUSEDSIGNAL: Signal is not used: 'u_Q'

   The hello top has 16 of these for the MMCM. The hello lint test accepts
   exactly this warning class and nothing else. Wish: treat instance outputs
   like other signals in `unused?/3`.

4. **Black boxes only through the macro.** The port list of a primitive comes
   from data (a table of 17 primitives, IP port lists with hundreds of ports),
   so `ExHdlXilinx.Primitives.box/3` calls `ExHdl.RTL.Builder.build/4` and the
   `input/3`, `output/3`, `domain/2` functions directly. Wish: a public
   `ExHdl.RTL.black_box_from(name, ports, opts)` taking
   `[{:input | :output, name, width, opts}]` and `domains:`, so this does not
   depend on `Builder` internals.

5. **Uppercase port names and dot access.** `u.O` fails to compile (`invalid
   alias: "u.O"`), because `O` parses as an alias. Everything vendor-facing is
   uppercase, so the code uses `u[:O]` and `connect: [I: x]`. Wish: document
   `u[:O]` in the design note, or add `pin(u, :O)`.

6. **Simulation sources for black boxes without leaking into synthesis.**
   `sources:` on a black box is emitted by `SV.generate/1` and so reaches
   Vivado, where a file defining `IBUFDS` clashes with the primitive. The
   stubs therefore live outside the box (`Primitives.sim_sources/1`) and
   nothing can pass them to `Cosim.build/2`. Wish: a second map `sim_sources:`
   on `black_box/3`, returned by `SV.generate(mod, sim: true)` and used by
   `Cosim`.

7. **Co-simulation of designs with internal clocks.** `Cosim.build/2`
   returns `{:error, "co-simulation needs top-level clock ports; internal
   clocks in ..."}` for any design whose clocks come from an MMCM/BUFG, so the
   hello top is simulated in BEAM and linted only, and the stub MMCM (which
   passes `CLKIN1` through) is never run in Verilator. Wish: co-simulation
   with stubs that generate clocks (`--timing`), or the harness driving
   internal clock wires like the BEAM simulator does.

8. **Clock outputs of black boxes.** There is no way to say that a black box
   output is a clock (`BUFG.O`, `MMCME4_ADV.CLKOUT0`); the design assigns
   them to an internal domain's clock (`signal(:clk250) <~ buf[:O]`) and
   the simulator ignores the model's value. It works, but the model of a
   `BUFGCE` cannot gate the clock in simulation. Wish: `output :O, 1, clock: true`
   so `Sim` can derive a gated or divided clock from a model.

9. **No `inout`.** Still needed for `SYSMONE4` I2C, SFP I2C and the
   configuration pins; the XDC side already handles `:inout` pins.

Earlier wishes now met: vector top ports with stable names and
`Module.ports` (used by `Vivado.Build` to check ports against board signals),
differential pairs as `<base>_p`/`<base>_n` plain inputs.
