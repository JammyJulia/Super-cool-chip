`timescale 1ns/1ps
`default_nettype none

/*
 * Testbench for the Guitar Hero VGA game.
 *
 * A full VGA frame is 800 x 525 = 420,000 clocks, so this checks the core
 * game loop over a few frames rather than a full scoring run:
 *   1. the game starts (state == S_PLAY)
 *   2. a note spawns (some lane becomes active)
 *   3. notes fall (a note's y increases over a frame)
 * Waveforms are dumped for the reset/start window only.
 */
module tb;

    reg        clk    = 1'b0;
    reg        rst_n  = 1'b0;
    reg        ena    = 1'b1;
    reg  [7:0] uio_in = 8'h00;
    wire [7:0] uo_out;
    wire [7:0] uio_out;
    wire [7:0] uio_oe;

    // Control bits from the initial block; strings from a clocked "player".
    reg        start   = 1'b0;
    reg        pause   = 1'b0;
    reg        stop    = 1'b0;
    reg  [4:0] str     = 5'b00000;
    reg        playing = 1'b0;

    wire [7:0] ui_in = {stop, pause, start, str};

    tt_um_project uut (
        .ui_in   (ui_in),
        .uo_out  (uo_out),
        .uio_in  (uio_in),
        .uio_out (uio_out),
        .uio_oe  (uio_oe),
        .ena     (ena),
        .clk     (clk),
        .rst_n   (rst_n)
    );

    // 25 MHz pixel clock (40 ns period)
    always #20 clk = ~clk;

    // Perfect player: hold every string pressed (only read during play)
    always @(negedge clk)
        str <= playing ? 5'b11111 : 5'b00000;

    integer k;
    reg [9:0] y_a, y_b;

    initial begin
        $dumpfile("tb.vcd");
        $dumpvars(0, tb);

        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;

        // Press START for two cycles
        start = 1'b1;
        @(posedge clk);
        @(posedge clk);
        start = 1'b0;
        playing = 1'b1;

        if (uut.state == 2'd1) $display("PASS: game started");
        else                   $display("FAIL: game did not start");

        // Frame 1: the first note spawns here. Trim the dump afterwards.
        @(posedge uut.frame_tick);
        $dumpoff;

        // Frame 2: the note falls one step; record its y
        @(posedge uut.frame_tick);
        y_a = 10'd0;
        for (k = 0; k < 5; k = k + 1)
            if (uut.nact[k]) y_a = uut.ny[k];

        // Frame 3: record again
        @(posedge uut.frame_tick);
        y_b = 10'd0;
        for (k = 0; k < 5; k = k + 1)
            if (uut.nact[k]) y_b = uut.ny[k];

        if (y_a != 10'd0) $display("PASS: a note spawned (y=%0d)", y_a);
        else              $display("FAIL: no note spawned");

        if (y_b > y_a) $display("PASS: notes fall (y %0d -> %0d)", y_a, y_b);
        else           $display("FAIL: note did not fall (%0d -> %0d)", y_a, y_b);

        $display("score = %0d, streak = %0d", uut.score, uut.streak);

        $finish;
    end

endmodule
