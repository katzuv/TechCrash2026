// Parallel 8-bit RX — replaces UART RX for Speed Loopback challenge.
// Captures the 1-byte checksum from ESP32 when par_valid pulses high.
//
// par_data[7:0] must be stable when par_valid rises; ESP32 holds it for 2 ms.
// 3-stage synchroniser on par_valid prevents metastability.

module uart_rx #(
    parameter CLK_FREQ = 50_000_000,    // kept for port compatibility
    parameter BAUD     = 9600           // kept for port compatibility
)(
    input             clk,
    input             rst_n,
    input      [7:0]  par_data,         // driven by ESP32 (FPGA bus in high-Z)
    input             par_valid,        // ESP32 pulses high when checksum is ready
    output reg [7:0]  rx_data,
    output reg        rx_valid
);

    // 3-stage synchroniser for par_valid
    reg [2:0] vsync;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) vsync <= 0;
        else        vsync <= {vsync[1:0], par_valid};
    end
    wire valid_rise = vsync[1] & ~vsync[2];   // rising edge of synchronised signal

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_data  <= 0;
            rx_valid <= 0;
        end else begin
            rx_valid <= 0;
            if (valid_rise) begin
                rx_data  <= par_data;   // stable for >> 60 ns at this point
                rx_valid <= 1;
            end
        end
    end

endmodule
