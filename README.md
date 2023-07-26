# pcileech-wifi
pcileech-fpga with wireless card emulation

# wifi adapter, but not really
![screenshot](https://i.imgur.com/Ri9IEXb.png)

# before building
Make sure to change line **202** (pcileech_pcie_tlp_a7.sv)  
to match your base address register. in my systems, ranges start with **(0xF)** **0xF**8F0000  
so i used (snoop_addr_id == 4'hF); for TLP validation.

```
bar_read_write <= (snoop_valid_bar_rd | snoop_valid_bar_wr) & (snoop_addr_id == 4'hF);
```

# MAC address
pcileech_pcie_tlp_a7.sv. Keep in mind, these DWORD's are backwards. 3,2,1,0.
```
end_of_day_data <= 32'h649C0000; // MAC0 information
end_of_day_data <= 32'h81080000; // MAC1 information
end_of_day_data <= 32'hC4C00000; // MAC2 information
```

