// =============================================================
//  sudoku_solver_top.v  (v3 – correct push/place sequencing)
//
//  Root cause fix:
//    In a clocked FSM, all register assignments (board[cell]<=digit,
//    stk_push<=1) take effect at the END of the clock edge.
//    Therefore in ST_PLACE, both the push AND the board write
//    happen simultaneously on the next rising edge — but the stack
//    captures board_flat (combinational) DURING that same edge,
//    which means it already sees the newly written digit.
//
//    Solution: Split PLACE into two states:
//      ST_PUSH_SNAP  – assert stk_push=1; do NOT write board yet.
//                      board_flat (old value) is captured correctly.
//      ST_WRITE_CELL – deassert push; write board[sel_cell]<=digit;
//                      advance sel_cell pointer.
//
//  All other logic (RESTORE state, push_tried wire) kept from v2.
// =============================================================
`timescale 1ns/1ps

module sudoku_solver_top (
    input             clk,
    input             rst,
    input             start,
    input  [323:0]    puzzle_in,
    output [323:0]    board_out,
    output reg        solved,
    output reg        no_solution
);

    // -------------------------------------------------------
    // FSM state encoding
    // -------------------------------------------------------
    localparam [3:0]
        ST_IDLE        = 4'd0,
        ST_LOAD        = 4'd1,
        ST_FIND_EMPTY  = 4'd2,
        ST_CALC_CANDS  = 4'd3,
        ST_CHECK_CANDS = 4'd4,
        ST_PUSH_SNAP   = 4'd5,   // push snapshot (board still unmodified)
        ST_WRITE_CELL  = 4'd6,   // write chosen digit, advance scan
        ST_BACKTRACK   = 4'd7,   // pop stack, restore board regs
        ST_RESTORE     = 4'd8,   // wait 1 cycle for board to settle
        ST_DONE        = 4'd9,
        ST_NO_SOL      = 4'd10;

    reg [3:0] state;

    // -------------------------------------------------------
    // Internal board (81 × 4 bits)
    // -------------------------------------------------------
    reg [3:0] board [0:80];
    integer   bi;

    wire [323:0] board_flat;
    genvar gv;
    generate
        for (gv = 0; gv < 81; gv = gv + 1) begin : pack_board
            assign board_flat[gv*4 +: 4] = board[gv];
        end
    endgenerate

    assign board_out = board_flat;

    // -------------------------------------------------------
    // Candidate mask (pure combinational)
    // -------------------------------------------------------
    reg  [6:0] sel_cell;
    wire [8:0] cand_mask;

    candidate_mask u_cand (
        .board_flat (board_flat),
        .cell_idx   (sel_cell),
        .mask       (cand_mask)
    );

    // -------------------------------------------------------
    // Digit selection helpers
    // -------------------------------------------------------
    reg [8:0] current_mask;   // latched available mask for sel_cell

    function [3:0] lowest_digit;
        input [8:0] m;
        integer fi;
        begin
            lowest_digit = 4'd0;
            for (fi = 8; fi >= 0; fi = fi - 1)
                if (m[fi]) lowest_digit = fi[3:0] + 4'd1;
        end
    endfunction

    wire [3:0] chosen_digit = lowest_digit(current_mask);

    // -------------------------------------------------------
    // Backtrack stack
    // -------------------------------------------------------
    reg  stk_push, stk_pop;
    reg  [8:0] tried;                    // digits tried at sel_cell

    // push_tried_w is combinational so the correct mask is
    // captured by the stack in the same cycle as stk_push.
    wire [8:0] push_tried_w = tried | ((chosen_digit != 4'd0)
                                       ? (9'd1 << (chosen_digit - 1))
                                       : 9'd0);

    wire [323:0] top_board;
    wire [6:0]   top_cell;
    wire [8:0]   top_tried;
    wire         stk_empty, stk_full;

    stack_mem u_stack (
        .clk         (clk),
        .rst         (rst),
        .push        (stk_push),
        .push_board  (board_flat),    // pre-placement snapshot (correct in ST_PUSH_SNAP)
        .push_cell   (sel_cell),
        .push_tried  (push_tried_w),
        .pop         (stk_pop),
        .top_board   (top_board),
        .top_cell    (top_cell),
        .top_tried   (top_tried),
        .stack_empty (stk_empty),
        .stack_full  (stk_full)
    );

    // -------------------------------------------------------
    // FSM
    // -------------------------------------------------------
    integer si;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state        <= ST_IDLE;
            solved       <= 1'b0;
            no_solution  <= 1'b0;
            sel_cell     <= 7'd0;
            stk_push     <= 1'b0;
            stk_pop      <= 1'b0;
            current_mask <= 9'd0;
            tried        <= 9'd0;
            for (bi = 0; bi < 81; bi = bi + 1)
                board[bi] <= 4'd0;
        end else begin
            stk_push <= 1'b0;
            stk_pop  <= 1'b0;

            case (state)

                // ------------------------------------------------
                ST_IDLE: begin
                    solved      <= 1'b0;
                    no_solution <= 1'b0;
                    if (start) state <= ST_LOAD;
                end

                // ------------------------------------------------
                ST_LOAD: begin
                    for (bi = 0; bi < 81; bi = bi + 1)
                        board[bi] <= puzzle_in[bi*4 +: 4];
                    sel_cell <= 7'd0;
                    tried    <= 9'd0;
                    state    <= ST_FIND_EMPTY;
                end

                // ------------------------------------------------
                ST_FIND_EMPTY: begin
                    if (board[sel_cell] == 4'd0) begin
                        tried <= 9'd0;
                        state <= ST_CALC_CANDS;
                    end else if (sel_cell == 7'd80) begin
                        state <= ST_DONE;
                    end else begin
                        sel_cell <= sel_cell + 1'b1;
                    end
                end

                // ------------------------------------------------
                ST_CALC_CANDS: begin
                    // cand_mask is combinational from board_flat & sel_cell
                    current_mask <= cand_mask & ~tried;
                    state        <= ST_CHECK_CANDS;
                end

                // ------------------------------------------------
                ST_CHECK_CANDS: begin
                    if (current_mask == 9'd0)
                        state <= ST_BACKTRACK;
                    else
                        state <= ST_PUSH_SNAP;
                end

                // ------------------------------------------------
                // Cycle A: push board snapshot BEFORE any board change.
                // board_flat = old board (cell still 0) → correct snapshot.
                // push_tried_w = tried | chosen_bit (combinational).
                // ------------------------------------------------
                ST_PUSH_SNAP: begin
                    stk_push <= 1'b1;          // snapshot captured here
                    state    <= ST_WRITE_CELL;
                end

                // ------------------------------------------------
                // Cycle B: stk_push de-asserted (default); write digit.
                // board[sel_cell] transitions here → next combinational
                // reads of board_flat see the new digit.
                // ------------------------------------------------
                ST_WRITE_CELL: begin
                    board[sel_cell] <= chosen_digit;
                    sel_cell        <= sel_cell + 1'b1;
                    tried           <= 9'd0;
                    state           <= ST_FIND_EMPTY;
                end

                // ------------------------------------------------
                ST_BACKTRACK: begin
                    if (stk_empty) begin
                        state <= ST_NO_SOL;
                    end else begin
                        // Restore board from top-of-stack snapshot
                        for (si = 0; si < 81; si = si + 1)
                            board[si] <= top_board[si*4 +: 4];
                        sel_cell <= top_cell;
                        tried    <= top_tried;
                        stk_pop  <= 1'b1;
                        state    <= ST_RESTORE;
                    end
                end

                // ------------------------------------------------
                // Board registers settled; candidate_mask now valid.
                // ------------------------------------------------
                ST_RESTORE: begin
                    state <= ST_CALC_CANDS;
                end

                // ------------------------------------------------
                ST_DONE: begin
                    solved <= 1'b1;
                    state  <= ST_DONE;
                end

                ST_NO_SOL: begin
                    no_solution <= 1'b1;
                    state       <= ST_NO_SOL;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule