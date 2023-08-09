//-----------------------------------------------------------------------------
//
// (c) Copyright 2010-2011 Xilinx, Inc. All rights reserved.
//
// This file contains confidential and proprietary information
// of Xilinx, Inc. and is protected under U.S. and
// international copyright and other intellectual property
// laws.
//
// DISCLAIMER
// This disclaimer is not a license and does not grant any
// rights to the materials distributed herewith. Except as
// otherwise provided in a valid license issued to you by
// Xilinx, and to the maximum extent permitted by applicable
// law: (1) THESE MATERIALS ARE MADE AVAILABLE "AS IS" AND
// WITH ALL FAULTS, AND XILINX HEREBY DISCLAIMS ALL WARRANTIES
// AND CONDITIONS, EXPRESS, IMPLIED, OR STATUTORY, INCLUDING
// BUT NOT LIMITED TO WARRANTIES OF MERCHANTABILITY, NON-
// INFRINGEMENT, OR FITNESS FOR ANY PARTICULAR PURPOSE; and
// (2) Xilinx shall not be liable (whether in contract or tort,
// including negligence, or under any other theory of
// liability) for any loss or damage of any kind or nature
// related to, arising under or in connection with these
// materials, including for any direct, or any indirect,
// special, incidental, or consequential loss or damage
// (including loss of data, profits, goodwill, or any type of
// loss or damage suffered as a result of any action brought
// by a third party) even if such damage or loss was
// reasonably foreseeable or Xilinx had been advised of the
// possibility of the same.
//
// CRITICAL APPLICATIONS
// Xilinx products are not designed or intended to be fail-
// safe, or for use in any application requiring fail-safe
// performance, such as life-support or safety devices or
// systems, Class III medical devices, nuclear facilities,
// applications related to the deployment of airbags, or any
// other applications that could lead to death, personal
// injury, or severe property or environmental damage
// (individually and collectively, "Critical
// Applications"). Customer assumes the sole risk and
// liability of any use of Xilinx products in Critical
// Applications, subject only to applicable laws and
// regulations governing limitations on product liability.
//
// THIS COPYRIGHT NOTICE AND DISCLAIMER MUST BE RETAINED AS
// PART OF THIS FILE AT ALL TIMES.
//
//-----------------------------------------------------------------------------
// Project    : Series-7 Integrated Block for PCI Express
// File       : PIO_RX_ENGINE.v
// Version    : 3.3
//--
//-- Description: Local-Link Receive Unit.
//--
//--------------------------------------------------------------------------------

