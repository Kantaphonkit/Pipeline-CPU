`timescale 1ns/1ps

// dmem.v -- data memory, synchronous access with byte lanes handled inside.
// See docs/INTERFACES.md §8.7.
// funct3: 000 b, 001 h, 010 w, 100 bu, 101 hu.
module dmem #(
    parameter INIT = ""
) (
    input  wire        clk,
    input  wire        we,            // store in MEM stage
    input  wire        re,            // load in MEM stage
    input  wire [31:0] addr,          // effective byte address
    input  wire [2:0]  funct3,        // 000 b, 001 h, 010 w, 100 bu, 101 hu
    input  wire [31:0] wdata,         // rs2 value (already forwarded)
    output wire [31:0] rdata,         // load result, extended; valid the cycle after `re`
    output wire [31:0] wmask_data     // store data masked to width, not shifted
);

    // ram_style: force block-RAM inference (registered read below, byte
    // -lane writes -> byte-write-enable BRAM).  Simulation-neutral.
    (* ram_style = "block" *)
    reg [31:0] mem [0:1023];

    integer init_i;
    initial begin
        for (init_i = 0; init_i < 1024; init_i = init_i + 1)
            mem[init_i] = 32'b0;
        if (INIT != "")
            $readmemh(INIT, mem);
    end

    // ---- write: byte-lane update ----
    always @(posedge clk) begin
        if (we) begin
            case (funct3[1:0])
                2'b00: begin // sb
                    case (addr[1:0])
                        2'b00: mem[addr[11:2]][7:0]   <= wdata[7:0];
                        2'b01: mem[addr[11:2]][15:8]  <= wdata[7:0];
                        2'b10: mem[addr[11:2]][23:16] <= wdata[7:0];
                        2'b11: mem[addr[11:2]][31:24] <= wdata[7:0];
                    endcase
                end
                2'b01: begin // sh
                    if (addr[1] == 1'b0)
                        mem[addr[11:2]][15:0]  <= wdata[15:0];
                    else
                        mem[addr[11:2]][31:16] <= wdata[15:0];
                end
                default: begin // sw
                    mem[addr[11:2]] <= wdata;
                end
            endcase
        end
    end

    // ---- read: register address/word/funct3 at posedge, extend combinationally ----
    reg [31:0] rword;
    reg [1:0]  raddr_l;
    reg [2:0]  rfunct3;

    always @(posedge clk) begin
        if (re) begin
            rword   <= mem[addr[11:2]];
            raddr_l <= addr[1:0];
            rfunct3 <= funct3;
        end
    end

    reg [7:0]  byte_sel;
    reg [15:0] half_sel;
    reg [31:0] rdata_r;

    always @(*) begin
        case (raddr_l)
            2'b00: byte_sel = rword[7:0];
            2'b01: byte_sel = rword[15:8];
            2'b10: byte_sel = rword[23:16];
            2'b11: byte_sel = rword[31:24];
        endcase

        if (raddr_l[1] == 1'b0)
            half_sel = rword[15:0];
        else
            half_sel = rword[31:16];

        case (rfunct3)
            3'b000:  rdata_r = {{24{byte_sel[7]}}, byte_sel};   // lb
            3'b001:  rdata_r = {{16{half_sel[15]}}, half_sel};  // lh
            3'b010:  rdata_r = rword;                            // lw
            3'b100:  rdata_r = {24'b0, byte_sel};                // lbu
            3'b101:  rdata_r = {16'b0, half_sel};                // lhu
            default: rdata_r = rword;
        endcase
    end

    assign rdata = rdata_r;

    // ---- wmask_data: store data masked to width, not shifted (for trace port) ----
    reg [31:0] wmask_data_r;
    always @(*) begin
        case (funct3[1:0])
            2'b00:   wmask_data_r = {24'b0, wdata[7:0]};
            2'b01:   wmask_data_r = {16'b0, wdata[15:0]};
            default: wmask_data_r = wdata;
        endcase
    end

    assign wmask_data = wmask_data_r;

endmodule
