// Speed Loopback Top Module — PARALLEL 8-bit interface
// FPGA generates N random bytes, sends to ESP32 via 8-bit parallel bus.
// ESP32 sums them and sends back checksum (LSB 8 bits).
// FPGA compares and displays elapsed time in ms.
//
// Parallel interface (Arduino header):
//   ARDUINO_IO[8:1] = DATA[7:0]   bidirectional: FPGA drives during send,
//                                  ESP32 drives during response
//   ARDUINO_IO[9]   = TX_CLK      FPGA output (1 pulse per byte)
//   ARDUINO_IO[10]  = RX_VALID    ESP32 output (pulse after checksum is ready)
//
// Wiring (jumper wires from Arduino header to ESP32):
//   ARDUINO_IO[1]  <-> ESP32 GPIO5   (DATA[0])
//   ARDUINO_IO[2]  <-> ESP32 GPIO13  (DATA[1])
//   ARDUINO_IO[3]  <-> ESP32 GPIO14  (DATA[2])
//   ARDUINO_IO[4]  <-> ESP32 GPIO27  (DATA[3])
//   ARDUINO_IO[5]  <-> ESP32 GPIO26  (DATA[4])
//   ARDUINO_IO[6]  <-> ESP32 GPIO25  (DATA[5])
//   ARDUINO_IO[7]  <-> ESP32 GPIO33  (DATA[6])
//   ARDUINO_IO[8]  <-> ESP32 GPIO32  (DATA[7])
//   ARDUINO_IO[9]  <-> ESP32 GPIO35  (TX_CLK, input-only on ESP32)
//   ARDUINO_IO[10] <-> ESP32 GPIO16  (RX_VALID, output from ESP32)
//
// Fixed infrastructure (UNCHANGED per challenge rules):
//   LFSR-16, sum accumulator, timer, comparator, state machine, data count
//
// SW[9]   debug mode: show expected/received checksums instead of timer
// KEY[0]  start / restart
// KEY[1]  reset (active low)
// HEX5-0  elapsed ms (hex) in DONE, progress during send, count in IDLE
// LEDR[9] running, LEDR[0] pass, LEDR[1] fail

