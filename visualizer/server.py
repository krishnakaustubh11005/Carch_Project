#!/usr/bin/env python3
"""Local RTL browser with Yosys elaboration and a static schematic frontend."""

from __future__ import annotations

import json
import re
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse
try:
    from .netlist import build, BuildError
except ImportError:
    from netlist import build, BuildError


ROOT = Path(__file__).resolve().parent.parent
RTL = ROOT / "rtl"
WEB = Path(__file__).resolve().parent


def strip_comments(source: str) -> str:
    source = re.sub(r"/\*.*?\*/", "", source, flags=re.S)
    return re.sub(r"//.*", "", source)


def split_top_level(text: str) -> list[str]:
    """Split comma-delimited Verilog lists while respecting nested delimiters."""
    items: list[str] = []
    start = 0
    stack: list[str] = []
    pairs = {")": "(", "]": "[", "}": "{"}
    for index, char in enumerate(text):
        if char in "([{":
            stack.append(char)
        elif char in ")]}" and stack and stack[-1] == pairs[char]:
            stack.pop()
        elif char == "," and not stack:
            items.append(text[start:index].strip())
            start = index + 1
    tail = text[start:].strip()
    if tail:
        items.append(tail)
    return items


def parenthesized(text: str, opening: int) -> tuple[str, int]:
    depth = 0
    for index in range(opening, len(text)):
        if text[index] == "(":
            depth += 1
        elif text[index] == ")":
            depth -= 1
            if depth == 0:
                return text[opening + 1:index], index + 1
    return "", len(text)


def parse_modules() -> list[dict]:
    modules: list[dict] = []
    paths = sorted(RTL.glob("*.v"))
    module_types = set()
    for path in paths:
        module_types.update(re.findall(r"\bmodule\s+(\w+)\b", strip_comments(path.read_text(encoding="utf-8"))))
    for path in paths:
        source = strip_comments(path.read_text(encoding="utf-8"))
        declarations = list(re.finditer(r"\bmodule\s+(\w+)\b", source))
        for position, declaration in enumerate(declarations):
            name = declaration.group(1)
            end = source.find("endmodule", declaration.end())
            if end < 0:
                continue
            module_text = source[declaration.end():end]
            depth = 0
            header_end = -1
            for index, char in enumerate(module_text):
                if char == "(":
                    depth += 1
                elif char == ")":
                    depth -= 1
                elif char == ";" and depth == 0:
                    header_end = index
                    break
            if header_end < 0:
                continue
            header = module_text[:header_end]
            body = module_text[header_end + 1:]
            params: list[dict] = []
            parameter_start = re.search(r"#\s*\(", header)
            if parameter_start:
                parameter_text, parameter_end = parenthesized(header, parameter_start.end() - 1)
                for parameter in split_top_level(parameter_text):
                    match = re.search(r"\bparameter\s+(?:\w+\s+)*(\w+)\s*=\s*(.*)$", parameter, flags=re.S)
                    if match:
                        params.append({"name": match.group(1), "default": match.group(2).strip()})
            else:
                parameter_end = 0

            ports_start = header.find("(", parameter_end)
            port_text = parenthesized(header, ports_start)[0] if ports_start >= 0 else ""

            ports: list[dict] = []
            inherited_direction = ""
            inherited_width = "1 bit"
            for declaration_text in split_top_level(port_text):
                direction_match = re.search(r"\b(input|output|inout)\b", declaration_text)
                if direction_match:
                    inherited_direction = direction_match.group(1)
                    range_match = re.search(r"\[([^]]+)\]", declaration_text)
                    inherited_width = range_match.group(1).replace(" ", "") if range_match else "1 bit"
                port_name = re.search(r"(\w+)\s*$", declaration_text)
                if port_name and inherited_direction:
                    ports.append({"name": port_name.group(1), "direction": inherited_direction, "width": inherited_width})

            instances: list[dict] = []
            for child_type in sorted(module_types):
                if child_type == name:
                    continue
                instance_pattern = re.compile(
                    rf"\b{re.escape(child_type)}\b\s*(?:#\s*\((?:[^()]|\([^()]*\))*\)\s*)?"
                    r"(\w+)\s*\((.*?)\)\s*;", re.S
                )
                for instance in instance_pattern.finditer(body):
                    connection_text = instance.group(2)
                    connections = []
                    for connection in re.finditer(r"\.(\w+)\s*\(", connection_text):
                        signal, _ = parenthesized(connection_text, connection.end() - 1)
                        connections.append({"port": connection.group(1), "signal": signal.strip()})
                    instances.append({
                        "module": child_type,
                        "name": instance.group(1),
                        "connections": connections,
                    })

            modules.append({
                "name": name,
                "file": path.relative_to(ROOT).as_posix(),
                "parameters": params,
                "ports": ports,
                "instances": instances,
            })
    return modules


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(WEB), **kwargs)

    def do_GET(self):
        if urlparse(self.path).path == "/vendor/elk.js":
            self.path = "/node_modules/elkjs/lib/elk.bundled.js"
        if urlparse(self.path).path == "/api/modules":
            payload = json.dumps(parse_modules()).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if urlparse(self.path).path == "/":
            self.path = "/index.html"
        return super().do_GET()

    def do_POST(self):
        if self.path != "/api/build":
            self.send_error(404)
            return
        # Only same-origin browser requests may trigger local tool execution.
        origin = self.headers.get("Origin")
        if origin and origin != "http://" + self.headers.get("Host", ""):
            self.send_error(403)
            return
        try:
            size = int(self.headers.get("Content-Length", "0"))
            if not 0 < size <= 4096:
                raise ValueError("Invalid request size")
            request = json.loads(self.rfile.read(size))
            if not isinstance(request, dict):
                raise ValueError("Expected a JSON object")
            top = request.get("top", "full_adder")
            if not isinstance(top, str):
                raise ValueError("Top must be a module name")
            payload = build(top)
            status = 200
        except (BuildError, ValueError) as error:
            payload, status = {"error": str(error)}, 400
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8000)
    args = parser.parse_args()
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"Carch RTL Visualizer: http://{args.host}:{args.port}")
    print("Serving live module information from rtl/ (Ctrl+C to stop)")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nVisualizer stopped")
    finally:
        server.server_close()
