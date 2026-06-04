// ADXL345 SPI driver
// SPI Mode 3 (CPOL=1, CPHA=1): SCLK idles HIGH
// ADXL345: samples SDI on rising SCLK, updates SDO on falling SCLK

module adxl345_spi #(
    parameter CLK_DIV = 10  // SCLK = 50MHz / (2*10) = 2.5 MHz
)(
    input  wire              clk,
    input  wire              resetN,
    output reg               sclk,
    output reg               cs_n,
    output reg               mosi,
    input  wire              miso,
    output reg [7:0]         devid,          // DEVID register — should be 0xE5
    output reg signed [15:0] accel_x,
    output reg signed [15:0] accel_y,
    output reg signed [15:0] accel_z,
    output reg               data_valid
);

// SPI command bytes: {R/W, MB, addr[5:0]}
localparam [7:0] CMD_RD_DEVID = 8'h80;  // read,  single, addr=0x00  → should return 0xE5
localparam [7:0] CMD_WR_FMT   = 8'h31;  // write, single, addr=0x31  DATA_FORMAT
localparam [7:0] CMD_WR_PWR   = 8'h2D;  // write, single, addr=0x2D  POWER_CTL
localparam [7:0] CMD_RD_XYZ   = 8'hF2;  // read,  multi,  addr=0x32  DATAX0..DATAZ1

localparam [7:0] VAL_FMT = 8'h08;  // full resolution, +-2g
localparam [7:0] VAL_PWR = 8'h08;  // measurement mode

localparam [3:0]
    ST_POWERON      = 4'd0,
    ST_DEVID_PREP   = 4'd1,   // read DEVID (8 TX + 8 RX = 32 hp)
    ST_DEVID_RUN    = 4'd2,
    ST_DEVID_END    = 4'd3,   // latch devid byte
    ST_WR1_PREP     = 4'd4,
    ST_SPI_WR       = 4'd5,   // 16-bit write (shared)
    ST_GAP          = 4'd6,
    ST_WR2_PREP     = 4'd7,
    ST_RD_PREP      = 4'd8,
    ST_SPI_RD       = 4'd9,   // 56-bit read (8 TX + 48 RX)
    ST_RD_END       = 4'd10,
    ST_THROTTLE     = 4'd11;

reg [3:0] state;
reg [3:0] gap_next;

reg [6:0]  spi_hp;
reg [6:0]  spi_total;     // total half-periods
reg [6:0]  spi_rx_start;  // first odd hp where MISO is sampled
reg [15:0] spi_tx;
reg [47:0] spi_rx;

reg [21:0] wait_cnt;
reg [$clog2(CLK_DIV)-1:0] div_cnt;
reg spi_tick;

