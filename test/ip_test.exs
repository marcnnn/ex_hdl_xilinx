defmodule ExHdlXilinx.IPTest do
  use ExUnit.Case, async: true
  use ExHdl.RTL
  doctest ExHdlXilinx.Vivado.IP

  alias ExHdl.Backends.SystemVerilog.RTL, as: SV
  alias ExHdl.RTL.Module
  alias ExHdlXilinx.Primitives, as: P
  alias ExHdlXilinx.Test.Lint
  alias ExHdlXilinx.Vivado.{Build, IP, Tcl}

  test "xdma Tcl: create, configure, generate, synthesise" do
    tcl = IP.xdma() |> IP.tcl("out/ip") |> Enum.join("\n")

    assert tcl =~
             "create_ip -name xdma -vendor xilinx.com -library ip -module_name xdma_0 -dir {out/ip}"

    assert tcl =~ "CONFIG.pl_link_cap_max_link_width {X8}"
    assert tcl =~ "CONFIG.pl_link_cap_max_link_speed {8.0_GT/s}"
    assert tcl =~ "CONFIG.xdma_axi_intf_mm {AXI_Stream}"
    assert tcl =~ "CONFIG.axilite_master_en {true}"
    assert tcl =~ "CONFIG.axi_data_width {256_bit}"
    assert tcl =~ "] [get_ips xdma_0]"

    order = [
      "create_ip",
      "set_property -dict",
      "generate_target all [get_ips xdma_0]",
      "synth_ip"
    ]

    idx = for o <- order, do: :binary.match(tcl, o) |> elem(0)
    assert idx == Enum.sort(idx)
  end

  test "xdma options and overrides" do
    ip =
      IP.xdma(
        interface: :axi_mm,
        lanes: 4,
        name: "dma",
        config: [{"axi_data_width", "128_bit"}],
        version: "4.1"
      )

    tcl = ip |> IP.tcl() |> Enum.join("\n")
    assert tcl =~ "-version 4.1 -module_name dma -dir {ip}"
    assert tcl =~ "CONFIG.xdma_axi_intf_mm {AXI_Memory_Mapped}"
    assert tcl =~ "CONFIG.pl_link_cap_max_link_width {X4}"
    assert tcl =~ "CONFIG.axi_data_width {128_bit}"
    refute tcl =~ "256_bit"
  end

  test "xdma ports as a black box" do
    m = IP.black_box(IP.xdma())
    assert m.name == "xdma_0" and m.kind == :black_box
    assert %{type: {:u, 8}, dir: :input} = Module.port(m, :pci_exp_rxp)
    assert %{type: {:u, 8}, dir: :output} = Module.port(m, :pci_exp_txn)
    assert %{type: {:u, 256}, dir: :input, domain: :axi} = Module.port(m, :s_axis_c2h_tdata_0)
    assert %{type: {:u, 32}, dir: :input} = Module.port(m, :s_axis_c2h_tkeep_0)
    assert %{type: {:u, 32}, dir: :output, domain: :axi} = Module.port(m, :m_axil_awaddr)
    assert %{dir: :output} = Module.port(m, :axi_aclk)

    mm = IP.black_box(IP.xdma(interface: :axi_mm))
    assert %{type: {:u, 64}} = Module.port(mm, :m_axi_awaddr)
    assert_raise ArgumentError, fn -> Module.port(mm, :s_axis_c2h_tdata_0) end
  end

  test "transceiver wizard: 10GBASE-R raw 64b/66b" do
    ip = IP.transceiver(:ten_gbase_r, channel: "X0Y4")
    tcl = ip |> IP.tcl() |> Enum.join("\n")
    assert tcl =~ "-name gtwizard_ultrascale"
    assert tcl =~ "-module_name gtwiz_10g_0"
    assert tcl =~ "CONFIG.TX_LINE_RATE {10.3125}"
    assert tcl =~ "CONFIG.TX_DATA_ENCODING {RAW}"
    assert tcl =~ "CONFIG.TX_USER_DATA_WIDTH {64}"
    assert tcl =~ "CONFIG.TX_REFCLK_FREQUENCY {156.25}"
    assert tcl =~ "CONFIG.CHANNEL_ENABLE {X0Y4}"

    assert tcl =~
             "CONFIG.ENABLE_OPTIONAL_PORTS {txheader_in txsequence_in rxheader_out rxgearboxslip_in}"

    m = IP.black_box(ip)
    assert %{type: {:u, 64}, domain: :txusr} = Module.port(m, :gtwiz_userdata_tx_in)
    assert %{type: {:u, 6}, dir: :output} = Module.port(m, :rxheader_out)
    assert %{type: {:u, 1}, dir: :output} = Module.port(m, :gtytxp_out)
  end

  test "transceiver wizard: 1000BASE-X" do
    ip = IP.transceiver(:gbe_1000base_x, refclk_mhz: 125, config: [{"TX_LINE_RATE", "1.25"}])
    tcl = ip |> IP.tcl() |> Enum.join("\n")
    assert tcl =~ "-module_name gtwiz_1g_0"
    assert tcl =~ "CONFIG.TX_DATA_ENCODING {8B10B}"
    assert tcl =~ "CONFIG.TX_USER_DATA_WIDTH {16}"
    assert tcl =~ "CONFIG.TX_REFCLK_FREQUENCY {125}"
    assert length(Regex.scan(~r/CONFIG\.TX_LINE_RATE/, tcl)) == 1

    m = IP.black_box(ip)
    assert %{type: {:u, 16}} = Module.port(m, :gtwiz_userdata_rx_out)
    assert %{type: {:u, 8}, dir: :input} = Module.port(m, :txctrl2_in)
  end

  test "the Build runs IP Tcl between reading sources and synth_design" do
    b = Build.new(name: "d", top: "t", part: "p", sources: ["a.sv"], ips: [IP.xdma()])
    tcl = Tcl.script(b)
    {ip_at, _} = :binary.match(tcl, "create_ip -name xdma")
    {read_at, _} = :binary.match(tcl, "read_verilog")
    {synth_at, _} = :binary.match(tcl, "synth_design")
    assert read_at < ip_at and ip_at < synth_at
    assert tcl =~ "file mkdir out/ip"
    assert tcl =~ "-dir {out/ip}"
    refute Tcl.script(%{b | ips: []}) =~ "create_ip"
  end

  @tag :verilator
  test "a top instantiating the XDMA black box generates SV that lints with a stub" do
    box = IP.black_box(IP.xdma())

    top =
      module "dma_top" do
        domain(:user, clock: :clk_user, clock_port: false, reset: nil)
        rx = input(:rx_p, 8, domain: :async)
        tx = output(:tx_p, 8)
        clk = output(:user_clk, 1)
        u = P.inst(:dma, box, clock: :user, connect: [pci_exp_rxp: rx])
        signal(:clk_user) <~ u[:axi_aclk]
        tx <~ u[:pci_exp_txp]
        clk <~ u[:axi_aresetn]
      end

    files = Map.put(SV.generate(top), "sim/xdma_0.sv", P.stub(box))
    {ok?, out} = Lint.run(files, "dma_top", ["-Wno-UNUSEDSIGNAL"])
    assert ok?, out
  end
end
