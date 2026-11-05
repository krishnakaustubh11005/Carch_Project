# Array control verification

Run `make test-array-controls` from the repository root. It uses the existing
Python-generated matrix vectors and runs six scenarios:

0. Continuous input, as a reference.
1. Three-clock stalls during input and during final drain propagation.
2. Enabled bubbles with all source valid bits zero.
3. Combined stalls and bubbles across consecutive matrices.
4. Clear while stalled with unfinished work in the mesh, then a fresh stream.
5. Reset while stalled with unfinished work in the mesh, then a fresh stream.

The checker compares every published element against Python, checks publication
timing in enabled steps, rejects publications while stalled, and checks for
missing/extra results. Reset/clear must zero outputs. Each recovery scenario
starts with three cycles of poison operands before discarding them.

Scenario numbers appear in the transcript and waveform (`scenario`). Default
inputs give 192 result checks: six scenarios, two matrices, sixteen PEs.
These are directed tests, not exhaustive control verification; independent lane
bubbles and output backpressure are not exercised.

Open the waveform with `make wave-array-controls` (requires GTKWave).
The waveform is `sim/vcd/systolic_4_4_array.vcd`; the full log is
`sim/build/logs/systolic_4_4_array.log`. Other array tests overwrite these files.

For mixed inner dimensions including K=256:

```sh
python3 golden/array_sizes.py
make test-array-controls ARRAY_MATRICES=sim/build/vectors/array_sizes_matrices.json
```

The regular `make test-array` keeps its uninterrupted scenario. No accelerator
RTL is modified by this verification change.
