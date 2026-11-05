# Elaborated RTL explorer

## Current milestone

The first review target is `full_adder`: two distinct `half_adder` instances plus
the OR primitive, with all eight single-bit nets connected. A small drill-down
foundation is included: enter either half adder and see its XOR/AND primitives,
then return via breadcrumbs. Inline hierarchical expansion is not implemented.

No RTL is modified. The original declaration parser only supplies the top-module
list; **all canvas connectivity comes from Yosys JSON**.

## Setup and launch

From the repository root:

```sh
make visualize-setup
make visualize
```

The setup target installs ELK.js from the npm lockfile and portable Yosys in an
ignored `visualizer/.venv`. It requires internet access on first installation.
Node/npm and Python with venv support must already be installed. A native Yosys
can be used instead: `npm ci --prefix visualizer`, then
`make visualize YOSYS=/path/to/yosys`.

The server binds to loopback by default. It executes local HDL tooling and is
intended for trusted source files on your workstation, not public deployment.

## Data flow

1. `POST /api/build` accepts a top-module name, validated as an identifier.
2. Yosys reads `rtl/*.v`, checks/resolves the selected hierarchy, lowers processes
   with `proc -noopt`, and exports JSON without flattening or technology mapping.
3. `netlist.py` retains each cell's ordered port bits and constructs per-module
   nets using integer bit IDs. Constants remain distinct string values.
4. Module input ports are drivers inside that module; output ports are consumers.
   Instance port roles are the reverse. Inout endpoints retain both roles.
5. ELK lays out blocks/ports and routes only the connections in this graph.

Net IDs are local to each module definition. Instance navigation retains the
full path, so entering two instances of the same definition is not confused
with instantiating that definition only once.

Artifacts live in separate build directories under `sim/build/visualizer/`.
The last diagram is replaced by an explicit error when a build fails; it is
never silently reused as if it reflected current RTL. Source syntax errors in
any loaded RTL file can prevent elaboration, even for a different top.

## Tests

```sh
YOSYS="$PWD/visualizer/.venv/bin/yowasp-yosys" make test-tooling
node --check visualizer/app.js
```

The Yosys integration test is skipped unless `YOSYS` is set or Yosys is on PATH;
normalization and HTTP regression checks do not need Yosys. Fixtures cover
fan-out, ordered slices/concatenations, aliases, constants, unknown primitive
types, feedback, and inout roles.

For optional browser automation, install Playwright separately (not a runtime
dependency), install its Chromium browser, and start the viewer. Then:

```sh
PLAYWRIGHT_PATH=/absolute/path/to/node_modules/playwright \
VIEWER_URL=http://127.0.0.1:8000 node visualizer/tests/browser.cjs
```

The test checks selection, tracing, pointer-centered zoom, pixel-accurate pan,
fit, drill-down, and parent viewport restoration. Its screenshot is written to
`sim/build/visualizer/full-adder.png`.

## Deliberate limits / follow-up milestones

- Current bus routing is bit-by-bit; vector grouping and split/join symbols are
  deferred. Port-bit offsets are retained; cell endpoint indices are connection
  positions, not necessarily original source declaration indices.
- Primitive cells use labeled generic blocks. No cell is removed just because
  it lacks a dedicated gate symbol.
- Zoom changes scale, not hierarchy; entering a module is explicit.
- Inline expansion, instance-tree navigation, effective-parameter inspection,
  and parameter override UI remain future work.
- Layout limits of 500 blocks and 5,000 edges per opened module avoid knowingly
  overloading the first-release renderer. Large arrays and deeply generated
  datapaths are not yet a validated visualization target.
- No FPGA mapping, critical-path analysis, live values, or cycle animation.
- Unlowered memories are explicitly rejected rather than omitted from a diagram.

Review the full-adder diagram before scaling the UI to the PE and array.
