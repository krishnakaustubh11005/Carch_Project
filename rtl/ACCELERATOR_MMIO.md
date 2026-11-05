# Accelerator MMIO peripheral

`accelerator_mmio.v` translates addressed reads/writes into the existing
`accelerator_4x4` interface. The controller and array are unchanged. This step
provides a bus-level peripheral; a processor, RAM, address-routing logic, and C
driver are not connected yet.

## Ports and request protocol

| Port | Direction | Meaning |
|---|---|---|
| `clk`, `rst` | Input | Rising-edge clock, synchronous active-high reset |
| `mem_valid` | Input | Request active |
| `mem_addr[31:0]` | Input | Full byte address |
| `mem_wdata[31:0]` | Input | Write payload |
| `mem_wstrb[3:0]` | Input | Byte enables; zero means read |
| `mem_ready` | Output | Registered one-clock acknowledgement |
| `mem_rdata[31:0]` | Output | Read response, registered with acknowledgement |

The signals follow PicoRV32's native-memory naming. This version supports one
outstanding request and **requires a valid-low clock edge between requests**.
It does not support a new back-to-back transaction with valid continuously high.
The eventual CPU integration must respect that requirement or insert an adapter.

1. Assert valid with address, payload, and strobes stable before a rising edge.
2. At the first edge, the peripheral performs the access, registers read data,
   and raises ready. The master samples the acknowledgement on the following
   rising edge. Keep the request stable until that handshake.
3. Ready drops after one clock. A held valid does not execute another access or
   receive another acknowledgement, even if address/data change after response.
4. Deassert valid for a rising edge to rearm, then issue another request.

Read data holds until reset or the next accepted transaction. Write responses
return zero. Reset clears response state, input/output storage, busy, and done;
it cancels an active computation and suppresses access acceptance. The master
must drop an aborted request across reset; a valid still high after reset is
treated as a new request.

The hardware has no error-response port. Unsupported accesses still acknowledge:
reads return zero and writes have no effect. Gate the peripheral's valid with
system address selection when connecting it alongside RAM or other peripherals.
It otherwise acknowledges even addresses outside its own window.

## Register map

`BASE_ADDR` defaults to `0x10000000`. Offsets below are relative to that base.
Use a word-aligned base, normally aligned to a 256-byte peripheral window.
Element index is row-major: `4*row + column`.

| Offset | Access | Meaning |
|---|---|---|
| `0x00` | Write | Bit 0 requests start; other bits ignored. Reads return zero |
| `0x04` | Read | Bit 0 = busy; bit 1 = done; other bits zero |
| `0x10 + 4*i`, i=0..15 | Write | A element i, low byte interpreted as signed INT8 |
| `0x50 + 4*i`, i=0..15 | Write | B element i, low byte interpreted as signed INT8 |
| `0x90 + 4*i`, i=0..15 | Read | C element i, signed 24-bit value sign-extended to 32 bits |

All accesses must be word-aligned. Inputs are write-only; their reads return
zero. Result/status writes, unaligned accesses, reserved offsets, and
out-of-window accesses have no effect and return zero.

Input and control writes require `mem_wstrb[0]=1`. Byte-lane-zero writes and
full-word writes are supported. Other byte enables do not affect the stored
element; upper payload bits are ignored. This is one element per word, not four
packed INT8 elements per word. A word write with strobes `1110` does nothing.

Busy-time input writes and start requests are acknowledged but ignored by the
controller; they are not deferred. Done is sticky until reset or an accepted
start. Writing control bit 0 as zero does not clear done. Input writes after
completion leave done high. Reads during computation can see partial results;
read the completed matrix only after status reports busy=0 and done=1.

## Caller sequence

1. Write all sixteen A elements and all sixteen B elements.
2. Write `1` to control.
3. Poll status with a bounded timeout until `(status & 3) == 2`.
4. Read all sixteen results as signed 32-bit values.
5. Reload inputs as needed, then start again. Reset is not required between jobs.

Status and result data are sampled when the request is accepted. A status read
on the same edge that computation completes may return the previous busy value;
polling again observes completion. No interrupt or DMA interface is implemented.

## Verification

```sh
make test-mmio
make wave-mmio                 # GTKWave required
make test-mmio ACCELERATOR_MATRICES=golden/array_matrices.json
```

The default eight-case fixture covers zero, identity, signed extremes, and
deterministic random inputs. Python computes the expected outputs. Four full
operations per case produce 512 result comparisons, all through bus transactions.
No DUT-internal signals are used by the checker. Tests also exercise:

- A non-default peripheral base address and all matrix element addresses.
- Lane-zero and full-word writes; ignored upper-lane and unaligned writes.
- Reserved/out-of-window accesses and read-only/write-only register behavior.
- Holding requests after acknowledgement, response stability, and one-shot start.
- Busy-time writes/starts, sticky completion, and reuse of stored matrices.
- Reset during computation with a pending request, zeroed results, and recovery.

Logs and vectors are under `sim/build/`, and the waveform is
`sim/vcd/accelerator_mmio.vcd`. The generic `make test` also discovers this
testbench and uses ARRAY_MATRICES; custom inputs for the peripheral must have
K=4. This verifies RTL simulation, not FPGA timing or CPU integration.
