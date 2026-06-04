// Parallel 8-bit RX: captures one byte when par_valid pulses high.
// Replaces uart_rx — same output interface (rx_data / rx_valid).
//
// par_data[7:0] must be stable when par_valid rises and held for 1+ ms.
// 3-stage synchroniser on par_valid to prevent metastability.

module parallel_rx (
    input             clk,
    input             rst_n,
    input      [7:0]  par_data,    // driven by ESP32 (bus is high-Z from FPGA)
    input             par_valid,   // ESP32 pulses high when data is ready
    output reg [7:0]  rx_data,
    output reg        rx_valid
);

    // 3-stage synchroniser for par_valid
    reg [2:0] vsync;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) vsync <= 0;
        else        vsync <= {vsync[1:0], par_valid};
    end
    wire valid_rise = vsync[1] & ~vsync[2];   // rising edge of synchronised valid

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_data  <= 0;
            rx_valid <= 0;
        end else begin
            rx_valid <= 0;
            if (valid_rise) begin
                rx_data  <= par_data;   // data stable for >> 60 ns at this point
                rx_valid <= 1;
            end
        end
    end

endmodule
