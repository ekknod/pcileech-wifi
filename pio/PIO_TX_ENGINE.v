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
// File       : PIO_TX_ENGINE.v
// Version    : 3.3

`timescale 1ps/1ps

(* DowngradeIPIdentifiedWarnings = "yes" *)
module PIO_TX_ENGINE    #(
  // RX/TX interface data width
  parameter C_DATA_WIDTH = 64,
  parameter TCQ = 1,

  // TSTRB width
  parameter KEEP_WIDTH = C_DATA_WIDTH / 8
)(

  input             clk,
  input             rst_n,

  // AXIS
  input                           s_axis_tx_tready,
  output  reg [C_DATA_WIDTH-1:0]  s_axis_tx_tdata,
  output  reg [KEEP_WIDTH-1:0]    s_axis_tx_tkeep,
  output  reg                     s_axis_tx_tlast,
  output  reg                     s_axis_tx_tvalid,
  output                          tx_src_dsc,

  input                           req_compl,
  input                           req_compl_wd,
  output reg                      compl_done,

  input [2:0]                     req_tc,
  input                           req_td,
  input                           req_ep,
  input [1:0]                     req_attr,
  input [9:0]                     req_len,
  input [15:0]                    req_rid,
  input [7:0]                     req_tag,
  input [7:0]                     req_be,
  input [12:0]                    req_addr,
  input [29:0]                    req_addr32,

  output [10:0]                   rd_addr,
  output [29:0]                   rd_addr32,
  output reg [3:0]                rd_be,
  input  [31:0]                   rd_data,
  input [15:0]                    completer_id

);

localparam PIO_CPLD_FMT_TYPE      = 7'b10_01010;
localparam PIO_CPL_FMT_TYPE       = 7'b00_01010;
localparam PIO_TX_RST_STATE       = 2'b00;
localparam PIO_TX_CPLD_QW1_FIRST  = 2'b01;
localparam PIO_TX_CPLD_QW1_TEMP   = 2'b10;
localparam PIO_TX_CPLD_QW1        = 2'b11;

  // Local registers

  reg [11:0]              byte_count;
  reg [6:0]               lower_addr;

  reg                     req_compl_q;
  reg                     req_compl_wd_q;

  reg                     compl_busy_i;
 
  // Local wires

  wire                    compl_wd;

  // Unused discontinue
  assign tx_src_dsc = 1'b0;

  // Present address and byte enable to memory module

  assign rd_addr = req_addr[12:2];
  assign rd_addr32 = req_addr32[29:0];
 
  always @(posedge clk) begin
    if (!rst_n)
    begin
     rd_be <= #TCQ 0;
    end else begin
     rd_be <= #TCQ req_be[3:0];
    end
  end

  // Calculate byte count based on byte enable

  always @ (rd_be) begin
    casex (rd_be[3:0])
      4'b1xx1 : byte_count = 12'h004;
      4'b01x1 : byte_count = 12'h003;
      4'b1x10 : byte_count = 12'h003;
      4'b0011 : byte_count = 12'h002;
      4'b0110 : byte_count = 12'h002;
      4'b1100 : byte_count = 12'h002;
      4'b0001 : byte_count = 12'h001;
      4'b0010 : byte_count = 12'h001;
      4'b0100 : byte_count = 12'h001;
      4'b1000 : byte_count = 12'h001;
      4'b0000 : byte_count = 12'h001;
    endcase
  end

  always @ ( posedge clk ) begin
    if (!rst_n ) 
    begin
      req_compl_q      <= #TCQ 1'b0;
      req_compl_wd_q   <= #TCQ 1'b1;
    end // if !rst_n
    else
    begin
      req_compl_q      <= #TCQ req_compl;
      req_compl_wd_q   <= #TCQ req_compl_wd;
    end // if rst_n
  end

    always @ (rd_be or req_addr or compl_wd) begin
    casex ({compl_wd, rd_be[3:0]})
       5'b1_0000 : lower_addr = {req_addr[6:2], 2'b00};
       5'b1_xxx1 : lower_addr = {req_addr[6:2], 2'b00};
       5'b1_xx10 : lower_addr = {req_addr[6:2], 2'b01};
       5'b1_x100 : lower_addr = {req_addr[6:2], 2'b10};
       5'b1_1000 : lower_addr = {req_addr[6:2], 2'b11};
       5'b0_xxxx : lower_addr = 8'h0;
    endcase // casex ({compl_wd, rd_be[3:0]})
    end

  //  Generate Completion with 1 DW Payload
    
  generate
    if (C_DATA_WIDTH == 64) begin : gen_cpl_64
      reg         [1:0]            state;

      assign compl_wd = req_compl_wd_q;

      always @ ( posedge clk ) begin

        if (!rst_n ) 
        begin
          s_axis_tx_tlast   <= #TCQ 1'b0;
          s_axis_tx_tvalid  <= #TCQ 1'b0;
          s_axis_tx_tdata   <= #TCQ {C_DATA_WIDTH{1'b0}};
          s_axis_tx_tkeep   <= #TCQ {KEEP_WIDTH{1'b0}};
         
          compl_done        <= #TCQ 1'b0;
          compl_busy_i      <= #TCQ 1'b0;
          state             <= #TCQ PIO_TX_RST_STATE;
        end // if (!rst_n ) 
        else
        begin
          compl_done        <= #TCQ 1'b0;
          // -- Generate compl_busy signal...
          if (req_compl_q ) 
            compl_busy_i <= 1'b1;
          case ( state )
            PIO_TX_RST_STATE : begin

              if (compl_busy_i) 
              begin
                
                s_axis_tx_tdata   <= #TCQ {C_DATA_WIDTH{1'b0}};
                s_axis_tx_tkeep   <= #TCQ 8'hFF;
                s_axis_tx_tlast   <= #TCQ 1'b0;
                s_axis_tx_tvalid  <= #TCQ 1'b0;
                  if (s_axis_tx_tready)
                    state             <= #TCQ PIO_TX_CPLD_QW1_FIRST;
                  else
                  state             <= #TCQ PIO_TX_RST_STATE;
               end
              else
              begin

                s_axis_tx_tlast   <= #TCQ 1'b0;
                s_axis_tx_tvalid  <= #TCQ 1'b0;
                s_axis_tx_tdata   <= #TCQ 64'b0;
                s_axis_tx_tkeep   <= #TCQ 8'hFF;
                compl_done        <= #TCQ 1'b0;
                state             <= #TCQ PIO_TX_RST_STATE;

              end // if !(compl_busy) 
              end // PIO_TX_RST_STATE

            PIO_TX_CPLD_QW1_FIRST : begin
              if (s_axis_tx_tready) begin

                s_axis_tx_tlast  <= #TCQ 1'b0;
                s_axis_tx_tdata  <= #TCQ {                      // Bits
                                      completer_id,             // 16
                                      {3'b0},                   // 3
                                      {1'b0},                   // 1
                                      byte_count,               // 12
                                      {1'b0},                   // 1
                                      (req_compl_wd_q ?
                                      PIO_CPLD_FMT_TYPE :
                                      PIO_CPL_FMT_TYPE),        // 7
                                      {1'b0},                   // 1
                                      req_tc,                   // 3
                                      {4'b0},                   // 4
                                      req_td,                   // 1
                                      req_ep,                   // 1
                                      req_attr,                 // 2
                                      {2'b0},                   // 2
                                      req_len                   // 10
                                      };
                s_axis_tx_tkeep   <= #TCQ 8'hFF;

                state             <= #TCQ PIO_TX_CPLD_QW1_TEMP;
                end
            else
                state             <= #TCQ PIO_TX_RST_STATE;

               end //PIO_TX_CPLD_QW1_FIRST


            PIO_TX_CPLD_QW1_TEMP : begin   
                s_axis_tx_tvalid <= #TCQ 1'b1;
                state             <= #TCQ PIO_TX_CPLD_QW1;
            end


            PIO_TX_CPLD_QW1 : begin

              if (s_axis_tx_tready)
              begin

                s_axis_tx_tlast  <= #TCQ 1'b1;
                s_axis_tx_tvalid <= #TCQ 1'b1;
                // Swap DWORDS for AXI
                s_axis_tx_tdata  <= #TCQ {        // Bits
                                      rd_data,    // 32
                                      req_rid,    // 16
                                      req_tag,    //  8
                                      {1'b0},     //  1
                                      lower_addr  //  7
                                      };

                // Here we select if the packet has data or
                // not.  The strobe signal will mask data
                // when it is not needed.  No reason to change
                // the data bus.
                if (req_compl_wd_q)
                  s_axis_tx_tkeep <= #TCQ 8'hFF;
                else
                  s_axis_tx_tkeep <= #TCQ 8'h0F;


                compl_done        <= #TCQ 1'b1;
                compl_busy_i      <= #TCQ 1'b0;
                state             <= #TCQ PIO_TX_RST_STATE;

              end // if (s_axis_tx_tready)
              else
                state             <= #TCQ PIO_TX_CPLD_QW1;

            end // PIO_TX_CPLD_QW1

            default : begin
              // case default stmt
              state             <= #TCQ PIO_TX_RST_STATE;
            end

          endcase
        end // if rst_n
      end
    end
    else if (C_DATA_WIDTH == 128) begin : gen_cpl_128
      reg                     hold_state;
      reg                     req_compl_q2;
      reg                     req_compl_wd_q2;

      assign compl_wd = req_compl_wd_q2;

      always @ ( posedge clk ) begin
        if (!rst_n ) 
        begin
          req_compl_q2      <= #TCQ 1'b0;
          req_compl_wd_q2   <= #TCQ 1'b0;
        end // if (!rst_n ) 
        else
        begin
          req_compl_q2      <= #TCQ req_compl_q;
          req_compl_wd_q2   <= #TCQ req_compl_wd_q;
        end // if (rst_n ) 
      end

      always @ ( posedge clk ) begin
        if (!rst_n ) 
        begin
          s_axis_tx_tlast   <= #TCQ 1'b0;
          s_axis_tx_tvalid  <= #TCQ 1'b0;
          s_axis_tx_tdata   <= #TCQ {C_DATA_WIDTH{1'b0}};
          s_axis_tx_tkeep   <= #TCQ {KEEP_WIDTH{1'b0}};
          compl_done        <= #TCQ 1'b0;
          hold_state        <= #TCQ 1'b0;
        end // if !rst_n
        else
        begin
  
          if (req_compl_q2 | hold_state)
          begin
            if (s_axis_tx_tready) 
            begin
  
              s_axis_tx_tlast   <= #TCQ 1'b1;
              s_axis_tx_tvalid  <= #TCQ 1'b1;
              s_axis_tx_tdata   <= #TCQ {                   // Bits
                                  rd_data,                  // 32
                                  req_rid,                  // 16
                                  req_tag,                  //  8
                                  {1'b0},                   //  1
                                  lower_addr,               //  7
                                  completer_id,             // 16
                                  {3'b0},                   //  3
                                  {1'b0},                   //  1
                                  byte_count,               // 12
                                  {1'b0},                   //  1
                                  (req_compl_wd_q2 ?
                                  PIO_CPLD_FMT_TYPE :
                                  PIO_CPL_FMT_TYPE),        //  7
                                  {1'b0},                   //  1
                                  req_tc,                   //  3
                                  {4'b0},                   //  4
                                  req_td,                   //  1
                                  req_ep,                   //  1
                                  req_attr,                 //  2
                                  {2'b0},                   //  2
                                  req_len                   // 10
                                  };
  
              // Here we select if the packet has data or
              // not.  The strobe signal will mask data
              // when it is not needed.  No reason to change
              // the data bus.
              if (req_compl_wd_q2)
                s_axis_tx_tkeep   <= #TCQ 16'hFFFF;
              else
                s_axis_tx_tkeep   <= #TCQ 16'h0FFF;
  
              compl_done        <= #TCQ 1'b1;
              hold_state        <= #TCQ 1'b0;
  
            end // if (s_axis_tx_tready) 
            else
              hold_state        <= #TCQ 1'b1;
  
          end // if (req_compl_q2 | hold_state)
          else
          begin
  
            s_axis_tx_tlast   <= #TCQ 1'b0;
            s_axis_tx_tvalid  <= #TCQ 1'b0;
            s_axis_tx_tdata   <= #TCQ {C_DATA_WIDTH{1'b0}};
            s_axis_tx_tkeep   <= #TCQ {KEEP_WIDTH{1'b1}};
            compl_done        <= #TCQ 1'b0;
  
          end // if !(req_compl_q2 | hold_state) 
        end // if rst_n
      end
    end
  endgenerate

endmodule // PIO_TX_ENGINE
