
module sms2hdmi (
	input clk,
	input resetn,

    // sms video signals
    input ce_pix,
    input [8:0] x,
    input [8:0] y,
    input [11:0] color,

    input [15:0] audio_l,
    input [15:0] audio_r,
    input [3:0] volume,       // master volume 0-10 from iosys (hdmi.sv brings it into the pixel clock)

    // overlay interface
    input overlay,
    input osd_strip,            // with overlay: only the strip (volume bar), over the running game
    output [7:0] overlay_x,
    output [7:0] overlay_y,
    input [14:0] overlay_color, // BGR5

	// video clocks
	input clk_pixel,
	input clk_5x_pixel,

	// output signals
	output       tmds_clk_n,
	output       tmds_clk_p,
	output [2:0] tmds_d_n,
	output [2:0] tmds_d_p
);

localparam CLKFRQ = 74250;
localparam AUDIO_BIT_WIDTH = 16;

// video stuff
wire [9:0] cy;
wire [10:0] cx;

//
// BRAM frame buffer
//
localparam MEM_DEPTH=256*192;

logic [11:0] mem [0:MEM_DEPTH-1];       // 72 KB
logic [15:0] mem_portA_addr;
logic [11:0] mem_portA_wdata;           // BGR444
logic mem_portA_we;

wire [15:0] mem_portB_addr;
logic [11:0] mem_portB_rdata;

// BRAM port A read/write
always @(posedge clk) begin
    if (mem_portA_we) begin
        mem[mem_portA_addr] <= mem_portA_wdata;
    end
end

// BRAM port B read
always @(posedge clk_pixel) begin
    mem_portB_rdata <= mem[mem_portB_addr];
end

// 
// Data input and initial background loading
//
logic [8:0] x_r;
logic [8:0] y_r;
always @(posedge clk) begin
    x_r <= x;
    y_r <= y;
    mem_portA_we <= 1'b0;
    if (ce_pix && y < 192 && x != 0 && x <= 256) begin  // the core outputs image from 1 to 256
        mem_portA_addr[15:8] <= y[7:0];
        mem_portA_addr[7:0] <= x[7:0] - 8'b1;
        mem_portA_wdata[11:0] <= color;
        mem_portA_we <= 1'b1;
    end
end

// audio stuff
localparam AUDIO_RATE=48000;
localparam AUDIO_CLK_DELAY = CLKFRQ * 1000 / AUDIO_RATE / 2;
logic [$clog2(AUDIO_CLK_DELAY)-1:0] audio_divider;
logic clk_audio;

always_ff@(posedge clk_pixel) 
begin
    if (audio_divider != AUDIO_CLK_DELAY - 1) 
        audio_divider++;
    else begin 
        clk_audio <= ~clk_audio; 
        audio_divider <= 0; 
    end
end

// Audio into clk_pixel, all 16 bits from one sample (audio_cdc.v). The mix is signed with
// silence at 0, so both sides power up at 0.
wire [15:0] audio_pix_l, audio_pix_r;
audio_cdc #(.W(16), .INIT(16'd0)) audio_cdc_inst (
    .clk_src(clk), .in_l(audio_l), .in_r(audio_r),
    .clk_dst(clk_pixel), .out_l(audio_pix_l), .out_r(audio_pix_r)
);
logic [15:0] audio_sample_word [1:0];
assign audio_sample_word[0] = audio_pix_l;
assign audio_sample_word[1] = audio_pix_r;

//
// Video
// Scale SMS image from 256x192 to 960x720
// Menu: textdisp's 256x224 at 3x in a 768x672 window, as in common/video/video_out.v
//
localparam WIDTH=256;
localparam HEIGHT=192;
reg [23:0] rgb;             // actual RGB output
reg active                  ;
reg [$clog2(WIDTH)-1:0] xx  ; // scaled-down pixel position
reg [$clog2(HEIGHT)-1:0] yy ;
reg [10:0] xcnt             ;
reg [10:0] ycnt             ;                  // fractional scaling counters
reg [9:0] cy_r;
assign mem_portB_addr = yy * WIDTH + xx;
localparam XSTART = (1280 - 960) / 2;   // 960:720 = 4:3
localparam XSTOP = (1280 + 960) / 2;

