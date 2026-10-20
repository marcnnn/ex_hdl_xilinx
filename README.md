# ExHdlXilinx

Everything vendor-specific for Xilinx parts, so the protocol libraries never
depend on a vendor.

## Scope

| Area | Status | Contents |
|---|---|---|
| Boards | done | `ExHdlXilinx.Board` structs and behaviour, `Boards.AS02MC04` (XCKU3P-FFVB676) with per-pin provenance and `verified?` |
| Constraints | done | `ExHdlXilinx.XDC`: pins, IO standards, clocks, clock groups, false paths, CDC bounds, flash properties, input validation |
| Vivado | done | `Vivado.Build` spec, `Vivado.Tcl` non-project script, `Vivado.Runner` (local or ssh+rsync), `mix ex_hdl_xilinx.build` |
| Reports | done | `Report.Timing`, `Report.Utilization`, `Report.Log` parsers |
| Device data | done | `ExHdlXilinx.Device`: KU3P resources, DSP48E2/BRAM/URAM, per-grade delays |
| Primitives | done, ports partly unverified | `ExHdlXilinx.Primitives`: 17 UltraScale+ primitives as `ExHdl.RTL` black boxes with Elixir models and SV simulation stubs (IBUF, OBUF, IBUFDS, IBUFDS_GTE4, BUFG, BUFGCE, BUFG_GT, MMCME4_ADV, PLLE4_ADV, IDELAYE3, ODELAYE3, STARTUPE3, DNA_PORTE2, SYSMONE4, GTYE4_COMMON, GTYE4_CHANNEL, PCIE4CE4) |
| Vivado IP | done, properties unverified | `Vivado.IP`: `create_ip`/`CONFIG`/`generate_target` from a spec; XDMA (Gen3 x8, AXI-Stream or AXI-MM, AXI4-Lite BAR) and the GT wizard (10GBASE-R raw 64b/66b, 1000BASE-X), each with its ports as a black box |
| Hello card | done, not run on hardware | `ExHdlXilinx.Hello`: IBUFDS, MMCM, reset sync, heartbeats on the four LEDs, all in `ExHdl.RTL`; `mix ex_hdl_xilinx.hello` writes SV, XDC and Tcl |
| More boards | planned | Zynq-7020 boards |

Timing and resource models of the families themselves are ExHdl targets;
`Device` only supplies the data.

## The hardware library set

ExHdl itself only provides the basics (RTL DSL, simulation, SystemVerilog,
targets, tool drivers). Function lives in these siblings:

| Library | Scope |
|---|---|
| [ex_hdl_cores](../ex_hdl_cores) | generic IP: FIFOs, CRC, arbiters, AXI4-Stream plumbing |
| [ex_hdl_xilinx](../ex_hdl_xilinx) | Xilinx primitives, constraints, boards |
| [ex_net](../ex_net) | Ethernet MAC, PCS, VLAN/IPv4/UDP/IGMP |
| [ex_ptp](../ex_ptp) | IEEE 1588: timestamping, wallclock, servo, BMCA |
| [ex_aes67](../ex_aes67) | RTP streams, jitter buffer, SAP/SDP, RTSP, mDNS, NMOS |
| [ex_audio](../ex_audio) | audio DSP kernels: EQ, dynamics, matrix mixer, meters |
| [ex_pcie](../ex_pcie) | PCIe DMA and BAR access, host side over vfio |

## Usage

```elixir
alias ExHdlXilinx.{Board, XDC}
alias ExHdlXilinx.Boards.AS02MC04

board = AS02MC04.board()
Board.part(board, speed_grade: "-2")            #=> "xcku3p-ffvb676-2-e"
Board.unverified(board)                          # pins to check with PIN_FUNC first

{:ok, xdc} =
  XDC.generate(board, [{:clk100, "clk"}, {:leds, "led"}, {:sfp1_tx, "sfp_tx"}],
    clock_groups: [[:clk100]],
    max_delay: [%{ns: 8, from: "[get_cells a*]", to: "[get_cells b*]"}])
```

A build spec is a module with `build/0`:

```elixir
defmodule MyApp.Build do
  @behaviour ExHdlXilinx.Vivado.Build

  def build do
    ExHdlXilinx.Vivado.Build.new(
      name: "aes67", top: "top",
      board: ExHdlXilinx.Boards.AS02MC04,
      signals: [{:clk100, "clk"}, {:leds, "led"}],
      sources: Path.wildcard("hdl/generated/*.sv"),
      cfgmem: %{interface: "SPIx4", size_mb: 32})
  end
end
```

```sh
mix ex_hdl_xilinx.build MyApp.Build                       # local vivado in PATH
mix ex_hdl_xilinx.build MyApp.Build --remote build1 \
    --remote-dir /work/aes67 --settings /opt/Xilinx/Vivado/2023.2/settings64.sh
mix ex_hdl_xilinx.build MyApp.Build --tcl-only            # just the script
```

Remote defaults can also come from `config :ex_hdl_xilinx, :remote, host: ...`
or `EX_HDL_XILINX_HOST`, `EX_HDL_XILINX_DIR`, `EX_HDL_XILINX_SETTINGS`. The
runner rsyncs sources up, runs Vivado through ssh with the output streamed,
and rsyncs `out/` back (also after a failure). The task parses the reports
and fails on Vivado errors, log errors or missing timing.

