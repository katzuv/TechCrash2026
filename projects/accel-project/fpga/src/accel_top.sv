// Top module: ADXL345 accelerometer reader
//
// HEX1:HEX0 = DEVID register  — should be 0xE5 if SPI works
// HEX3:HEX2 = accel_x low byte
// HEX5:HEX4 = accel_y low byte
// LEDR[7:0] = X tilt (right=7-4, left=3-0)
// LEDR[8]   = sensor_ok (lit after first valid read)
// LEDR[9]   = 1 Hz heartbeat
// SW[9]     = resetN

module accel_top (
    input  wire        MAX10_CLK1_50,
    input  wire [9:0]  SW,
    input  wire [1:0]  KEY,
    output wire [9:0]  LEDR,
    output wire [7:0]  HEX0, HEX1, HEX2, HEX3, HEX4, HEX5,
    output wire        GSENSOR_SCLK,
    output wire        GSENSOR_CS_N,
    output wire        GSENSOR_SDI,
    input  wire        GSENSOR_SDO
);

wire resetN = SW[9];

wire               sclk, cs_n, mosi;
wire [7:0]         devid;
wire signed [15:0] accel_x, accel_y, accel_z;
wire               data_valid;

adxl345_spi #(.CLK_DIV(10)) accel_inst (
    .clk       (MAX10_CLK1_50),
    .resetN    (resetN),
    .sclk      (sclk),
    .cs_n      (cs_n),
    .mosi      (mosi),
    .miso      (GSENSOR_SDO),
    .devid     (devid),
    .accel_x   (accel_x),
    .accel_y   (accel_y),
    .accel_z   (accel_z),
    .data_valid(data_valid)
);

assign GSENSOR_SCLK = sclk;
assign GSENSOR_CS_N = cs_n;
assign GSENSOR_SDI  = mosi;

// 1 Hz heartbeat
reg [25:0] beat_cnt;
reg        heartbeat;
always @(posedge MAX10_CLK1_50 or negedge resetN) begin
    if (!resetN) begin
        beat_cnt  <= 26'd0;
        heartbeat <= 1'b0;
    end else if (beat_cnt == 26'd24_999_999) begin
        beat_cnt  <= 26'd0;
        heartbeat <= ~heartbeat;
    end else
        beat_cnt <= beat_cnt + 26'd1;
end

// Sensor OK: latches after first data
reg sensor_ok;
always @(posedge MAX10_CLK1_50 or negedge resetN) begin
    if (!resetN)         sensor_ok <= 1'b0;
    else if (data_valid) sensor_ok <= 1'b1;
end

// X-axis tilt meter
assign LEDR[7] = (accel_x > 16'sd300);
assign LEDR[6] = (accel_x > 16'sd150);
assign LEDR[5] = (accel_x > 16'sd50);
assign LEDR[4] = (accel_x > 16'sd10);
assign LEDR[3] = (accel_x < -16'sd10);
assign LEDR[2] = (accel_x < -16'sd50);
assign LEDR[1] = (accel_x < -16'sd150);
assign LEDR[0] = (accel_x < -16'sd300);
assign LEDR[8] = sensor_ok;
assign LEDR[9] = heartbeat;

// HEX1:HEX0 = DEVID  (should be E5 when SPI is working)
// HEX3:HEX2 = accel_x low byte
// HEX5:HEX4 = accel_y low byte
seven_segment hex0_inst (.value(devid[3:0]),   .segments(HEX0));
seven_segment hex1_inst (.value(devid[7:4]),   .segments(HEX1));
seven_segment hex2_inst (.value(accel_x[3:0]), .segments(HEX2));
seven_segment hex3_inst (.value(accel_x[7:4]), .segments(HEX3));
seven_segment hex4_inst (.value(accel_y[3:0]), .segments(HEX4));
seven_segment hex5_inst (.value(accel_y[7:4]), .segments(HEX5));

endmodule