// address calculation
// Assume the video occupies fully on the Y direction, we are upscaling the video by `720/height`.
// xcnt and ycnt are fractional scaling counters.
always @(posedge clk_pixel) begin
    reg active_t;
    reg [10:0] xcnt_next;
    reg [10:0] ycnt_next;
    xcnt_next = xcnt + 256;
    ycnt_next = ycnt + 192;

    active_t = 0;
    if (cx == XSTART - 1) begin
        active_t = 1;
        active <= 1;
    end else if (cx == XSTOP - 1) begin
        active_t = 0;
        active <= 0;
    end

    if (active_t | active) begin        // increment xx
        xcnt <= xcnt_next;
        if (xcnt_next >= 960) begin
            xcnt <= xcnt_next - 960;
            xx <= xx + 1;
        end
    end

    cy_r <= cy;
    if (cy[0] != cy_r[0]) begin         // increment yy at new lines
        ycnt <= ycnt_next;
        if (ycnt_next >= 720) begin
            ycnt <= ycnt_next - 720;
            yy <= yy + 1;
        end
    end

    if (cx == 0) begin
        xx <= 0;
        xcnt <= 0;
    end
    
    if (cy == 0) begin
        yy <= 0;
        ycnt <= 0;
    end 

end

//
// Menu window, the same pixels as video_out.v. textdisp returns the color of (overlay_x,
// overlay_y) 2 cycles later and needs at least 3 cycles per x step. The position counter
// works on pixel hpos = cx + LAT; rgb, which the HDMI encoder reads, is stage 6.
//
localparam LAT = 6;
localparam [10:0] LINE_EVT = 11'd1290;  // next line's overlay_y is set here, in horizontal blanking
localparam [10:0] MENU_X0 = 11'd256;    // window left edge
localparam [9:0]  MENU_Y0 = 10'd24;     // window top edge
// Strip (osd_strip, the volume bar): text columns 8-23 of rows 23-24, 128x16 pixels (the
// firmware's OVERLAY_STRIP_*), on a band 2 pixels (6 output pixels) wider on every side
localparam [10:0] STRIP_X0 = MENU_X0 + 11'd192;     // column 8
localparam [10:0] STRIP_X1 = MENU_X0 + 11'd576;     // after column 23
localparam [9:0]  STRIP_Y0 = MENU_Y0 + 10'd552;     // row 23
localparam [9:0]  STRIP_Y1 = MENU_Y0 + 10'd600;     // after row 24

