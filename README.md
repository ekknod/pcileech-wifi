# pcileech-wifi
pcileech-fpga with wireless card emulation

# wifi adapter, but not really
![screenshot](https://i.imgur.com/Ri9IEXb.png)

# MAC address (optional)
pio/PIO_EP_MEM_ACCESS.v | 212
```
rd_data_raw_o <= #TCQ 32'h00009C64; // EEPROM_MAC0 (64:9C)
rd_data_raw_o <= #TCQ 32'h00000881; // EEPROM_MAC1 (81:08)
rd_data_raw_o <= #TCQ 32'h0000C0C4; // EEPROM_MAC2 (C4:C0)
```

# Usage
This firmware was created for researching purposes only.  

# Original project by Ulf Frisk
Original project can be found from https://github.com/ufrisk/pcileech-fpga/  
I decided to make separate repository, because my version disables some original features e.g. shadow config space.

# Anti-Cheats
This project was created to test current top Anti-Cheats against FPGA approach with minimal effort / knowledge.  
FACEIT/Vanguard both tested, and Vanguard did take the win on this.  
Project temporary did get through VGK Entry Level detection,  
but just 8 days and it was fixed. Good job again.
