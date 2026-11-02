#Computer Architechture Project

##Problem Statement
A parameterized n*n systolic array accelerator implemnted in verilog on FPGA performing int8 matrix multiplication using an output stationary data flow verified against software golden model and benchmarked for speed up over a sequential software implementation.

## Arithmetic modules and staged PE work

| Module | Ports / parameters | Registered latency |
|---|---|---|
| `half_adder` | `a,b` -> `sum,carry`; one-bit ports | 0 cycles (combinational) |
| `full_adder` | `a,b,cin` -> `sum,cout`; instantiates two half adders | 0 cycles (combinational) |
| `booth_recoder` | `y[2:0]` -> `sign,one,two`; one radix-4 digit | 0 cycles (combinational) |
| `booth_pp_gen` | DATA_W=8; signed `x` and `sign,one,two` -> unsigned DATA_W+2-bit `pp`, separate `neg` | 0 cycles (combinational) |
| `compressor_tree` | WIDTH=24, ROWS=7; packed `rows` -> aligned `sum,carry`; reuses FA/HA | 0 cycles (combinational) |
| `booth_mac_datapath` | DATA_W=8, ACC_W=DATA_W+DATA_W+8; `a,b,acc_s,acc_c` -> `sum,carry` | 0 cycles (combinational) |
| `signed_multiplier` | DATA_W=8; `a,b` -> full signed `product`; resolves only at output | 0 cycles (combinational) |
| `pe_booth_csa` | DATA_W=8, K_MAX=256, derived ACC_W=24; clocked valid streams, clear, drain, result | One forwarding hop; result after sampled drain edge |

Run `make test-booth_recoder` for exhaustive window and signed INT8 reconstruction checks, or `make` for the available suite. The recoder is independent of DATA_W; both zero windows use sign=0.

Retained PE defaults: DATA_W=8, K_MAX=256, ACC_W=2*DATA_W+ceil(log2(K_MAX))=24. The clocked Booth/carry-save PE is implemented. The behavioral baseline and MUL_TYPE comparison wrapper remain deferred; no synthesis comparison is claimed. See [the implementation guide](docs/IMPLEMENTATION.md) for the six review stages. Current work stops after the clocked Booth/CSA PE for review.

Run `make test-booth_pp_gen` for widths 2/3/4/8/16. Its row contract is `unsigned(pp)+neg = Booth_digit*x + 2^(DATA_W+1)`. The future tree must cancel the combined shifted biases: for INT8 and ACC_W=24 the constant is `0xFF5600`. Rows are zero-extended into that tree, not sign-extended. See the guide for the derivation and corner cases.

Run `make test-signed_multiplier` for exhaustive INT8 multiplication (65,536 pairs), `make test-compressor_tree` for structural sum-preservation checks, and `make test-booth_mac_datapath` for nonzero carry-save accumulator inputs. The INT8 tree reduces seven rows through 7->5->4->3->2, retaining two vectors with no carry-propagate adder in the MAC feedback path. The clocked Booth/CSA PE now instantiates this core; baseline/wrapper comparison remains future work.

## Clocked PE

Run `make test-pe` (alias of `make test-pe_booth_csa`) or `make wave MOD=pe`. Control priority is synchronous reset > clear > drain > enable. Enabled edges forward independent A/B streams and MAC current operands only when both valid bits are asserted. Drain accepts no MAC, holds accumulator/forwarding state, and publishes result/result_valid immediately after its rising edge, even with en=0. Result_valid deasserts on the next non-drain clock; result holds until reset, clear, or another drain. No extra input pipeline or continuous acc_out port is present.

For signed fixed point, F input fractional bits imply 2F result fractional bits; the hardware is unchanged. The tested F=4 example `1.5*(-2)+0.5*1` produces raw result -640, interpreted as -2.5. Rounding/output rescaling is not included.