`timescale 1ps/1ps


(* DowngradeIPIdentifiedWarnings = "yes" *)
module PIO_RX_ENGINE  #(
  parameter TCQ = 1,
  parameter C_DATA_WIDTH = 64,            // RX/TX interface data width

  // Do not override parameters below this line
  parameter KEEP_WIDTH = C_DATA_WIDTH / 8               // TSTRB width
) (
  input                         clk,
  input                         rst_n,

  // AXI-S
  input  [C_DATA_WIDTH-1:0]     m_axis_rx_tdata,
  input  [KEEP_WIDTH-1:0]       m_axis_rx_tkeep,
  input                         m_axis_rx_tlast,
  input                         m_axis_rx_tvalid,
  output reg                    m_axis_rx_tready,
  input    [21:0]               m_axis_rx_tuser,


  //  Memory Read data handshake with Completion
  //  transmit unit. Transmit unit reponds to
  //  req_compl assertion and responds with compl_done
  //  assertion when a Completion w/ data is transmitted.


  output reg         req_compl,
  output reg         req_compl_wd,
  input              compl_done,

  output reg [2:0]   req_tc,                        // Memory Read TC
  output reg         req_td,                        // Memory Read TD
  output reg         req_ep,                        // Memory Read EP
  output reg [1:0]   req_attr,                      // Memory Read Attribute
  output reg [9:0]   req_len,                       // Memory Read Length (1DW)
  output reg [15:0]  req_rid,                       // Memory Read Requestor ID
  output reg [7:0]   req_tag,                       // Memory Read Tag
  output reg [7:0]   req_be,                        // Memory Read Byte Enables
  output reg [12:0]  req_addr,                      // Memory Read Address
  output reg [29:0]  req_addr32,                    // Memory Read Address 32


  // Memory interface used to save 1 DW data received
  // on Memory Write 32 TLP. Data extracted from
  // inbound TLP is presented to the Endpoint memory
  // unit. Endpoint memory unit reacts to wr_en
  // assertion and asserts wr_busy when it is
  // processing written information.


  output reg [10:0]  wr_addr,                       // Memory Write Address
  output reg [7:0]   wr_be,                         // Memory Write Byte Enable
  output reg [31:0]  wr_data,                       // Memory Write Data
  output reg         wr_en,                         // Memory Write Enable
  input              wr_busy                        // Memory Write Busy
);

  localparam PIO_RX_MEM_RD32_FMT_TYPE = 7'b00_00000;
  localparam PIO_RX_MEM_WR32_FMT_TYPE = 7'b10_00000;
  localparam PIO_RX_MEM_RD64_FMT_TYPE = 7'b01_00000;
  localparam PIO_RX_MEM_WR64_FMT_TYPE = 7'b11_00000;
  localparam PIO_RX_IO_RD32_FMT_TYPE  = 7'b00_00010;
  localparam PIO_RX_IO_WR32_FMT_TYPE  = 7'b10_00010;

  localparam PIO_RX_RST_STATE            = 8'b00000000;
  localparam PIO_RX_MEM_RD32_DW1DW2      = 8'b00000001;
  localparam PIO_RX_MEM_WR32_DW1DW2      = 8'b00000010;
  localparam PIO_RX_MEM_RD64_DW1DW2      = 8'b00000100;
  localparam PIO_RX_MEM_WR64_DW1DW2      = 8'b00001000;
  localparam PIO_RX_MEM_WR64_DW3         = 8'b00010000;
  localparam PIO_RX_WAIT_STATE           = 8'b00100000;
  localparam PIO_RX_IO_WR_DW1DW2         = 8'b01000000;
  localparam PIO_RX_IO_MEM_WR_WAIT_STATE = 8'b10000000;


  // Local Registers

  reg [7:0]          state;
  reg [7:0]          tlp_type;

  wire               io_bar_hit_n;
  wire               mem32_bar_hit_n;
  wire               mem64_bar_hit_n;
  wire               erom_bar_hit_n;

  reg [1:0]          region_select;

  generate
    if (C_DATA_WIDTH == 64) begin : pio_rx_sm_64
      wire               sop;                   // Start of packet
      reg                in_packet_q;

      // Generate a signal that indicates if we are currently receiving a packet.
      // This value is one clock cycle delayed from what is actually on the AXIS
      // data bus.
      always@(posedge clk)
      begin
        if(!rst_n)
          in_packet_q <= #   TCQ 1'b0;
        else if (m_axis_rx_tvalid && m_axis_rx_tready && m_axis_rx_tlast)
          in_packet_q <= #   TCQ 1'b0;
        else if (sop && m_axis_rx_tready)
          in_packet_q <= #   TCQ 1'b1;

      end

      assign sop = !in_packet_q && m_axis_rx_tvalid;

      always @ ( posedge clk ) begin

        if (!rst_n )
        begin

          m_axis_rx_tready <= #TCQ 1'b0;

          req_compl    <= #TCQ 1'b0;
          req_compl_wd <= #TCQ 1'b1;

          req_tc       <= #TCQ 3'b0;
          req_td       <= #TCQ 1'b0;
          req_ep       <= #TCQ 1'b0;
          req_attr     <= #TCQ 2'b0;
          req_len      <= #TCQ 10'b0;
          req_rid      <= #TCQ 16'b0;
          req_tag      <= #TCQ 8'b0;
          req_be       <= #TCQ 8'b0;
          req_addr     <= #TCQ 13'b0;
          req_addr32   <= #TCQ 29'b0;

          wr_be        <= #TCQ 8'b0;
          wr_addr      <= #TCQ 11'b0;
          wr_data      <= #TCQ 32'b0;
          wr_en        <= #TCQ 1'b0;

          state        <= #TCQ PIO_RX_RST_STATE;
          tlp_type     <= #TCQ 8'b0;

        end
        else
        begin

          wr_en        <= #TCQ 1'b0;
          req_compl    <= #TCQ 1'b0;

          case (state)

            PIO_RX_RST_STATE : begin

              m_axis_rx_tready <= #TCQ 1'b1;
              req_compl_wd     <= #TCQ 1'b1;


              if (sop)
              begin

                case (m_axis_rx_tdata[30:24])

                  PIO_RX_MEM_RD32_FMT_TYPE : begin

                    tlp_type     <= #TCQ m_axis_rx_tdata[31:24];
                    req_len      <= #TCQ m_axis_rx_tdata[9:0];
                    m_axis_rx_tready <= #TCQ 1'b0;


                    if (m_axis_rx_tdata[9:0] == 10'b1)
                    begin

                      req_tc     <= #TCQ m_axis_rx_tdata[22:20];
                      req_td     <= #TCQ m_axis_rx_tdata[15];
                      req_ep     <= #TCQ m_axis_rx_tdata[14];
                      req_attr   <= #TCQ m_axis_rx_tdata[13:12];
                      req_len    <= #TCQ m_axis_rx_tdata[9:0];
                      req_rid    <= #TCQ m_axis_rx_tdata[63:48];
                      req_tag    <= #TCQ m_axis_rx_tdata[47:40];
                      req_be     <= #TCQ m_axis_rx_tdata[39:32];
                      state      <= #TCQ PIO_RX_MEM_RD32_DW1DW2;

                    end // if (m_axis_rx_tdata[9:0] == 10'b1)
                    else
                    begin

                      state        <= #TCQ PIO_RX_RST_STATE;

                    end // if !(m_axis_rx_tdata[9:0] == 10'b1)

                  end // PIO_RX_MEM_RD32_FMT_TYPE

                  PIO_RX_MEM_WR32_FMT_TYPE : begin

                    tlp_type     <= #TCQ m_axis_rx_tdata[31:24];
                    req_len      <= #TCQ m_axis_rx_tdata[9:0];
                    m_axis_rx_tready <= #TCQ 1'b0;

                    if (m_axis_rx_tdata[9:0] == 10'b1)
                    begin

                      wr_be      <= #TCQ m_axis_rx_tdata[39:32];
                      state      <= #TCQ PIO_RX_MEM_WR32_DW1DW2;

                    end // if (m_axis_rx_tdata[9:0] == 10'b1)
                    else
                    begin

                      state      <= #TCQ PIO_RX_RST_STATE;

                    end // if !(m_axis_rx_tdata[9:0] == 10'b1)

                  end // PIO_RX_MEM_WR32_FMT_TYPE

                  PIO_RX_MEM_RD64_FMT_TYPE : begin

                    tlp_type     <= #TCQ m_axis_rx_tdata[31:24];
                    req_len      <= #TCQ m_axis_rx_tdata[9:0];
                    m_axis_rx_tready <= #TCQ 1'b0;

                    if (m_axis_rx_tdata[9:0] == 10'b1)
                    begin

                      req_tc     <= #TCQ m_axis_rx_tdata[22:20];
                      req_td     <= #TCQ m_axis_rx_tdata[15];
                      req_ep     <= #TCQ m_axis_rx_tdata[14];
                      req_attr   <= #TCQ m_axis_rx_tdata[13:12];
                      req_len    <= #TCQ m_axis_rx_tdata[9:0];
                      req_rid    <= #TCQ m_axis_rx_tdata[63:48];
                      req_tag    <= #TCQ m_axis_rx_tdata[47:40];
                      req_be     <= #TCQ m_axis_rx_tdata[39:32];
                      state        <= #TCQ PIO_RX_MEM_RD64_DW1DW2;

                    end // if (m_axis_rx_tdata[9:0] == 10'b1)
                    else
                    begin

                      state      <= #TCQ PIO_RX_RST_STATE;

                    end // if !(m_axis_rx_tdata[9:0] == 10'b1)

                  end // PIO_RX_MEM_RD64_FMT_TYPE

                  PIO_RX_MEM_WR64_FMT_TYPE : begin

                    tlp_type     <= #TCQ m_axis_rx_tdata[31:24];
                    req_len      <= #TCQ m_axis_rx_tdata[9:0];

                    if (m_axis_rx_tdata[9:0] == 10'b1) begin

                      wr_be      <= #TCQ m_axis_rx_tdata[39:32];
                      state      <= #TCQ PIO_RX_MEM_WR64_DW1DW2;

                    end // if (m_axis_rx_tdata[9:0] == 10'b1)
                    else
                    begin

                      state      <= #TCQ PIO_RX_RST_STATE;

                    end // if !(m_axis_rx_tdata[9:0] == 10'b1)

                  end // PIO_RX_MEM_WR64_FMT_TYPE


                  PIO_RX_IO_RD32_FMT_TYPE : begin

                    tlp_type     <= #TCQ m_axis_rx_tdata[31:24];
                    req_len      <= #TCQ m_axis_rx_tdata[9:0];
                    m_axis_rx_tready <= #TCQ 1'b0;


                    if (m_axis_rx_tdata[9:0] == 10'b1)
                    begin

                      req_tc     <= #TCQ m_axis_rx_tdata[22:20];
                      req_td     <= #TCQ m_axis_rx_tdata[15];
                      req_ep     <= #TCQ m_axis_rx_tdata[14];
                      req_attr   <= #TCQ m_axis_rx_tdata[13:12];
                      req_len    <= #TCQ m_axis_rx_tdata[9:0];
                      req_rid    <= #TCQ m_axis_rx_tdata[63:48];
                      req_tag    <= #TCQ m_axis_rx_tdata[47:40];
                      req_be     <= #TCQ m_axis_rx_tdata[39:32];
                      state      <= #TCQ PIO_RX_MEM_RD32_DW1DW2;

                    end // if (m_axis_rx_tdata[9:0] == 10'b1)
                    else
                    begin

                      state      <= #TCQ PIO_RX_RST_STATE;

                    end // if !(m_axis_rx_tdata[9:0] == 10'b1)

                  end // PIO_RX_IO_RD32_FMT_TYPE

                  PIO_RX_IO_WR32_FMT_TYPE : begin

                    tlp_type     <= #TCQ m_axis_rx_tdata[31:24];
                    req_len      <= #TCQ m_axis_rx_tdata[9:0];
                    m_axis_rx_tready <= #TCQ 1'b0;

                    if (m_axis_rx_tdata[9:0] == 10'b1)
                    begin

                      req_tc     <= #TCQ m_axis_rx_tdata[22:20];
                      req_td     <= #TCQ m_axis_rx_tdata[15];
                      req_ep     <= #TCQ m_axis_rx_tdata[14];
                      req_attr   <= #TCQ m_axis_rx_tdata[13:12];
                      req_len    <= #TCQ m_axis_rx_tdata[9:0];
                      req_rid    <= #TCQ m_axis_rx_tdata[63:48];
                      req_tag    <= #TCQ m_axis_rx_tdata[47:40];
                      req_be     <= #TCQ m_axis_rx_tdata[39:32];
                      wr_be      <= #TCQ m_axis_rx_tdata[39:32];
                      state      <= #TCQ PIO_RX_IO_WR_DW1DW2;

                    end //if (m_axis_rx_tdata[9:0] == 10'b1)
                    else
                    begin

                      state        <= #TCQ PIO_RX_RST_STATE;

                    end //if !(m_axis_rx_tdata[9:0] == 10'b1)

                  end // PIO_RX_IO_WR32_FMT_TYPE


                  default : begin // other TLPs

                    state        <= #TCQ PIO_RX_RST_STATE;

                  end // default

                endcase

              end // if (sop)
              else
                  state <= #TCQ PIO_RX_RST_STATE;

            end // PIO_RX_RST_STATE

            PIO_RX_MEM_RD32_DW1DW2 : begin

              if (m_axis_rx_tvalid)
              begin

                m_axis_rx_tready <= #TCQ 1'b0;
                req_addr     <= #TCQ {region_select[1:0],m_axis_rx_tdata[10:2], 2'b00};
                req_addr32   <= #TCQ m_axis_rx_tdata[31:2];
                req_compl    <= #TCQ 1'b1;
                req_compl_wd <= #TCQ 1'b1;
                state        <= #TCQ PIO_RX_WAIT_STATE;

              end // if (m_axis_rx_tvalid)
              else
                state        <= #TCQ PIO_RX_MEM_RD32_DW1DW2;

            end // PIO_RX_MEM_RD32_DW1DW2


            PIO_RX_MEM_WR32_DW1DW2 : begin

              if (m_axis_rx_tvalid)
              begin

                wr_data      <= #TCQ m_axis_rx_tdata[63:32];
                wr_en        <= #TCQ 1'b1;
                m_axis_rx_tready <= #TCQ 1'b0;
                wr_addr      <= #TCQ {region_select[1:0],m_axis_rx_tdata[10:2]};
                state        <= #TCQ  PIO_RX_WAIT_STATE;

              end // if (m_axis_rx_tvalid)
              else
                state        <= #TCQ PIO_RX_MEM_WR32_DW1DW2;

            end // PIO_RX_MEM_WR32_DW1DW2


            PIO_RX_MEM_RD64_DW1DW2 : begin

              if (m_axis_rx_tvalid)
              begin

                req_addr     <= #TCQ {region_select[1:0],m_axis_rx_tdata[42:34], 2'b00};
                req_addr32   <= #TCQ m_axis_rx_tdata[63:34];
                req_compl    <= #TCQ 1'b1;
                req_compl_wd <= #TCQ 1'b1;
                m_axis_rx_tready <= #TCQ 1'b0;
                state        <= #TCQ PIO_RX_WAIT_STATE;

              end // if (m_axis_rx_tvalid)
              else
                state        <= #TCQ PIO_RX_MEM_RD64_DW1DW2;

            end // PIO_RX_MEM_RD64_DW1DW2


            PIO_RX_MEM_WR64_DW1DW2 : begin

              if (m_axis_rx_tvalid)
              begin

                m_axis_rx_tready <= #TCQ 1'b0;
                wr_addr        <= #TCQ {region_select[1:0],m_axis_rx_tdata[42:34]};
                state          <= #TCQ  PIO_RX_MEM_WR64_DW3;

              end // if (m_axis_rx_tvalid)
              else
                state          <= #TCQ PIO_RX_MEM_WR64_DW1DW2;

            end // PIO_RX_MEM_WR64_DW1DW2


            PIO_RX_MEM_WR64_DW3 : begin

              if (m_axis_rx_tvalid)
              begin

                wr_data      <= #TCQ m_axis_rx_tdata[31:0];
                wr_en        <= #TCQ 1'b1;
                m_axis_rx_tready <= #TCQ 1'b0;
                state        <= #TCQ PIO_RX_WAIT_STATE;

              end // if (m_axis_rx_tvalid)
              else
                 state        <= #TCQ PIO_RX_MEM_WR64_DW3;

            end // PIO_RX_MEM_WR64_DW3


            PIO_RX_IO_WR_DW1DW2 : begin

              if (m_axis_rx_tvalid)
              begin

                wr_data         <= #TCQ m_axis_rx_tdata[63:32];
                wr_en           <= #TCQ 1'b1;
                m_axis_rx_tready  <= #TCQ 1'b0;
                wr_addr         <= #TCQ {region_select[1:0],m_axis_rx_tdata[10:2]};
                req_compl       <= #TCQ 1'b1;
                req_compl_wd    <= #TCQ 1'b0;
                state             <= #TCQ  PIO_RX_WAIT_STATE;

              end // if (m_axis_rx_tvalid)
              else
                state             <= #TCQ PIO_RX_IO_WR_DW1DW2;
            end // PIO_RX_IO_WR_DW1DW2

            PIO_RX_WAIT_STATE : begin

              wr_en      <= #TCQ 1'b0;
              req_compl  <= #TCQ 1'b0;

              if ((tlp_type == PIO_RX_MEM_WR32_FMT_TYPE) && (!wr_busy))
              begin

                m_axis_rx_tready <= #TCQ 1'b1;
                state        <= #TCQ PIO_RX_RST_STATE;

              end // if ((tlp_type == PIO_RX_MEM_WR32_FMT_TYPE) && (!wr_busy))
              else if ((tlp_type == PIO_RX_IO_WR32_FMT_TYPE) && (!wr_busy))
              begin

                m_axis_rx_tready <= #TCQ 1'b1;
                state        <= #TCQ PIO_RX_RST_STATE;

              end // if ((tlp_type == PIO_RX_IO_WR32_FMT_TYPE) && (!wr_busy))
              else if ((tlp_type == PIO_RX_MEM_WR64_FMT_TYPE) && (!wr_busy))
              begin

                m_axis_rx_tready <= #TCQ 1'b1;
                state        <= #TCQ PIO_RX_RST_STATE;

              end // if ((tlp_type == PIO_RX_MEM_WR64_FMT_TYPE) && (!wr_busy))
              else if ((tlp_type == PIO_RX_MEM_RD32_FMT_TYPE) && (compl_done))
              begin

                m_axis_rx_tready <= #TCQ 1'b1;
                state        <= #TCQ PIO_RX_RST_STATE;

              end // if ((tlp_type == PIO_RX_MEM_RD32_FMT_TYPE) && (compl_done))
              else if ((tlp_type == PIO_RX_IO_RD32_FMT_TYPE) && (compl_done))
              begin

                m_axis_rx_tready <= #TCQ 1'b1;
                state        <= #TCQ PIO_RX_RST_STATE;

              end // if ((tlp_type == PIO_RX_IO_RD32_FMT_TYPE) && (compl_done))
              else if ((tlp_type == PIO_RX_MEM_RD64_FMT_TYPE) && (compl_done))
              begin

                m_axis_rx_tready <= #TCQ 1'b1;
                state        <= #TCQ PIO_RX_RST_STATE;

              end // if ((tlp_type == PIO_RX_MEM_RD64_FMT_TYPE) && (compl_done))
              else
                state        <= #TCQ PIO_RX_WAIT_STATE;

            end // PIO_RX_WAIT_STATE

            default : begin
              // default case stmt
              state        <= #TCQ PIO_RX_RST_STATE;
            end // default

          endcase

        end

      end
    end
    else if (C_DATA_WIDTH == 128) begin : pio_rx_sm_128
      // Define where the start of packet happens.  Remember that PCIe dwords
      // start on the right and get filled in to the left of the 128-bit data
      // bus.
      // Start of packet can only happen on byte 0 (right most byte) or on
      // byte 8 (middle byte).
      wire               sof_present = m_axis_rx_tuser[14];
      wire               sof_right = !m_axis_rx_tuser[13] && sof_present;
      wire               sof_mid = m_axis_rx_tuser[13] && sof_present;



      always @ ( posedge clk ) begin
        if (!rst_n )
        begin
          m_axis_rx_tready <= #TCQ 1'b0;
          req_compl    <= #TCQ 1'b0;
          req_compl_wd <= #TCQ 1'b1;
          req_tc       <= #TCQ 3'b0;
          req_td       <= #TCQ 1'b0;
          req_ep       <= #TCQ 1'b0;
          req_attr     <= #TCQ 2'b0;
          req_len      <= #TCQ 10'b0;
          req_rid      <= #TCQ 16'b0;
          req_tag      <= #TCQ 8'b0;
          req_be       <= #TCQ 8'b0;
          req_addr     <= #TCQ 13'b0;
          req_addr32   <= #TCQ 29'b0;
          wr_be        <= #TCQ 8'b0;
          wr_addr      <= #TCQ 11'b0;
          wr_data      <= #TCQ 32'b0;
          wr_en        <= #TCQ 1'b0;

          state        <= #TCQ PIO_RX_RST_STATE;
          tlp_type     <= #TCQ 8'b0;
        end // if (!rst_n )
        else
        begin
          wr_en        <= #TCQ 1'b0;
          req_compl    <= #TCQ 1'b0;

          case (state)

            PIO_RX_RST_STATE : begin

              m_axis_rx_tready  <= #TCQ 1'b1;
              state             <= #TCQ PIO_RX_RST_STATE;
              req_compl_wd      <= #TCQ 1'b1;


              // Packet starts in the middle of the 128-bit bus.
              if ((m_axis_rx_tvalid) && (m_axis_rx_tready))
              begin
                if (sof_mid)
                begin
                  tlp_type          <= #TCQ m_axis_rx_tdata[95:88];
                  req_len           <= #TCQ m_axis_rx_tdata[73:64];
                  m_axis_rx_tready  <= #TCQ 1'b0;

                  // Evaluate packet type
                  case (m_axis_rx_tdata[94:88])

                    PIO_RX_MEM_RD32_FMT_TYPE : begin
                      if (m_axis_rx_tdata[73:64] == 10'b1)
                      begin
                        req_tc       <= #TCQ m_axis_rx_tdata[86:84];
                        req_td       <= #TCQ m_axis_rx_tdata[79];
                        req_ep       <= #TCQ m_axis_rx_tdata[78];
                        req_attr     <= #TCQ m_axis_rx_tdata[77:76];
                        req_len      <= #TCQ m_axis_rx_tdata[73:64];
                        req_rid      <= #TCQ m_axis_rx_tdata[127:112];
                        req_tag      <= #TCQ m_axis_rx_tdata[111:104];
                        req_be       <= #TCQ m_axis_rx_tdata[103:96];
                        state        <= #TCQ PIO_RX_MEM_RD32_DW1DW2;
                      end // if (m_axis_rx_tdata[73:64] == 10'b1)
                      else
                      begin
                        state        <= #TCQ PIO_RX_RST_STATE;
                      end // if !(m_axis_rx_tdata[73:64] == 10'b1)
                    end // PIO_RX_MEM_RD32_FMT_TYPE

                    PIO_RX_MEM_WR32_FMT_TYPE : begin
                      if (m_axis_rx_tdata[73:64] == 10'b1)
                      begin
                        wr_be        <= #TCQ m_axis_rx_tdata[103:96];
                        state        <= #TCQ PIO_RX_MEM_WR32_DW1DW2;
                      end // if (m_axis_rx_tdata[73:64] == 10'b1)
                      else
                      begin
                        state        <= #TCQ PIO_RX_RST_STATE;
                      end // if !(m_axis_rx_tdata[73:64] == 10'b1)
                    end // PIO_RX_MEM_WR32_FMT_TYPE

                    PIO_RX_MEM_RD64_FMT_TYPE : begin
                      if (m_axis_rx_tdata[73:64] == 10'b1)
                      begin
                        req_tc       <= #TCQ m_axis_rx_tdata[86:84];
                        req_td       <= #TCQ m_axis_rx_tdata[79];
                        req_ep       <= #TCQ m_axis_rx_tdata[78];
                        req_attr     <= #TCQ m_axis_rx_tdata[77:76];
                        req_len      <= #TCQ m_axis_rx_tdata[73:64];
                        req_rid      <= #TCQ m_axis_rx_tdata[127:112];
                        req_tag      <= #TCQ m_axis_rx_tdata[111:104];
                        req_be       <= #TCQ m_axis_rx_tdata[103:96];
                        state        <= #TCQ PIO_RX_MEM_RD64_DW1DW2;
                      end // if !(m_axis_rx_tdata[73:64] == 10'b1)
                      else
                      begin
                        state        <= #TCQ PIO_RX_RST_STATE;
                      end // if !(m_axis_rx_tdata[73:64] == 10'b1)
                    end // PIO_RX_MEM_RD64_FMT_TYPE

                    PIO_RX_MEM_WR64_FMT_TYPE : begin
                      if (m_axis_rx_tdata[73:64] == 10'b1)
                      begin
                        wr_be        <= #TCQ m_axis_rx_tdata[103:96];
                        state        <= #TCQ PIO_RX_MEM_WR64_DW1DW2;
                      end // if (m_axis_rx_tdata[73:64] == 10'b1)
                      else
                      begin
                        state        <= #TCQ PIO_RX_RST_STATE;
                      end // if !(m_axis_rx_tdata[73:64] == 10'b1)
                    end // PIO_RX_MEM_WR64_FMT_TYPE

                    PIO_RX_IO_RD32_FMT_TYPE : begin
                      if (m_axis_rx_tdata[73:64] == 10'b1)
                      begin
                        req_tc       <= #TCQ m_axis_rx_tdata[86:84];
                        req_td       <= #TCQ m_axis_rx_tdata[79];
                        req_ep       <= #TCQ m_axis_rx_tdata[78];
                        req_attr     <= #TCQ m_axis_rx_tdata[77:76];
                        req_len      <= #TCQ m_axis_rx_tdata[73:64];
                        req_rid      <= #TCQ m_axis_rx_tdata[127:112];
                        req_tag      <= #TCQ m_axis_rx_tdata[111:104];
                        req_be       <= #TCQ m_axis_rx_tdata[103:96];
                        state        <= #TCQ PIO_RX_MEM_RD32_DW1DW2;
                      end // if (m_axis_rx_tdata[73:64] == 10'b1)
                      else
                      begin
                        state        <= #TCQ PIO_RX_RST_STATE;
                      end // if !(m_axis_rx_tdata[73:64] == 10'b1)
                    end // PIO_RX_IO_RD32_FMT_TYPE

                    PIO_RX_IO_WR32_FMT_TYPE : begin
                      if (m_axis_rx_tdata[73:64] == 10'b1)
                      begin
                        req_tc       <= #TCQ m_axis_rx_tdata[86:84];
                        req_td       <= #TCQ m_axis_rx_tdata[79];
                        req_ep       <= #TCQ m_axis_rx_tdata[78];
                        req_attr     <= #TCQ m_axis_rx_tdata[77:76];
                        req_len      <= #TCQ m_axis_rx_tdata[73:64];
                        req_rid      <= #TCQ m_axis_rx_tdata[127:112];
                        req_tag      <= #TCQ m_axis_rx_tdata[111:104];

                        wr_be        <= #TCQ m_axis_rx_tdata[103:96];
                        state        <= #TCQ PIO_RX_MEM_WR32_DW1DW2;
                      end // if (m_axis_rx_tdata[73:64] == 10'b1)
                      else
                      begin
                        state        <= #TCQ PIO_RX_RST_STATE;
                      end // if !(m_axis_rx_tdata[73:64] == 10'b1)
                    end // PIO_RX_IO_WR32_FMT_TYPE

                    default : begin // other TLPs
                      state        <= #TCQ PIO_RX_RST_STATE;
                    end // default
                  endcase // case (m_axis_rx_tdata[94:88])

                // Packet starts on the right of the data bus.  Remember, packets start
                // on the right and are filled to the left.  The data-bus is filled 32-bits
                // (one Dword) at time.

                end
                else if (sof_right)
                begin
                  tlp_type        <= #TCQ m_axis_rx_tdata[31:24];
                  req_len         <= #TCQ m_axis_rx_tdata[9:0];
                  m_axis_rx_tready  <= #TCQ 1'b0;

                  case (m_axis_rx_tdata[30:24])
                    PIO_RX_MEM_RD32_FMT_TYPE : begin
                      if (m_axis_rx_tdata[9:0] == 10'b1)
                      begin
                        req_tc       <= #TCQ m_axis_rx_tdata[22:20];
                        req_td       <= #TCQ m_axis_rx_tdata[15];
                        req_ep       <= #TCQ m_axis_rx_tdata[14];
                        req_attr     <= #TCQ m_axis_rx_tdata[13:12];
                        req_len      <= #TCQ m_axis_rx_tdata[9:0];
                        req_rid      <= #TCQ m_axis_rx_tdata[63:48];
                        req_tag      <= #TCQ m_axis_rx_tdata[47:40];
                        req_be       <= #TCQ m_axis_rx_tdata[39:32];

                        //lower qw
                        req_addr     <= #TCQ {region_select[1:0],
                                                 m_axis_rx_tdata[74:66],2'b00};
                        req_addr32   <= #TCQ m_axis_rx_tdata[95:66];
                        req_compl    <= #TCQ 1'b1;
                        req_compl_wd <= #TCQ 1'b1;
                        state        <= #TCQ PIO_RX_WAIT_STATE;
                      end // if (m_axis_rx_tdata[9:0] == 10'b1)
                      else
                      begin
                        state        <= #TCQ PIO_RX_RST_STATE;
                      end // if (m_axis_rx_tdata[9:0] == 10'b1)
                    end // PIO_RX_MEM_RD32_FMT_TYPE

                    PIO_RX_MEM_WR32_FMT_TYPE : begin
                      if (m_axis_rx_tdata[9:0] == 10'b1)
                      begin
                        wr_be        <= #TCQ m_axis_rx_tdata[39:32];

                        //lower qw
                        wr_data      <= #TCQ m_axis_rx_tdata[127:96];
                        wr_en        <= #TCQ 1'b1;
                        wr_addr      <= #TCQ {region_select[1:0], m_axis_rx_tdata[74:66]};
                        wr_en        <= #TCQ 1'b1;
                        state        <= #TCQ PIO_RX_WAIT_STATE;
                      end // if (m_axis_rx_tdata[9:0] == 10'b1)
                      else
                      begin
                          state        <= #TCQ PIO_RX_RST_STATE;
                      end // if !(m_axis_rx_tdata[9:0] == 10'b1)
                    end // PIO_RX_MEM_WR32_FMT_TYPE


                    PIO_RX_MEM_RD64_FMT_TYPE : begin
                      if (m_axis_rx_tdata[9:0] == 10'b1)
                      begin
                        req_tc       <= #TCQ m_axis_rx_tdata[22:20];
                        req_td       <= #TCQ m_axis_rx_tdata[15];
                        req_ep       <= #TCQ m_axis_rx_tdata[14];
                        req_attr     <= #TCQ m_axis_rx_tdata[13:12];
                        req_len      <= #TCQ m_axis_rx_tdata[9:0];
                        req_rid      <= #TCQ m_axis_rx_tdata[63:48];
                        req_tag      <= #TCQ m_axis_rx_tdata[47:40];
                        req_be       <= #TCQ m_axis_rx_tdata[39:32];

                        //lower qw
                        // Upper 32-bits of 64-bit address not used, but would be captured
                        // in this state if used.  Upper 32 address bits are on
                        //m_axis_rx_tdata[127:96]
                        req_addr     <= #TCQ {region_select[1:0], m_axis_rx_tdata[74:66],2'b00};
                        req_addr32   <= #TCQ m_axis_rx_tdata[95:66];
                        req_compl    <= #TCQ 1'b1;
                        req_compl_wd <= #TCQ 1'b1;
                        state        <= #TCQ PIO_RX_WAIT_STATE;
                      end // if (m_axis_rx_tdata[9:0] == 10'b1)
                      else
                      begin
                        state        <= #TCQ PIO_RX_RST_STATE;
                      end // if !(m_axis_rx_tdata[9:0] == 10'b1)
                    end // PIO_RX_MEM_RD64_FMT_TYPE

                    PIO_RX_MEM_WR64_FMT_TYPE : begin
                      if (m_axis_rx_tdata[9:0] == 10'b1)
                      begin
                        wr_be        <= #TCQ m_axis_rx_tdata[39:32];

                        // lower qw
                        wr_addr      <= #TCQ {region_select[1:0], m_axis_rx_tdata[74:66]};
                        state        <= #TCQ PIO_RX_MEM_WR64_DW3;
                      end // if (m_axis_rx_tdata[9:0] == 10'b1)
                      else
                      begin
                        state        <= #TCQ PIO_RX_WAIT_STATE;
                      end // if !(m_axis_rx_tdata[9:0] == 10'b1)
                    end // PIO_RX_MEM_WR64_FMT_TYPE


                    PIO_RX_IO_RD32_FMT_TYPE : begin
                      if (m_axis_rx_tdata[9:0] == 10'b1)
                      begin
                        req_tc       <= #TCQ m_axis_rx_tdata[22:20];
                        req_td       <= #TCQ m_axis_rx_tdata[15];
                        req_ep       <= #TCQ m_axis_rx_tdata[14];
                        req_attr     <= #TCQ m_axis_rx_tdata[13:12];
                        req_len      <= #TCQ m_axis_rx_tdata[9:0];
                        req_rid      <= #TCQ m_axis_rx_tdata[63:48];
                        req_tag      <= #TCQ m_axis_rx_tdata[47:40];
                        req_be       <= #TCQ m_axis_rx_tdata[39:32];

                        //lower qw
                        req_addr     <= #TCQ {region_select[1:0], m_axis_rx_tdata[74:66],2'b00};
                        req_addr32   <= #TCQ m_axis_rx_tdata[95:66];
                        req_compl    <= #TCQ 1'b1;
                        req_compl_wd <= #TCQ 1'b1;
                        state        <= #TCQ PIO_RX_WAIT_STATE;
                      end // if (m_axis_rx_tdata[9:0] == 10'b1)
                      else
                      begin
                        state        <= #TCQ PIO_RX_RST_STATE;
                      end // if !(m_axis_rx_tdata[9:0] == 10'b1)
                    end // PIO_RX_IO_RD32_FMT_TYPE


                    PIO_RX_IO_WR32_FMT_TYPE : begin
                      if (m_axis_rx_tdata[9:0] == 10'b1)
                      begin
                        wr_be        <= #TCQ m_axis_rx_tdata[39:32];

                        //lower qw
                        req_tc       <= #TCQ m_axis_rx_tdata[22:20];
                        req_td       <= #TCQ m_axis_rx_tdata[15];
                        req_ep       <= #TCQ m_axis_rx_tdata[14];
                        req_attr     <= #TCQ m_axis_rx_tdata[13:12];
                        req_len      <= #TCQ m_axis_rx_tdata[9:0];
                        req_rid      <= #TCQ m_axis_rx_tdata[63:48];
                        req_tag      <= #TCQ m_axis_rx_tdata[47:40];

                        wr_data      <= #TCQ m_axis_rx_tdata[127:96];
                        wr_en        <= #TCQ 1'b1;
                        wr_addr      <= #TCQ {region_select[1:0], m_axis_rx_tdata[74:66]};
                        wr_en        <= #TCQ 1'b1;
                        req_compl    <= #TCQ 1'b1;
                        req_compl_wd <= #TCQ 1'b0;
                        state        <= #TCQ PIO_RX_WAIT_STATE;
                      end // if (m_axis_rx_tdata[9:0] == 10'b1)
                      else
                      begin
                        state        <= #TCQ PIO_RX_RST_STATE;
                      end // if !(m_axis_rx_tdata[9:0] == 10'b1)
                    end // PIO_RX_IO_WR32_FMT_TYPE

                  endcase // case (m_axis_rx_tdata[30:24])

                end // if (sof_right)
              end
              else // not a start of packet
                state <= #TCQ PIO_RX_RST_STATE;
            end //PIO_RX_RST_STATE

            PIO_RX_MEM_WR64_DW3 : begin
              if (m_axis_rx_tvalid)
              begin
                wr_data        <= #TCQ m_axis_rx_tdata[31:0];
                wr_en          <= #TCQ 1'b1;
                state          <= #TCQ PIO_RX_WAIT_STATE;
              end // if (m_axis_rx_tvalid)
              else
              begin
                state          <= #TCQ PIO_RX_MEM_WR64_DW3;
              end // if !(m_axis_rx_tvalid)
            end // PIO_RX_MEM_WR64_DW3

            PIO_RX_MEM_RD32_DW1DW2 : begin
              if (m_axis_rx_tvalid)
              begin
                m_axis_rx_tready  <= #TCQ 1'b0;
                req_addr          <= #TCQ {region_select[1:0], m_axis_rx_tdata[10:2], 2'b00};
                req_addr32        <= #TCQ m_axis_rx_tdata[31:2];
                req_compl         <= #TCQ 1'b1;
                req_compl_wd      <= #TCQ 1'b1;
                state             <= #TCQ PIO_RX_WAIT_STATE;
              end // if (m_axis_rx_tvalid)
              else
              begin
                state             <= #TCQ PIO_RX_MEM_RD32_DW1DW2;
              end // if !(m_axis_rx_tvalid)
            end // PIO_RX_MEM_RD32_DW1DW2


            PIO_RX_MEM_WR32_DW1DW2 : begin
              if (m_axis_rx_tvalid)
              begin
                wr_data           <= #TCQ m_axis_rx_tdata[63:32];
                wr_en             <= #TCQ 1'b1;
                m_axis_rx_tready  <= #TCQ 1'b0;
                wr_addr           <= #TCQ {region_select[1:0], m_axis_rx_tdata[10:2]};
                state             <= #TCQ  PIO_RX_WAIT_STATE;
              end // if (m_axis_rx_tvalid)
              else
              begin
                state             <= #TCQ PIO_RX_MEM_WR32_DW1DW2;
              end // if !(m_axis_rx_tvalid)
            end // PIO_RX_MEM_WR32_DW1DW2


            PIO_RX_IO_WR_DW1DW2 : begin
              if (m_axis_rx_tvalid)
              begin
                wr_data           <= #TCQ m_axis_rx_tdata[63:32];
                wr_en             <= #TCQ 1'b1;
                m_axis_rx_tready  <= #TCQ 1'b0;
                wr_addr           <= #TCQ {region_select[1:0], m_axis_rx_tdata[10:2]};
                req_compl         <= #TCQ 1'b1;
                req_compl_wd      <= #TCQ 1'b0;
                state             <= #TCQ  PIO_RX_WAIT_STATE;
              end // if (m_axis_rx_tvalid)
              else
              begin
                state             <= #TCQ PIO_RX_MEM_WR32_DW1DW2;
              end // if !(m_axis_rx_tvalid)
            end // PIO_RX_IO_WR_DW1DW2


            PIO_RX_MEM_RD64_DW1DW2 : begin
              if (m_axis_rx_tvalid)
              begin
                req_addr         <= #TCQ {region_select[1:0], m_axis_rx_tdata[10:2], 2'b00};
                req_addr32       <= #TCQ m_axis_rx_tdata[31:2];
                req_compl        <= #TCQ 1'b1;
                req_compl_wd     <= #TCQ 1'b1;
                m_axis_rx_tready <= #TCQ 1'b0;
                state            <= #TCQ PIO_RX_WAIT_STATE;
              end // if (m_axis_rx_tvalid)
              else
              begin
                state        <= #TCQ PIO_RX_MEM_RD64_DW1DW2;
              end // if !(m_axis_rx_tvalid)
            end // PIO_RX_MEM_RD64_DW1DW2


            PIO_RX_MEM_WR64_DW1DW2 : begin
              if (m_axis_rx_tvalid)
              begin
                m_axis_rx_tready  <= #TCQ 1'b0;
                wr_addr           <= #TCQ {region_select[1:0], m_axis_rx_tdata[10:2]};
                // lower QW
                wr_data           <= #TCQ m_axis_rx_tdata[95:64];
                wr_en             <= #TCQ 1'b1;
                state             <= #TCQ PIO_RX_WAIT_STATE;
              end // if (m_axis_rx_tvalid)
              else
              begin
                state            <= #TCQ PIO_RX_MEM_WR64_DW1DW2;
              end // if (m_axis_rx_tvalid)
            end // PIO_RX_MEM_WR64_DW1DW2


            PIO_RX_WAIT_STATE : begin

              wr_en      <= #TCQ 1'b0;
              req_compl  <= #TCQ 1'b0;

              if ((tlp_type == PIO_RX_MEM_WR32_FMT_TYPE) &&(!wr_busy))
              begin

                m_axis_rx_tready  <= #TCQ 1'b1;
                state             <= #TCQ PIO_RX_RST_STATE;

              end // if ((tlp_type == PIO_RX_MEM_WR32_FMT_TYPE) &&(!wr_busy))
              else if ((tlp_type == PIO_RX_IO_WR32_FMT_TYPE) && (!wr_busy))
              begin

                m_axis_rx_tready <= #TCQ 1'b1;
                state        <= #TCQ PIO_RX_RST_STATE;

              end // if ((tlp_type == PIO_RX_IO_WR32_FMT_TYPE) && (!compl_done))
              else if ((tlp_type == PIO_RX_MEM_WR64_FMT_TYPE) && (!wr_busy))
              begin

                m_axis_rx_tready <= #TCQ 1'b1;
                state        <= #TCQ PIO_RX_RST_STATE;

              end // if ((tlp_type == PIO_RX_MEM_WR64_FMT_TYPE) && (!wr_busy))
              else if ((tlp_type == PIO_RX_MEM_RD32_FMT_TYPE) && (compl_done))
              begin

                m_axis_rx_tready <= #TCQ 1'b1;
                state        <= #TCQ PIO_RX_RST_STATE;

              end // if ((tlp_type == PIO_RX_MEM_RD32_FMT_TYPE) && (compl_done))
              else if ((tlp_type == PIO_RX_IO_RD32_FMT_TYPE) && (compl_done))
              begin

                m_axis_rx_tready <= #TCQ 1'b1;
                state        <= #TCQ PIO_RX_RST_STATE;

              end // if ((tlp_type == PIO_RX_IO_RD32_FMT_TYPE) && (compl_done))
              else if ((tlp_type == PIO_RX_MEM_RD64_FMT_TYPE) && (compl_done))
              begin

                m_axis_rx_tready <= #TCQ 1'b1;
                state        <= #TCQ PIO_RX_RST_STATE;

              end // if ((tlp_type == PIO_RX_MEM_RD64_FMT_TYPE) && (compl_done))
              else
              begin
                state        <= #TCQ PIO_RX_WAIT_STATE;
              end

            end // PIO_RX_WAIT_STATE

            default : begin
              // default case stmt
              state        <= #TCQ PIO_RX_RST_STATE;
            end // default

          endcase
        end // if rst_n
      end // always
    end // pio_rx_sm_128
  endgenerate

assign    mem64_bar_hit_n = 1'b1;
assign    io_bar_hit_n = 1'b1;
assign    mem32_bar_hit_n = ~(m_axis_rx_tuser[2]);
assign    erom_bar_hit_n  = ~(m_axis_rx_tuser[8]);


  always @*
  begin
    case ({io_bar_hit_n, mem32_bar_hit_n, mem64_bar_hit_n, erom_bar_hit_n})

      4'b0111 : begin
        region_select <= #TCQ 2'b00;    // Select IO region
      end // 4'b0111

      4'b1011 : begin
        region_select <= #TCQ 2'b01;    // Select Mem32 region
      end // 4'b1011

      4'b1101 : begin
        region_select <= #TCQ 2'b10;    // Select Mem64 region
      end // 4'b1101

      4'b1110 : begin
        region_select <= #TCQ 2'b11;    // Select EROM region
      end // 4'b1110

      default : begin
        region_select <= #TCQ 2'b00;    // Error selection will select IO region
      end // default

    endcase // case ({io_bar_hit_n, mem32_bar_hit_n, mem64_bar_hit_n, erom_bar_hit_n})

  end

  // synthesis translate_off
  reg  [8*20:1] state_ascii;
  always @(state)
  begin
    case (state)
      PIO_RX_RST_STATE              : state_ascii <= #TCQ "RX_RST_STATE";
      PIO_RX_MEM_RD32_DW1DW2        : state_ascii <= #TCQ "RX_MEM_RD32_DW1DW2";
      PIO_RX_MEM_WR32_DW1DW2        : state_ascii <= #TCQ "RX_MEM_WR32_DW1DW2";
      PIO_RX_MEM_RD64_DW1DW2        : state_ascii <= #TCQ "RX_MEM_RD64_DW1DW2";
      PIO_RX_MEM_WR64_DW1DW2        : state_ascii <= #TCQ "RX_MEM_WR64_DW1DW2";
      PIO_RX_MEM_WR64_DW3           : state_ascii <= #TCQ "RX_MEM_WR64_DW3";
      PIO_RX_WAIT_STATE             : state_ascii <= #TCQ "RX_WAIT_STATE";
      PIO_RX_IO_WR_DW1DW2           : state_ascii <= #TCQ "RX_IO_WR_DW1DW2";
      PIO_RX_IO_MEM_WR_WAIT_STATE   : state_ascii <= #TCQ "RX_IO_MEM_WR_WAIT_STATE";
      default                       : state_ascii <= #TCQ "PIO 128 STATE ERR";
    endcase

  end
  // synthesis translate_on

endmodule // PIO_RX_ENGINE