wire [10:0] hpos = cx + LAT;
wire [9:0] next_line = cy == 10'd749 ? 10'd0 : cy + 10'd1;
reg [7:0] mx, my;
reg [1:0] mx_ph, my_ph;
assign overlay_x = mx;
assign overlay_y = my;
always @(posedge clk_pixel) begin
    if (hpos == MENU_X0 - 11'd1) begin
        mx <= 8'd255;
        mx_ph <= 0;
    end else if (mx_ph == 2'd2) begin
        mx <= mx + 8'd1;
        mx_ph <= 0;
    end else
        mx_ph <= mx_ph + 2'd1;

    if (cx == LINE_EVT) begin
        if (next_line == MENU_Y0) begin
            my <= 0;
            my_ph <= 0;
        end else if (my_ph == 2'd2) begin
            my <= my + 8'd1;
            my_ph <= 0;
        end else
            my_ph <= my_ph + 2'd1;
    end
end

wire menu_win0 = hpos >= MENU_X0 && hpos < MENU_X0 + 11'd768 &&
                 cy >= MENU_Y0 && cy < MENU_Y0 + 10'd672;
reg [4:0] menu_win_d;
always @(posedge clk_pixel)
    menu_win_d <= {menu_win_d[3:0], menu_win0};
wire menu_win5 = menu_win_d[4];
wire strip_win0 = hpos >= STRIP_X0 && hpos < STRIP_X1 && cy >= STRIP_Y0 && cy < STRIP_Y1;
wire band_win0 = hpos >= STRIP_X0 - 11'd6 && hpos < STRIP_X1 + 11'd6 &&
                 cy >= STRIP_Y0 - 10'd6 && cy < STRIP_Y1 + 10'd6;
reg [4:0] strip_win_d, band_win_d;
always @(posedge clk_pixel) begin
    strip_win_d <= {strip_win_d[3:0], strip_win0};
    band_win_d <= {band_win_d[3:0], band_win0};
end
wire strip_win5 = strip_win_d[4];
wire band_win5 = band_win_d[4];

// osd_strip from the core clock domain: two flip-flops, the first *_meta
reg strip_meta, strip_r;
always @(posedge clk_pixel)
    {strip_r, strip_meta} <= {strip_meta, osd_strip};

// BGR5 to RGB888, low bits repeated so that 31 becomes 255
wire [23:0] menu_rgb = {overlay_color[4:0],   overlay_color[4:2],
                        overlay_color[9:5],   overlay_color[9:7],
                        overlay_color[14:10], overlay_color[14:12]};

// calc rgb value to hdmi: the menu over the game dimmed to 1/4; the strip (volume bar) in
// white on a band of the game dimmed to 1/8 with a green tint. Black around the picture.
always @(posedge clk_pixel) begin
    reg [23:0] game;
    game = active ? {mem_portB_rdata[3:0], 4'b0, mem_portB_rdata[7:4], 4'b0, mem_portB_rdata[11:8], 4'b0} // BGR4 to RGB8
                  : 24'h000000;
    if (overlay && ~strip_r)
        rgb <= menu_win5 && overlay_color != 15'd0 ? menu_rgb
             : {2'b0, game[23:18], 2'b0, game[15:10], 2'b0, game[7:2]};
    else if (overlay && band_win5)
        rgb <= strip_win5 && overlay_color != 15'd0 ? 24'hFFFFFF
             : {3'b000, game[23:19], 3'b010, game[15:11], 3'b000, game[7:3]};
    else
        rgb <= game;
end

// HDMI output.
logic[2:0] tmds;

localparam VIDEOID = 4;
localparam VIDEO_REFRESH = 60.0;

hdmi #( .VIDEO_ID_CODE(VIDEOID), 
        .DVI_OUTPUT(0), 
        .VIDEO_REFRESH_RATE(VIDEO_REFRESH),
        .IT_CONTENT(1),
        .RGB_QUANTIZATION_RANGE(2'b01),    // limited range (16-235), converted in hdmi.sv
        .CONTENT_TYPE(2'b11),              // Game
        .AUDIO_RATE(AUDIO_RATE), 
        .AUDIO_BIT_WIDTH(AUDIO_BIT_WIDTH),
        .START_X(0),
        .START_Y(0) )

hdmi( .clk_pixel_x5(clk_5x_pixel), 
        .clk_pixel(clk_pixel), 
        .clk_audio(clk_audio),
        .rgb(rgb), 
        .reset( 0 ),
        .audio_sample_word(audio_sample_word),
        .volume(volume),
        .tmds(tmds), 
        .tmds_clock(tmdsClk), 
        .cx(cx), 
        .cy(cy),
        .frame_width( ),
        .frame_height( ) );

// Gowin LVDS output buffer
ELVDS_OBUF tmds_bufds [3:0] (
    .I({clk_pixel, tmds}),
    .O({tmds_clk_p, tmds_d_p}),
    .OB({tmds_clk_n, tmds_d_n})
);

endmodule
