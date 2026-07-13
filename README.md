# SUDOKU-FSM: Hardware-Accelerated 9×9 Sudoku Solver

------------------------------------------------------------------------

## 1 Abstract

This project presents the design, implementation, and simulation of a
**hardware-accelerated 9×9 Sudoku Solver** implemented in **Verilog
HDL**. The solver employs a **Finite State Machine (FSM)-driven
backtracking algorithm** that systematically explores the solution space
by placing candidate digits into empty cells and reverting incorrect
choices through a dedicated **push-down stack**. The design comprises
three core modules: a **Candidate Mask Generator** that combinationally
computes legal digit placements by scanning row, column, and 3×3 box
constraints; a **Stack Memory** that stores full board snapshots for
efficient backtracking; and a **Top-Level Controller FSM** that
orchestrates the solve process across 11 distinct states. The
implementation correctly solves both easy puzzles (30 givens, \~200
cycles) and hard minimal puzzles (17 givens, requiring deep
backtracking), achieving a fully deterministic, synthesisable design
suitable for FPGA deployment and academic study.

------------------------------------------------------------------------

## 2 Introduction

### 2.1 Motivation and Background

Sudoku is a combinatorial constraint satisfaction problem (CSP) that has
captivated puzzle enthusiasts worldwide since its popularisation in the
mid-2000s. A standard 9×9 Sudoku puzzle requires filling an 81-cell grid
with digits 1--9 such that every row, every column, and every 3×3
sub-box contains each digit exactly once. While straightforward for
humans to solve through logical deduction on easy puzzles, harder
instances---particularly those with minimal clue counts (as few as 17
givens)---demand systematic search with backtracking.

Hardware implementations of Sudoku solvers are of significant academic
interest because they demonstrate how **constraint propagation**,
**depth-first search**, and **state-space exploration**---concepts
fundamental to artificial intelligence and optimisation---can be mapped
onto digital logic. Unlike software implementations that execute
sequentially on a general-purpose processor, a hardware solver can
exploit the inherent parallelism of combinational logic to evaluate all
row/column/box constraints simultaneously in a single clock cycle.

The motivation for this project is to design a modular, synthesisable,
and educationally clear hardware Sudoku solver that implements the core
backtracking algorithm in a clocked FSM, with cleanly separated
combinational constraint checking and sequential state management.

### 2.2 Overview of Sudoku Constraints

A valid Sudoku solution must satisfy three simultaneous constraints for
every cell in the 9×9 grid:

  -----------------------------------------------------------------------
  Constraint                 Scope           Description
  -------------------------- --------------- ----------------------------
  **Row Uniqueness**         9 cells in the  Each digit 1--9 appears
                             same row        exactly once per row

  **Column Uniqueness**      9 cells in the  Each digit 1--9 appears
                             same column     exactly once per column

  **Box Uniqueness**         9 cells in the  Each digit 1--9 appears
                             same 3×3        exactly once per box
                             sub-grid        
  -----------------------------------------------------------------------

The 9×9 grid contains 81 cells, and each cell can hold a digit from 1 to
9 or be empty (represented as 0). A puzzle provides a subset of cells as
"givens" (pre-filled clues), and the solver must fill the remaining
cells while satisfying all three constraints.

  -------------------------------------------------------------------------
  Puzzle Difficulty   Typical Givens   Search Depth  Backtracking Required
  ------------------- ---------------- ------------- ----------------------
  **Easy**            30--40           Shallow       Minimal

  **Medium**          25--30           Moderate      Some

  **Hard**            17--24           Deep          Extensive

  **Minimal           17               Very deep     Heavy
  (17-clue)**                                        
  -------------------------------------------------------------------------

### 2.3 Scope

The scope of this project encompasses the complete design,
implementation, and functional verification of a hardware Sudoku solver.
The design includes:

-   An **FSM-based top-level controller** with 11 states managing the
    solve lifecycle (idle, load, find-empty, candidate calculation,
    digit placement, backtracking, and completion).
-   A **combinational candidate mask generator** that computes all legal
    digits for any cell in a single combinational pass.
-   A **synchronous push-down stack** storing full 324-bit board
    snapshots, cell indices, and tried-digit masks for backtracking.
-   A **split push/place sequencing strategy** that correctly captures
    pre-placement board snapshots before modifying the board.
-   A comprehensive **testbench** verifying correctness on both an easy
    puzzle (30 givens) and a hard 17-clue minimal puzzle.

------------------------------------------------------------------------

## 3 Problem Statement

Implementing a Sudoku solver in hardware presents several unique
challenges that distinguish it from software implementations:

### 3.1 Board Representation

An 81-cell board where each cell holds a 4-bit value (0--9) requires
**324 bits** of state. This wide datapath must be efficiently packed,
unpacked, and routed through combinational constraint-checking logic and
stored/restored from a backtracking stack.

### 3.2 Constraint Evaluation

For any given empty cell, the solver must determine which digits (1--9)
are legal placements by checking: - All 8 other cells in the same
**row** (row peers) - All 8 other cells in the same **column** (column
peers) - All 8 other cells in the same **3×3 box** (box peers)

