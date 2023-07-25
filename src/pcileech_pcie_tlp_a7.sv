//
// PCILeech FPGA.
//
// PCIe controller module - TLP handling for Artix-7.
//
// (c) Ulf Frisk, 2018-2021
// Author: Ulf Frisk, pcileech@frizk.net
//

`timescale 1ns / 1ps
`include "pcileech_header.svh"

module pcileech_pcie_tlp_a7(
    input                   rst,
    input                   clk_100,            // 100MHz
    input                   clk_pcie,           // 62.5MHz
    IfPCIeFifoTlp.mp_pcie   dfifo,
    
    // PCIe core transmit data (s_axis)
    IfPCIeTlpRxTx.source    tlp_tx,
    IfPCIeTlpRxTx.sink      tlp_rx,
    
    IfCfg_TlpCfg.tlp        cfg_tlpcfg,
    IfTlp64.sink            tlp_static,
    IfShadow2Fifo.tlp       dshadow2fifo,
    IfShadow2Tlp.tlp        dshadow2tlp
    );
    
    // ------------------------------------------------------------------------
    // Convert received TLPs from PCIe core and transmit onwards to FT601
    // FIFO depth: 512 / 64-bits.
    // ------------------------------------------------------------------------
    // pcie_tlp_rx_din[31:0]  = 2st DWORD
    // pcie_tlp_rx_din[32]    = 2st DWORD is LAST in TLP
    // pcie_tlp_rx_din[33]    = 2st DWORD VALID
    // pcie_tlp_tx_din[65:34] = 1nd DWORD
    // pcie_tlp_tx_din[66]    = 1nd DWORD is LAST in TLP
    // pcie_tlp_tx_din[67]    = 1nd DWORD VALID
    // pcie_tlp_rx_suppress   = CfgRdWr packets may optionally kept by logic (not forwarded to rx fifo)
    wire [67:0]     pcie_tlp_rx_din;
    wire            pcie_tlp_rx_almost_full;
    wire [33:0]     pcie_tlp_rx_dout;
    wire            pcie_tlp_rx_dout_i;
    wire            pcie_tlp_rx_filter;
    
    assign pcie_tlp_rx_din[31:0] = tlp_rx.data[63:32];
    assign pcie_tlp_rx_din[32] = tlp_rx.last;
    assign pcie_tlp_rx_din[33] = tlp_rx.keep[7];
    assign pcie_tlp_rx_din[65:34] = tlp_rx.data[31:0];
    assign pcie_tlp_rx_din[66] = tlp_rx.last & ~tlp_rx.keep[7];
    assign pcie_tlp_rx_din[67] = 1'b1;
    assign tlp_rx.ready = ~pcie_tlp_rx_almost_full;
   
    fifo_68_34 i_fifo_pcie_tlp_rx (
        .rst            ( rst                       ),
        .wr_clk         ( clk_pcie                  ),
        .rd_clk         ( clk_100                   ),
        .din            ( pcie_tlp_rx_din           ),
        .wr_en          ( tlp_rx.valid & ~pcie_tlp_rx_filter  ),
        .rd_en          ( dfifo.rx_rd_en            ),
        .dout           ( pcie_tlp_rx_dout          ),
        .almost_full    ( pcie_tlp_rx_almost_full   ),
        .full           (                           ),
        .empty          ( dfifo.rx_empty            ),
        .valid          ( pcie_tlp_rx_dout_i        )
    );
    
    assign dfifo.rx_data     = pcie_tlp_rx_dout[31:0];
    assign dfifo.rx_last     = pcie_tlp_rx_dout[32];
    assign dfifo.rx_valid    = pcie_tlp_rx_dout_i & pcie_tlp_rx_dout[33];
    
    // ------------------------------------------------------------------------
    // PCIe configuration space implementation - snoop received TLPs from PCIe
    // fore for configuration space read requests and forward them onto module
    // for configuration space.
    // ------------------------------------------------------------------------
    IfTlp16 tlp_cpl_cfgspace();
    
    pcileech_pcie_tlptapcfgspace i_pcileech_pcie_tlptapcfgspace (
        .rst            ( rst                       ),
        .clk_100        ( clk_100                   ),
        .clk_pcie       ( clk_pcie                  ),
        .tlp_rx         ( tlp_rx                    ),
        .tlp_tx         ( tlp_cpl_cfgspace          ),
        .tlp_pcie_id    ( cfg_tlpcfg.tlp_pcie_id    ),
        .tlp_pcie_filter  ( pcie_tlp_rx_filter      ),
        .dshadow2fifo   ( dshadow2fifo              ),
        .dshadow2tlp    ( dshadow2tlp               )
    );
        
    // ------------------------------------------------------------------------
    // TX data received from FIFO
    // ------------------------------------------------------------------------
    IfTlp128 fifo_tlp();
    
    tlp128_source_fifo i_tlp128_source_fifo(
        .clk_fifo       ( clk_100                   ),
        .clk            ( clk_pcie                  ),
        .rst            ( rst                       ),
        .dfifo_tx_data  ( dfifo.tx_data             ),
        .dfifo_tx_last  ( dfifo.tx_last             ),
        .dfifo_tx_valid ( dfifo.tx_valid            ),
        .tlp_out        ( fifo_tlp                  )
    );
    
    tlp128_sink_mux1 i_tlp128_sink_mux1(
        .clk            ( clk_pcie                  ),
        .rst            ( rst                       ),
        .tlp_tx         ( tlp_tx                    ),
        .p0             ( fifo_tlp                  ),
        .p1             ( tlp_cpl_cfgspace          ),
        .p2             ( tlp_static                ),
        .pX_en          ( cfg_tlpcfg.tlp_tx_en      )
    );

