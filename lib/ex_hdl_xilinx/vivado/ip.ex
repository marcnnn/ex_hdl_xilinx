defmodule ExHdlXilinx.Vivado.IP do
  @moduledoc """
  Vivado IP cores from an Elixir spec: `create_ip`, `set_property CONFIG...`,
  `generate_target`, `synth_ip`, plus the core's port list as an `ExHdl.RTL`
  black box so a top written with `ExHdl.RTL` can instantiate it.

  An `IP` is plain data:

    * `name` - the module name (`xdma_0`), also the black box name
    * `ip` - the Vivado IP type (`"xdma"`), `vendor`, `library`, `version`
    * `config` - `[{"pl_link_cap_max_link_speed", "8.0_GT/s"}, ...]`, written
      as `CONFIG.<key> {<value>}`
    * `ports` - port string in the grammar of `ExHdlXilinx.Primitives.box/3`

  `tcl/2` renders the commands, `black_box/1` the module. `Build` runs the
  Tcl of its `ips` before `synth_design`.

  Constructors: `xdma/1` (PCIe Gen3 x8 DMA with AXI4-Stream or AXI-MM, plus
  the AXI4-Lite BAR master) and `transceiver/2` (UltraScale+ GT wizard for
  10GBASE-R raw 64b/66b or 1000BASE-X).

  Vivado was not available when these were written. Property names and
  values come from memory of the 2022 to 2023 releases (XDMA 4.1,
  `gtwizard_ultrascale` 1.7); the first real run will reject some. `config:`
  overrides or adds any property, `version: nil` (the default) lets Vivado
  pick the newest installed. The ports are the commonly used ones.
  """

  alias ExHdlXilinx.Primitives

  defstruct [
    :name,
    :ip,
    :ports,
    vendor: "xilinx.com",
    library: "ip",
    version: nil,
    config: [],
    note: nil
  ]

  @type t :: %__MODULE__{}

  @doc "Keyword list or struct to `IP`."
  def new(opts), do: struct!(__MODULE__, opts)

  @doc """
  Tcl for one IP. `dir` is where the IP sources go (default `ip`).

      iex> ip = ExHdlXilinx.Vivado.IP.new(name: "fifo_0", ip: "fifo_generator", ports: "i:din",
      ...>   config: [{"Fifo_Implementation", "Common_Clock_Block_RAM"}])
      iex> ExHdlXilinx.Vivado.IP.tcl(ip) |> Enum.at(0)
      "create_ip -name fifo_generator -vendor xilinx.com -library ip -module_name fifo_0 -dir {ip}"
  """
  @spec tcl(t(), Path.t()) :: [String.t()]
  def tcl(%__MODULE__{} = ip, dir \\ "ip") do
    ver = if ip.version, do: " -version #{ip.version}", else: ""
    get = "[get_ips #{ip.name}]"

    [
      "create_ip -name #{ip.ip} -vendor #{ip.vendor} -library #{ip.library}#{ver} " <>
        "-module_name #{ip.name} -dir {#{dir}}"
    ] ++
      if(ip.config == [],
        do: [],
        else: [
          "set_property -dict [list \\\n" <>
            Enum.map_join(ip.config, " \\\n", fn {k, v} -> "  CONFIG.#{k} {#{v}}" end) <>
            " \\\n] #{get}"
        ]
      ) ++
      [
        "generate_target all #{get}",
        "synth_ip #{get}"
      ]
  end

  @doc "The IP as a black box (ports only)."
  @spec black_box(t()) :: ExHdl.RTL.Module.t()
  def black_box(%__MODULE__{name: n, ports: p}), do: Primitives.box(n, p)

  # -- XDMA ------------------------------------------------------------------------------

  @doc """
  XDMA, PCIe Gen3 x8 (the card's edge connector), with the AXI4-Lite BAR
  master `m_axil_*` and either AXI4-Stream or memory-mapped DMA channels.

  Options: `name:` (default `"xdma_0"`), `interface:` `:axi_stream` (default)
  or `:axi_mm`, `lanes:` 8, `speed:` `"8.0_GT/s"`, `axi_width:` 256,
  `ref_clk:` `"100_MHz"`, `bar_size_mb:` 1 (size of the AXI-Lite BAR),
  `channels:` 1 (read and write), `vendor_id:`, `device_id:`, `config:`
  extra or overriding properties, `version:`.

  Ports: `sys_clk` (the `ODIV2` of the `IBUFDS_GTE4` on the PCIe reference
  clock), `sys_clk_gt` (its `O`), `sys_rst_n`, the serial lanes, `axi_aclk`
  and `axi_aresetn` (user clock and reset, drive an internal domain),
  `user_lnk_up`, `usr_irq_req`/`usr_irq_ack`, AXI4-Lite `m_axil_*`, and
  `c2h`/`h2c` streams (`s_axis_c2h_*_0`, `m_axis_h2c_*_0`) or `m_axi_*`.
  Everything in the `axi` domain; `ExHdlXilinx.Primitives.inst/3` maps it
  to a parent domain with `clock:`. Unverified: `axilite_master_size`,
  `pcie_blk_locn` and the GT quad selection (the card's PCIe reference clock
  is `MGTREFCLK1_225`), see `Boards.AS02MC04`.
  """
  @spec xdma(keyword()) :: t()
  def xdma(opts \\ []) do
    iface = Keyword.get(opts, :interface, :axi_stream)
    lanes = Keyword.get(opts, :lanes, 8)
    width = Keyword.get(opts, :axi_width, 256)
    channels = Keyword.get(opts, :channels, 1)
    name = Keyword.get(opts, :name, "xdma_0")

    base = [
      {"mode_selection", "Advanced"},
      {"functional_mode", "DMA"},
      {"pl_link_cap_max_link_speed", Keyword.get(opts, :speed, "8.0_GT/s")},
      {"pl_link_cap_max_link_width", "X#{lanes}"},
      {"ref_clk_freq", Keyword.get(opts, :ref_clk, "100_MHz")},
      {"axi_data_width", "#{width}_bit"},
      {"axisten_freq", if(width == 256, do: "250", else: "125")},
      {"xdma_axi_intf_mm", if(iface == :axi_stream, do: "AXI_Stream", else: "AXI_Memory_Mapped")},
      {"xdma_rnum_chnl", channels},
      {"xdma_wnum_chnl", channels},
      {"axilite_master_en", "true"},
      {"axilite_master_size", Keyword.get(opts, :bar_size_mb, 1)},
      {"axilite_master_scale", "Megabytes"},
      {"pf0_device_id", Keyword.get(opts, :device_id, "9038")},
      {"vendor_id", Keyword.get(opts, :vendor_id, "10EE")}
    ]

    %__MODULE__{
      name: name,
      ip: "xdma",
      version: opts[:version],
      config: merge(base, Keyword.get(opts, :config, [])),
      ports: xdma_ports(iface, lanes, width),
      note: "XDMA PCIe Gen3 x#{lanes}, #{iface}"
    }
  end

  defp xdma_ports(iface, lanes, width) do
    keep = div(width, 8)

    common =
      "d:axi i:sys_clk i:sys_clk_gt i:sys_rst_n i:pci_exp_rxp[#{lanes}] i:pci_exp_rxn[#{lanes}] " <>
        "o:pci_exp_txp[#{lanes}] o:pci_exp_txn[#{lanes}] o:axi_aclk o:axi_aresetn@axi " <>
        "o:user_lnk_up@axi i:usr_irq_req[1]@axi o:usr_irq_ack[1]@axi " <>
        "o:msi_enable@axi? o:msix_enable@axi? " <>
        "o:m_axil_awaddr[32]@axi o:m_axil_awprot[3]@axi o:m_axil_awvalid@axi i:m_axil_awready@axi " <>
        "o:m_axil_wdata[32]@axi o:m_axil_wstrb[4]@axi o:m_axil_wvalid@axi i:m_axil_wready@axi " <>
        "i:m_axil_bresp[2]@axi i:m_axil_bvalid@axi o:m_axil_bready@axi " <>
        "o:m_axil_araddr[32]@axi o:m_axil_arprot[3]@axi o:m_axil_arvalid@axi i:m_axil_arready@axi " <>
        "i:m_axil_rdata[32]@axi i:m_axil_rresp[2]@axi i:m_axil_rvalid@axi o:m_axil_rready@axi "

    case iface do
      :axi_stream ->
        common <>
          "i:s_axis_c2h_tdata_0[#{width}]@axi i:s_axis_c2h_tlast_0@axi i:s_axis_c2h_tvalid_0@axi " <>
          "o:s_axis_c2h_tready_0@axi i:s_axis_c2h_tkeep_0[#{keep}]@axi " <>
          "o:m_axis_h2c_tdata_0[#{width}]@axi o:m_axis_h2c_tlast_0@axi o:m_axis_h2c_tvalid_0@axi " <>
          "i:m_axis_h2c_tready_0@axi o:m_axis_h2c_tkeep_0[#{keep}]@axi"

      :axi_mm ->
        common <>
          "o:m_axi_awid[4]@axi o:m_axi_awaddr[64]@axi o:m_axi_awlen[8]@axi o:m_axi_awsize[3]@axi " <>
          "o:m_axi_awburst[2]@axi o:m_axi_awprot[3]@axi o:m_axi_awvalid@axi i:m_axi_awready@axi " <>
          "o:m_axi_awlock@axi o:m_axi_awcache[4]@axi " <>
          "o:m_axi_wdata[#{width}]@axi o:m_axi_wstrb[#{keep}]@axi o:m_axi_wlast@axi " <>
          "o:m_axi_wvalid@axi i:m_axi_wready@axi i:m_axi_bid[4]@axi i:m_axi_bresp[2]@axi " <>
          "i:m_axi_bvalid@axi o:m_axi_bready@axi o:m_axi_arid[4]@axi o:m_axi_araddr[64]@axi " <>
          "o:m_axi_arlen[8]@axi o:m_axi_arsize[3]@axi o:m_axi_arburst[2]@axi " <>
          "o:m_axi_arprot[3]@axi o:m_axi_arvalid@axi i:m_axi_arready@axi o:m_axi_arlock@axi " <>
          "o:m_axi_arcache[4]@axi i:m_axi_rid[4]@axi i:m_axi_rdata[#{width}]@axi " <>
          "i:m_axi_rresp[2]@axi i:m_axi_rlast@axi i:m_axi_rvalid@axi o:m_axi_rready@axi"
    end
  end

  # -- transceiver wizard ----------------------------------------------------------------

  @doc """
  UltraScale+ transceiver wizard (`gtwizard_ultrascale`), one GTY channel,
  with the helper blocks (user clocking, reset controller) in the core.

  `mode`: `:ten_gbase_r` - 10.3125 Gb/s, raw 64b/66b (`txheader_in`,
  `txsequence_in`, `rxheader_out`, `rxgearboxslip_in`; scrambling and block
  sync are logic in the fabric), 64-bit user data; `:gbe_1000base_x` -
  1.25 Gb/s, 8b/10b, 16-bit user data with `txctrl*`/`rxctrl*` K flags.

  Options: `name:` (default `gtwiz_10g_0` / `gtwiz_1g_0`), `refclk_mhz:`
  (default 156.25, the SFP reference of the card), `freerun_mhz:` (100),
  `channel:` a location like `"X0Y4"` (`CHANNEL_ENABLE`; unknown for the
  card's SFP balls, see `Boards.AS02MC04`), `config:`, `version:`.

  Ports: free-running clock and reset controller (`gtwiz_reset_*`),
  `gtwiz_userclk_tx_usrclk2_out`/`rx` (user clocks, in the `txusr`/`rxusr`
  domains), `gtwiz_userdata_*`, serial pins `gtytxp_out` and friends,
  `gtrefclk00_in`, status. The 10GBASE-R property set is a guess for the
  `PRESET` route (`GTY-10GBASE-R`); both property lists are unverified.
  """
  @spec transceiver(:ten_gbase_r | :gbe_1000base_x, keyword()) :: t()
  def transceiver(mode, opts \\ [])

  def transceiver(:ten_gbase_r, opts) do
    ref = Keyword.get(opts, :refclk_mhz, 156.25)

    config =
      [
        {"PRESET", "GTY-10GBASE-R"},
        {"TX_LINE_RATE", "10.3125"},
        {"RX_LINE_RATE", "10.3125"},
        {"TX_REFCLK_FREQUENCY", ref},
        {"RX_REFCLK_FREQUENCY", ref},
        {"TX_DATA_ENCODING", "RAW"},
        {"RX_DATA_DECODING", "RAW"},
        {"TX_USER_DATA_WIDTH", "64"},
        {"RX_USER_DATA_WIDTH", "64"},
        {"TX_INT_DATA_WIDTH", "64"},
        {"RX_INT_DATA_WIDTH", "64"},
        {"TX_BUFFER_MODE", "0"},
        {"RX_BUFFER_MODE", "0"},
        {"ENABLE_OPTIONAL_PORTS", "txheader_in txsequence_in rxheader_out rxgearboxslip_in"}
      ]

    wizard(
      opts,
      "gtwiz_10g_0",
      config,
      "i:gtwiz_userdata_tx_in[64]@txusr o:gtwiz_userdata_rx_out[64]@rxusr " <>
        "i:txheader_in[6]@txusr i:txsequence_in[7]@txusr o:rxheader_out[6]@rxusr " <>
        "o:rxheadervalid_out[2]@rxusr? o:rxdatavalid_out[2]@rxusr? i:rxgearboxslip_in@rxusr?"
    )
  end

  def transceiver(:gbe_1000base_x, opts) do
    ref = Keyword.get(opts, :refclk_mhz, 156.25)

    config = [
      {"TX_LINE_RATE", "1.25"},
      {"RX_LINE_RATE", "1.25"},
      {"TX_REFCLK_FREQUENCY", ref},
      {"RX_REFCLK_FREQUENCY", ref},
      {"TX_DATA_ENCODING", "8B10B"},
      {"RX_DATA_DECODING", "8B10B"},
      {"TX_USER_DATA_WIDTH", "16"},
      {"RX_USER_DATA_WIDTH", "16"},
      {"TX_INT_DATA_WIDTH", "20"},
      {"RX_INT_DATA_WIDTH", "20"},
      {"RX_COMMA_PRESET", "K28.5"},
      {"RX_COMMA_P_ENABLE", "true"},
      {"RX_COMMA_M_ENABLE", "true"},
      {"RX_COMMA_SHOW_REALIGN_ENABLE", "true"},
      {"ENABLE_OPTIONAL_PORTS",
       "txctrl0_in txctrl1_in txctrl2_in rxctrl0_out rxctrl1_out rxctrl2_out rxctrl3_out"}
    ]

    wizard(
      opts,
      "gtwiz_1g_0",
      config,
      "i:gtwiz_userdata_tx_in[16]@txusr o:gtwiz_userdata_rx_out[16]@rxusr " <>
        "i:txctrl0_in[16]@txusr i:txctrl1_in[16]@txusr i:txctrl2_in[8]@txusr " <>
        "o:rxctrl0_out[16]@rxusr o:rxctrl1_out[16]@rxusr o:rxctrl2_out[8]@rxusr " <>
        "o:rxctrl3_out[8]@rxusr"
    )
  end

  defp wizard(opts, default_name, config, data_ports) do
    channel = if c = opts[:channel], do: [{"CHANNEL_ENABLE", c}], else: []

    base =
      config ++
        channel ++
        [
          {"FREERUN_FREQUENCY", Keyword.get(opts, :freerun_mhz, 100)},
          {"LOCATE_COMMON", "CORE"},
          {"LOCATE_RESET_CONTROLLER", "CORE"},
          {"LOCATE_TX_USER_CLOCKING", "CORE"},
          {"LOCATE_RX_USER_CLOCKING", "CORE"},
          {"TXPROGDIV_FREQ_ENABLE", "true"},
          {"TXPROGDIV_FREQ_SOURCE", "CPLL"},
          {"TXPROGDIV_FREQ_VAL", "322.265625"}
        ]

    %__MODULE__{
      name: Keyword.get(opts, :name, default_name),
      ip: "gtwizard_ultrascale",
      version: opts[:version],
      config: merge(base, Keyword.get(opts, :config, [])),
      ports: wizard_ports() <> " " <> data_ports
    }
  end

  defp wizard_ports do
    "d:txusr d:rxusr i:gtwiz_reset_clk_freerun_in i:gtwiz_reset_all_in " <>
      "i:gtwiz_reset_tx_pll_and_datapath_in i:gtwiz_reset_tx_datapath_in " <>
      "i:gtwiz_reset_rx_pll_and_datapath_in i:gtwiz_reset_rx_datapath_in " <>
      "o:gtwiz_reset_rx_cdr_stable_out o:gtwiz_reset_tx_done_out o:gtwiz_reset_rx_done_out " <>
      "i:gtwiz_userclk_tx_reset_in i:gtwiz_userclk_rx_reset_in " <>
      "o:gtwiz_userclk_tx_srcclk_out o:gtwiz_userclk_tx_usrclk_out o:gtwiz_userclk_tx_usrclk2_out " <>
      "o:gtwiz_userclk_tx_active_out o:gtwiz_userclk_rx_srcclk_out o:gtwiz_userclk_rx_usrclk_out " <>
      "o:gtwiz_userclk_rx_usrclk2_out o:gtwiz_userclk_rx_active_out " <>
      "i:gtrefclk00_in o:qpll0outclk_out o:qpll0outrefclk_out " <>
      "i:gtyrxn_in i:gtyrxp_in o:gtytxn_out o:gtytxp_out " <>
      "o:rxpmaresetdone_out o:txpmaresetdone_out o:txprgdivresetdone_out"
  end

  defp merge(base, extra) do
    keys = Enum.map(extra, fn {k, _} -> to_string(k) end)
    Enum.reject(base, fn {k, _} -> to_string(k) in keys end) ++ extra
  end
end