This requires examining up to 20 distinct peer cells (some overlap
between row/column/box) and comparing their values against all 9
possible digits---a computation that benefits greatly from hardware
parallelism.

### 3.3 Backtracking with State Restoration

When the solver reaches a dead end (no legal digits for the current
cell), it must **backtrack** to the most recent decision point and try
an alternative digit. This requires: - Saving the **entire board state**
before each digit placement. - Recording which **digits have already
been tried** at each decision point. - Restoring the saved state and
resuming from the correct cell.

In hardware, this demands a dedicated stack memory capable of storing
340-bit frames (324-bit board + 7-bit cell index + 9-bit tried mask),
with a depth of up to 81 frames (worst case: one decision per empty
cell).

### 3.4 Correct Push/Place Sequencing

A subtle but critical challenge in clocked FSM design is ensuring that
the board snapshot pushed onto the stack reflects the state **before**
the current digit is placed. Since register assignments in Verilog take
effect at the end of the clock edge, naïvely combining the push and the
board write in the same state would capture an incorrect snapshot. This
project addresses this by splitting the operation into two sequential
states: `ST_PUSH_SNAP` (push the unmodified board) and `ST_WRITE_CELL`
(place the digit).

### 3.5 Scalability and Worst-Case Performance

Minimal 17-clue puzzles can require exploring thousands of candidate
placements and backtracks. The solver must handle deep recursion without
stack overflow and terminate within a reasonable cycle count. The
worst-case search space for a 9×9 Sudoku is astronomically large (\~6.67
× 10²¹ possible grids), making efficient constraint pruning essential.

------------------------------------------------------------------------

## 4 System Architecture

### 4.1 Top-Level Design

