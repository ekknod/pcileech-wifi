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
// File       : PIO_EP_MEM_ACCESS.v
// Version    : 3.3
//--
//-- Description: Endpoint Memory Access Unit. This module provides access functions
//--              to the Endpoint memory aperture.
//--
//--              Read Access: Module returns data for the specifed address and
//--              byte enables selected.
//--
//--              Write Access: Module accepts data, byte enables and updates
//--              data when write enable is asserted. Modules signals write busy
//--              when data write is in progress.
//--
//--------------------------------------------------------------------------------

`timescale 1ps/1ps

(* DowngradeIPIdentifiedWarnings = "yes" *)
module PIO_EP_MEM_ACCESS  #(
  parameter TCQ = 1
) (

  clk,
  rst_n,

  // Read Access

  rd_addr,     // I [10:0]  Read Address
  rd_addr32,   // I [29:0]  Read Address
  base_address_register, // I [31:0]  Base Address Register
  rd_be,       // I [3:0]   Read Byte Enable
  rd_data,     // O [31:0]  Read Data

  // Write Access

  wr_addr,     // I [10:0]  Write Address
  wr_be,       // I [7:0]   Write Byte Enable
  wr_data,     // I [31:0]  Write Data
  wr_en,       // I         Write Enable
  wr_busy      // O         Write Controller Busy

);

  input            clk;
  input            rst_n;

  //  Read Port

  input  [10:0]    rd_addr;
  input  [29:0]    rd_addr32;
  input  [31:0]    base_address_register;
  input  [3:0]     rd_be;
  output [31:0]    rd_data;

  //  Write Port

  input  [10:0]    wr_addr;
  input  [7:0]     wr_be;
  input  [31:0]    wr_data;
  input            wr_en;
  output           wr_busy;

  localparam PIO_MEM_ACCESS_WR_RST   = 3'b000;
  localparam PIO_MEM_ACCESS_WR_WAIT  = 3'b001;
  localparam PIO_MEM_ACCESS_WR_READ  = 3'b010;
  localparam PIO_MEM_ACCESS_WR_WRITE = 3'b100;

  wire  [31:0]     rd_data;
  reg   [31:0]      rd_data_raw_o;


  wire  [31:0]     rd_data0_o, rd_data1_o, rd_data2_o, rd_data3_o;

  wire             rd_data0_en, rd_data1_en, rd_data2_en, rd_data3_en;

  wire             wr_busy;
  reg              write_en;
  reg   [31:0]     post_wr_data;
  reg   [31:0]     w_pre_wr_data;

  reg   [2:0]      wr_mem_state;
  
  reg   [7:0]      data_8;
  reg   [31:0]     pre_wr_data;
  wire  [31:0]     w_pre_wr_data0;
  wire  [31:0]     w_pre_wr_data1;
  wire  [31:0]     w_pre_wr_data2;
  wire  [31:0]     w_pre_wr_data3;

  wire  [7:0]      w_pre_wr_data_b0;
  wire  [7:0]      w_pre_wr_data_b1;
  wire  [7:0]      w_pre_wr_data_b2;
  wire  [7:0]      w_pre_wr_data_b3;

  wire  [7:0]      w_wr_data_b0;
  wire  [7:0]      w_wr_data_b1;
  wire  [7:0]      w_wr_data_b2;
  wire  [7:0]      w_wr_data_b3;



  // Memory Write Process

  //  Extract current data bytes. These need to be swizzled
  //  BRAM storage format :
  //    data[31:0] = { byte[3], byte[2], byte[1], byte[0] (lowest addr) }

  assign w_pre_wr_data_b3 = pre_wr_data[31:24];
  assign w_pre_wr_data_b2 = pre_wr_data[23:16];
  assign w_pre_wr_data_b1 = pre_wr_data[15:08];
  assign w_pre_wr_data_b0 = pre_wr_data[07:00];

  //  Extract new data bytes from payload
  //  TLP Payload format :
  //    data[31:0] = { byte[0] (lowest addr), byte[2], byte[1], byte[3] }

  assign w_wr_data_b3 = wr_data[07:00];
  assign w_wr_data_b2 = wr_data[15:08];
  assign w_wr_data_b1 = wr_data[23:16];
  assign w_wr_data_b0 = wr_data[31:24];

  always @(posedge clk) begin

    if ( !rst_n )
    begin
      data_8      <= #TCQ 8'b0;
      pre_wr_data <= #TCQ 32'b0;
      post_wr_data <= #TCQ 32'b0;
      pre_wr_data <= #TCQ 32'b0;
      write_en   <= #TCQ 1'b0;
      wr_mem_state <= #TCQ PIO_MEM_ACCESS_WR_RST;

    end // if !rst_n
    else
    begin
      if (rd_addr[10:9] == 2'b01)
        begin
          case ({rd_addr32, 2'b00})
            {base_address_register + 16'h2000} : begin data_8 <= #TCQ 1; rd_data_raw_o <= #TCQ 32'hDEADBEEF; end
            {base_address_register + 16'h2200} : begin data_8 <= #TCQ 2; rd_data_raw_o <= #TCQ 32'hDEADBEEF; end
            {base_address_register + 16'h2204} : begin data_8 <= #TCQ 3; rd_data_raw_o <= #TCQ 32'hDEADBEEF; end
            {base_address_register + 16'h2208} : begin data_8 <= #TCQ 4; rd_data_raw_o <= #TCQ 32'hDEADBEEF; end
            {base_address_register + 16'h220C} : begin data_8 <= #TCQ 5; rd_data_raw_o <= #TCQ 32'hDEADBEEF; end
            {base_address_register + 16'h2210} : begin data_8 <= #TCQ 6; rd_data_raw_o <= #TCQ 32'hDEADBEEF; end
            {base_address_register + 16'h2218} : begin data_8 <= #TCQ 7; rd_data_raw_o <= #TCQ 32'hDEADBEEF; end
            {base_address_register + 16'h221C} : begin data_8 <= #TCQ 8; rd_data_raw_o <= #TCQ 32'hDEADBEEF; end
            {base_address_register + 16'h2220} : begin data_8 <= #TCQ 9; rd_data_raw_o <= #TCQ 32'hDEADBEEF; end
            {base_address_register + 16'h2224} : begin data_8 <= #TCQ 10; rd_data_raw_o <= #TCQ 32'hDEADBEEF; end
            {base_address_register + 16'h2228} : begin data_8 <= #TCQ 11; rd_data_raw_o <= #TCQ 32'hDEADBEEF; end
            {base_address_register + 16'h4020} : rd_data_raw_o <= #TCQ 32'h001800FF;
            {base_address_register + 16'h4028} : rd_data_raw_o <= #TCQ 32'h00000060;
            {base_address_register + 16'h4038} : rd_data_raw_o <= #TCQ 32'h00000002;
            {base_address_register + 16'h407C} :
              begin
                case (data_8)
                  1  : rd_data_raw_o <= #TCQ 32'h0000A55A; // EEPROM MAGIC
                  2  : rd_data_raw_o <= #TCQ 32'h00000004; // EEPROM_SIZE
                  3  : rd_data_raw_o <= #TCQ 32'h0000FFFB; // EEPROM_CHECKSUM
                  4  : rd_data_raw_o <= #TCQ 32'h0000E00E; // EEPROM version + revision
                  5  : rd_data_raw_o <= #TCQ 32'h0000E00E; // EEPROM_ANTENNA (2.4ghz, 5.0ghz)
                  6  : rd_data_raw_o <= #TCQ 32'h00000000; // EEPROM_REGDOMAIN (location data)
                  7  : rd_data_raw_o <= #TCQ 32'h00009C64; // EEPROM_MAC0 (64:9C)
                  8  : rd_data_raw_o <= #TCQ 32'h00000881; // EEPROM_MAC1 (81:08)
                  9  : rd_data_raw_o <= #TCQ 32'h0000C0C4; // EEPROM_MAC2 (C4:C0)
                  10 : rd_data_raw_o <= #TCQ 32'h00000100; // EEPROM_RXTX (00,01)
                  11 : begin rd_data_raw_o <= #TCQ 32'h00000000; data_8 <= #TCQ 0; end
                  default : rd_data_raw_o <= 32'h00000000;
                endcase
              end
            {base_address_register + 16'h7000} : rd_data_raw_o <= #TCQ 32'h00000000;
            {base_address_register + 16'h7044} : rd_data_raw_o <= #TCQ 32'h00000002;
            {base_address_register + 16'h8000} : rd_data_raw_o <= rd_data1_o;
            {base_address_register + 16'h806C} : rd_data_raw_o <= #TCQ 32'h00000000;
            {base_address_register + 16'h9820} : rd_data_raw_o <= rd_data1_o;
            {base_address_register + 16'h9860} : rd_data_raw_o <= #TCQ 32'h00000000;
            {base_address_register + 16'h9C00} : rd_data_raw_o <= #TCQ 32'h00000000;
            default : rd_data_raw_o <= #TCQ 32'hDEADBEEF;
          endcase
        end

      case ( wr_mem_state )

        PIO_MEM_ACCESS_WR_RST : begin

          if (wr_en)
          begin // read state
            wr_mem_state <= #TCQ PIO_MEM_ACCESS_WR_WAIT; //Pipelining happens in RAM's internal output reg.
          end
          else
          begin
            write_en <= #TCQ 1'b0;
            wr_mem_state <= #TCQ PIO_MEM_ACCESS_WR_RST;
          end
        end // PIO_MEM_ACCESS_WR_RST

        PIO_MEM_ACCESS_WR_WAIT : begin

          write_en <= #TCQ 1'b0;
          wr_mem_state <= #TCQ PIO_MEM_ACCESS_WR_READ ;

        end // PIO_MEM_ACCESS_WR_WAIT

        PIO_MEM_ACCESS_WR_READ : begin

            // Now save the selected BRAM B port data out

            pre_wr_data <= #TCQ w_pre_wr_data;
            write_en <= #TCQ 1'b0;
            wr_mem_state <= #TCQ PIO_MEM_ACCESS_WR_WRITE;

        end // PIO_MEM_ACCESS_WR_READ

        PIO_MEM_ACCESS_WR_WRITE : begin

          //Merge new enabled data and write target BlockRAM location

          post_wr_data <= #TCQ {{wr_be[3] ? w_wr_data_b3 : w_pre_wr_data_b3},
                               {wr_be[2] ? w_wr_data_b2 : w_pre_wr_data_b2},
                               {wr_be[1] ? w_wr_data_b1 : w_pre_wr_data_b1},
                               {wr_be[0] ? w_wr_data_b0 : w_pre_wr_data_b0}};
          write_en     <= #TCQ 1'b1;
          wr_mem_state <= #TCQ PIO_MEM_ACCESS_WR_RST;

        end // PIO_MEM_ACCESS_WR_WRITE

        default : begin
          // default case stmt
          wr_mem_state <= #TCQ PIO_MEM_ACCESS_WR_RST;
        end // default

      endcase // case (wr_mem_state)
    end // if rst_n
  end

  // Write controller busy

  assign wr_busy = wr_en | (wr_mem_state != PIO_MEM_ACCESS_WR_RST);

  //  Select BlockRAM output based on higher 2 address bits

  always @* 
  begin
    case ({wr_addr[10:9]}) // synthesis parallel_case full_case

      2'b00 : w_pre_wr_data = w_pre_wr_data0;
      2'b01 : w_pre_wr_data = w_pre_wr_data1;
      2'b10 : w_pre_wr_data = w_pre_wr_data2;
      2'b11 : w_pre_wr_data = w_pre_wr_data3;

    endcase
  end

  //  Memory Read Controller

  assign rd_data0_en = {rd_addr[10:9]  == 2'b00};
  assign rd_data1_en = {rd_addr[10:9]  == 2'b01};
  assign rd_data2_en = {rd_addr[10:9]  == 2'b10};
  assign rd_data3_en = {rd_addr[10:9]  == 2'b11};
  // Handle Read byte enables

  assign rd_data = {{rd_be[0] ? rd_data_raw_o[07:00] : 8'h0},
                      {rd_be[1] ? rd_data_raw_o[15:08] : 8'h0},
                      {rd_be[2] ? rd_data_raw_o[23:16] : 8'h0},
                      {rd_be[3] ? rd_data_raw_o[31:24] : 8'h0}};


  EP_MEM EP_MEM_inst (

     .clk_i(clk),

     .a_rd_a_i_0(rd_addr[8:0]),                              // I [8:0]
     .a_rd_en_i_0(rd_data0_en),                                // I [1:0]
     .a_rd_d_o_0(rd_data0_o),                                  // O [31:0]

     .b_wr_a_i_0(wr_addr[8:0]),                              // I [8:0]
     .b_wr_d_i_0(post_wr_data),                                // I [31:0]
     .b_wr_en_i_0({write_en & (wr_addr[10:9] == 2'b00)}),    // I
     .b_rd_d_o_0(w_pre_wr_data0[31:0]),                        // O [31:0]
     .b_rd_en_i_0({wr_addr[10:9] == 2'b00}),                 // I

     .a_rd_a_i_1(rd_addr[8:0]),                              // I [8:0]
     .a_rd_en_i_1(rd_data1_en),                                // I [1:0]
     .a_rd_d_o_1(rd_data1_o),                                  // O [31:0]

     .b_wr_a_i_1(wr_addr[8:0]),                              // [8:0]
     .b_wr_d_i_1(post_wr_data),                                // [31:0]
     .b_wr_en_i_1({write_en & (wr_addr[10:9] == 2'b01)}),    // I
     .b_rd_d_o_1(w_pre_wr_data1[31:0]),                        // [31:0]
     .b_rd_en_i_1({wr_addr[10:9] == 2'b01}),                 // I

     .a_rd_a_i_2(rd_addr[8:0]),                              // I [8:0]
     .a_rd_en_i_2(rd_data2_en),                                // I [1:0]
     .a_rd_d_o_2(rd_data2_o),                                  // O [31:0]

     .b_wr_a_i_2(wr_addr[8:0]),                              // I [8:0]
     .b_wr_d_i_2(post_wr_data),                                // I [31:0]
     .b_wr_en_i_2({write_en & (wr_addr[10:9] == 2'b10)}),    // I
     .b_rd_d_o_2(w_pre_wr_data2[31:0]),                        // I [31:0]
     .b_rd_en_i_2({wr_addr[10:9] == 2'b10}),                 // I

     .a_rd_a_i_3(rd_addr[8:0]),                              // [8:0]
     .a_rd_en_i_3(rd_data3_en),                                // [1:0]
     .a_rd_d_o_3(rd_data3_o),                                  // O [31:0]

     .b_wr_a_i_3(wr_addr[8:0]),                              // I [8:0]
     .b_wr_d_i_3(post_wr_data),                                // I [31:0]
     .b_wr_en_i_3({write_en & (wr_addr[10:9] == 2'b11)}),    // I
     .b_rd_d_o_3(w_pre_wr_data3[31:0]),                        // I [31:0]
     .b_rd_en_i_3({wr_addr[10:9] == 2'b11})                  // I

  );

  // synthesis translate_off
  reg  [8*20:1] state_ascii;
  always @(wr_mem_state)
  begin
    case (wr_mem_state)
      PIO_MEM_ACCESS_WR_RST    : state_ascii <= #TCQ "PIO_MEM_WR_RST";
      PIO_MEM_ACCESS_WR_WAIT   : state_ascii <= #TCQ "PIO_MEM_WR_WAIT";
      PIO_MEM_ACCESS_WR_READ   : state_ascii <= #TCQ "PIO_MEM_WR_READ";
      PIO_MEM_ACCESS_WR_WRITE  : state_ascii <= #TCQ "PIO_MEM_WR_WRITE";
      default                  : state_ascii <= #TCQ "PIO MEM STATE ERR";
    endcase
  end
  // synthesis translate_on


endmodule