always @(posedge clk or negedge resetN) begin
    if (!resetN) begin
        sclk         <= 1'b1;
        cs_n         <= 1'b1;
        mosi         <= 1'b0;
        state        <= ST_POWERON;
        gap_next     <= ST_POWERON;
        spi_hp       <= 7'd0;
        spi_rx       <= 48'd0;
        spi_tx       <= 16'd0;
        spi_total    <= 7'd0;
        spi_rx_start <= 7'd0;
        wait_cnt     <= 22'd0;
        div_cnt      <= '0;
        spi_tick     <= 1'b0;
        devid        <= 8'hFF;
        accel_x      <= 16'sd0;
        accel_y      <= 16'sd0;
        accel_z      <= 16'sd0;
        data_valid   <= 1'b0;
    end else begin
        spi_tick <= 1'b0;
        if (div_cnt == CLK_DIV - 1) begin
            div_cnt  <= '0;
            spi_tick <= 1'b1;
        end else
            div_cnt <= div_cnt + 1;

        data_valid <= 1'b0;

        case (state)

            // Wait ~84 ms for ADXL345 to power up
            ST_POWERON: begin
                wait_cnt <= wait_cnt + 22'd1;
                if (wait_cnt == 22'h3FFFFF) begin
                    wait_cnt <= 22'd0;
                    state    <= ST_DEVID_PREP;
                end
            end

            // Read DEVID register: cmd=0x80, expect 0xE5 back
            // 8 TX bits + 8 RX bits = 16 bits = 32 half-periods
            ST_DEVID_PREP: begin
                spi_tx       <= {CMD_RD_DEVID, 8'h00};
                spi_total    <= 7'd32;
                spi_rx_start <= 7'd17;  // first RX odd hp
                spi_hp       <= 7'd0;
                spi_rx       <= 48'd0;
                cs_n         <= 1'b0;
                mosi         <= CMD_RD_DEVID[7];
                state        <= ST_DEVID_RUN;
            end

            // Generic read engine — reused for DEVID and XYZ reads
            ST_DEVID_RUN: begin
                if (spi_tick) begin
                    if (!spi_hp[0]) begin
                        sclk   <= 1'b0;
                        spi_hp <= spi_hp + 7'd1;
                    end else begin
                        sclk <= 1'b1;
                        if (spi_hp >= spi_rx_start)
                            spi_rx <= {spi_rx[46:0], miso};
                        if (spi_hp == spi_total - 7'd1) begin
                            cs_n  <= 1'b1;
                            state <= ST_DEVID_END;
                        end else begin
                            spi_hp <= spi_hp + 7'd1;
                            mosi   <= (spi_hp + 7'd1 < spi_rx_start - 7'd1)
                                      ? spi_tx[15 - ((spi_hp + 7'd1) >> 1)]
                                      : 1'b0;
                        end
                    end
                end
            end

            ST_DEVID_END: begin
                // spi_rx[7:0] holds the received byte
                devid    <= spi_rx[7:0];
                wait_cnt <= 22'd0;
                state    <= ST_WR1_PREP;
            end

            // Write DATA_FORMAT = 0x08
            ST_WR1_PREP: begin
                spi_tx    <= {CMD_WR_FMT, VAL_FMT};
                spi_total <= 7'd32;
                spi_hp    <= 7'd0;
                cs_n      <= 1'b0;
                mosi      <= CMD_WR_FMT[7];
                gap_next  <= ST_WR2_PREP;
                state     <= ST_SPI_WR;
            end

            // Write POWER_CTL = 0x08
            ST_WR2_PREP: begin
                spi_tx    <= {CMD_WR_PWR, VAL_PWR};
                spi_total <= 7'd32;
                spi_hp    <= 7'd0;
                cs_n      <= 1'b0;
                mosi      <= CMD_WR_PWR[7];
                gap_next  <= ST_RD_PREP;
                state     <= ST_SPI_WR;
            end

            // 16-bit SPI write
            ST_SPI_WR: begin
                if (spi_tick) begin
                    if (!spi_hp[0]) begin
                        sclk   <= 1'b0;
                        spi_hp <= spi_hp + 7'd1;
                    end else begin
                        sclk <= 1'b1;
                        if (spi_hp == spi_total - 7'd1) begin
                            cs_n     <= 1'b1;
                            wait_cnt <= 22'd0;
                            state    <= ST_GAP;
                        end else begin
                            spi_hp <= spi_hp + 7'd1;
                            mosi   <= spi_tx[15 - ((spi_hp + 7'd1) >> 1)];
                        end
                    end
                end
            end

            ST_GAP: begin
                wait_cnt <= wait_cnt + 22'd1;
                if (wait_cnt == 22'd2499) begin
                    wait_cnt <= 22'd0;
                    state    <= gap_next;
                end
            end

            // Read 6 bytes from DATAX0: cmd=0xF2, 8 TX + 48 RX = 56 bits = 112 hp
            ST_RD_PREP: begin
                spi_tx       <= {CMD_RD_XYZ, 8'h00};
                spi_total    <= 7'd112;
                spi_rx_start <= 7'd17;
                spi_hp       <= 7'd0;
                spi_rx       <= 48'd0;
                cs_n         <= 1'b0;
                mosi         <= CMD_RD_XYZ[7];
                state        <= ST_SPI_RD;
            end

            ST_SPI_RD: begin
                if (spi_tick) begin
                    if (!spi_hp[0]) begin
                        sclk   <= 1'b0;
                        spi_hp <= spi_hp + 7'd1;
                    end else begin
                        sclk <= 1'b1;
                        if (spi_hp >= spi_rx_start)
                            spi_rx <= {spi_rx[46:0], miso};
                        if (spi_hp == spi_total - 7'd1) begin
                            cs_n  <= 1'b1;
                            state <= ST_RD_END;
                        end else begin
                            spi_hp <= spi_hp + 7'd1;
                            mosi   <= (spi_hp + 7'd1 < 7'd16) ?
                                      spi_tx[15 - ((spi_hp + 7'd1) >> 1)] : 1'b0;
                        end
                    end
                end
            end

            // spi_rx layout (MSB first per byte):
            //   [47:40]=DATAX0  [39:32]=DATAX1
            //   [31:24]=DATAY0  [23:16]=DATAY1
            //   [15: 8]=DATAZ0  [ 7: 0]=DATAZ1
            ST_RD_END: begin
                accel_x    <= {spi_rx[39:32], spi_rx[47:40]};
                accel_y    <= {spi_rx[23:16], spi_rx[31:24]};
                accel_z    <= {spi_rx[7:0],   spi_rx[15:8]};
                data_valid <= 1'b1;
                wait_cnt   <= 22'd0;
                state      <= ST_THROTTLE;
            end

            ST_THROTTLE: begin
                wait_cnt <= wait_cnt + 22'd1;
                if (wait_cnt == 22'd499_999) begin
                    wait_cnt <= 22'd0;
                    state    <= ST_RD_PREP;
                end
            end

            default: state <= ST_POWERON;
        endcase
    end
end

endmodule
