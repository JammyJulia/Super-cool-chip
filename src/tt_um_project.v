`timescale 1ns/1ps
`default_nettype none

/*
 * Guitar Hero style VGA game for the Tiny Tapeout VGA Playground.
 * (Note Pool Architecture Edition)
 */
module tt_um_project (
    input  wire [7:0] ui_in,     // 8 buttons
    output wire [7:0] uo_out,    // VGA (Tiny VGA pinout)
    input  wire [7:0] uio_in,    // unused
    output wire [7:0] uio_out,   // sound (all pins identical)
    output wire [7:0] uio_oe,    // sound pins driven as outputs
    input  wire       ena,       // unused (always 1)
    input  wire       clk,       // pixel clock (~25 MHz)
    input  wire       rst_n      // active low reset
);

    // ------------------------------------------------------------------
    // 3x5 bitmap font. Each glyph is 15 bits, 5 rows of 3, 12MSB = top-left.
    // ------------------------------------------------------------------
    function [14:0] glyph;
        input [4:0] c;
        case (c)
            5'd0:    glyph = 15'b000_000_000_000_000; // space
            5'd1:    glyph = 15'b111_101_101_101_111; // 0
            5'd2:    glyph = 15'b010_110_010_010_111; // 1
            5'd3:    glyph = 15'b111_001_111_100_111; // 2
            5'd4:    glyph = 15'b111_001_111_001_111; // 3
            5'd5:    glyph = 15'b101_101_111_001_001; // 4
            5'd6:    glyph = 15'b111_100_111_001_111; // 5
            5'd7:    glyph = 15'b111_100_111_101_111; // 6
            5'd8:    glyph = 15'b111_001_001_001_001; // 7
            5'd9:    glyph = 15'b111_101_111_101_111; // 8
            5'd10:   glyph = 15'b111_101_111_001_111; // 9
            5'd11:   glyph = 15'b111_100_111_001_111; // S
            5'd12:   glyph = 15'b111_100_100_100_111; // C
            5'd13:   glyph = 15'b101_101_111_101_101; // H
            5'd14:   glyph = 15'b111_010_010_010_111; // I
            5'd15:   glyph = 15'b111_101_111_100_100; // P
            5'd16:   glyph = 15'b111_101_111_101_101; // A
            5'd17:   glyph = 15'b101_101_101_101_111; // U
            5'd18:   glyph = 15'b111_100_111_100_111; // E
            5'd19:   glyph = 15'b111_010_010_010_010; // T
            5'd20:   glyph = 15'b111_101_111_110_101; // R
            5'd21:   glyph = 15'b111_100_101_101_111; // G
            5'd22:   glyph = 15'b111_101_101_101_111; // O
            default: glyph = 15'b000_000_000_000_000;
        endcase
    endfunction

    function pixbit;
        input [14:0] g;
        input [2:0]  gy;
        input [1:0]  gx;
        input        valid;
        begin
            if (!valid) pixbit = 1'b0;
            else        pixbit = g[14 - 3*gy - gx];
        end
    endfunction

    localparam [4:0] C_SP = 5'd0;
    localparam [4:0] C_S  = 5'd11, C_C = 5'd12, C_H = 5'd13, C_I = 5'd14;
    localparam [4:0] C_P  = 5'd15, C_A = 5'd16, C_U = 5'd17,
                     C_E  = 5'd18, C_T = 5'd19, C_R = 5'd20,
                     C_G  = 5'd21, C_O = 5'd22;

    // ------------------------------------------------------------------
    // VGA timing
    // ------------------------------------------------------------------
    wire        hsync;
    wire        vsync;
    wire        display_on;
    wire [9:0]  hpos;
    wire [9:0]  vpos;

    hvsync_generator vga_sync (
        .clk        (clk),
        .reset      (~rst_n),
        .hsync      (hsync),
        .vsync      (vsync),
        .display_on (display_on),
        .hpos       (hpos),
        .vpos       (vpos)
    );

    wire [4:0] str_btn    = ui_in[4:0];
    wire       gostop_btn = ui_in[5];
    wire       pause_btn  = ui_in[6];

    wire frame_tick = (hpos == 10'd0) && (vpos == 10'd0);

    // ------------------------------------------------------------------
    // Game constants
    // ------------------------------------------------------------------
    localparam integer SPEED     = 25;    // Note falling speed
    localparam integer NOTE_H    = 24;
    localparam integer HIT_Y     = 408;
    localparam integer HIT_LO    = HIT_Y - NOTE_H - NOTE_H/2;
    localparam integer HIT_HI    = HIT_Y + NOTE_H + NOTE_H/2;
    localparam integer PENALTY   = 2;
    
    // NOTE POOL ARCHITECTURE: We can have up to 12 notes active at once anywhere
    localparam integer POOL_SIZE = 12;

    localparam [23:0] TONE0 = 24'd21;
    localparam [23:0] TONE1 = 24'd28;
    localparam [23:0] TONE2 = 24'd37;
    localparam [23:0] TONE3 = 24'd49;
    localparam [23:0] TONE4 = 24'd66;
    localparam [23:0] BEEP_K = 24'd644;
    localparam [15:0] HIT_LEN  = 16'd6000;
    localparam [15:0] MISS_LEN = 16'd9000;

    localparam [7:0] FPB = 8'd20;
    localparam [2:0] L_Q = 3'd0, L_E = 3'd1, L_S = 3'd2, L_H = 3'd3, L_W = 3'd4;

    function [7:0] len_frames;
        input [2:0] n;
        case (n)
            3'd0:    len_frames = FPB;
            3'd1:    len_frames = FPB >> 1;
            3'd2:    len_frames = FPB >> 2;
            3'd3:    len_frames = FPB << 1;
            3'd4:    len_frames = FPB << 2;
            default: len_frames = FPB;
        endcase
    endfunction

    reg [4:0] step_chord;
    reg [2:0] step_len;
    reg [7:0] step_gap;
    reg [3:0] step;

    always @(*) begin
        step_chord = 5'b00001; step_len = L_Q;
        case (step)
            // bar 1: Machine Gun
            4'd0:  begin step_chord = 5'b00100; step_len = L_S; end 
            4'd1:  begin step_chord = 5'b00010; step_len = L_S; end 
            4'd2:  begin step_chord = 5'b00100; step_len = L_S; end 
            4'd3:  begin step_chord = 5'b00010; step_len = L_E; end 
            
            // bar 2: The Staircase
            4'd4:  begin step_chord = 5'b10000; step_len = L_E; end
            4'd5:  begin step_chord = 5'b01000; step_len = L_E; end
            4'd6:  begin step_chord = 5'b00100; step_len = L_E; end
            4'd7:  begin step_chord = 5'b00010; step_len = L_E; end
            
            // bar 3: Machine gun
            4'd8:  begin step_chord = 5'b00001; step_len = L_S; end 
            4'd9:  begin step_chord = 5'b01001; step_len = L_S; end 
            4'd10: begin step_chord = 5'b00001; step_len = L_S; end 
            4'd11: begin step_chord = 5'b00101; step_len = L_E; end 
            
            // bar 4: Power Chords
            4'd12: begin step_chord = 5'b10001; step_len = L_Q; end 
            4'd13: begin step_chord = 5'b01010; step_len = L_Q; end 
            4'd14: begin step_chord = 5'b00101; step_len = L_E; end 
            4'd14: begin step_chord = 5'b00101; step_len = L_E; end 
            
            default: begin step_chord = 5'b00001; step_len = L_Q; end
        endcase
        step_gap = len_frames(step_len);
    end

    localparam [1:0] S_MENU = 2'd0, S_PLAY = 2'd1, S_PAUSE = 2'd2;

    // ------------------------------------------------------------------
    // State and Note Pool Registers
    // ------------------------------------------------------------------
    reg [1:0]  state;
    reg [15:0] score;
    reg [15:0] hiscore;
    reg [7:0]  streak;
    reg        pause_prev;
    reg        gostop_prev;
    reg [4:0]  str_prev;
    reg [4:0]  press_latch;
    reg [7:0]  spawn_gap;
    reg [15:0] nscore;

    // The Note Pool Array
    reg [POOL_SIZE-1:0] note_act;          // 1 if this note slot is currently in flight
    reg [2:0]           note_lane [0:POOL_SIZE-1]; // Which lane (0-4) this note is falling on
    reg [9:0]           note_y    [0:POOL_SIZE-1]; // Vertical position

    wire [4:0] press_now = str_btn & ~str_prev;

    integer   i, j, k;
    integer   n_hit, n_miss, n_wrong;
    reg [4:0] lane_has_win_note;
    integer   sd;
    reg [POOL_SIZE-1:0] pool_free;
    reg allocated;

    // ------------------------------------------------------------------
    // Combinational Per-Frame Logic
    // ------------------------------------------------------------------
    always @(*) begin
        n_hit = 0; n_miss = 0; n_wrong = 0; lane_has_win_note = 5'b0;
        
        // Scan the entire pool to see what is currently in the hit window or falling off
        for (i = 0; i < POOL_SIZE; i = i + 1) begin
            if (note_act[i]) begin
                if ((note_y[i] >= HIT_LO) && (note_y[i] <= HIT_HI)) begin
                    lane_has_win_note[note_lane[i]] = 1'b1;
                end
                if (note_y[i] >= 10'd480 - SPEED) begin
                    n_miss = n_miss + 1;
                end
            end
        end

        // Check user inputs against what's in the window
        for (i = 0; i < 5; i = i + 1) begin
            if (lane_has_win_note[i] && str_btn[i]) n_hit = n_hit + 1;
            if (press_latch[i] && !lane_has_win_note[i]) n_wrong = n_wrong + 1;
        end
    end

    wire [3:0] mult = (streak >= 8'd32) ? 4'd8 :
                      (streak >= 8'd16) ? 4'd4 :
                      (streak >= 8'd8)  ? 4'd2 : 4'd1;

    wire pause_press  = pause_btn  & ~pause_prev;
    wire gostop_press = gostop_btn & ~gostop_prev;

    // ------------------------------------------------------------------
    // Main Game Loop
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            state       <= S_MENU;
            score       <= 16'd0;
            hiscore     <= 16'd0;
            streak      <= 8'd0;
            pause_prev  <= 1'b0;
            gostop_prev <= 1'b0;
            str_prev    <= 5'd0;
            press_latch <= 5'd0;
            spawn_gap   <= 8'd0;
            step        <= 4'd0;
            note_act    <= 0;
            for (i = 0; i < POOL_SIZE; i = i + 1) begin
                note_y[i]    <= 10'd0;
                note_lane[i] <= 3'd0;
            end
        end else begin
            pause_prev  <= pause_btn;
            gostop_prev <= gostop_btn;
            str_prev    <= str_btn;
            press_latch <= (frame_tick ? 5'd0 : press_latch) | press_now;

            if (gostop_press) begin
                if (state == S_MENU) begin
                    state  <= S_PLAY;
                    score  <= 16'd0; streak <= 8'd0;
                    spawn_gap <= 8'd0; step <= 4'd0;
                    note_act <= 0;
                end else begin
                    if (score > hiscore) hiscore <= score;
                    state <= S_MENU;
                    score <= 16'd0; streak <= 8'd0;
                    spawn_gap <= 8'd0; step <= 4'd0;
                    note_act <= 0;
                end
            end else if (pause_press && state != S_MENU) begin
                state <= (state == S_PAUSE) ? S_PLAY : S_PAUSE;
            end

            if (state == S_PLAY && frame_tick) begin
                // 1. Move Notes, Process Hits & Misses
                for (j = 0; j < POOL_SIZE; j = j + 1) begin
                    if (note_act[j]) begin
                        if (str_btn[note_lane[j]] && (note_y[j] >= HIT_LO) && (note_y[j] <= HIT_HI)) begin
                            note_act[j] <= 1'b0; // Destroy note on hit
                        end else if (note_y[j] >= 10'd480 - SPEED) begin
                            note_act[j] <= 1'b0; // Destroy note on miss
                        end else begin
                            note_y[j] <= note_y[j] + SPEED; // Gravity
                        end
                    end
                end

                // 2. Score Update
                sd = n_hit * mult - n_wrong * PENALTY;
                nscore = score;
                if (sd >= 0) begin
                    nscore = score + sd[15:0];
                end else begin
                    if (score >= -sd) nscore = score - (-sd);
                    else              nscore = 16'd0;
                end
                score <= nscore;
                if (nscore > hiscore) hiscore <= nscore;

                if (n_miss > 0 || n_wrong > 0) streak <= 8'd0;
                else if (streak > 8'd255 - n_hit) streak <= 8'd255;
                else streak <= streak + n_hit;

                // 3. Spawning New Notes into the Pool
                if (spawn_gap == 8'd0) begin
                    pool_free = ~note_act; // Find which slots are free right now

                    for (k = 0; k < 5; k = k + 1) begin
                        if (step_chord[k]) begin
                            allocated = 0;
                            // Search the pool for the first empty slot to put the new note
                            for (j = 0; j < POOL_SIZE; j = j + 1) begin
                                if (!allocated && pool_free[j]) begin
                                    note_act[j]  <= 1'b1;
                                    note_lane[j] <= k[2:0];
                                    note_y[j]    <= 10'd0;
                                    pool_free[j] = 1'b0; // Mark this slot as taken
                                    allocated    = 1;
                                end
                            end
                        end
                    end
                    spawn_gap <= step_gap;
                    step      <= (step == 4'd15) ? 4'd0 : step + 4'd1;
                end else begin
                    spawn_gap <= spawn_gap - 8'd1;
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // Audio Generation
    // ------------------------------------------------------------------
    reg [23:0] acc0, acc1, acc2, acc3, acc4;
    reg [23:0] beep_acc;
    reg [15:0] hit_timer, miss_timer;
    
    wire hit_event  = frame_tick && (state == S_PLAY) && (n_hit  > 0);
    wire miss_event = frame_tick && (state == S_PLAY) && (n_miss > 0 || n_wrong > 0);

    always @(posedge clk) begin
        if (!rst_n) begin
            acc0 <= 20'd0; acc1 <= 20'd0; acc2 <= 20'd0;
            acc3 <= 20'd0; acc4 <= 20'd0;
            beep_acc <= 20'd0; hit_timer <= 16'd0; miss_timer <= 16'd0;
        end else begin
            acc0 <= acc0 + TONE0;
            acc1 <= acc1 + TONE1;
            acc2 <= acc2 + TONE2;
            acc3 <= acc3 + TONE3;
            acc4 <= acc4 + TONE4;
            beep_acc <= beep_acc + BEEP_K;

            if (hit_event)                 hit_timer  <= HIT_LEN;
            else if (hit_timer != 16'd0)   hit_timer  <= hit_timer - 16'd1;

            if (miss_event)                miss_timer <= MISS_LEN;
            else if (miss_timer != 16'd0)  miss_timer <= miss_timer - 16'd1;
        end
    end

    wire hit_snd  = (hit_timer  != 16'd0) ? beep_acc[19] : 1'b0;
    wire miss_snd = (miss_timer != 16'd0) ? beep_acc[17] : 1'b0;

    wire audio = (acc0[19] & str_btn[0]) |
                 (acc1[19] & str_btn[1]) |
                 (acc2[19] & str_btn[2]) |
                 (acc3[19] & str_btn[3]) |
                 (acc4[19] & str_btn[4]) |
                 hit_snd | miss_snd;

    assign uio_out = {8{audio}};
    assign uio_oe  = 8'hFF;

    // ------------------------------------------------------------------
    // Text rendering 
    // ------------------------------------------------------------------
    reg [4:0] line0 [0:11];
    reg [4:0] line1 [0:11];
    reg [4:0] line2 [0:11];
    integer n;

    wire [4:0] scd2 = 5'd1 + (score   / 100) % 10;
    wire [4:0] scd1 = 5'd1 + (score   /  10) % 10;
    wire [4:0] scd0 = 5'd1 + (score        ) % 10;
    wire [4:0] hid2 = 5'd1 + (hiscore / 100) % 10;
    wire [4:0] hid1 = 5'd1 + (hiscore /  10) % 10;
    wire [4:0] hid0 = 5'd1 + (hiscore      ) % 10;

    always @(*) begin
        for (n = 0; n < 12; n = n + 1) begin
            line0[n] = C_SP; line1[n] = C_SP; line2[n] = C_SP;
        end
        case (state)
            S_MENU: begin
                line0[0]=C_H; line0[1]=C_I; line0[2]=C_G; line0[3]=C_H;
                line0[4]=C_SP; line0[5]=C_S; line0[6]=C_C; line0[7]=C_O;
                line0[8]=C_R; line0[9]=C_E;
                line1[0]=hid2; line1[1]=hid1; line1[2]=hid0;
                line2[0]=C_S; line2[1]=C_T; line2[2]=C_A;
                line2[3]=C_R; line2[4]=C_T;
            end
            S_PAUSE: begin
                line0[0]=C_P; line0[1]=C_A; line0[2]=C_U;
                line0[3]=C_S; line0[4]=C_E;
                line1[0]=C_H; line1[1]=C_I; line1[2]=C_SP;
                line1[3]=hid2; line1[4]=hid1; line1[5]=hid0;
            end
            default: begin
                line0[0]=C_S; line0[1]=C_C; line0[2]=C_SP;
                line0[3]=scd2; line0[4]=scd1; line0[5]=scd0;
                line1[0]=C_H; line1[1]=C_I; line1[2]=C_SP;
                line1[3]=hid2; line1[4]=hid1; line1[5]=hid0;
            end
        endcase
    end

    localparam [9:0] MENU_TEXT_DY = 10'd184;
    wire [9:0] yofs = (state == S_MENU) ? MENU_TEXT_DY : 10'd0;

    wire [9:0] hx  = hpos - 10'd16;
    wire [9:0] vyA = vpos - (10'd16 + yofs);
    wire [9:0] vyB = vpos - (10'd44 + yofs);
    wire [9:0] vyC = vpos - (10'd72 + yofs);

    wire textA = (vpos >= (10'd16 + yofs)) && (vpos < (10'd36 + yofs)) && (hpos >= 10'd16) && (hpos < 10'd208);
    wire textB = (vpos >= (10'd44 + yofs)) && (vpos < (10'd64 + yofs)) && (hpos >= 10'd16) && (hpos < 10'd208);
    wire textC = (vpos >= (10'd72 + yofs)) && (vpos < (10'd92 + yofs)) && (hpos >= 10'd16) && (hpos < 10'd208);

    wire [3:0] ci   = hx[8:4];
    wire       ciok = (ci < 4'd12);
    wire [1:0] gx   = hx[3:2];
    wire [2:0] gyA  = vyA[4:2];
    wire [2:0] gyB  = vyB[4:2];
    wire [2:0] gyC  = vyC[4:2];
    wire       okA  = ciok && (gx < 2'd3) && (gyA < 3'd5);
    wire       okB  = ciok && (gx < 2'd3) && (gyB < 3'd5);
    wire       okC  = ciok && (gx < 2'd3) && (gyC < 3'd5);

    wire litA = textA && pixbit(glyph(line0[ci]), gyA, gx, okA);
    wire litB = textB && pixbit(glyph(line1[ci]), gyB, gx, okB);
    wire litC = textC && pixbit(glyph(line2[ci]), gyC, gx, okC);

    // ------------------------------------------------------------------
    // Pixel generation
    // ------------------------------------------------------------------
    wire [2:0] lane = hpos[9:7];         // 0..4 (lanes are 128 px wide)
    wire [6:0] hoff = hpos[6:0];         // 0..127 within the lane
    wire in_lane_body = (hoff >= 7'd8) && (hoff < 7'd120);

    // Dynamic Note Rendering: check if ANY active note from the pool is under the beam
    reg on_note_pool;
    always @(*) begin
        on_note_pool = 1'b0;
        for (i = 0; i < POOL_SIZE; i = i + 1) begin
            if (note_act[i] && (note_lane[i] == lane) && (vpos >= note_y[i]) && (vpos < note_y[i] + NOTE_H)) begin
                on_note_pool = 1'b1;
            end
        end
    end
    
    wire on_note = (state != S_MENU) && in_lane_body && on_note_pool;

    reg [5:0] lane_col;
    always @(*) begin
        case (lane)
            3'd0:    lane_col = 6'b110000;
            3'd1:    lane_col = 6'b111100;
            3'd2:    lane_col = 6'b001100;
            3'd3:    lane_col = 6'b001111;
            default: lane_col = 6'b110011;
        endcase
    end

    wire on_sep = (hoff < 7'd2);
    wire on_hit = (state != S_MENU) && (vpos >= HIT_Y) && (vpos < HIT_Y + 4);

    wire       streak_bar = (vpos >= 10'd472) && (vpos < 10'd478);
    wire       streak_lit = streak[hpos[9:7]];
    wire [5:0] bgcol = str_btn[lane] ? 6'b000100 : 6'b000010;

    wire [5:0] pix =
        !display_on       ? 6'b000000 :
        (litA|litB|litC)  ? 6'b111111 :
        (state == S_MENU) ? 6'b100001 :
        streak_bar        ? (streak_lit ? 6'b001111 : 6'b000001) :
        on_sep            ? 6'b101010 :
        on_note           ? lane_col :
        on_hit            ? 6'b111111 :
                            bgcol;

    wire r1 = pix[5], r0 = pix[4];
    wire g1 = pix[3], g0 = pix[2];
    wire b1 = pix[1], b0 = pix[0];

    assign uo_out = {hsync, b0, g0, r0, vsync, b1, g1, r1};

    wire _unused = &{1'b0, uio_in, ena};

endmodule