endmodule



module pcileech_pcie_tlptapcfgspace(
    input                   rst,
    input                   clk_100,            // 100MHz
    input                   clk_pcie,           // 62.5MHz
    
    IfPCIeTlpRxTx.sink      tlp_rx,
    IfTlp16.source          tlp_tx,
    IfShadow2Fifo.tlp       dshadow2fifo,
    IfShadow2Tlp.tlp        dshadow2tlp,
    
    input   [15:0]          tlp_pcie_id,        // PCIe id of this core
    output                  tlp_pcie_filter     // do not forward TLP QWORD to user application
    );
    
    // ------------------------------------------------------------------------
    // INCOMING data to pcie config space - snooped from main TLP AXI stream
    // only act on valid configuration space requests. Read requests should be
    // turned into BRAM read requests.
    // ------------------------------------------------------------------------
    bit  [63:0]     snoop_data_first;   
    wire            snoop_next_first_n = ~rst & tlp_rx.valid & ~tlp_rx.last;      // Next QWORD may be 1st in CfgRdWr TLP. 
    bit             snoop_first_n   = 1'b0;
    bit             snoop_error     = 1'b0;
    wire [127:0]    snoop_data      = { tlp_rx.data, snoop_data_first };
    wire [9:0]      snoop_addr_dw   = snoop_data[75:66];
    wire [15:0]     snoop_addr_dw16 = snoop_data[81:66];
    wire [3:0]      snoop_addr_id   = snoop_data[95:92];

    wire [31:0]     snoop_data_wr_dw = snoop_data[127:96];
    wire [7:0]      snoop_tag       = snoop_data[47:40];
    wire [3:0]      snoop_be        = {snoop_data[32], snoop_data[33], snoop_data[34], snoop_data[35]};
    wire [15:0]     snoop_requester_id = snoop_data[63:48];
    wire            snoop_valid_rdwr = dshadow2fifo.cfgtlp_en & 
                                    ~rst & tlp_rx.valid & tlp_rx.last & ~snoop_error &
                                    (snoop_data[39:36] == 4'b0000) &            // Last DW BE[3:0] == 0000b
                                    (snoop_data[22:20] == 3'b000) &             // TC[2:0] == 000b
                                    (snoop_data[13:00] == 14'b00000000000001);  // LENGTH = 0000000001b, AT=00b, Attr = 00b


    wire            snoop_valid_bar_rd = (snoop_data[31:25] == 7'b0000000);
    wire            snoop_valid_bar_wr = (snoop_data[31:25] == 7'b0100000);

    
    wire            snoop_valid_rd = snoop_valid_rdwr & 
                                    ((snoop_data[31:25] == 7'b0000010) | snoop_valid_bar_rd);          // Fmt[2:0]=000b (3 DW header, no data), CfgRd0/CfgRd1=0010xb
    wire            snoop_valid_wr = snoop_valid_rdwr & 
                                    ((snoop_data[31:25] == 7'b0100010) | snoop_valid_bar_wr);          // Fmt[2:0]=010b (3 DW header, data), CfgWr0/CfgWr1=0010xb
    // Filter / suppress forwarding of received CfgRdWr TLP packets to user application.
    // This is done to avoid too many config TLPs to be received w/o reading them -
    // since that will clog up the buffers and may cause target OS to freeze.
    bit             cfgtlp_filter         = 1'b0;
    wire            cfgtlp_filter_snoop   = ~snoop_first_n & (tlp_rx.data[29:25] == 5'b00010);  // fast detect cfg packet - Fmt[2:0]=xx0b, CfgRdWr0/CfgRdWr1=0010xb
    assign          tlp_pcie_filter       = dshadow2fifo.cfgtlp_filter & (cfgtlp_filter | cfgtlp_filter_snoop);

    always @ ( posedge clk_pcie )
        begin
            snoop_data_first    <= tlp_rx.data;
            snoop_first_n       <= snoop_next_first_n;
            snoop_error         <= snoop_next_first_n & snoop_first_n;
            cfgtlp_filter       <= snoop_next_first_n & tlp_pcie_filter;
        end
        
    // ------------------------------------------------------------------------
    // TX DATA TO SHADOW CFGSPACE
    // ------------------------------------------------------------------------
    
    wire        fifotx_valid;
    wire        fifotx_tlprd;
    bit  [15:0] fifotx_requester_id;
    

    // ------------------------------------------------------------------------
    // BASE ADDRESS REGISTER | SSB (SuperSimpleBar) | wireless network card
    // ------------------------------------------------------------------------
    bit [31:0] end_of_day_data;
    bit [31:0] data_64;
    bit        bar_read_write = 1'b0;

    always @ ( posedge clk_pcie )
        if ( snoop_valid_rd | snoop_valid_wr )
            begin
                fifotx_requester_id <= snoop_requester_id;
                bar_read_write <= (snoop_valid_bar_rd | snoop_valid_bar_wr) & (snoop_addr_id == 4'hF);

                if (bar_read_write)
                    begin
                        

                        //
                        // 0x2000 == EEPROM MAGIC                     (0x00EC0000)
                        // 0x2200 == EEPROM_SIZE                      (0x00000004)
                        // 0x2204 == EEPROM_CHECKSUM                  (0x0000FFFB)
                        // 0x2208 == EEPROM version + revision        (0x0000E00E)
                        // 0x220C == EEPROM_ANTENNA (2.4ghz, 5.0ghz)  (0x0000E00E)
                        // 0x2210 == EEPROM_REGDOMAIN (location data) (0x00000000)
                        // 0x2218 == EEPROM_MAC0 (64:9C)              (0x00009C64)
                        // 0x221C == EEPROM_MAC1 (81:08)              (0x00000881)
                        // 0x2220 == EEPROM_MAC2 (C4:C0)              (0x0000C0C4)
                        // 0x2224 == EEPROM_RXTX (00,01)              (0x00000100)
                        if (snoop_addr_dw16[15:0] == 16'h0002) // 0x8
                            begin
                                if (snoop_valid_bar_wr)
                                        data_64 <= 32'h01000000; // dw 0x20
                                else
                                    begin
                                        if (data_64 == 32'h01000000) // 0x20 ->
                                            begin
                                                data_64 <= 32'hEFBEADDE;
                                                end_of_day_data <= 32'h00000000; // hal stop dma receive
                                            end
                                        else
                                            end_of_day_data <= 32'hEFBEADDE; // hal stop dma receive
                                    end
                            end
                        else if (snoop_addr_dw16[15:0] == 16'h1008) // 0x4020 mac version
                            begin
                                end_of_day_data <= 32'hFF001800;
                            end
                        else if (snoop_addr_dw16[15:0] == 16'h0800) // 0x2000, EEPROM_MAGIC
                            begin
                                data_64 <= 32'h0000EC00;
                                end_of_day_data <= 32'hEFBEADDE;
                            end
                        else if (snoop_addr_dw16[15:0] == 16'h0880) // 0x2200, EEPROM_SIZE
                            begin
                                data_64 <= 32'h0000EC04;
                                end_of_day_data <= 32'hEFBEADDE;
                            end
                        else if (snoop_addr_dw16[15:0] == 16'h0881) // 0x2204, EEPROM_CHECKSUM
                            begin
                                data_64 <= 32'h0000EC08;
                                end_of_day_data <= 32'hEFBEADDE;
                            end
                        else if (snoop_addr_dw16[15:0] == 16'h0882) // 0x2208, EEPROM_VER_REV
                            begin
                                data_64 <= 32'h0000EC0C;
                                end_of_day_data <= 32'hEFBEADDE;
                            end
                        else if (snoop_addr_dw16[15:0] == 16'h0883) // 0x220C, EEPROM_ANTENNA
                            begin
                                data_64 <= 32'h0000EC10;
                                end_of_day_data <= 32'hEFBEADDE;
                            end
                        else if (snoop_addr_dw16[15:0] == 16'h0886) // 0x2218, EEPROM_MAC0
                            begin
                                data_64 <= 32'h0000EC14;
                                end_of_day_data <= 32'hEFBEADDE;
                            end
                        else if (snoop_addr_dw16[15:0] == 16'h0887) // 0x221C, EEPROM_MAC1
                            begin
                                data_64 <= 32'h0000EC18;
                                end_of_day_data <= 32'hEFBEADDE;
                            end
                        else if (snoop_addr_dw16[15:0] == 16'h0888) // 0x2220, EEPROM_MAC2
                            begin
                                data_64 <= 32'h0000EC1C;
                                end_of_day_data <= 32'hEFBEADDE;
                            end

                        else if (snoop_addr_dw16[15:0] == 16'h0884) // 0x2210, EEPROM_REGDOMAIN
                            begin
                                data_64 <= 32'h0000EC20;
                                end_of_day_data <= 32'hEFBEADDE;
                            end

                        else if (snoop_addr_dw16[15:0] == 16'h0889) // 0x2224, EEPROM_RXTX
                            begin
                                data_64 <= 32'h0000EC24;
                                end_of_day_data <= 32'hEFBEADDE;
                            end

                        else if (snoop_addr_dw16[15:0] == 16'h101F) // 0x407C, EEPROM_REPLY
                            begin
                                if (data_64 == 32'h0000EC00)
                                    begin
                                        data_64 <= 32'h0000EC02;
                                        end_of_day_data <= 32'h00000000;
                                    end
                                else if (data_64 == 32'h0000EC02)
                                    begin
                                        data_64 <= 32'hEFBEADDE;
                                        end_of_day_data <= 32'h5AA50000; // apply magic
                                    end

                                else if (data_64 == 32'h0000EC04)
                                    begin
                                        data_64 <= 32'h0000EC06;
                                        end_of_day_data <= 32'h00000000;
                                    end
                                else if (data_64 == 32'h0000EC06)
                                    begin
                                        data_64 <= 32'hEFBEADDE;
                                        end_of_day_data <= 32'h04000000; // apply checksum size
                                    end

                                else if (data_64 == 32'h0000EC08)
                                    begin
                                        data_64 <= 32'h0000EC0A;
                                        end_of_day_data <= 32'h00000000;
                                    end

                                else if (data_64 == 32'h0000EC0A)
                                    begin
                                        data_64 <= 32'hEFBEADDE;
                                        end_of_day_data <= 32'hFBFF0000; // apply checksum
                                    end

                                else if (data_64 == 32'h0000EC0C)
                                    begin
                                        data_64 <= 32'h0000EC0E;
                                        end_of_day_data <= 32'h00000000;
                                    end

                                else if (data_64 == 32'h0000EC0E)
                                    begin
                                        data_64 <= 32'hEFBEADDE;
                                        end_of_day_data <= 32'h0EE00000; // apply checksum version / revision
                                    end

                                else if (data_64 == 32'h0000EC10)
                                    begin
                                        data_64 <= 32'h0000EC12;
                                        end_of_day_data <= 32'h00000000;
                                    end

                                else if (data_64 == 32'h0000EC12)
                                    begin
                                        data_64 <= 32'hEFBEADDE;
                                        end_of_day_data <= 32'h0EE00000; // apply antnna information
                                    end
           
                                else if (data_64 == 32'h0000EC14)
                                    begin
                                        data_64 <= 32'h0000EC16;
                                        end_of_day_data <= 32'h00000000;
                                    end

                                else if (data_64 == 32'h0000EC16)
                                    begin
                                        data_64 <= 32'hEFBEADDE;
                                        end_of_day_data <= 32'h649C0000; // MAC0 information
                                    end

                                else if (data_64 == 32'h0000EC18)
                                    begin
                                        data_64 <= 32'h0000EC1A;
                                        end_of_day_data <= 32'h00000000;
                                    end

                                else if (data_64 == 32'h0000EC1A)
                                    begin
                                        data_64 <= 32'hEFBEADDE;
                                        end_of_day_data <= 32'h81080000; // MAC1 information
                                    end

                                else if (data_64 == 32'h0000EC1C)
                                    begin
                                        data_64 <= 32'h0000EC1E;
                                        end_of_day_data <= 32'h00000000;
                                    end

                                else if (data_64 == 32'h0000EC1E)
                                    begin
                                        data_64 <= 32'hEFBEADDE;
                                        end_of_day_data <= 32'hC4C00000; // MAC2 information
                                    end

                                else if (data_64 == 32'h0000EC20)
                                    begin
                                        data_64 <= 32'h0000EC22;
                                        end_of_day_data <= 32'h00000000;
                                    end

                                else if (data_64 == 32'h0000EC22)
                                    begin
                                        data_64 <= 32'hEFBEADDE;
                                        end_of_day_data <= 32'h00000000; // regdomain
                                    end

                                else if (data_64 == 32'h0000EC24)
                                    begin
                                        data_64 <= 32'h0000EC26;
                                        end_of_day_data <= 32'h00000000;
                                    end

                                else if (data_64 == 32'h0000EC26)
                                    begin
                                        data_64 <= 32'hEFBEADDE;
                                        end_of_day_data <= 32'h00010000; // end_of_day_data <= 32'h01010000; // rx/tx mask (1,1) 
                                    end

                                else if (data_64 == 32'h0000ECEC)
                                    begin
                                        data_64 <= 32'hEFBEADDE;
                                        end_of_day_data <= 32'h00000000; // EEPROM test 0x00
                                    end
                                else
                                    begin
                                        data_64 <= 32'h0000ECEC;
                                        end_of_day_data <= 32'h00000000;
                                    end
                            end

                        else if (snoop_addr_dw16[15:0] == 16'h1C00) // 0x7000, AR_RTC_RC
                            begin
                                    end_of_day_data <= 32'h00000000;
                            end

                        else if (snoop_addr_dw16[15:0] == 16'h1C10) // 0x7040, AR_RTC_RESET
                            begin
                                if (snoop_valid_bar_wr)
                                    data_64 <= snoop_data_wr_dw;
                                else
                                    end_of_day_data <= 32'hEFBEADDE;
                            end

                        else if (snoop_addr_dw16[15:0] == 16'h1C11) // 0x7044, AR_RTC_STATUS
                            begin
                                /*
                                if (data_64 == 32'h01000000) // data_64 == 0x01
                                    begin
                                        end_of_day_data <= 32'h02000000; // 0x02
                                        data_64 <= 32'hEFBEADDE;
                                    end
                                else
                                    end_of_day_data <= 32'hEFBEADDE;
                                */
                                end_of_day_data <= 32'h02000000;
                            end

                        else if (snoop_addr_dw16[15:0] == 16'h1C13) // 0x704C, AR_RTC_FORCE_WAKE
                            begin
                                if (snoop_valid_bar_wr)
                                    data_64 <= snoop_data_wr_dw;
                                else
                                    end_of_day_data <= 32'hEFBEADDE;
                            end

                        else if (snoop_addr_dw16[15:0] == 16'h2000) // 0x8000, AR_STA_ID0
                            begin
                                if (snoop_valid_bar_wr)
                                    data_64 <= snoop_data_wr_dw;
                                else
                                    begin
                                        end_of_day_data <= data_64;
                                        data_64 <= 32'hEFBEADDE;
                                    end
                            end

                        else if (snoop_addr_dw16[15:0] == 16'h201B) // 0x806C, AR_OBS_BUS_1
                            begin
                                end_of_day_data <= 32'h00000000;
                            end

                        else if (snoop_addr_dw16[15:0] == 16'h100A) // 0x4028, interrupt pending
                            begin
                                end_of_day_data <= 32'h60000000;
                            end

                        else if (snoop_addr_dw16[15:0] == 16'h100E) // 0x4038, interrupt pending
                            begin
                                end_of_day_data <= 32'h02000000;
                            end

                        else if (snoop_addr_dw16[15:0] == 16'h2608) // 0x9820, AR_STA_ID0
                            begin
                                if (snoop_valid_bar_wr)
                                    data_64 <= snoop_data_wr_dw;
                                else
                                    begin
                                        end_of_day_data <= data_64;
                                        data_64 <= 32'hEFBEADDE;
                                    end
                            end

                        else if (snoop_addr_dw16[15:0] == 16'h2618) // 0x9860, ath_hal_wait
                            begin
                                end_of_day_data <= 32'h00000000;
                            end

                        else if (snoop_addr_dw16[15:0] == 16'h2700) // 0x9C00, rf claim
                            begin
                                end_of_day_data <= 32'h00000000;
                            end
                        else
                            begin
                                // end_of_day_data <= 32'hEFBEADDE;
                                end_of_day_data <= 32'hEFBEADDE; // h01000000
                            end
                    end
            end
    
    
    fifo_55_55_clk2_tlptapcfgspace i_fifo_55_55_clk2_tlptapcfgspace (
        .rst            ( rst                       ),
        .wr_clk         ( clk_pcie                  ),
        .rd_clk         ( clk_100                   ),
        .din            ( {snoop_valid_rd, snoop_be, snoop_addr_dw, snoop_tag, snoop_data_wr_dw}  ),
        .wr_en          ( snoop_valid_rd | snoop_valid_wr   ),
        .rd_en          ( 1'b1                      ),
        .dout           ( {fifotx_tlprd, dshadow2tlp.rx_be, dshadow2tlp.rx_addr, dshadow2tlp.rx_tag, dshadow2tlp.rx_data} ),    
        .full           (                           ),
        .empty          (                           ),
        .valid          ( fifotx_valid              )
    );
    
    assign dshadow2tlp.rx_rden = fifotx_valid & fifotx_tlprd;
    assign dshadow2tlp.rx_wren = fifotx_valid & ~fifotx_tlprd;
    
    wire [7:0]  fiforx_tag;
    wire [31:0] fiforx_data;
    wire        fiforx_tlprd;
    
    fifo_41_41_clk2_tlptapcfgspace i_fifo_41_41_clk2_tlptapcfgspace (
        .rst            ( rst                       ),
        .wr_clk         ( clk_100                   ),
        .rd_clk         ( clk_pcie                  ),
        .din            ( {dshadow2tlp.tx_tlprd, dshadow2tlp.tx_tag, dshadow2tlp.tx_data}   ),
        .wr_en          ( dshadow2tlp.tx_valid      ),
        .rd_en          ( tlp_tx.req_data           ),
        .dout           ( {fiforx_tlprd, fiforx_tag, fiforx_data}   ),    
        .full           (                           ),
        .empty          ( fiforx_empty              ),
        .valid          ( tlp_tx.valid              )
    );
    
    //
    // ( Completion packet )
    //
    wire [63:0]     cpl_tlp_data_qw1_rd  = { `_bs16(tlp_pcie_id), 16'h0004, 32'b01001010000000000000000000000001 };
    wire [63:0]     cpl_tlp_data_qw1_wr  = { `_bs16(tlp_pcie_id), 16'h0000, 32'b00001010000000000000000000000000 };
    wire [63:0]     cpl_tlp_data_qw2     = { bar_read_write ? end_of_day_data : fiforx_data, fifotx_requester_id, fiforx_tag, 8'h00 };
    
    assign tlp_tx.has_data = ~fiforx_empty;
    assign tlp_tx.data = {fiforx_tlprd, 1'b1, cpl_tlp_data_qw2, 2'b10, (fiforx_tlprd ? cpl_tlp_data_qw1_rd : cpl_tlp_data_qw1_wr)};

endmodule



module tlp128_sink_mux1 (
    input                   clk,
    input                   rst,
    IfPCIeTlpRxTx.source    tlp_tx,
    IfTlp128.sink           p0,
    IfTlp16.sink            p1,
    IfTlp64.sink            p2,
    input   [2:0]           pX_en
);
    reg [66 * 18 - 1 : 0]   tlp     = 0;
    
    wire req_data = ~tlp[64] & ~tlp[65] & ~p0.valid & ~p1.valid & ~p2.valid; 
    assign p0.req_data = req_data & pX_en[0] & p0.has_data;
    assign p1.req_data = req_data & pX_en[1] & p1.has_data & ~p0.req_data;
    assign p2.req_data = req_data & pX_en[2] & p2.has_data & ~p0.req_data & ~p1.req_data;
    
    assign tlp_tx.data = tlp[63:0];
    assign tlp_tx.keep = (tlp[64] & ~tlp[65]) ? 8'h0f : 8'hff;
    assign tlp_tx.last = tlp[64];
    assign tlp_tx.valid = tlp_tx.ready & (tlp[64] | tlp[65]);
    
    always @ ( posedge clk )
        if ( rst )
            tlp <= 0;
        else if ( p0.valid )
            tlp <= p0.data;
        else if ( p1.valid )
            tlp <= p1.data;
        else if ( p2.valid )
            tlp <= p2.data;
        else if ( tlp_tx.ready )
            tlp <= (tlp >> 66);
            
endmodule



module tlp128_source_fifo (
    input                   clk_fifo,
    input                   clk,
    input                   rst,
    input [31:0]            dfifo_tx_data,
    input                   dfifo_tx_last,
    input                   dfifo_tx_valid,
    IfTlp128.source         tlp_out
);
    // data ( pcie_tlp_tx_din / tlp_din ) as follows:
    // pcie_tlp_tx_din[31:0]  = 1st DWORD
    // pcie_tlp_tx_din[63:32] = 2nd DWORD
    // pcie_tlp_tx_din[64]    = Last DWORD in TLP
    // pcie_tlp_tx_din[65]    = 2nd DWORD is valid
    wire [65:0]     pcie_tlp_tx_din;
    wire            pcie_tlp_tx_wren;
    reg [31:0]      d_pcie_tlp_tx_data;
    reg             d_pcie_tlp_tx_valid = 1'b0;
    
    assign pcie_tlp_tx_din[31:0] = d_pcie_tlp_tx_valid ? d_pcie_tlp_tx_data : dfifo_tx_data;
    assign pcie_tlp_tx_din[63:32] = dfifo_tx_data;
    assign pcie_tlp_tx_din[64] = dfifo_tx_last;
    assign pcie_tlp_tx_din[65] = d_pcie_tlp_tx_valid;
    assign pcie_tlp_tx_wren = dfifo_tx_valid & ( dfifo_tx_last | d_pcie_tlp_tx_valid );
    
    always @ ( posedge clk_fifo )
        if( rst )
            d_pcie_tlp_tx_valid <= 1'b0;
        else if ( dfifo_tx_valid )
            begin
                d_pcie_tlp_tx_data <= dfifo_tx_data;
                d_pcie_tlp_tx_valid <= ~pcie_tlp_tx_wren;
            end
            
    wire [65:0]     tlp_din;
    wire            tlp_din_valid;
    wire            tlp_din_rd_en;
    
    fifo_66_66 i_fifo_66_66_clk2(
        .rst            ( rst                       ),
        .wr_clk         ( clk_fifo                  ),
        .rd_clk         ( clk                       ),
        .din            ( pcie_tlp_tx_din           ),
        .wr_en          ( pcie_tlp_tx_wren          ),
        .rd_en          ( tlp_din_rd_en             ),
        .dout           ( tlp_din                   ),
        .almost_full    (                           ),
        .full           (                           ),
        .empty          (                           ),
        .valid          ( tlp_din_valid             )
    );
 
    reg [66 * 18 - 1 : 0]   tlp             = 0;
    reg [10:0]              tlp_base        = 0;
    reg                     tlp_complete    = 0;
    reg                     tlp_error       = 0;
    reg                     tlp_valid       = 0;
    
    assign tlp_din_rd_en = ~tlp_complete & ~(tlp_din_valid & tlp_din[64]);
    
    assign tlp_out.data = tlp;
    assign tlp_out.valid = tlp_valid;
    assign tlp_out.has_data = tlp_complete;
    
    always @ ( posedge clk )
        if ( rst | tlp_valid | (tlp_error & tlp_din[64]) )
            begin
                tlp <= 0;
                tlp_base <= 0;
                tlp_complete <= 0;
                tlp_error <= 0;
                tlp_valid <= 0;
            end
        else
            begin
                if ( tlp_complete & tlp_out.req_data )
                    tlp_valid <= 1'b1;
                if ( tlp_din_valid & ~tlp_error )
                    begin
                        tlp[tlp_base+:66] <= tlp_din;
                        if ( tlp_din[64] )
                            tlp_complete <= 1'b1;
                        else if ( tlp_base == 66 * 17 )
                            tlp_error <= 1'b1;
                        else
                            tlp_base <= tlp_base + 66;
                    end
            end

endmodule