module speed_loopback_top(
    input         MAX10_CLK1_50,
    input  [1:0]  KEY,
    input  [9:0]  SW,
    output [9:0]  LEDR,
    output [7:0]  HEX0, HEX1, HEX2, HEX3, HEX4, HEX5,
    inout  [15:0] ARDUINO_IO
);

    wire clk   = MAX10_CLK1_50;
    wire rst_n  = KEY[1];

    // ---- Edge detect KEY[0] (active-low button) ----
    reg key0_r, key0_rr;
    always @(posedge clk) begin
        key0_r  <= KEY[0];
        key0_rr <= key0_r;
    end
    wire start_pulse = key0_rr & ~key0_r;   // falling edge

    // ---- Fixed data count: 10,000 bytes ----
    wire [31:0] total_count = 32'd10_000;

    // ---- LFSR-16 (x^16 + x^15 + x^13 + x^4 + 1) ----
    reg [15:0] lfsr;
    wire lfsr_feedback = lfsr[15] ^ lfsr[14] ^ lfsr[12] ^ lfsr[3];

    // ---- Checksum accumulator ----
    reg [31:0] sum;

    // ---- Parallel TX (FPGA -> ESP32) ----
    reg        tx_start;
    reg  [7:0] tx_data;
    wire       tx_busy;
    wire       tx_active;
    wire [7:0] par_data_out;
    wire       par_clk_out;

    parallel_tx u_tx (
        .clk(clk), .rst_n(rst_n),
        .tx_start(tx_start), .tx_data(tx_data),
        .tx_busy(tx_busy),   .tx_active(tx_active),
        .par_data(par_data_out), .par_clk(par_clk_out)
    );

    // ---- Parallel RX (ESP32 -> FPGA): data on ARDUINO_IO[8:1], valid on [10] ----
    wire [7:0] rx_data;
    wire       rx_valid;

    parallel_rx u_rx (
        .clk(clk), .rst_n(rst_n),
        .par_data(ARDUINO_IO[8:1]),
        .par_valid(ARDUINO_IO[10]),
        .rx_data(rx_data), .rx_valid(rx_valid)
    );

    // ---- Arduino Header IO ----
    // DATA[7:0] bidirectional: FPGA drives when tx_active, else high-Z (ESP32 drives)
    genvar g;
    generate
        for (g = 1; g <= 8; g++) begin : gen_data
            assign ARDUINO_IO[g] = tx_active ? par_data_out[g-1] : 1'bz;
        end
    endgenerate

    assign ARDUINO_IO[9]     = par_clk_out;  // TX CLK: FPGA output
    assign ARDUINO_IO[10]    = 1'bz;         // RX_VALID: ESP32 drives, FPGA reads
    assign ARDUINO_IO[0]     = 1'bz;
    assign ARDUINO_IO[15:11] = {5{1'bz}};

    // ---- Millisecond timer ----
    reg [31:0] timer_ms;
    reg [15:0] timer_pre;
    reg        timer_running, timer_reset;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            timer_ms  <= 0;
            timer_pre <= 0;
        end else if (timer_reset) begin
            timer_ms  <= 0;
            timer_pre <= 0;
        end else if (timer_running) begin
            if (timer_pre == 16'd49_999) begin
                timer_pre <= 0;
                timer_ms  <= timer_ms + 1;
            end else
                timer_pre <= timer_pre + 1;
        end
    end

    // ---- State machine ----
    localparam S_IDLE = 3'd0,
               S_HDR  = 3'd1,
               S_DATA = 3'd2,
               S_WAIT = 3'd3,
               S_DONE = 3'd4;

    reg [2:0]  state;
    reg [31:0] send_count;
    reg [1:0]  hdr_idx;
    reg        pass;
    reg [7:0]  rx_checksum;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= S_IDLE;
            lfsr          <= 16'hACE1;
            sum           <= 0;
            send_count    <= 0;
            hdr_idx       <= 0;
            pass          <= 0;
            rx_checksum   <= 0;
            tx_start      <= 0;
            timer_running <= 0;
            timer_reset   <= 0;
        end else begin
            tx_start    <= 0;       // default: one-cycle pulse
            timer_reset <= 0;

            // ---- Start / Restart ----
            if (start_pulse && (state == S_IDLE || state == S_DONE)) begin
                state         <= S_HDR;
                lfsr          <= 16'hACE1;
                sum           <= 0;
                send_count    <= 0;
                hdr_idx       <= 0;
                pass          <= 0;
                timer_reset   <= 1;
                timer_running <= 1;
            end else begin
                case (state)
                    S_IDLE: ;   // wait for start_pulse

                    // Send 4-byte header: total_count little-endian
                    S_HDR: begin
                        if (!tx_busy && !tx_start) begin
                            case (hdr_idx)
                                2'd0: tx_data <= total_count[7:0];
                                2'd1: tx_data <= total_count[15:8];
                                2'd2: tx_data <= total_count[23:16];
                                2'd3: tx_data <= total_count[31:24];
                            endcase
                            tx_start <= 1;
                            if (hdr_idx == 2'd3)
                                state <= S_DATA;
                            hdr_idx <= hdr_idx + 1;
                        end
                    end

                    // Send N random bytes
                    S_DATA: begin
                        if (!tx_busy && !tx_start) begin
                            if (send_count < total_count) begin
                                tx_data    <= lfsr[7:0];
                                tx_start   <= 1;
                                sum        <= sum + {24'd0, lfsr[7:0]};
                                lfsr       <= {lfsr[14:0], lfsr_feedback};
                                send_count <= send_count + 1;
                            end else begin
                                state <= S_WAIT;
                            end
                        end
                    end

                    // Wait for ESP32 checksum byte
                    S_WAIT: begin
                        if (rx_valid) begin
                            rx_checksum   <= rx_data;
                            timer_running <= 0;
                            pass          <= (rx_data == sum[7:0]);
                            state         <= S_DONE;
                        end
                    end

                    S_DONE: ;   // wait for start_pulse
                endcase
            end
        end
    end

    // ---- Display mux ----
    reg [23:0] disp;
    always @(*) begin
        case (state)
            S_IDLE:  disp = total_count[23:0];
            S_HDR:   disp = 24'd0;
            S_DATA:  disp = send_count[23:0];
            S_WAIT:  disp = send_count[23:0];
            S_DONE:  disp = SW[9] ? {8'd0, sum[7:0], rx_checksum}
                                  : timer_ms[23:0];
            default: disp = 24'd0;
        endcase
    end

    seven_segment seg0(.value(disp[3:0]),   .segments(HEX0));
    seven_segment seg1(.value(disp[7:4]),   .segments(HEX1));
    seven_segment seg2(.value(disp[11:8]),  .segments(HEX2));
    seven_segment seg3(.value(disp[15:12]), .segments(HEX3));
    seven_segment seg4(.value(disp[19:16]), .segments(HEX4));
    seven_segment seg5(.value(disp[23:20]), .segments(HEX5));

    // ---- LEDs ----
    assign LEDR[9]   = timer_running;
    assign LEDR[8]   = (state == S_DONE);
    assign LEDR[7:2] = 6'd0;
    assign LEDR[1]   = (state == S_DONE) & ~pass;
    assign LEDR[0]   = (state == S_DONE) &  pass;

endmodule
