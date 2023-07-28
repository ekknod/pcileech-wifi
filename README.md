# pcileech-wifi
pcileech-fpga with wireless card emulation

# wifi adapter, but not really
![screenshot](https://i.imgur.com/Ri9IEXb.png)

# MAC address (optional)
pcileech_pcie_tlp_a7.sv. Keep in mind, these DWORD's are backwards. 3,2,1,0.
```
end_of_day_data <= 32'h649C0000; // MAC0 information
end_of_day_data <= 32'h81080000; // MAC1 information
end_of_day_data <= 32'hC4C00000; // MAC2 information
```

# Known issues, to-do
AMD / Intel z690 systems are not supported for unresolved reason.

# Usage
Research only. this firmware was created to look up current stage of anti-cheats FPGA protection and  
to my surprise, **Vanguard** handles this job very nicely. Good job. 
