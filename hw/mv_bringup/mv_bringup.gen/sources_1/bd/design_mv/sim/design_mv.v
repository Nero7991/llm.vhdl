//Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
//Copyright 2022-2023 Advanced Micro Devices, Inc. All Rights Reserved.
//--------------------------------------------------------------------------------
//Tool Version: Vivado v.2023.2 (lin64) Build 4029153 Fri Oct 13 20:13:54 MDT 2023
//Date        : Sun Aug 23 15:01:38 2026
//Host        : Oren-Dell-Ubuntu running 64-bit Ubuntu 22.04.5 LTS
//Command     : generate_target design_mv.bd
//Design      : design_mv
//Purpose     : IP block netlist
//--------------------------------------------------------------------------------
`timescale 1 ps / 1 ps

(* CORE_GENERATION_INFO = "design_mv,IP_Integrator,{x_ipVendor=xilinx.com,x_ipLibrary=BlockDiagram,x_ipName=design_mv,x_ipVersion=1.00.a,x_ipLanguage=VERILOG,numBlks=5,numReposBlks=5,numNonXlnxBlks=1,numHierBlks=0,maxHierDepth=0,numSysgenBlks=0,numHlsBlks=0,numHdlrefBlks=1,numPkgbdBlks=0,bdsource=USER,synth_mode=Hierarchical}" *) (* HW_HANDOFF = "design_mv.hwdef" *) 
module design_mv
   ();

  wire [7:0]ctrl_ic_M00_AXI_ARADDR;
  wire [2:0]ctrl_ic_M00_AXI_ARPROT;
  wire ctrl_ic_M00_AXI_ARREADY;
  wire ctrl_ic_M00_AXI_ARVALID;
  wire [7:0]ctrl_ic_M00_AXI_AWADDR;
  wire [2:0]ctrl_ic_M00_AXI_AWPROT;
  wire ctrl_ic_M00_AXI_AWREADY;
  wire ctrl_ic_M00_AXI_AWVALID;
  wire ctrl_ic_M00_AXI_BREADY;
  wire [1:0]ctrl_ic_M00_AXI_BRESP;
  wire ctrl_ic_M00_AXI_BVALID;
  wire [31:0]ctrl_ic_M00_AXI_RDATA;
  wire ctrl_ic_M00_AXI_RREADY;
  wire [1:0]ctrl_ic_M00_AXI_RRESP;
  wire ctrl_ic_M00_AXI_RVALID;
  wire [31:0]ctrl_ic_M00_AXI_WDATA;
  wire ctrl_ic_M00_AXI_WREADY;
  wire [3:0]ctrl_ic_M00_AXI_WSTRB;
  wire ctrl_ic_M00_AXI_WVALID;
  wire [3:0]ctrl_ic_M01_AXI_ARADDR;
  wire [2:0]ctrl_ic_M01_AXI_ARPROT;
  wire ctrl_ic_M01_AXI_ARREADY;
  wire ctrl_ic_M01_AXI_ARVALID;
  wire [3:0]ctrl_ic_M01_AXI_AWADDR;
  wire [2:0]ctrl_ic_M01_AXI_AWPROT;
  wire ctrl_ic_M01_AXI_AWREADY;
  wire ctrl_ic_M01_AXI_AWVALID;
  wire ctrl_ic_M01_AXI_BREADY;
  wire [1:0]ctrl_ic_M01_AXI_BRESP;
  wire ctrl_ic_M01_AXI_BVALID;
  wire [31:0]ctrl_ic_M01_AXI_RDATA;
  wire ctrl_ic_M01_AXI_RREADY;
  wire [1:0]ctrl_ic_M01_AXI_RRESP;
  wire ctrl_ic_M01_AXI_RVALID;
  wire [31:0]ctrl_ic_M01_AXI_WDATA;
  wire ctrl_ic_M01_AXI_WREADY;
  wire [3:0]ctrl_ic_M01_AXI_WSTRB;
  wire ctrl_ic_M01_AXI_WVALID;
  wire [31:0]mv_m00_axi_ARADDR;
  wire [1:0]mv_m00_axi_ARBURST;
  wire [3:0]mv_m00_axi_ARCACHE;
  wire [7:0]mv_m00_axi_ARLEN;
  wire mv_m00_axi_ARLOCK;
  wire [2:0]mv_m00_axi_ARPROT;
  wire [3:0]mv_m00_axi_ARQOS;
  wire mv_m00_axi_ARREADY;
  wire [2:0]mv_m00_axi_ARSIZE;
  wire mv_m00_axi_ARVALID;
  wire [127:0]mv_m00_axi_RDATA;
  wire mv_m00_axi_RLAST;
  wire mv_m00_axi_RREADY;
  wire [1:0]mv_m00_axi_RRESP;
  wire mv_m00_axi_RVALID;
  wire [31:0]mv_m01_axi_ARADDR;
  wire [1:0]mv_m01_axi_ARBURST;
  wire [3:0]mv_m01_axi_ARCACHE;
  wire [7:0]mv_m01_axi_ARLEN;
  wire mv_m01_axi_ARLOCK;
  wire [2:0]mv_m01_axi_ARPROT;
  wire [3:0]mv_m01_axi_ARQOS;
  wire mv_m01_axi_ARREADY;
  wire [2:0]mv_m01_axi_ARSIZE;
  wire mv_m01_axi_ARVALID;
  wire [127:0]mv_m01_axi_RDATA;
  wire mv_m01_axi_RLAST;
  wire mv_m01_axi_RREADY;
  wire [1:0]mv_m01_axi_RRESP;
  wire mv_m01_axi_RVALID;
  wire [31:0]mv_m02_axi_ARADDR;
  wire [1:0]mv_m02_axi_ARBURST;
  wire [3:0]mv_m02_axi_ARCACHE;
  wire [7:0]mv_m02_axi_ARLEN;
  wire mv_m02_axi_ARLOCK;
  wire [2:0]mv_m02_axi_ARPROT;
  wire [3:0]mv_m02_axi_ARQOS;
  wire mv_m02_axi_ARREADY;
  wire [2:0]mv_m02_axi_ARSIZE;
  wire mv_m02_axi_ARVALID;
  wire [127:0]mv_m02_axi_RDATA;
  wire mv_m02_axi_RLAST;
  wire mv_m02_axi_RREADY;
  wire [1:0]mv_m02_axi_RRESP;
  wire mv_m02_axi_RVALID;
  wire [31:0]mv_m03_axi_ARADDR;
  wire [1:0]mv_m03_axi_ARBURST;
  wire [3:0]mv_m03_axi_ARCACHE;
  wire [7:0]mv_m03_axi_ARLEN;
  wire mv_m03_axi_ARLOCK;
  wire [2:0]mv_m03_axi_ARPROT;
  wire [3:0]mv_m03_axi_ARQOS;
  wire mv_m03_axi_ARREADY;
  wire [2:0]mv_m03_axi_ARSIZE;
  wire mv_m03_axi_ARVALID;
  wire [127:0]mv_m03_axi_RDATA;
  wire mv_m03_axi_RLAST;
  wire mv_m03_axi_RREADY;
  wire [1:0]mv_m03_axi_RRESP;
  wire mv_m03_axi_RVALID;
  wire [31:0]mv_m04_axi_ARADDR;
  wire [1:0]mv_m04_axi_ARBURST;
  wire [3:0]mv_m04_axi_ARCACHE;
  wire [7:0]mv_m04_axi_ARLEN;
  wire mv_m04_axi_ARLOCK;
  wire [2:0]mv_m04_axi_ARPROT;
  wire [3:0]mv_m04_axi_ARQOS;
  wire mv_m04_axi_ARREADY;
  wire [2:0]mv_m04_axi_ARSIZE;
  wire mv_m04_axi_ARVALID;
  wire [127:0]mv_m04_axi_RDATA;
  wire mv_m04_axi_RLAST;
  wire mv_m04_axi_RREADY;
  wire [1:0]mv_m04_axi_RRESP;
  wire mv_m04_axi_RVALID;
  wire [39:0]ps_M_AXI_HPM0_LPD_ARADDR;
  wire [1:0]ps_M_AXI_HPM0_LPD_ARBURST;
  wire [3:0]ps_M_AXI_HPM0_LPD_ARCACHE;
  wire [15:0]ps_M_AXI_HPM0_LPD_ARID;
  wire [7:0]ps_M_AXI_HPM0_LPD_ARLEN;
  wire ps_M_AXI_HPM0_LPD_ARLOCK;
  wire [2:0]ps_M_AXI_HPM0_LPD_ARPROT;
  wire [3:0]ps_M_AXI_HPM0_LPD_ARQOS;
  wire ps_M_AXI_HPM0_LPD_ARREADY;
  wire [2:0]ps_M_AXI_HPM0_LPD_ARSIZE;
  wire [15:0]ps_M_AXI_HPM0_LPD_ARUSER;
  wire ps_M_AXI_HPM0_LPD_ARVALID;
  wire [39:0]ps_M_AXI_HPM0_LPD_AWADDR;
  wire [1:0]ps_M_AXI_HPM0_LPD_AWBURST;
  wire [3:0]ps_M_AXI_HPM0_LPD_AWCACHE;
  wire [15:0]ps_M_AXI_HPM0_LPD_AWID;
  wire [7:0]ps_M_AXI_HPM0_LPD_AWLEN;
  wire ps_M_AXI_HPM0_LPD_AWLOCK;
  wire [2:0]ps_M_AXI_HPM0_LPD_AWPROT;
  wire [3:0]ps_M_AXI_HPM0_LPD_AWQOS;
  wire ps_M_AXI_HPM0_LPD_AWREADY;
  wire [2:0]ps_M_AXI_HPM0_LPD_AWSIZE;
  wire [15:0]ps_M_AXI_HPM0_LPD_AWUSER;
  wire ps_M_AXI_HPM0_LPD_AWVALID;
  wire [15:0]ps_M_AXI_HPM0_LPD_BID;
  wire ps_M_AXI_HPM0_LPD_BREADY;
  wire [1:0]ps_M_AXI_HPM0_LPD_BRESP;
  wire ps_M_AXI_HPM0_LPD_BVALID;
  wire [31:0]ps_M_AXI_HPM0_LPD_RDATA;
  wire [15:0]ps_M_AXI_HPM0_LPD_RID;
  wire ps_M_AXI_HPM0_LPD_RLAST;
  wire ps_M_AXI_HPM0_LPD_RREADY;
  wire [1:0]ps_M_AXI_HPM0_LPD_RRESP;
  wire ps_M_AXI_HPM0_LPD_RVALID;
  wire [31:0]ps_M_AXI_HPM0_LPD_WDATA;
  wire ps_M_AXI_HPM0_LPD_WLAST;
  wire ps_M_AXI_HPM0_LPD_WREADY;
  wire [3:0]ps_M_AXI_HPM0_LPD_WSTRB;
  wire ps_M_AXI_HPM0_LPD_WVALID;
  wire ps_pl_clk0;
  wire ps_pl_resetn0;
  wire [0:0]rst_peripheral_aresetn;

  design_mv_ctrl_ic_0 ctrl_ic
       (.M00_AXI_araddr(ctrl_ic_M00_AXI_ARADDR),
        .M00_AXI_arprot(ctrl_ic_M00_AXI_ARPROT),
        .M00_AXI_arready(ctrl_ic_M00_AXI_ARREADY),
        .M00_AXI_arvalid(ctrl_ic_M00_AXI_ARVALID),
        .M00_AXI_awaddr(ctrl_ic_M00_AXI_AWADDR),
        .M00_AXI_awprot(ctrl_ic_M00_AXI_AWPROT),
        .M00_AXI_awready(ctrl_ic_M00_AXI_AWREADY),
        .M00_AXI_awvalid(ctrl_ic_M00_AXI_AWVALID),
        .M00_AXI_bready(ctrl_ic_M00_AXI_BREADY),
        .M00_AXI_bresp(ctrl_ic_M00_AXI_BRESP),
        .M00_AXI_bvalid(ctrl_ic_M00_AXI_BVALID),
        .M00_AXI_rdata(ctrl_ic_M00_AXI_RDATA),
        .M00_AXI_rready(ctrl_ic_M00_AXI_RREADY),
        .M00_AXI_rresp(ctrl_ic_M00_AXI_RRESP),
        .M00_AXI_rvalid(ctrl_ic_M00_AXI_RVALID),
        .M00_AXI_wdata(ctrl_ic_M00_AXI_WDATA),
        .M00_AXI_wready(ctrl_ic_M00_AXI_WREADY),
        .M00_AXI_wstrb(ctrl_ic_M00_AXI_WSTRB),
        .M00_AXI_wvalid(ctrl_ic_M00_AXI_WVALID),
        .M01_AXI_araddr(ctrl_ic_M01_AXI_ARADDR),
        .M01_AXI_arprot(ctrl_ic_M01_AXI_ARPROT),
        .M01_AXI_arready(ctrl_ic_M01_AXI_ARREADY),
        .M01_AXI_arvalid(ctrl_ic_M01_AXI_ARVALID),
        .M01_AXI_awaddr(ctrl_ic_M01_AXI_AWADDR),
        .M01_AXI_awprot(ctrl_ic_M01_AXI_AWPROT),
        .M01_AXI_awready(ctrl_ic_M01_AXI_AWREADY),
        .M01_AXI_awvalid(ctrl_ic_M01_AXI_AWVALID),
        .M01_AXI_bready(ctrl_ic_M01_AXI_BREADY),
        .M01_AXI_bresp(ctrl_ic_M01_AXI_BRESP),
        .M01_AXI_bvalid(ctrl_ic_M01_AXI_BVALID),
        .M01_AXI_rdata(ctrl_ic_M01_AXI_RDATA),
        .M01_AXI_rready(ctrl_ic_M01_AXI_RREADY),
        .M01_AXI_rresp(ctrl_ic_M01_AXI_RRESP),
        .M01_AXI_rvalid(ctrl_ic_M01_AXI_RVALID),
        .M01_AXI_wdata(ctrl_ic_M01_AXI_WDATA),
        .M01_AXI_wready(ctrl_ic_M01_AXI_WREADY),
        .M01_AXI_wstrb(ctrl_ic_M01_AXI_WSTRB),
        .M01_AXI_wvalid(ctrl_ic_M01_AXI_WVALID),
        .S00_AXI_araddr(ps_M_AXI_HPM0_LPD_ARADDR),
        .S00_AXI_arburst(ps_M_AXI_HPM0_LPD_ARBURST),
        .S00_AXI_arcache(ps_M_AXI_HPM0_LPD_ARCACHE),
        .S00_AXI_arid(ps_M_AXI_HPM0_LPD_ARID),
        .S00_AXI_arlen(ps_M_AXI_HPM0_LPD_ARLEN),
        .S00_AXI_arlock(ps_M_AXI_HPM0_LPD_ARLOCK),
        .S00_AXI_arprot(ps_M_AXI_HPM0_LPD_ARPROT),
        .S00_AXI_arqos(ps_M_AXI_HPM0_LPD_ARQOS),
        .S00_AXI_arready(ps_M_AXI_HPM0_LPD_ARREADY),
        .S00_AXI_arsize(ps_M_AXI_HPM0_LPD_ARSIZE),
        .S00_AXI_aruser(ps_M_AXI_HPM0_LPD_ARUSER),
        .S00_AXI_arvalid(ps_M_AXI_HPM0_LPD_ARVALID),
        .S00_AXI_awaddr(ps_M_AXI_HPM0_LPD_AWADDR),
        .S00_AXI_awburst(ps_M_AXI_HPM0_LPD_AWBURST),
        .S00_AXI_awcache(ps_M_AXI_HPM0_LPD_AWCACHE),
        .S00_AXI_awid(ps_M_AXI_HPM0_LPD_AWID),
        .S00_AXI_awlen(ps_M_AXI_HPM0_LPD_AWLEN),
        .S00_AXI_awlock(ps_M_AXI_HPM0_LPD_AWLOCK),
        .S00_AXI_awprot(ps_M_AXI_HPM0_LPD_AWPROT),
        .S00_AXI_awqos(ps_M_AXI_HPM0_LPD_AWQOS),
        .S00_AXI_awready(ps_M_AXI_HPM0_LPD_AWREADY),
        .S00_AXI_awsize(ps_M_AXI_HPM0_LPD_AWSIZE),
        .S00_AXI_awuser(ps_M_AXI_HPM0_LPD_AWUSER),
        .S00_AXI_awvalid(ps_M_AXI_HPM0_LPD_AWVALID),
        .S00_AXI_bid(ps_M_AXI_HPM0_LPD_BID),
        .S00_AXI_bready(ps_M_AXI_HPM0_LPD_BREADY),
        .S00_AXI_bresp(ps_M_AXI_HPM0_LPD_BRESP),
        .S00_AXI_bvalid(ps_M_AXI_HPM0_LPD_BVALID),
        .S00_AXI_rdata(ps_M_AXI_HPM0_LPD_RDATA),
        .S00_AXI_rid(ps_M_AXI_HPM0_LPD_RID),
        .S00_AXI_rlast(ps_M_AXI_HPM0_LPD_RLAST),
        .S00_AXI_rready(ps_M_AXI_HPM0_LPD_RREADY),
        .S00_AXI_rresp(ps_M_AXI_HPM0_LPD_RRESP),
        .S00_AXI_rvalid(ps_M_AXI_HPM0_LPD_RVALID),
        .S00_AXI_wdata(ps_M_AXI_HPM0_LPD_WDATA),
        .S00_AXI_wlast(ps_M_AXI_HPM0_LPD_WLAST),
        .S00_AXI_wready(ps_M_AXI_HPM0_LPD_WREADY),
        .S00_AXI_wstrb(ps_M_AXI_HPM0_LPD_WSTRB),
        .S00_AXI_wvalid(ps_M_AXI_HPM0_LPD_WVALID),
        .aclk(ps_pl_clk0),
        .aresetn(rst_peripheral_aresetn));
  design_mv_fan_pwm_0 fan_pwm
       (.s00_axi_aclk(ps_pl_clk0),
        .s00_axi_araddr(ctrl_ic_M01_AXI_ARADDR),
        .s00_axi_aresetn(rst_peripheral_aresetn),
        .s00_axi_arprot(ctrl_ic_M01_AXI_ARPROT),
        .s00_axi_arready(ctrl_ic_M01_AXI_ARREADY),
        .s00_axi_arvalid(ctrl_ic_M01_AXI_ARVALID),
        .s00_axi_awaddr(ctrl_ic_M01_AXI_AWADDR),
        .s00_axi_awprot(ctrl_ic_M01_AXI_AWPROT),
        .s00_axi_awready(ctrl_ic_M01_AXI_AWREADY),
        .s00_axi_awvalid(ctrl_ic_M01_AXI_AWVALID),
        .s00_axi_bready(ctrl_ic_M01_AXI_BREADY),
        .s00_axi_bresp(ctrl_ic_M01_AXI_BRESP),
        .s00_axi_bvalid(ctrl_ic_M01_AXI_BVALID),
        .s00_axi_rdata(ctrl_ic_M01_AXI_RDATA),
        .s00_axi_rready(ctrl_ic_M01_AXI_RREADY),
        .s00_axi_rresp(ctrl_ic_M01_AXI_RRESP),
        .s00_axi_rvalid(ctrl_ic_M01_AXI_RVALID),
        .s00_axi_wdata(ctrl_ic_M01_AXI_WDATA),
        .s00_axi_wready(ctrl_ic_M01_AXI_WREADY),
        .s00_axi_wstrb(ctrl_ic_M01_AXI_WSTRB),
        .s00_axi_wvalid(ctrl_ic_M01_AXI_WVALID));
  design_mv_mv_0 mv
       (.m00_axi_araddr(mv_m00_axi_ARADDR),
        .m00_axi_arburst(mv_m00_axi_ARBURST),
        .m00_axi_arcache(mv_m00_axi_ARCACHE),
        .m00_axi_arlen(mv_m00_axi_ARLEN),
        .m00_axi_arlock(mv_m00_axi_ARLOCK),
        .m00_axi_arprot(mv_m00_axi_ARPROT),
        .m00_axi_arqos(mv_m00_axi_ARQOS),
        .m00_axi_arready(mv_m00_axi_ARREADY),
        .m00_axi_arsize(mv_m00_axi_ARSIZE),
        .m00_axi_arvalid(mv_m00_axi_ARVALID),
        .m00_axi_rdata(mv_m00_axi_RDATA),
        .m00_axi_rlast(mv_m00_axi_RLAST),
        .m00_axi_rready(mv_m00_axi_RREADY),
        .m00_axi_rresp(mv_m00_axi_RRESP),
        .m00_axi_rvalid(mv_m00_axi_RVALID),
        .m01_axi_araddr(mv_m01_axi_ARADDR),
        .m01_axi_arburst(mv_m01_axi_ARBURST),
        .m01_axi_arcache(mv_m01_axi_ARCACHE),
        .m01_axi_arlen(mv_m01_axi_ARLEN),
        .m01_axi_arlock(mv_m01_axi_ARLOCK),
        .m01_axi_arprot(mv_m01_axi_ARPROT),
        .m01_axi_arqos(mv_m01_axi_ARQOS),
        .m01_axi_arready(mv_m01_axi_ARREADY),
        .m01_axi_arsize(mv_m01_axi_ARSIZE),
        .m01_axi_arvalid(mv_m01_axi_ARVALID),
        .m01_axi_rdata(mv_m01_axi_RDATA),
        .m01_axi_rlast(mv_m01_axi_RLAST),
        .m01_axi_rready(mv_m01_axi_RREADY),
        .m01_axi_rresp(mv_m01_axi_RRESP),
        .m01_axi_rvalid(mv_m01_axi_RVALID),
        .m02_axi_araddr(mv_m02_axi_ARADDR),
        .m02_axi_arburst(mv_m02_axi_ARBURST),
        .m02_axi_arcache(mv_m02_axi_ARCACHE),
        .m02_axi_arlen(mv_m02_axi_ARLEN),
        .m02_axi_arlock(mv_m02_axi_ARLOCK),
        .m02_axi_arprot(mv_m02_axi_ARPROT),
        .m02_axi_arqos(mv_m02_axi_ARQOS),
        .m02_axi_arready(mv_m02_axi_ARREADY),
        .m02_axi_arsize(mv_m02_axi_ARSIZE),
        .m02_axi_arvalid(mv_m02_axi_ARVALID),
        .m02_axi_rdata(mv_m02_axi_RDATA),
        .m02_axi_rlast(mv_m02_axi_RLAST),
        .m02_axi_rready(mv_m02_axi_RREADY),
        .m02_axi_rresp(mv_m02_axi_RRESP),
        .m02_axi_rvalid(mv_m02_axi_RVALID),
        .m03_axi_araddr(mv_m03_axi_ARADDR),
        .m03_axi_arburst(mv_m03_axi_ARBURST),
        .m03_axi_arcache(mv_m03_axi_ARCACHE),
        .m03_axi_arlen(mv_m03_axi_ARLEN),
        .m03_axi_arlock(mv_m03_axi_ARLOCK),
        .m03_axi_arprot(mv_m03_axi_ARPROT),
        .m03_axi_arqos(mv_m03_axi_ARQOS),
        .m03_axi_arready(mv_m03_axi_ARREADY),
        .m03_axi_arsize(mv_m03_axi_ARSIZE),
        .m03_axi_arvalid(mv_m03_axi_ARVALID),
        .m03_axi_rdata(mv_m03_axi_RDATA),
        .m03_axi_rlast(mv_m03_axi_RLAST),
        .m03_axi_rready(mv_m03_axi_RREADY),
        .m03_axi_rresp(mv_m03_axi_RRESP),
        .m03_axi_rvalid(mv_m03_axi_RVALID),
        .m04_axi_araddr(mv_m04_axi_ARADDR),
        .m04_axi_arburst(mv_m04_axi_ARBURST),
        .m04_axi_arcache(mv_m04_axi_ARCACHE),
        .m04_axi_arlen(mv_m04_axi_ARLEN),
        .m04_axi_arlock(mv_m04_axi_ARLOCK),
        .m04_axi_arprot(mv_m04_axi_ARPROT),
        .m04_axi_arqos(mv_m04_axi_ARQOS),
        .m04_axi_arready(mv_m04_axi_ARREADY),
        .m04_axi_arsize(mv_m04_axi_ARSIZE),
        .m04_axi_arvalid(mv_m04_axi_ARVALID),
        .m04_axi_rdata(mv_m04_axi_RDATA),
        .m04_axi_rlast(mv_m04_axi_RLAST),
        .m04_axi_rready(mv_m04_axi_RREADY),
        .m04_axi_rresp(mv_m04_axi_RRESP),
        .m04_axi_rvalid(mv_m04_axi_RVALID),
        .s_axi_aclk(ps_pl_clk0),
        .s_axi_araddr(ctrl_ic_M00_AXI_ARADDR),
        .s_axi_aresetn(rst_peripheral_aresetn),
        .s_axi_arprot(ctrl_ic_M00_AXI_ARPROT),
        .s_axi_arready(ctrl_ic_M00_AXI_ARREADY),
        .s_axi_arvalid(ctrl_ic_M00_AXI_ARVALID),
        .s_axi_awaddr(ctrl_ic_M00_AXI_AWADDR),
        .s_axi_awprot(ctrl_ic_M00_AXI_AWPROT),
        .s_axi_awready(ctrl_ic_M00_AXI_AWREADY),
        .s_axi_awvalid(ctrl_ic_M00_AXI_AWVALID),
        .s_axi_bready(ctrl_ic_M00_AXI_BREADY),
        .s_axi_bresp(ctrl_ic_M00_AXI_BRESP),
        .s_axi_bvalid(ctrl_ic_M00_AXI_BVALID),
        .s_axi_rdata(ctrl_ic_M00_AXI_RDATA),
        .s_axi_rready(ctrl_ic_M00_AXI_RREADY),
        .s_axi_rresp(ctrl_ic_M00_AXI_RRESP),
        .s_axi_rvalid(ctrl_ic_M00_AXI_RVALID),
        .s_axi_wdata(ctrl_ic_M00_AXI_WDATA),
        .s_axi_wready(ctrl_ic_M00_AXI_WREADY),
        .s_axi_wstrb(ctrl_ic_M00_AXI_WSTRB),
        .s_axi_wvalid(ctrl_ic_M00_AXI_WVALID));
  design_mv_ps_0 ps
       (.emio_sdio0_cmdin(1'b0),
        .emio_sdio0_datain({1'b0,1'b0,1'b0,1'b0}),
        .emio_sdio0_fb_clk_in(1'b0),
        .maxigp2_araddr(ps_M_AXI_HPM0_LPD_ARADDR),
        .maxigp2_arburst(ps_M_AXI_HPM0_LPD_ARBURST),
        .maxigp2_arcache(ps_M_AXI_HPM0_LPD_ARCACHE),
        .maxigp2_arid(ps_M_AXI_HPM0_LPD_ARID),
        .maxigp2_arlen(ps_M_AXI_HPM0_LPD_ARLEN),
        .maxigp2_arlock(ps_M_AXI_HPM0_LPD_ARLOCK),
        .maxigp2_arprot(ps_M_AXI_HPM0_LPD_ARPROT),
        .maxigp2_arqos(ps_M_AXI_HPM0_LPD_ARQOS),
        .maxigp2_arready(ps_M_AXI_HPM0_LPD_ARREADY),
        .maxigp2_arsize(ps_M_AXI_HPM0_LPD_ARSIZE),
        .maxigp2_aruser(ps_M_AXI_HPM0_LPD_ARUSER),
        .maxigp2_arvalid(ps_M_AXI_HPM0_LPD_ARVALID),
        .maxigp2_awaddr(ps_M_AXI_HPM0_LPD_AWADDR),
        .maxigp2_awburst(ps_M_AXI_HPM0_LPD_AWBURST),
        .maxigp2_awcache(ps_M_AXI_HPM0_LPD_AWCACHE),
        .maxigp2_awid(ps_M_AXI_HPM0_LPD_AWID),
        .maxigp2_awlen(ps_M_AXI_HPM0_LPD_AWLEN),
        .maxigp2_awlock(ps_M_AXI_HPM0_LPD_AWLOCK),
        .maxigp2_awprot(ps_M_AXI_HPM0_LPD_AWPROT),
        .maxigp2_awqos(ps_M_AXI_HPM0_LPD_AWQOS),
        .maxigp2_awready(ps_M_AXI_HPM0_LPD_AWREADY),
        .maxigp2_awsize(ps_M_AXI_HPM0_LPD_AWSIZE),
        .maxigp2_awuser(ps_M_AXI_HPM0_LPD_AWUSER),
        .maxigp2_awvalid(ps_M_AXI_HPM0_LPD_AWVALID),
        .maxigp2_bid(ps_M_AXI_HPM0_LPD_BID),
        .maxigp2_bready(ps_M_AXI_HPM0_LPD_BREADY),
        .maxigp2_bresp(ps_M_AXI_HPM0_LPD_BRESP),
        .maxigp2_bvalid(ps_M_AXI_HPM0_LPD_BVALID),
        .maxigp2_rdata(ps_M_AXI_HPM0_LPD_RDATA),
        .maxigp2_rid(ps_M_AXI_HPM0_LPD_RID),
        .maxigp2_rlast(ps_M_AXI_HPM0_LPD_RLAST),
        .maxigp2_rready(ps_M_AXI_HPM0_LPD_RREADY),
        .maxigp2_rresp(ps_M_AXI_HPM0_LPD_RRESP),
        .maxigp2_rvalid(ps_M_AXI_HPM0_LPD_RVALID),
        .maxigp2_wdata(ps_M_AXI_HPM0_LPD_WDATA),
        .maxigp2_wlast(ps_M_AXI_HPM0_LPD_WLAST),
        .maxigp2_wready(ps_M_AXI_HPM0_LPD_WREADY),
        .maxigp2_wstrb(ps_M_AXI_HPM0_LPD_WSTRB),
        .maxigp2_wvalid(ps_M_AXI_HPM0_LPD_WVALID),
        .maxihpm0_lpd_aclk(ps_pl_clk0),
        .pl_clk0(ps_pl_clk0),
        .pl_resetn0(ps_pl_resetn0),
        .saxigp0_araddr({1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,mv_m04_axi_ARADDR}),
        .saxigp0_arburst(mv_m04_axi_ARBURST),
        .saxigp0_arcache(mv_m04_axi_ARCACHE),
        .saxigp0_arid({1'b0,1'b0,1'b0,1'b0,1'b0,1'b0}),
        .saxigp0_arlen(mv_m04_axi_ARLEN),
        .saxigp0_arlock(mv_m04_axi_ARLOCK),
        .saxigp0_arprot(mv_m04_axi_ARPROT),
        .saxigp0_arqos(mv_m04_axi_ARQOS),
        .saxigp0_arready(mv_m04_axi_ARREADY),
        .saxigp0_arsize(mv_m04_axi_ARSIZE),
        .saxigp0_aruser(1'b0),
        .saxigp0_arvalid(mv_m04_axi_ARVALID),
        .saxigp0_awaddr({1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0}),
        .saxigp0_awburst({1'b0,1'b1}),
        .saxigp0_awcache({1'b0,1'b0,1'b1,1'b1}),
        .saxigp0_awid({1'b0,1'b0,1'b0,1'b0,1'b0,1'b0}),
        .saxigp0_awlen({1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0}),
        .saxigp0_awlock(1'b0),
        .saxigp0_awprot({1'b0,1'b0,1'b0}),
        .saxigp0_awqos({1'b0,1'b0,1'b0,1'b0}),
        .saxigp0_awsize({1'b1,1'b0,1'b0}),
        .saxigp0_awuser(1'b0),
        .saxigp0_awvalid(1'b0),
        .saxigp0_bready(1'b0),
        .saxigp0_rdata(mv_m04_axi_RDATA),
        .saxigp0_rlast(mv_m04_axi_RLAST),
        .saxigp0_rready(mv_m04_axi_RREADY),
        .saxigp0_rresp(mv_m04_axi_RRESP),
        .saxigp0_rvalid(mv_m04_axi_RVALID),
        .saxigp0_wdata({1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0}),
        .saxigp0_wlast(1'b0),
        .saxigp0_wstrb({1'b1,1'b1,1'b1,1'b1,1'b1,1'b1,1'b1,1'b1,1'b1,1'b1,1'b1,1'b1,1'b1,1'b1,1'b1,1'b1}),
        .saxigp0_wvalid(1'b0),
        .saxigp2_araddr({1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,mv_m00_axi_ARADDR}),
        .saxigp2_arburst(mv_m00_axi_ARBURST),
        .saxigp2_arcache(mv_m00_axi_ARCACHE),
        .saxigp2_arid({1'b0,1'b0,1'b0,1'b0,1'b0,1'b0}),
        .saxigp2_arlen(mv_m00_axi_ARLEN),
        .saxigp2_arlock(mv_m00_axi_ARLOCK),
        .saxigp2_arprot(mv_m00_axi_ARPROT),
        .saxigp2_arqos(mv_m00_axi_ARQOS),
        .saxigp2_arready(mv_m00_axi_ARREADY),
        .saxigp2_arsize(mv_m00_axi_ARSIZE),
        .saxigp2_aruser(1'b0),
        .saxigp2_arvalid(mv_m00_axi_ARVALID),
        .saxigp2_awaddr({1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0}),
        .saxigp2_awburst({1'b0,1'b1}),
        .saxigp2_awcache({1'b0,1'b0,1'b1,1'b1}),
        .saxigp2_awid({1'b0,1'b0,1'b0,1'b0,1'b0,1'b0}),
        .saxigp2_awlen({1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0}),
        .saxigp2_awlock(1'b0),
        .saxigp2_awprot({1'b0,1'b0,1'b0}),
        .saxigp2_awqos({1'b0,1'b0,1'b0,1'b0}),
        .saxigp2_awsize({1'b1,1'b0,1'b0}),
        .saxigp2_awuser(1'b0),
        .saxigp2_awvalid(1'b0),
        .saxigp2_bready(1'b0),
        .saxigp2_rdata(mv_m00_axi_RDATA),
        .saxigp2_rlast(mv_m00_axi_RLAST),
        .saxigp2_rready(mv_m00_axi_RREADY),
        .saxigp2_rresp(mv_m00_axi_RRESP),
        .saxigp2_rvalid(mv_m00_axi_RVALID),
        .saxigp2_wdata({1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0}),
        .saxigp2_wlast(1'b0),
        .saxigp2_wstrb({1'b1,1'b1,1'b1,1'b1,1'b1,1'b1,1'b1,1'b1,1'b1,1'b1,1'b1,1'b1,1'b1,1'b1,1'b1,1'b1}),
        .saxigp2_wvalid(1'b0),
        .saxigp3_araddr({1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,mv_m01_axi_ARADDR}),
        .saxigp3_arburst(mv_m01_axi_ARBURST),
        .saxigp3_arcache(mv_m01_axi_ARCACHE),
        .saxigp3_arid({1'b0,1'b0,1'b0,1'b0,1'b0,1'b0}),
        .saxigp3_arlen(mv_m01_axi_ARLEN),
        .saxigp3_arlock(mv_m01_axi_ARLOCK),
        .saxigp3_arprot(mv_m01_axi_ARPROT),
        .saxigp3_arqos(mv_m01_axi_ARQOS),
        .saxigp3_arready(mv_m01_axi_ARREADY),
        .saxigp3_arsize(mv_m01_axi_ARSIZE),
        .saxigp3_aruser(1'b0),
        .saxigp3_arvalid(mv_m01_axi_ARVALID),
        .saxigp3_awaddr({1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0}),
        .saxigp3_awburst({1'b0,1'b1}),
        .saxigp3_awcache({1'b0,1'b0,1'b1,1'b1}),
        .saxigp3_awid({1'b0,1'b0,1'b0,1'b0,1'b0,1'b0}),
        .saxigp3_awlen({1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0}),
        .saxigp3_awlock(1'b0),
        .saxigp3_awprot({1'b0,1'b0,1'b0}),
        .saxigp3_awqos({1'b0,1'b0,1'b0,1'b0}),
        .saxigp3_awsize({1'b1,1'b0,1'b0}),
        .saxigp3_awuser(1'b0),
        .saxigp3_awvalid(1'b0),
        .saxigp3_bready(1'b0),
        .saxigp3_rdata(mv_m01_axi_RDATA),
        .saxigp3_rlast(mv_m01_axi_RLAST),
        .saxigp3_rready(mv_m01_axi_RREADY),
        .saxigp3_rresp(mv_m01_axi_RRESP),
        .saxigp3_rvalid(mv_m01_axi_RVALID),
        .saxigp3_wdata({1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0}),
        .saxigp3_wlast(1'b0),
        .saxigp3_wstrb({1'b1,1'b1,1'b1,1'b1,1'b1,1'b1,1'b1,1'b1,1'b1,1'b1,1'b1,1'b1,1'b1,1'b1,1'b1,1'b1}),
        .saxigp3_wvalid(1'b0),
        .saxigp4_araddr({1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,mv_m02_axi_ARADDR}),
        .saxigp4_arburst(mv_m02_axi_ARBURST),
        .saxigp4_arcache(mv_m02_axi_ARCACHE),
        .saxigp4_arid({1'b0,1'b0,1'b0,1'b0,1'b0,1'b0}),
        .saxigp4_arlen(mv_m02_axi_ARLEN),
        .saxigp4_arlock(mv_m02_axi_ARLOCK),
        .saxigp4_arprot(mv_m02_axi_ARPROT),
        .saxigp4_arqos(mv_m02_axi_ARQOS),
        .saxigp4_arready(mv_m02_axi_ARREADY),
        .saxigp4_arsize(mv_m02_axi_ARSIZE),
        .saxigp4_aruser(1'b0),
        .saxigp4_arvalid(mv_m02_axi_ARVALID),
        .saxigp4_awaddr({1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0}),
        .saxigp4_awburst({1'b0,1'b1}),
        .saxigp4_awcache({1'b0,1'b0,1'b1,1'b1}),
        .saxigp4_awid({1'b0,1'b0,1'b0,1'b0,1'b0,1'b0}),
        .saxigp4_awlen({1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0}),
        .saxigp4_awlock(1'b0),
        .saxigp4_awprot({1'b0,1'b0,1'b0}),
        .saxigp4_awqos({1'b0,1'b0,1'b0,1'b0}),
        .saxigp4_awsize({1'b1,1'b0,1'b0}),
        .saxigp4_awuser(1'b0),
        .saxigp4_awvalid(1'b0),
        .saxigp4_bready(1'b0),
        .saxigp4_rdata(mv_m02_axi_RDATA),
        .saxigp4_rlast(mv_m02_axi_RLAST),
        .saxigp4_rready(mv_m02_axi_RREADY),
        .saxigp4_rresp(mv_m02_axi_RRESP),
        .saxigp4_rvalid(mv_m02_axi_RVALID),
        .saxigp4_wdata({1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0}),
        .saxigp4_wlast(1'b0),
        .saxigp4_wstrb({1'b1,1'b1,1'b1,1'b1,1'b1,1'b1,1'b1,1'b1,1'b1,1'b1,1'b1,1'b1,1'b1,1'b1,1'b1,1'b1}),
        .saxigp4_wvalid(1'b0),
        .saxigp5_araddr({1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,mv_m03_axi_ARADDR}),
        .saxigp5_arburst(mv_m03_axi_ARBURST),
        .saxigp5_arcache(mv_m03_axi_ARCACHE),
        .saxigp5_arid({1'b0,1'b0,1'b0,1'b0,1'b0,1'b0}),
        .saxigp5_arlen(mv_m03_axi_ARLEN),
        .saxigp5_arlock(mv_m03_axi_ARLOCK),
        .saxigp5_arprot(mv_m03_axi_ARPROT),
        .saxigp5_arqos(mv_m03_axi_ARQOS),
        .saxigp5_arready(mv_m03_axi_ARREADY),
        .saxigp5_arsize(mv_m03_axi_ARSIZE),
        .saxigp5_aruser(1'b0),
        .saxigp5_arvalid(mv_m03_axi_ARVALID),
        .saxigp5_awaddr({1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0}),
        .saxigp5_awburst({1'b0,1'b1}),
        .saxigp5_awcache({1'b0,1'b0,1'b1,1'b1}),
        .saxigp5_awid({1'b0,1'b0,1'b0,1'b0,1'b0,1'b0}),
        .saxigp5_awlen({1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0}),
        .saxigp5_awlock(1'b0),
        .saxigp5_awprot({1'b0,1'b0,1'b0}),
        .saxigp5_awqos({1'b0,1'b0,1'b0,1'b0}),
        .saxigp5_awsize({1'b1,1'b0,1'b0}),
        .saxigp5_awuser(1'b0),
        .saxigp5_awvalid(1'b0),
        .saxigp5_bready(1'b0),
        .saxigp5_rdata(mv_m03_axi_RDATA),
        .saxigp5_rlast(mv_m03_axi_RLAST),
        .saxigp5_rready(mv_m03_axi_RREADY),
        .saxigp5_rresp(mv_m03_axi_RRESP),
        .saxigp5_rvalid(mv_m03_axi_RVALID),
        .saxigp5_wdata({1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0}),
        .saxigp5_wlast(1'b0),
        .saxigp5_wstrb({1'b1,1'b1,1'b1,1'b1,1'b1,1'b1,1'b1,1'b1,1'b1,1'b1,1'b1,1'b1,1'b1,1'b1,1'b1,1'b1}),
        .saxigp5_wvalid(1'b0),
        .saxihp0_fpd_aclk(ps_pl_clk0),
        .saxihp1_fpd_aclk(ps_pl_clk0),
        .saxihp2_fpd_aclk(ps_pl_clk0),
        .saxihp3_fpd_aclk(ps_pl_clk0),
        .saxihpc0_fpd_aclk(ps_pl_clk0));
  design_mv_rst_0 rst
       (.aux_reset_in(1'b1),
        .dcm_locked(1'b1),
        .ext_reset_in(ps_pl_resetn0),
        .mb_debug_sys_rst(1'b0),
        .peripheral_aresetn(rst_peripheral_aresetn),
        .slowest_sync_clk(ps_pl_clk0));
endmodule
