defmodule ExHdlXilinx.Boards.AS02MC04 do
  @moduledoc """
  Alibaba Cloud AS02MC04 accelerator card (R1291-F9003-02): XCKU3P in an
  FFVB676 package (not FFVD900), two SFP28 cages, PCIe Gen3 x8 edge, 100 MHz
  LVDS oscillator, 156.25 MHz SFP reference, MT25QU256 QSPI flash, no DDR.

  The card has no vendor documentation. All pin data comes from community
  reverse engineering, listed in `sources` and attached to every pin:

    * `:gillon`: Chester Gillon's gist, the most complete one; measured the
      bank voltages with SYSMON and ran PCIe enumeration experiments.
    * `:essenceia`: write-up with a working LED and PCIe enumeration design.
    * `:dkozel`: repository, confirms the part and package only.
    * `:aes67_xdc`: the AES67 repo's XDC, which copies the above (untested).

  `verified?` is true only where two sources agree and a design using the
  ball was reported working: the 100 MHz clock and the four LEDs. The PCIe
  reference clock `T7` is reported working for x4 enumeration but only over
  JTAG (the link does not survive a reboot), so it stays unverified.

  Points where the sources disagree, resolved here:

    * IO standard: the gist's table says LVCMOS18, but its SYSMON
      measurements give bank 86, 87 and 84 a VCCO of 3.3 V and banks 64 to 67
      1.8 V. The pins use LVCMOS33 and keep the other claim in
      `alt_io_standards`.
    * PERST: `A9` (gist, essenceia); some reports say `T19` without
      difference in results. `A9` is used.
    * PCIe lane order is reversed: logical lane 0 sits on the highest
      physical lane (`AF2` as `rxp[0]` enumerated, see the gist). Lanes here
      are in physical order, `ExHdlXilinx.Board.Pcie.logical_lanes/1` reverses.
    * Speed grade: the gist reads `-1E` from the device DNA, the
      as02mc04_hack project builds `-2E`. Default is `-1`; pass
      `speed_grade: "-2"` to `ExHdlXilinx.Board.part/2` for the other.
    * Neither cage has a TX_DISABLE routed to the FPGA (from the AES67 notes,
      not confirmed by a public source), so `tx_disable` is nil.

  The GT channel within a quad is not known for the SFP and PCIe balls (the
  `gt.index` of tx/rx is nil): read `get_property PIN_FUNC` in Vivado.

      iex> b = ExHdlXilinx.Boards.AS02MC04.board()
      iex> ExHdlXilinx.Board.validate(b)
      :ok
      iex> b.package
      "FFVB676"
  """
  @behaviour ExHdlXilinx.Board

  alias ExHdlXilinx.Board
  alias ExHdlXilinx.Board.{Clock, Flash, Pcie, Pin, Sfp}

  @sources %{
    gillon: "https://gist.github.com/Chester-Gillon/765d6286b1c34c7dc26a7b4c4dd0c48c",
    essenceia: "https://essenceia.github.io/projects/alibaba_cloud_fpga/",
    dkozel: "https://github.com/dkozel/Alibaba-Cloud-FPGA",
    forencich: "Alex Forencich's XDC for the card, as quoted by :essenceia (gpio, eeprom)",
    aes67_xdc: "../AES67/FPGA/boards/xilinx/alibaba_ku3p/alibaba_ku3p.xdc (copy, untested)"
  }

  @pcie_rx ~w(P2 T2 V2 Y2 AB2 AD2 AE4 AF2)
  @pcie_rx_n ~w(P1 T1 V1 Y1 AB1 AD1 AE3 AF1)
  @pcie_tx ~w(R5 U5 W5 AA5 AC5 AD7 AE9 AF7)
  @pcie_tx_n ~w(R4 U4 W4 AA4 AC4 AD6 AE8 AF6)

  @impl true
  def board do
    pcie_pins = pcie_pins()
    pcie_lanes = for i <- 0..7, do: %{index: i, tx: :"pcie_tx#{i}", rx: :"pcie_rx#{i}"}
    leds = for {n, p} <- Enum.with_index(~w(B11 C11 A10 B10)), do: led(:"led#{p}", n, true)

    %Board{
      name: "Alibaba AS02MC04",
      device: "xcku3p",
      package: "FFVB676",
      speed_grade: "-1",
      speed_grades: ["-1", "-2"],
      temp: "E",
      sources: @sources,
      bank_voltages: %{
        64 => 1.8,
        65 => 1.8,
        66 => 1.8,
        67 => 1.8,
        84 => 3.3,
        86 => 3.3,
        87 => 3.3
      },
      clocks: [
        %Clock{name: :clk100, signal: :clk100, frequency_hz: 100_000_000},
        %Clock{name: :sfp_refclk, signal: :sfp_refclk, frequency_hz: 156_250_000, kind: :gt_ref},
        %Clock{name: :pcie_refclk, signal: :pcie_refclk, frequency_hz: 100_000_000, kind: :gt_ref}
      ],
      pcie: %Pcie{
        refclk: :pcie_refclk,
        perst: :pcie_perst,
        gen: 3,
        lane_order: :reversed,
        reported_width: 4,
        lanes: pcie_lanes,
        note: "x8 electrically; hosts enumerate x4 only, and only after a JTAG load (gist)"
      },
      sfps: [sfp1(), sfp2()],
      flash: %Flash{
        part: "MT25QU256ABA8ESF-0SIT",
        cfgmem_part: "mt25qu256-spi-x1_x2_x4",
        size_mbit: 256,
        interface: "SPIx4",
        buswidth: 4,
        config_voltage: "1.8",
        cfgbvs: "GND",
        config_rate_mhz: 51.0,
        spi_fall_edge: true,
        compress: true,
        unusedpin: "PULLUP",
        extmastercclk_en: "disable",
        source: [:gillon, :aes67_xdc]
      },
      pins:
        [
          diff(:clk100, "E18", "D18", "LVDS", 67, [:gillon, :essenceia, :aes67_xdc], true,
            note: "reported as the global clock with create_clock -period 10"
          ),
          gt(:sfp_refclk, :refclk, 227, "K7", "K6", 0, [:gillon, :essenceia, :aes67_xdc],
            note: "MGTREFCLK0_227, 156.25 MHz"
          ),
          gt(:pcie_refclk, :refclk, 225, "T7", "T6", 1, [:gillon, :essenceia, :aes67_xdc],
            note: "MGTREFCLK1_225 per the gist; reported for x4 enumeration after JTAG load"
          ),
          io(:pcie_perst, "A9", 86, :in, [:gillon, :essenceia, :aes67_xdc],
            pull: :up,
            timing: :async_in,
            note: "T19 reported by some, no difference in the gist's experiments"
          ),
          io(:sw_reset, "F12", nil, :in, [:gillon, :aes67_xdc],
            pull: :up,
            timing: :async_in,
            note: "active low; bank not listed, 3.3 V assumed"
          )
        ] ++
          pcie_pins ++
          sfp_pins() ++
          leds ++
          [
            led(:led_r, "A13", false, 87),
            led(:led_g, "A12", false, 87),
            led(:led_heart, "B9", false, 86)
          ] ++ misc_pins(),
      groups: %{
        leds: [:led0, :led1, :led2, :led3],
        pcie_rx: for(i <- 0..7, do: :"pcie_rx#{i}"),
        pcie_tx: for(i <- 0..7, do: :"pcie_tx#{i}"),
        gpio: for(i <- 0..5, do: :"gpio#{i}")
      },
      notes: [
        "no DDR, no audio pins",
        "SFP TX_DISABLE not routed to the FPGA (AES67 notes)",
        "LED polarity unknown (AES67 plan 'Not verified')"
      ]
    }
  end

  defp pcie_pins do
    for {i, rx, rxn, tx, txn} <- Enum.zip([0..7, @pcie_rx, @pcie_rx_n, @pcie_tx, @pcie_tx_n]) do
      quad = if i < 4, do: 225, else: 224

      [
        gt(:"pcie_tx#{i}", :tx, quad, tx, txn, nil, [:gillon, :essenceia]),
        gt(:"pcie_rx#{i}", :rx, quad, rx, rxn, nil, [:gillon, :essenceia, :aes67_xdc])
      ]
    end
    |> List.flatten()
  end

  defp sfp1 do
    %Sfp{
      index: 1,
      gt_quad: 227,
      tx: :sfp1_tx,
      rx: :sfp1_rx,
      refclk: :sfp_refclk,
      los: :sfp1_los,
      mod_abs: :sfp1_mod_abs,
      tx_fault: :sfp1_tx_fault,
      i2c_scl: :sfp1_i2c_scl,
      i2c_sda: :sfp1_i2c_sda,
      led: :sfp1_led
    }
  end

  defp sfp2 do
    %Sfp{
      index: 2,
      gt_quad: 227,
      tx: :sfp2_tx,
      rx: :sfp2_rx,
      refclk: :sfp_refclk,
      los: :sfp2_los,
      mod_abs: :sfp2_mod_abs,
      tx_fault: :sfp2_tx_fault,
      i2c_scl: :sfp2_i2c_scl,
      i2c_sda: :sfp2_i2c_sda,
      led: :sfp2_led
    }
  end

  @sfp_ctrl %{
    1 => [mod_abs: {"D14", 87}, tx_fault: {"B14", 87}, los: {"D13", 87}],
    2 => [mod_abs: {"E11", 86}, tx_fault: {"F9", 86}, los: {"E10", 86}]
  }
  @sfp_i2c %{1 => {"C14", "C13", 87}, 2 => {"D11", "D10", 86}}
  @sfp_gt %{1 => {"B7", "B6", "A4", "A3"}, 2 => {"D7", "D6", "B2", "B1"}}

  defp sfp_pins do
    for n <- [1, 2], into: [] do
      {txp, txn, rxp, rxn} = @sfp_gt[n]
      {sda, scl, ibank} = @sfp_i2c[n]
      src = [:gillon, :essenceia, :aes67_xdc]

      [
        gt(:"sfp#{n}_tx", :tx, 227, txp, txn, nil, src,
          note: "channel unknown; cage 2 pairs are unchecked in the AES67 notes"
        ),
        gt(:"sfp#{n}_rx", :rx, 227, rxp, rxn, nil, src),
        for {sig, {ball, bank}} <- @sfp_ctrl[n] do
          io(:"sfp#{n}_#{sig}", ball, bank, :in, src, pull: :up, timing: :async_in)
        end,
        io(:"sfp#{n}_i2c_sda", sda, ibank, :inout, src, pull: :up, timing: :async_out),
        io(:"sfp#{n}_i2c_scl", scl, ibank, :inout, src, pull: :up, timing: :async_out),
        io(:"sfp#{n}_led", if(n == 1, do: "B12", else: "C12"), 87, :out, src,
          drive: 12,
          slew: :slow,
          timing: :async_out
        )
      ]
    end
    |> List.flatten()
  end

  defp misc_pins do
    src = [:essenceia, :forencich]

    eeprom =
      for {name, ball, bank} <- [
            {:eeprom0_sda, "G10", 86},
            {:eeprom0_scl, "G9", 86},
            {:eeprom1_sda, "J15", 87},
            {:eeprom1_scl, "J14", 87}
          ] do
        io(name, ball, bank, :inout, [:essenceia], pull: :up, timing: :async_out)
      end

    gpio =
      for {ball, i} <- Enum.with_index(~w(A14 E12 E13 F10 C9 D9)) do
        io(:"gpio#{i}", ball, nil, :inout, src, note: "J5 pad, bank not listed, 3.3 V assumed")
      end

    eeprom ++ gpio
  end

  defp led(name, ball, verified?, bank \\ 86) do
    src = if verified?, do: [:gillon, :essenceia, :aes67_xdc], else: [:gillon, :essenceia]

    io(name, ball, bank, :out, src, timing: :async_out, verified?: verified?)
  end

  defp io(name, ball, bank, dir, source, opts) do
    struct!(
      Pin,
      [
        name: name,
        pin: ball,
        bank: bank,
        dir: dir,
        io_standard: "LVCMOS33",
        alt_io_standards: ["LVCMOS18"],
        source: source
      ] ++ opts
    )
  end

  defp diff(name, p, n, std, bank, source, verified?, opts) do
    struct!(
      Pin,
      [
        name: name,
        pin: p,
        pin_n: n,
        io_standard: std,
        bank: bank,
        source: source,
        verified?: verified?
      ] ++ opts
    )
  end

  defp gt(name, kind, quad, p, n, index, source, opts \\ []) do
    struct!(
      Pin,
      [
        name: name,
        pin: p,
        pin_n: n,
        gt: %{quad: quad, kind: kind, index: index},
        dir: if(kind == :tx, do: :out, else: :in),
        source: source
      ] ++ opts
    )
  end
end