Reports: `ExHdlXilinx.Report.load("out")` returns `%{timing:, utilization:, log:}`.

## Primitives and IP

```elixir
alias ExHdlXilinx.Primitives, as: P

module "top" do
  p = input :clk_p, 1, domain: :async
  n = input :clk_n, 1, domain: :async
  domain :ibuf, clock: :clk_ibuf, clock_port: false, reset: nil
  ibuf = P.inst(:ibufds, P.ibufds(), connect: [I: p, IB: n])
  signal(:clk_ibuf) <~ ibuf[:O]
  mmcm = P.inst(:mmcm, P.mmcme4_adv(), clocks: [clkin1: :ibuf], clock: :ibuf,
                params: [CLKIN1_PERIOD: 10, CLKFBOUT_MULT_F: 10, CLKOUT0_DIVIDE_F: 4],
                open: [:CLKFBIN])
  ...
end
```

`P.inst/3` maps the clock domains of the primitive and ties unconnected
inputs (0, or 1 where the primitive needs it, e.g. `BUFGCE.CE`). Port names
are uppercase, so access is `u[:O]`. Primitive clock outputs are data
outputs that the design assigns to an internal domain's clock.
`Primitives.sim_sources/1` returns lint/simulation stubs (`sim/<NAME>.sv`),
never part of a Vivado build. The moduledoc lists the confidence per port
list: IBUF/OBUF/IBUFDS/IBUFDS_GTE4/BUFG*/delays/STARTUPE3/DNA_PORTE2 are
complete, MMCM/PLL/SYSMON have a few widths marked unsure, `GTYE4_*` carry the
commonly used subset, `PCIE4CE4` only the AXI4-Stream sides (use XDMA).
Real-valued parameters are integers (a limit of the SV backend, see NEEDS.md).

IP cores are specs that `Vivado.Build` creates before `synth_design`:

```elixir
xdma = ExHdlXilinx.Vivado.IP.xdma(interface: :axi_stream)       # Gen3 x8, AXI4-Lite BAR
gt = ExHdlXilinx.Vivado.IP.transceiver(:ten_gbase_r, channel: "X0Y4")
box = ExHdlXilinx.Vivado.IP.black_box(xdma)                      # for instance/3
Build.new(..., ips: [xdma, gt])
```

## Hello card

`ExHdlXilinx.Hello` is the smallest design for the AS02MC04: the 100 MHz LVDS
clock goes through an IBUFDS into an MMCM (250 and 125 MHz), each clock gets a
reset synchroniser released by `LOCKED`, and a counter per clock (100, 250,
125 MHz) drives `led[0..2]`; `led[3]` shows the lock. Everything is
`ExHdl.RTL`. It simulates in the BEAM (`Hello.sim/1`: clocks are ideal, the
MMCM model reports `LOCKED` after 16 input cycles), lints with the stubs, and
produces the XDC from the board data. Not yet run on hardware: the LEDs and
clock pins are verified, the LED polarity is not.

```sh
mix ex_hdl_xilinx.hello                      # _build/ex_hdl_xilinx/hello_card: src/, constraints.xdc, build.tcl, sim/
mix ex_hdl_xilinx.build ExHdlXilinx.Hello.Spec --tcl-only          # inspect the script
mix ex_hdl_xilinx.build ExHdlXilinx.Hello.Spec --remote build1 \
    --remote-dir /work/hello --settings /opt/Xilinx/Vivado/2023.2/settings64.sh
```

The remote run rsyncs the staged directory to `build1`, runs Vivado in batch
mode over ssh and brings `out/` back: `hello_card.bit`, reports and
`vivado.log`. The task prints WNS/TNS and utilisation and fails on log
errors. Program with `write_cfgmem`/hardware manager over JTAG (the PCIe link
does not survive a reboot after a JTAG-only load, see the board notes).
`Vivado.Build.new(rtl: top, board: ..., signals: ...)` takes the sources from
`ExHdl.Backends.SystemVerilog.RTL.generate/1` and raises when top-level
port names, widths or directions disagree with the board signals; ports that
are deliberately unconstrained go in `unconstrained:`.

## Board data: AS02MC04

The card has no documentation. Pins come from three community write-ups (see
`Boards.AS02MC04` for URLs); each pin lists its sources. Verified on
hardware (two sources agree and a design used them): the 100 MHz clock and
the four LEDs. Everything else is unverified until checked with
`get_property PIN_FUNC [get_package_pins ...]` in Vivado, in particular the
SFP channel mapping and PERST (`A9`, some reports say `T19`).

Notable corrections to older notes in the AES67 repo: the package is
FFVB676 (not FFVD900), banks 86/87 run at 3.3 V (so `LVCMOS33`, not
`LVCMOS18`), the PCIe refclock `T7` is `MGTREFCLK1_225`, and PCIe lane order
is reversed.

Device numbers in `ExHdlXilinx.Device` were entered without the datasheets at
hand and are marked unverified.

## Development

```sh
./scripts/checkout_siblings.sh   # path dependencies
mix test
```

Status: boards, XDC, Vivado flow, report parsers, device data, primitives,
IP generation and the hello top are implemented and tested without Vivado
(BEAM simulator, Verilator lint, Tcl/XDC text). Nothing here has run in
Vivado yet; IP property names and the GT/SYSMON/PCIe port subsets are the
parts most likely to need fixes on the first real build. `NEEDS.md` lists the
gaps found in exhdl.
