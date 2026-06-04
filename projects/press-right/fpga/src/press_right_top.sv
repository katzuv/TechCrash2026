// Press Right — FPGA Top Module
// Counter increments every 10ms (1/100 sec).
// KEY[0] starts/stops counter.
// Stopped value sent to ESP32 over UART.
// HEX3..0 show 4-digit decimal count.
// LEDR[9:0] show closeness to 1000 (more LEDs = closer).

module press_right_top (
    input           MAX10_CLK1_50,
    input   [9:0]   SW,
    input   [1:0]   KEY,
    output  [9:0]   LEDR,
    output  [7:0]   HEX0, HEX1, HEX2, HEX3, HEX4, HEX5,
    inout   [15:0]  ARDUINO_IO,
    inout           ARDUINO_RESET_N
);

    wire clk   = MAX10_CLK1_50;
    wire rst_n = KEY[1];

    // -------------------------------------------------------
    // KEY[0] edge detect (active-low)
    // -------------------------------------------------------
    reg key0_r, key0_rr;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            key0_r  <= 1'b1;
            key0_rr <= 1'b1;
        end else begin
            key0_r  <= KEY[0];
            key0_rr <= key0_r;
        end
    end
    wire key0_press = key0_rr & ~key0_r;   // falling edge = button pressed

    // -------------------------------------------------------
    // 10 ms tick (50 MHz / 500,000 = 100 Hz)
    // -------------------------------------------------------
    localparam TICK_DIV = 500_000;
    reg [19:0] tick_cnt;
    reg        tick;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tick_cnt <= 0;
            tick     <= 0;
        end else if (tick_cnt == TICK_DIV - 1) begin
            tick_cnt <= 0;
            tick     <= 1;
        end else begin
            tick_cnt <= tick_cnt + 1;
            tick     <= 0;
        end
    end

    // -------------------------------------------------------
    // Counter FSM
    //   IDLE    — waiting for first KEY[0]
    //   RUNNING — counting
    //   STOPPED — value frozen, waiting for reset
    // -------------------------------------------------------
    localparam S_IDLE    = 2'd0,
               S_RUNNING = 2'd1,
               S_STOPPED = 2'd2;

    reg [1:0]  state;
    reg [13:0] counter;      // 0..9999, 14 bits sufficient
    reg        send_pulse;   // one-cycle pulse to begin UART TX

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            counter     <= 0;
            send_pulse  <= 0;
        end else begin
            send_pulse <= 0;

            case (state)
                S_IDLE: begin
                    counter <= 0;
                    if (key0_press)
                        state <= S_RUNNING;
                end

                S_RUNNING: begin
                    if (tick) begin
                        if (counter == 14'd9999)
                            counter <= 0;     // wrap-around
                        else
                            counter <= counter + 1;
                    end
                    if (key0_press) begin
                        state      <= S_STOPPED;
                        send_pulse <= 1;
                    end
                end

                S_STOPPED: begin
                    if (key0_press) begin    // third press resets
                        state   <= S_IDLE;
                        counter <= 0;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // -------------------------------------------------------
    // UART TX  — send stopped value as two bytes, little-endian
    //            low byte first, then high byte
    // -------------------------------------------------------
    reg        tx_start;
    reg  [7:0] tx_data;
    wire       tx_busy;
    wire       tx_out;

    uart_tx #(.CLK_FREQ(50_000_000), .BAUD(9600)) u_tx (
        .clk(clk), .rst_n(rst_n),
        .tx_start(tx_start), .tx_data(tx_data),
        .tx_busy(tx_busy),   .tx_out(tx_out)
    );

    // TX sequencer: send low byte, then high byte
    localparam TX_IDLE  = 2'd0,
               TX_LOW   = 2'd1,
               TX_WAIT  = 2'd2,
               TX_HIGH  = 2'd3;

    reg [1:0]  tx_seq;
    reg [13:0] tx_val;   // latched counter value

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_seq   <= TX_IDLE;
            tx_start <= 0;
            tx_data  <= 0;
            tx_val   <= 0;
        end else begin
            tx_start <= 0;

            case (tx_seq)
                TX_IDLE: begin
                    if (send_pulse) begin
                        tx_val  <= counter;
                        tx_seq  <= TX_LOW;
                    end
                end

                TX_LOW: begin
                    if (!tx_busy) begin
                        tx_data  <= tx_val[7:0];
                        tx_start <= 1;
                        tx_seq   <= TX_WAIT;
                    end
                end

                TX_WAIT: begin
                    // wait for low byte to finish, then send high byte
                    if (!tx_busy && !tx_start) begin
                        tx_data  <= {2'b0, tx_val[13:8]};
                        tx_start <= 1;
                        tx_seq   <= TX_HIGH;
                    end
                end

                TX_HIGH: begin
                    if (!tx_busy && !tx_start)
                        tx_seq <= TX_IDLE;
                end

                default: tx_seq <= TX_IDLE;
            endcase
        end
    end

    // -------------------------------------------------------
    // Arduino header
    // -------------------------------------------------------
    assign ARDUINO_IO[0]    = 1'bz;        // RX input (unused here)
    assign ARDUINO_IO[1]    = tx_out;      // TX to ESP32
    assign ARDUINO_IO[15:2] = {14{1'bz}};

    // -------------------------------------------------------
    // 4-digit BCD decode for HEX3..0
    // -------------------------------------------------------
    // Binary to BCD using double-dabble
    wire [3:0] d3, d2, d1, d0;
    bin_to_bcd u_bcd (
        .bin(counter),
        .thousands(d3), .hundreds(d2), .tens(d1), .ones(d0)
    );

    // Registered display values — latch on tick so segments only update every 10 ms
    reg [3:0] disp3, disp2, disp1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            disp3 <= 0; disp2 <= 0; disp1 <= 0;
        end else if (tick) begin
            disp3 <= d3; disp2 <= d2; disp1 <= d1;
        end
    end

    // DEBUG: SW[1:0]=00->0, 01->2, 10->3, 11->normal
    wire [3:0] hex2_test = (SW[1:0] == 2'b00) ? 4'd0 :
                           (SW[1:0] == 2'b01) ? 4'd2 :
                           (SW[1:0] == 2'b10) ? 4'd3 : disp2;

    seven_segment hex0_dec (.value(4'd0),    .segments(HEX0));  // fixed 0
    seven_segment hex1_dec (.value(disp1),   .segments(HEX1));
    seven_segment hex2_dec (.value(hex2_test),.segments(HEX2));
    seven_segment hex3_dec (.value(disp3),   .segments(HEX3));
 
    // HEX4/5 blank
    assign HEX4 = 8'hFF;
    assign HEX5 = 8'hFF;

    // -------------------------------------------------------
    // LEDR — closeness indicator (only active in STOPPED state)
    // 0 LEDs = far, 10 LEDs = exact
    // diff 0       -> 10 LEDs
    // diff 1-2     ->  9 LEDs
    // diff 3-4     ->  8 LEDs
    // diff 5-6     ->  7 LEDs
    // diff 7-8     ->  6 LEDs
    // diff 9-10    ->  5 LEDs
    // diff 11-20   ->  4 LEDs
    // diff 21-50   ->  3 LEDs
    // diff 51-100  ->  2 LEDs
    // diff 101-200 ->  1 LED
    // diff >200    ->  0 LEDs
    // -------------------------------------------------------
    wire [13:0] diff = (counter >= 14'd1000)
                       ? (counter - 14'd1000)
                       : (14'd1000 - counter);

    reg [3:0] led_count;
    always @(*) begin
        if (state != S_STOPPED) begin
            // running: show activity on LEDR[9]
            led_count = 4'd0;
        end else if (diff == 0)           led_count = 4'd10;
        else if (diff <= 2)               led_count = 4'd9;
        else if (diff <= 4)               led_count = 4'd8;
        else if (diff <= 6)               led_count = 4'd7;
        else if (diff <= 8)               led_count = 4'd6;
        else if (diff <= 10)              led_count = 4'd5;
        else if (diff <= 20)              led_count = 4'd4;
        else if (diff <= 50)              led_count = 4'd3;
        else if (diff <= 100)             led_count = 4'd2;
        else if (diff <= 200)             led_count = 4'd1;
        else                              led_count = 4'd0;
    end

    assign LEDR[0]  = (led_count >= 1)  | (state == S_RUNNING);
    assign LEDR[1]  = (led_count >= 2);
    assign LEDR[2]  = (led_count >= 3);
    assign LEDR[3]  = (led_count >= 4);
    assign LEDR[4]  = (led_count >= 5);
    assign LEDR[5]  = (led_count >= 6);
    assign LEDR[6]  = (led_count >= 7);
    assign LEDR[7]  = (led_count >= 8);
    assign LEDR[8]  = (led_count >= 9);
    assign LEDR[9]  = (led_count >= 10);

endmodule


// ============================================================
// Binary to BCD (double-dabble), 14-bit input -> 4 BCD digits
// ============================================================
module bin_to_bcd (
    input  [13:0] bin,
    output reg [3:0] thousands,
    output reg [3:0] hundreds,
    output reg [3:0] tens,
    output reg [3:0] ones
);
    integer i;
    reg [29:0] scratch;   // [29:16]=BCD digits 4x4, [13:0]=input shift

    always @(*) begin
        scratch = 30'd0;
        scratch[13:0] = bin;

        for (i = 0; i < 14; i = i + 1) begin
            // Add 3 to any BCD digit >= 5
            if (scratch[17:14] >= 5) scratch[17:14] = scratch[17:14] + 3;
            if (scratch[21:18] >= 5) scratch[21:18] = scratch[21:18] + 3;
            if (scratch[25:22] >= 5) scratch[25:22] = scratch[25:22] + 3;
            if (scratch[29:26] >= 5) scratch[29:26] = scratch[29:26] + 3;
            // Shift left
            scratch = scratch << 1;
        end

        ones      = scratch[17:14];
        tens      = scratch[21:18];
        hundreds  = scratch[25:22];
        thousands = scratch[29:26];
    end
endmodule
