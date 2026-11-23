## PYNQ-Z2 (xc7z020clg400-1) pins for fpga_top.
## From memory of the TUL PYNQ-Z2 master XDC: check against the real file
## before programming a board. For simulation-only use they just need to be
## legal pins.

## 125 MHz PL clock
set_property -dict {PACKAGE_PIN H16 IOSTANDARD LVCMOS33} [get_ports clk125]
create_clock -period 8.000 -name sysclk [get_ports clk125]

## BTN0 = reset
set_property -dict {PACKAGE_PIN D19 IOSTANDARD LVCMOS33} [get_ports btn0]

## LD0-LD3
set_property -dict {PACKAGE_PIN R14 IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN P14 IOSTANDARD LVCMOS33} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN N16 IOSTANDARD LVCMOS33} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN M14 IOSTANDARD LVCMOS33} [get_ports {led[3]}]

## UART TX on Pmod JA pin 1 (connect a 3.3 V USB-UART adapter's RX here)
set_property -dict {PACKAGE_PIN Y18 IOSTANDARD LVCMOS33} [get_ports uart_tx]

## Button and outputs are slow / asynchronous: no I/O timing to meet
set_false_path -from [get_ports btn0]
set_false_path -to [get_ports {led[*] uart_tx}]
