// Parallel 8-bit TX: drives DATA[7:0] + CLK for one byte per transfer
// Replaces uart_tx — same handshake interface (tx_start / tx_busy).
//
// Pin timing (default = 1 MHz byte rate at 50 MHz FPGA clock):
//   SETUP_CYCLES   = data stable, CLK=0 before rising edge
//   CLK_HIGH_CYCS  = CLK=1, ESP32 samples here
//   CLK_LOW_CYCS   = CLK=0 after byte, next-byte prep window
//
// tx_active: high whenever this module is driving the bus (use for tristate)

module parallel_tx #(
    parameter SETUP_CYCLES  = 5,    // 100 ns data setup
    parameter CLK_HIGH_CYCS = 25,   // 500 ns CLK high  (ESP32 must sample here)
    parameter CLK_LOW_CYCS  = 20    // 400 ns CLK low
)(
    input              clk,
    input              rst_n,
    input              tx_start,
    input       [7:0]  tx_data,
    output reg         tx_busy,
    output reg         tx_active,   // 1 = FPGA is driving par_data
    output reg  [7:0]  par_data,
    output reg         par_clk
);

    localparam S_IDLE     = 2'd0,
               S_SETUP    = 2'd1,
               S_CLK_HIGH = 2'd2,
               S_CLK_LOW  = 2'd3;

    reg [1:0] state;
    reg [5:0] cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            tx_busy   <= 0;
            tx_active <= 0;
            par_data  <= 0;
            par_clk   <= 0;
            cnt       <= 0;
        end else begin
            case (state)
                S_IDLE: begin
                    par_clk <= 0;
                    if (tx_start) begin
                        par_data  <= tx_data;
                        tx_busy   <= 1;
                        tx_active <= 1;
                        cnt       <= 0;
                        state     <= S_SETUP;
                    end else begin
                        tx_active <= 0;
                    end
                end

                S_SETUP: begin
                    if (cnt == SETUP_CYCLES - 1) begin
                        par_clk <= 1;
                        cnt     <= 0;
                        state   <= S_CLK_HIGH;
                    end else
                        cnt <= cnt + 1;
                end

                S_CLK_HIGH: begin
                    if (cnt == CLK_HIGH_CYCS - 1) begin
                        par_clk <= 0;
                        cnt     <= 0;
                        state   <= S_CLK_LOW;
                    end else
                        cnt <= cnt + 1;
                end

                S_CLK_LOW: begin
                    if (cnt == CLK_LOW_CYCS - 1) begin
                        tx_busy   <= 0;
                        tx_active <= 0;
                        state     <= S_IDLE;
                    end else
                        cnt <= cnt + 1;
                end
            endcase
        end
    end

endmodule
