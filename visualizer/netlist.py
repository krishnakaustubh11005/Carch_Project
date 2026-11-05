"""Hierarchy-preserving Yosys builds and bit-accurate graph normalization."""

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
class BuildError(Exception):
    pass


def normalize(design, top):
    """Keep ordered bits on ports; nets are indexed by identity, never alias names."""
    if top not in design.get("modules", {}):
        raise BuildError(f"Elaborated design does not contain top module {top}")
    result = {}
    for name, module in design["modules"].items():
        if module.get("memories"):
            raise BuildError(f"Module {name} contains unlowered memories; memory visualization is not supported in this milestone.")
        nets = {}

        def net(bit):
            # Constants are strings in Yosys JSON, signal bit identities are integers.
            key = f"const:{bit}" if isinstance(bit, str) else f"bit:{bit}"
            return nets.setdefault(key, {"id": key, "bit": bit, "constant": isinstance(bit, str),
                                         "aliases": [], "drivers": [], "consumers": []})

        def endpoint(node, port, direction, bits, boundary=False):
            for index, bit in enumerate(bits):
                item = {"node": node, "port": port, "index": index}
                is_driver = direction == "input" if boundary else direction == "output"
                if direction == "inout":
                    net(bit)["drivers"].append(item)
                    net(bit)["consumers"].append(item)
                else:
                    net(bit)["drivers" if is_driver else "consumers"].append(item)

        ports = []
        for port_name, port in module.get("ports", {}).items():
            ports.append({"name": port_name, **port})
            endpoint("$boundary", port_name, port["direction"], port["bits"], True)
        cells = []
        for cell_name, cell in module.get("cells", {}).items():
            directions = cell.get("port_directions", {})
            ports_in_cell = []
            for port_name, bits in cell.get("connections", {}).items():
                if port_name not in directions:
                    raise BuildError(f"Missing port direction: {name}/{cell_name}.{port_name}")
                direction = directions[port_name]
                ports_in_cell.append({"name": port_name, "direction": direction, "bits": bits})
                endpoint(cell_name, port_name, direction, bits)
            cells.append({"id": cell_name, "type": cell["type"], "ports": ports_in_cell,
                          "module": cell["type"] if cell["type"] in design["modules"] else None,
                          "parameters": cell.get("parameters", {}),
                          "source": cell.get("attributes", {}).get("src", "")})
        for alias, wire in module.get("netnames", {}).items():
            for index, bit in enumerate(wire["bits"]):
                label = alias if len(wire["bits"]) == 1 else f"{alias}[{wire.get('offset', 0) + (len(wire['bits']) - 1 - index if wire.get('upto') else index)}]"
                if label not in net(bit)["aliases"]:
                    net(bit)["aliases"].append(label)
        for item in nets.values():
            item["aliases"].sort(key=lambda alias: (alias.startswith("$"), len(alias), alias))
            item["label"] = item["aliases"][0] if item["aliases"] else str(item["bit"])
        result[name] = {"name": name, "ports": ports, "cells": cells, "nets": list(nets.values()),
                        "parameters": module.get("parameter_default_values", {}),
                        "source": module.get("attributes", {}).get("src", "")}
    return {"top": top, "modules": result, "creator": design.get("creator", ""),
            "representation": "Elaborated RTL · hierarchy preserved"}


def build(top, root=ROOT, executable=None):
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_$]*", top):
        raise BuildError("Invalid top module name")
    local_tool = Path(root) / "visualizer" / ".venv" / "bin" / "yowasp-yosys"
    tool = (executable or os.environ.get("YOSYS") or shutil.which("yosys")
            or shutil.which("yowasp-yosys") or (str(local_tool) if local_tool.exists() else None))
    if not tool or not shutil.which(tool):
        raise BuildError("Yosys is unavailable. Install Yosys or yowasp-yosys, or set YOSYS to its executable path. No guessed schematic is shown.")
    build_root = Path(root) / "sim" / "build" / "visualizer"
    build_root.mkdir(parents=True, exist_ok=True)
    # Each build has separate artifacts, so concurrent requests cannot mix results.
    directory = Path(tempfile.mkdtemp(prefix=f"{top}-", dir=build_root))
    sources = sorted((Path(root) / "rtl").glob("*.v"))
    # Use relative paths for native and WASI Yosys compatibility; run from project root.
    def quote(path):
        return '"' + str(path).replace('\\', '\\\\').replace('"', '\\"') + '"'
    output = directory.relative_to(root) / "netlist.json"
    script = "\n".join([
        "read_verilog " + " ".join(quote(path.relative_to(root)) for path in sources),
        f"hierarchy -check -top {top}",
        "proc -noopt",
        f"write_json {quote(output)}",
    ]) + "\n"
    script_path = directory / "build.ys"
    script_path.write_text(script)
    command = [str(tool), "-s", str(script_path.relative_to(root))]
    try:
        process = subprocess.run(command, cwd=root, capture_output=True, text=True, timeout=120)
    except subprocess.TimeoutExpired as error:
        (directory / "build.log").write_text(str(error))
        raise BuildError(f"Elaboration timed out after 120 seconds. Artifacts: {directory.relative_to(root)}") from error
    except OSError as error:
        raise BuildError(f"Could not run Yosys: {error}") from error
    log = process.stdout + process.stderr
    (directory / "build.log").write_text(log)
    if process.returncode != 0:
        raise BuildError(f"Yosys elaboration failed:\n{log[-14000:]}")
    try:
        graph = normalize(json.loads((Path(root) / output).read_text()), top)
    except (ValueError, OSError) as error:
        raise BuildError(f"Cannot read Yosys output: {error}") from error
    graph["artifacts"] = directory.relative_to(root).as_posix()
    graph["tool"] = str(tool)
    (directory / "graph.json").write_text(json.dumps(graph, indent=2))
    return graph
