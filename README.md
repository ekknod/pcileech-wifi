# pcileech-wifi
pcileech-fpga with wireless card emulation

# wifi adapter, but not really
![screenshot](https://i.imgur.com/Ri9IEXb.png)

# Before building
Make sure to change line **202** (pcileech_pcie_tlp_a7.sv)  
to match your base address register. in my system, ranges start with **(0xF)** **0xF**8F0000  
so i personally used (snoop_addr_id == 4'hF); for TLP validation.

```
bar_read_write <= (snoop_valid_bar_rd | snoop_valid_bar_wr) & (snoop_addr_id == 4'hF);
```

# MAC address (optional)
pcileech_pcie_tlp_a7.sv. Keep in mind, these DWORD's are backwards. 3,2,1,0.
```
end_of_day_data <= 32'h649C0000; // MAC0 information
end_of_day_data <= 32'h81080000; // MAC1 information
end_of_day_data <= 32'hC4C00000; // MAC2 information
```

# Known issues, to-do
AMD systems are not supported for unresolved reason. when i started this project  
i found out AMD systems can access only certain addresses (0x00, 0x80, 0x180) from BAR.  
TLP validation could be done better as well -> with better "BAR hit" detection.  

# Usage
Research only. this firmware was created to look up current stage of anti-cheats FPGA protection and  
to my surprise, **Vanguard** handles this job very nicely. Good job. 