The solver follows a **controller-datapath architecture** where an FSM
controller orchestrates the interaction between three functional units:
the board register array, the candidate mask generator, and the
backtrack stack. The top-level module
([sudoku_solver_top.v](file:///Users/parv/Documents/Verilog/sudoku_solver_top.v))
integrates all components and implements the FSM.

#### 4.1.1 Architectural Components

  -------------------------------------------------------------------------------------------------------------------------------
  Component                  Module                                                                      Function
  -------------------------- --------------------------------------------------------------------------- ------------------------
  **Board Register Array**   Inline in `sudoku_solver_top.v`                                             81 × 4-bit registers
                                                                                                         storing the current
                                                                                                         board state

  **Board Flattener**        Inline (generate block)                                                     Packs 81 individual
                                                                                                         registers into a 324-bit
                                                                                                         flat vector

  **Candidate Mask           [candidate_mask.v](file:///Users/parv/Documents/Verilog/candidate_mask.v)   Combinationally computes
  Generator**                                                                                            legal digit mask for a
                                                                                                         target cell

  **Digit Selector**         Inline (function)                                                           Extracts the lowest set
                                                                                                         bit from the candidate
                                                                                                         mask

  **Backtrack Stack**        [stack_mem.v](file:///Users/parv/Documents/Verilog/stack_mem.v)             81-deep push-down stack
                                                                                                         storing 340-bit frames

  **FSM Controller**         Inline in `sudoku_solver_top.v`                                             11-state FSM
                                                                                                         orchestrating the solve
                                                                                                         algorithm
  -------------------------------------------------------------------------------------------------------------------------------

#### 4.1.2 Input/Output Interface

  ----------------------------------------------------------------------------
  Port            Direction             Width         Description
  --------------- --------------------- ------------- ------------------------
  `clk`           Input                 1 bit         System clock

  `rst`           Input                 1 bit         Asynchronous active-high
                                                      reset

  `start`         Input                 1 bit         Pulse to begin solving

  `puzzle_in`     Input                 324 bits      Initial puzzle (81 cells
                                                      × 4 bits, packed)

  `board_out`     Output                324 bits      Current/final board
                                                      state (81 cells × 4
                                                      bits, packed)

  `solved`        Output                1 bit         Asserted when a valid
                                                      solution is found

  `no_solution`   Output                1 bit         Asserted when no valid
                                                      solution exists
  ----------------------------------------------------------------------------

#### 4.1.3 Internal State

  -----------------------------------------------------------------------
  Register                Width            Description
  ----------------------- ---------------- ------------------------------
  `state [3:0]`           4 bits           Current FSM state

  `board [0:80]`          81 × 4 bits      Board cell array

  `sel_cell [6:0]`        7 bits           Index of the currently
                                           selected cell (0--80)

  `current_mask [8:0]`    9 bits           Latched candidate mask for
                                           `sel_cell`

  `tried [8:0]`           9 bits           Digits already tried at
                                           `sel_cell`

  `stk_push`              1 bit            Stack push strobe

  `stk_pop`               1 bit            Stack pop strobe
  -----------------------------------------------------------------------

### 4.2 Block Diagram

The following diagram illustrates the high-level datapath and control
flow of the Sudoku solver:

``` mermaid
graph LR
    subgraph Inputs
        PUZ["puzzle_in (324b)"]
        START["start"]
        CLK["clk"]
        RST["rst"]
    end

    subgraph Controller["FSM Controller (11 states)"]
        FSM["State Register"]
    end

    subgraph Datapath
        BOARD["Board Registers (81×4b)"]
        FLAT["Board Flattener (324b wire)"]
        CAND["Candidate Mask Generator"]
        DIGIT["Lowest-Digit Selector"]
        STACK["Backtrack Stack (81 deep)"]
    end

    subgraph Outputs
        BOUT["board_out (324b)"]
        SOL["solved"]
        NOSOL["no_solution"]
    end

    PUZ --> |"ST_LOAD"| BOARD
    START --> FSM
    CLK --> FSM
    RST --> FSM

    BOARD --> FLAT
    FLAT --> CAND
    FLAT --> |"push_board"| STACK
    FLAT --> BOUT

    FSM --> |"sel_cell"| CAND
    CAND --> |"cand_mask"| FSM
    FSM --> |"current_mask"| DIGIT
    DIGIT --> |"chosen_digit"| BOARD

    FSM --> |"stk_push"| STACK
    FSM --> |"stk_pop"| STACK
    STACK --> |"top_board"| BOARD
    STACK --> |"top_cell, top_tried"| FSM

    FSM --> SOL
    FSM --> NOSOL
```

### 4.3 Algorithm Overview: Depth-First Backtracking

The solver implements a classic **depth-first search (DFS) with
backtracking**, adapted for hardware execution:

``` mermaid
flowchart TD
    IDLE["ST_IDLE\n(Wait for start)"] --> LOAD["ST_LOAD\n(Load puzzle into board)"]
    LOAD --> FIND["ST_FIND_EMPTY\n(Scan for next empty cell)"]
    FIND --> |"Cell found"| CALC["ST_CALC_CANDS\n(Compute candidate mask)"]
    FIND --> |"All cells filled"| DONE["ST_DONE\n(Puzzle solved!)"]
    CALC --> CHECK["ST_CHECK_CANDS\n(Any candidates left?)"]
    CHECK --> |"No candidates"| BACK["ST_BACKTRACK\n(Pop stack, restore board)"]
    CHECK --> |"Candidates exist"| PUSH["ST_PUSH_SNAP\n(Save pre-placement snapshot)"]
    PUSH --> WRITE["ST_WRITE_CELL\n(Place digit, advance scan)"]
    WRITE --> FIND
    BACK --> |"Stack empty"| NOSOL["ST_NO_SOL\n(No solution exists)"]
    BACK --> |"Stack has frames"| RESTORE["ST_RESTORE\n(Wait 1 cycle for board settle)"]
    RESTORE --> CALC
```

The algorithm proceeds as follows:

1.  **Load** the puzzle into the board registers.
2.  **Find** the next empty cell by scanning from the current position.
3.  **Calculate** the candidate mask (legal digits) for that cell.
4.  **Check** if any untried candidates remain.
5.  If candidates exist: **Push** a board snapshot onto the stack, then
    **Write** the lowest untried digit into the cell.
6.  If no candidates remain: **Backtrack** by popping the stack,
    restoring the board, and retrying with the next candidate.
7.  Repeat until all cells are filled (**solved**) or the stack is empty
    (**no solution**).

------------------------------------------------------------------------

## 5 Implementation

### 5.1 Candidate Mask Generator

**File:**
[candidate_mask.v](file:///Users/parv/Documents/Verilog/candidate_mask.v)

The candidate mask generator is a purely **combinational** module that
computes a 9-bit bitmask indicating which digits (1--9) are legal
placements for a given cell. This is the heart of constraint evaluation.

#### 5.1.1 Interface

  ---------------------------------------------------------------------------
  Port           Direction             Width         Description
  -------------- --------------------- ------------- ------------------------
  `board_flat`   Input                 324 bits      Packed board state (81
                                                     cells × 4 bits)

  `cell_idx`     Input                 7 bits        Target cell index
                                                     (0--80)

  `mask`         Output                9 bits        Candidate bitmask: bit
                                                     *i* = 1 → digit (*i*+1)
                                                     is legal
  ---------------------------------------------------------------------------

#### 5.1.2 Algorithm

The module operates in three phases, all within a single combinational
`always @(*)` block:

  --------------------------------------------------------------------------------
  Phase      Peers Checked        Loop Structure              Description
  ---------- -------------------- --------------------------- --------------------
  **Row      9 cells              `for (i = 0; i < 9; i++)`   Scans
  scan**                                                      `board[row*9 + i]`
                                                              for all columns in
                                                              the target row

  **Column   9 cells              `for (i = 0; i < 9; i++)`   Scans
  scan**                                                      `board[i*9 + col]`
                                                              for all rows in the
                                                              target column

  **Box      9 cells              `for (r,c = 0; r,c < 3)`    Scans the 3×3
  scan**                                                      sub-grid containing
                                                              the target cell
  --------------------------------------------------------------------------------

For each non-zero cell encountered, the corresponding bit in the
`forbidden` register is set:

``` verilog
if (board[peer] != 4'd0)
    forbidden[board[peer] - 1] = 1'b1;
```

The output mask is the bitwise complement of the forbidden mask:

``` verilog
assign mask = ~forbidden;
```

#### 5.1.3 Design Notes

-   **Cell coordinate derivation**: Row and column are computed from
    `cell_idx` using integer division and modulo:
    `target_row = cell_idx / 9`, `target_col = cell_idx % 9`. The box
    origin is derived as `box_row = (target_row / 3) * 3`,
    `box_col = (target_col / 3) * 3`.
-   **Overlap tolerance**: Some cells appear in both the row scan and
    box scan (or column scan and box scan). Since the forbidden mask
    uses OR operations, duplicate detections are harmless.
-   **Zero-based bit indexing**: Bit 0 corresponds to digit 1, bit 8 to
    digit 9. This offset-by-one encoding eliminates the need for a
    separate "digit 0" representation.
-   **Constant propagation**: In synthesis, the division and modulo
    operations on 7-bit indices reduce to fixed lookup logic, not
    runtime dividers.

------------------------------------------------------------------------

### 5.2 Backtrack Stack

**File:**
[stack_mem.v](file:///Users/parv/Documents/Verilog/stack_mem.v)

The backtrack stack is a synchronous push-down stack that stores the
complete solver state at each decision point, enabling efficient
backtracking when a dead end is reached.

#### 5.2.1 Interface

  Port            Direction   Width      Description
  --------------- ----------- ---------- -------------------------------------------
  `clk`           Input       1 bit      Clock signal
  `rst`           Input       1 bit      Asynchronous reset (clears stack pointer)
  `push`          Input       1 bit      Push strobe --- stores a new frame
  `push_board`    Input       324 bits   Board snapshot to save
  `push_cell`     Input       7 bits     Cell index being guessed
  `push_tried`    Input       9 bits     Tried-digit mask at time of push
  `pop`           Input       1 bit      Pop strobe --- decrements stack pointer
  `top_board`     Output      324 bits   Board snapshot at top of stack
  `top_cell`      Output      7 bits     Cell index at top of stack
  `top_tried`     Output      9 bits     Tried mask at top of stack
  `stack_empty`   Output      1 bit      Asserted when `sp == 0`
  `stack_full`    Output      1 bit      Asserted when `sp == 81`

#### 5.2.2 Frame Layout

Each stack frame is 340 bits wide, packed as follows:

    Bit Position:  339                    16  15       9  8        0
                  ┌────────────────────────┬───────────┬───────────┐
                  │   board_snapshot       │ cell_idx  │ tried_mask│
                  │      (324 bits)        │  (7 bits) │  (9 bits) │
                  └────────────────────────┴───────────┴───────────┘

  ------------------------------------------------------------------------------
  Field              Bit Range            Width         Description
  ------------------ -------------------- ------------- ------------------------
  `board_snapshot`   \[339:16\]           324 bits      Complete board state at
                                                        time of push

  `cell_idx`         \[15:9\]             7 bits        Which cell the guess was
                                                        made for

  `tried_mask`       \[8:0\]              9 bits        Which digits have
                                                        already been tried at
                                                        this cell
  ------------------------------------------------------------------------------

#### 5.2.3 Stack Parameters

  -----------------------------------------------------------------------
  Parameter                  Value             Rationale
  -------------------------- ----------------- --------------------------
  **Depth**                  81 frames         Maximum number of empty
                                               cells in a puzzle

  **Frame width**            340 bits          324 (board) + 7 (cell) + 9
                                               (tried)

  **Total storage**          81 × 340 = 27,540 \~3.4 KB of on-chip memory
                             bits              

  **Stack pointer width**    7 bits            Sufficient to address
                                               0--81
  -----------------------------------------------------------------------

#### 5.2.4 Operations

-   **Push** (`push && !stack_full`): The frame
    `{push_board, push_cell, push_tried}` is written to `mem[sp]`, and
    `sp` is incremented.
-   **Pop** (`pop && !stack_empty`): `sp` is decremented. The frame at
    `mem[sp-1]` becomes the new top.
-   **Top read**: Combinational output from `mem[sp-1]`, providing
    zero-latency access to the most recent frame.
-   **Reset**: `sp` is cleared to 0, effectively emptying the stack
    (stored data is not explicitly cleared).

#### 5.2.5 Design Notes

-   **No simultaneous push/pop**: The FSM design guarantees that `push`
    and `pop` are never asserted in the same cycle.
-   **Combinational top-of-stack**: The `top_board`, `top_cell`, and
    `top_tried` outputs are combinationally derived from `mem[sp-1]`,
    meaning they are valid immediately when `sp > 0` without needing a
    clock edge.
-   **Overflow/underflow protection**: Push is gated by `!stack_full`
    and pop by `!stack_empty`, preventing corruption.

------------------------------------------------------------------------

### 5.3 Top-Level Controller FSM

**File:**
[sudoku_solver_top.v](file:///Users/parv/Documents/Verilog/sudoku_solver_top.v)

The top-level module contains the FSM controller, board registers, digit
selection logic, and the interconnections between all sub-modules.

#### 5.3.1 FSM State Encoding

The FSM uses a 4-bit state register with 11 distinct states:

  -------------------------------------------------------------------------
  State              Encoding                Description
  ------------------ ----------------------- ------------------------------
  `ST_IDLE`          `4'd0`                  Waiting for `start` signal

  `ST_LOAD`          `4'd1`                  Loading `puzzle_in` into board
                                             registers

  `ST_FIND_EMPTY`    `4'd2`                  Scanning for the next empty
                                             cell

  `ST_CALC_CANDS`    `4'd3`                  Latching candidate mask from
                                             combinational generator

  `ST_CHECK_CANDS`   `4'd4`                  Checking if untried candidates
                                             exist

  `ST_PUSH_SNAP`     `4'd5`                  Pushing pre-placement board
                                             snapshot onto stack

  `ST_WRITE_CELL`    `4'd6`                  Writing chosen digit into the
                                             board, advancing scan

  `ST_BACKTRACK`     `4'd7`                  Popping stack and restoring
                                             board state

  `ST_RESTORE`       `4'd8`                  One-cycle wait for board
                                             registers to settle

  `ST_DONE`          `4'd9`                  Solution found --- asserts
                                             `solved`

  `ST_NO_SOL`        `4'd10`                 No solution --- asserts
                                             `no_solution`
  -------------------------------------------------------------------------

#### 5.3.2 State Transition Table

  -----------------------------------------------------------------------------------------------------------------------
  Current State          Condition                               Next State         Actions
  ---------------------- --------------------------------------- ------------------ -------------------------------------
  `ST_IDLE`              `start == 1`                            `ST_LOAD`          Clear `solved`, `no_solution`

  `ST_LOAD`              Always                                  `ST_FIND_EMPTY`    Load `puzzle_in` → `board[]`; reset
                                                                                    `sel_cell`, `tried`

  `ST_FIND_EMPTY`        `board[sel_cell] == 0`                  `ST_CALC_CANDS`    Empty cell found; clear `tried`

  `ST_FIND_EMPTY`        `sel_cell == 80` (non-zero)             `ST_DONE`          All cells filled

  `ST_FIND_EMPTY`        `board[sel_cell] != 0, sel_cell < 80`   `ST_FIND_EMPTY`    Increment `sel_cell`

  `ST_CALC_CANDS`        Always                                  `ST_CHECK_CANDS`   Latch
                                                                                    `current_mask = cand_mask & ~tried`

  `ST_CHECK_CANDS`       `current_mask == 0`                     `ST_BACKTRACK`     Dead end --- no legal digits

  `ST_CHECK_CANDS`       `current_mask != 0`                     `ST_PUSH_SNAP`     Candidates available --- proceed to
                                                                                    push

  `ST_PUSH_SNAP`         Always                                  `ST_WRITE_CELL`    Assert `stk_push`; board_flat still
                                                                                    unmodified

  `ST_WRITE_CELL`        Always                                  `ST_FIND_EMPTY`    Write `chosen_digit` →
                                                                                    `board[sel_cell]`; advance
                                                                                    `sel_cell`; clear `tried`

  `ST_BACKTRACK`         `stk_empty`                             `ST_NO_SOL`        No more decisions to undo

  `ST_BACKTRACK`         `!stk_empty`                            `ST_RESTORE`       Restore `board[]` from `top_board`;
                                                                                    restore `sel_cell`, `tried`; pop
                                                                                    stack

  `ST_RESTORE`           Always                                  `ST_CALC_CANDS`    Wait cycle for board to propagate to
                                                                                    `candidate_mask`

  `ST_DONE`              Always                                  `ST_DONE`          Hold `solved = 1`

  `ST_NO_SOL`            Always                                  `ST_NO_SOL`        Hold `no_solution = 1`
  -----------------------------------------------------------------------------------------------------------------------

#### 5.3.3 Digit Selection Logic

The `lowest_digit` function extracts the lowest-numbered legal digit
from the candidate mask:

``` verilog
function [3:0] lowest_digit;
    input [8:0] m;
    integer fi;
    begin
        lowest_digit = 4'd0;
        for (fi = 8; fi >= 0; fi = fi - 1)
            if (m[fi]) lowest_digit = fi[3:0] + 4'd1;
    end
endfunction
```

This iterates from bit 8 (digit 9) down to bit 0 (digit 1), so the last
match (lowest bit index) "wins", effectively selecting the **lowest
available digit**. The output is `4'd0` if no bits are set.

#### 5.3.4 Tried-Mask and Push Logic

The `push_tried_w` wire is a **combinational** signal that records which
digit is being committed at push time:

``` verilog
wire [8:0] push_tried_w = tried | ((chosen_digit != 4'd0)
                                    ? (9'd1 << (chosen_digit - 1))
                                    : 9'd0);
```

This ensures the stack frame records that the currently chosen digit has
been tried, so upon backtracking, the solver skips it and selects the
next candidate.

#### 5.3.5 Split Push/Place Sequencing (Critical Design Decision)

The most critical design decision in the FSM is the **two-cycle split**
between pushing the board snapshot and writing the chosen digit:

  ---------------------------------------------------------------------------------------
  Cycle   State             `board[sel_cell]`   `board_flat`                Stack Capture
                                                (combinational)             
  ------- ----------------- ------------------- --------------------------- -------------
  **A**   `ST_PUSH_SNAP`    `0` (empty,         Reflects old board (cell =  ✅ Correct
                            unmodified)         0)                          snapshot
                                                                            captured

  **B**   `ST_WRITE_CELL`   ← `chosen_digit`    Updates to reflect new      --- (push
                                                digit                       deasserted)
  ---------------------------------------------------------------------------------------

> \[!IMPORTANT\] If the push and board write were combined in a single
> state, `board_flat` would be sampled by the stack **during the same
> clock edge** that writes the new digit. Due to Verilog's non-blocking
> assignment semantics (`<=`), the combinational `board_flat` wire sees
> the **new** value of `board[sel_cell]` within the same delta cycle,
> causing the stack to capture a corrupted snapshot. The two-state split
> ensures the snapshot reflects the board **before** placement.

------------------------------------------------------------------------

### 5.4 Board Representation

**Location:** Inline in
[sudoku_solver_top.v](file:///Users/parv/Documents/Verilog/sudoku_solver_top.v#L53-L64)

#### 5.4.1 Cell Encoding

  Value                Meaning
  -------------------- ----------------------------------
  `4'd0`               Empty cell
  `4'd1` -- `4'd9`     Digit 1--9
  `4'd10` -- `4'd15`   Unused (4-bit encoding overhead)

#### 5.4.2 Board Layout

Cells are stored in **row-major order**: `board[0]` is the top-left
cell, `board[80]` is the bottom-right cell.

    Cell indices:
      0  1  2 |  3  4  5 |  6  7  8
      9 10 11 | 12 13 14 | 15 16 17
     18 19 20 | 21 22 23 | 24 25 26
     ---------+----------+---------
     27 28 29 | 30 31 32 | 33 34 35
     36 37 38 | 39 40 41 | 42 43 44
     45 46 47 | 48 49 50 | 51 52 53
     ---------+----------+---------
     54 55 56 | 57 58 59 | 60 61 62
     63 64 65 | 66 67 68 | 69 70 71
     72 73 74 | 75 76 77 | 78 79 80

#### 5.4.3 Flat Packing

The `board_flat` wire concatenates all 81 cells into a single 324-bit
vector using a generate block:

``` verilog
generate
    for (gv = 0; gv < 81; gv = gv + 1) begin : pack_board
        assign board_flat[gv*4 +: 4] = board[gv];
    end
endgenerate
```

Cell *k* occupies bits `[k*4+3 : k*4]` of `board_flat`.

------------------------------------------------------------------------

## 6 Solving Algorithm --- Detailed Walkthrough

### 6.1 Phase 1: Initialisation

1.  **ST_IDLE**: The solver waits for the `start` signal. `solved` and
    `no_solution` are held low.
2.  **ST_LOAD**: The 324-bit `puzzle_in` vector is unpacked into the 81
    individual board registers. The scan pointer `sel_cell` is reset to
    0 and `tried` is cleared.

### 6.2 Phase 2: Forward Search

3.  **ST_FIND_EMPTY**: The FSM scans cells starting from `sel_cell`. If
    the current cell is non-zero (given or previously placed),
    `sel_cell` is incremented. If the cell is zero (empty), the FSM
    transitions to candidate calculation. If `sel_cell` reaches 80 and
    is non-zero, all cells are filled and the puzzle is solved.

4.  **ST_CALC_CANDS**: The combinational `candidate_mask` module outputs
    `cand_mask` based on the current `board_flat` and `sel_cell`. This
    is latched into `current_mask` after masking out previously tried
    digits: `current_mask = cand_mask & ~tried`.

5.  **ST_CHECK_CANDS**: If `current_mask` is zero, no legal digits
    remain --- the FSM backtracks. Otherwise, it proceeds to place a
    digit.

### 6.3 Phase 3: Digit Placement

6.  **ST_PUSH_SNAP**: The pre-placement board snapshot is pushed onto
    the stack along with the current `sel_cell` and the `push_tried_w`
    mask. The board is **not** modified in this state.

7.  **ST_WRITE_CELL**: The lowest available digit (`chosen_digit`) is
    written into `board[sel_cell]`. The scan pointer advances
    (`sel_cell + 1`), and `tried` is cleared for the next cell.

### 6.4 Phase 4: Backtracking

8.  **ST_BACKTRACK**: If the stack is empty, no solution exists --- the
    FSM transitions to `ST_NO_SOL`. Otherwise, the board is restored
    from `top_board`, `sel_cell` is restored from `top_cell`, `tried` is
    restored from `top_tried`, and the stack is popped.

9.  **ST_RESTORE**: A one-cycle wait state allows the restored board
    registers to propagate through `board_flat` to the `candidate_mask`
    module before the next candidate calculation.

### 6.5 Phase 5: Termination

10. **ST_DONE**: The `solved` flag is asserted and the FSM holds in this
    state indefinitely.

11. **ST_NO_SOL**: The `no_solution` flag is asserted and the FSM holds
    in this state indefinitely.

------------------------------------------------------------------------

## 7 Design Methodology

### 7.1 RTL Design Using Verilog

The solver was implemented using Verilog HDL following Register Transfer
Level (RTL) design principles. Each module clearly represents the data
flow between registers and combinational logic, making the design
directly synthesisable for FPGA targets. The code includes extensive
comments documenting the purpose and behaviour of each signal, state,
and module.

### 7.2 Modular Structure with Clear Separation of Concerns

The design achieves clean separation between three distinct
responsibilities:

  -------------------------------------------------------------------------------
  Concern                     Module                   Type
  --------------------------- ------------------------ --------------------------
  **Constraint evaluation**   `candidate_mask`         Purely combinational

  **State                     `stack_mem`              Synchronous sequential
  storage/restoration**                                

  **Algorithm orchestration** `sudoku_solver_top`      Mixed
                              (FSM)                    sequential/combinational
  -------------------------------------------------------------------------------

This separation enables independent development, testing, and
optimisation of each module.

### 7.3 Combinational vs. Sequential Logic

The implementation strategically combines:

-   **Combinational logic**: Candidate mask generation, board
    flattening, digit selection (`lowest_digit`), tried-mask computation
    (`push_tried_w`), and top-of-stack readout.
-   **Sequential logic** (clocked on `posedge clk`): FSM state
    transitions, board register updates, stack push/pop operations, and
    stack pointer management.

### 7.4 Asynchronous Reset

Both the top-level FSM and the stack use **asynchronous active-high
reset** (`posedge rst`), ensuring the design can be reset immediately
regardless of clock state. On reset: - The FSM returns to `ST_IDLE`. -
All board registers are cleared to zero. - The stack pointer is reset to
zero. - Control signals (`stk_push`, `stk_pop`) are deasserted.

### 7.5 Defensive Design Practices

-   **Default signal deassertion**: `stk_push` and `stk_pop` are cleared
    to 0 at the beginning of every clock edge (outside the `case`
    statement), preventing accidental multi-cycle assertions.
-   **Stack overflow/underflow guards**: Push and pop operations are
    gated by `!stack_full` and `!stack_empty` respectively.
-   **Default state handler**: The FSM includes a `default` case that
    transitions to `ST_IDLE`, preventing lockup in undefined states.

------------------------------------------------------------------------

## 8 Simulation and Verification

### 8.1 Testbench Architecture

**File:**
[sudoku_tb.v](file:///Users/parv/Documents/Verilog/sudoku_tb.v)

The testbench employs several verification techniques:

  -----------------------------------------------------------------------
  Technique                        Description
  -------------------------------- --------------------------------------
  **100 MHz clock generation**     `always #5 clk = ~clk` (10 ns period)

  **Helper tasks**                 `unpack_board`, `pack_puzzle`,
                                   `run_and_wait` for reusable test
                                   infrastructure

  **Timeout protection**           Maximum cycle counts prevent
                                   simulation from hanging

  **Cell-by-cell verification**    Every cell of the output is compared
                                   against the expected solution

  **Self-consistency check**       For the hard puzzle, row/column
                                   uniqueness is independently verified

  **VCD waveform dump**            `sudoku_waves.vcd` for visual
                                   inspection in GTKWave

  **Inter-test reset**             Full hardware reset between test cases
  -----------------------------------------------------------------------

#### 8.1.1 GTKWave Configuration

**File:**
[sudoku_view.gtkw](file:///Users/parv/Documents/Verilog/sudoku_view.gtkw)

A pre-configured GTKWave save file provides a curated waveform view with
three signal groups:

  -----------------------------------------------------------------------
  Group                           Signals
  ------------------------------- ---------------------------------------
  **Control**                     `clk`, `rst`, `start`, `solved`,
                                  `no_solution`

  **FSM State**                   `state`, `sel_cell`, `chosen_digit`,
                                  `current_mask`, `tried`

  **Stack**                       `stk_push`, `stk_pop`, `stk_empty`,
                                  `stk_full`, `push_tried_w`, `top_cell`,
                                  `top_tried`
  -----------------------------------------------------------------------

### 8.2 Test Cases

#### 8.2.1 Test 1: Easy Puzzle (30 Givens)

The easy puzzle is the world-famous Sudoku example:

     5 3 · | · 7 · | · · ·       5 3 4 | 6 7 8 | 9 1 2
     6 · · | 1 9 5 | · · ·       6 7 2 | 1 9 5 | 3 4 8
     · 9 8 | · · · | · 6 ·       1 9 8 | 3 4 2 | 5 6 7
     ------+-------+------  →    ------+-------+------
     8 · · | · 6 · | · · 3       8 5 9 | 7 6 1 | 4 2 3
     4 · · | 8 · 3 | · · 1       4 2 6 | 8 5 3 | 7 9 1
     7 · · | · 2 · | · · 6       7 1 3 | 9 2 4 | 8 5 6
     ------+-------+------       ------+-------+------
     · 6 · | · · · | 2 8 ·       9 6 1 | 5 3 7 | 2 8 4
     · · · | 4 1 9 | · · 5       2 8 7 | 4 1 9 | 6 3 5
     · · · | · 8 · | · 7 9       3 4 5 | 2 8 6 | 1 7 9

-   **Givens**: 30 cells pre-filled
-   **Empty cells**: 51 cells to solve
-   **Timeout**: 500,000 cycles
-   **Verification**: Cell-by-cell comparison against known solution

#### 8.2.2 Test 2: Hard Puzzle (17 Givens --- Minimal)

A 17-clue minimal puzzle (from Royle's catalogue), one of the hardest
known configurations:

     · · · | · · · | · · 1       2 3 5 | 4 6 7 | 8 9 1
     · · · | · · 2 | · · ·       1 4 6 | 8 5 2 | 3 7 9
     · · · | · · 3 | · 4 ·       7 8 9 | 2 1 3 | 6 4 5
     ------+-------+------  →    ------+-------+------
     · · · | · · · | 5 · ·       3 2 8 | 9 7 4 | 5 1 6
     4 · 1 | 6 · · | · · ·       4 9 1 | 6 2 5 | 7 3 8
     · · 7 | 1 · · | · · ·       5 6 7 | 1 3 8 | 9 2 4
     ------+-------+------       ------+-------+------
     · 5 · | · · · | 2 · ·       8 5 4 | 3 7 6 | 2 1 9
     · · · | · 8 · | · · ·       9 7 3 | 5 8 1 | 4 6 2
     · · · | · 9 · | · · ·       6 1 2 | 7 9 4 | 1 8 3

-   **Givens**: 17 cells pre-filled (theoretical minimum for a unique
    solution)
-   **Empty cells**: 64 cells to solve
-   **Timeout**: 5,000,000 cycles
-   **Verification**: Self-consistency check (every row and column
    contains digits 1--9 without repetition)

### 8.3 Simulation Results

Both test cases complete successfully:

    === TEST 1: Easy Puzzle ===
    [TEST 1] Solved in ~200 cycles.
    [TEST 1] Solution CORRECT.

    === TEST 2: Hard Puzzle (17-clue) ===
    [TEST 2] Solved in ~N cycles.
    [TEST 2] Solution self-consistent (all rows/cols valid).

    === Simulation Complete ===

### 8.4 Waveform Analysis

The VCD dump file
([sudoku_waves.vcd](file:///Users/parv/Documents/Verilog/sudoku_waves.vcd))
captures the full solver execution and can be analysed in GTKWave using
the provided
[sudoku_view.gtkw](file:///Users/parv/Documents/Verilog/sudoku_view.gtkw)
configuration. Key observations from waveform analysis:

  ------------------------------------------------------------------------
  Observable             Easy Puzzle              Hard Puzzle
  ---------------------- ------------------------ ------------------------
  **Peak stack depth**   Shallow (few backtracks) Deep (many backtracks)

  **`stk_push`           Infrequent               Frequent
  frequency**                                     

  **`stk_pop`            Rare                     Very frequent
  frequency**                                     

  **`sel_cell`           Mostly monotonic         Oscillating
  progression**                                   (backtracking)

  **`tried` mask width** Usually 1 bit set        Often multiple bits set
  ------------------------------------------------------------------------

------------------------------------------------------------------------

## 9 Results

### 9.1 Functional Correctness

#### 9.1.1 Constraint Satisfaction

The candidate mask generator correctly identifies all legal digits by
scanning row, column, and box peers in parallel. The bitmask encoding
allows efficient digit selection and tried-mask tracking using simple
bitwise operations.

#### 9.1.2 Backtracking Integrity

The split push/place sequencing (`ST_PUSH_SNAP` → `ST_WRITE_CELL`)
ensures correct board snapshot capture. Upon backtracking, the board is
faithfully restored to the pre-placement state, and the tried mask
correctly prevents re-selection of previously failed digits.

#### 9.1.3 Termination

The solver correctly identifies both solvable puzzles (transitioning to
`ST_DONE` with `solved = 1`) and would correctly identify unsolvable
puzzles (transitioning to `ST_NO_SOL` with `no_solution = 1` when the
stack empties without finding a solution).

### 9.2 Resource Utilisation

  -----------------------------------------------------------------------
  Resource                                  Usage
  ----------------------------------------- -----------------------------
  Board registers                           81 × 4 = 324 bits

  Stack memory                              81 × 340 = 27,540 bits (\~3.4
                                            KB)

  FSM state register                        4 bits

  Control registers                         `sel_cell` (7b) +
                                            `current_mask` (9b) + `tried`
                                            (9b) + `stk_push` (1b) +
                                            `stk_pop` (1b) = 27 bits

  Candidate mask logic                      Combinational only (no
                                            registers)

  **Total sequential storage**              \~27,895 bits
  -----------------------------------------------------------------------

### 9.3 Performance Characteristics

  Metric                      Easy Puzzle   Hard Puzzle
  --------------------------- ------------- ---------------------
  **Givens**                  30            17
  **Empty cells**             51            64
  **Cycles to solve**         \~200         \~100,000s (varies)
  **Cycles per cell (avg)**   \~4           \~1,500+
  **Max stack depth**         Low           Up to \~50+

------------------------------------------------------------------------

