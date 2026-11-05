"""Connectivity regression checks independent of a local Yosys installation."""

import os
import shutil
import threading
import unittest
from unittest.mock import patch
from http.server import ThreadingHTTPServer
from urllib.error import HTTPError
from urllib.request import Request, urlopen
import json

from visualizer.netlist import BuildError, build, normalize
from visualizer.server import Handler


def full_adder_fixture():
    def cell(kind, connections, directions):
        return {"type": kind, "connections": connections, "port_directions": directions}
    ha_directions = {"a": "input", "b": "input", "sum": "output", "carry": "output"}
    return {"modules": {"full_adder": {
        "ports": {name: {"direction": direction, "bits": [bit]} for name, direction, bit in
                  [("a", "input", 2), ("b", "input", 3), ("cin", "input", 4),
                   ("sum", "output", 5), ("cout", "output", 6)]},
        "cells": {
            "add_operands": cell("half_adder", {"a": [2], "b": [3], "sum": [7], "carry": [8]}, ha_directions),
            "add_carry_in": cell("half_adder", {"a": [7], "b": [4], "sum": [5], "carry": [9]}, ha_directions),
            "carry_or": cell("$or", {"A": [8], "B": [9], "Y": [6]}, {"A": "input", "B": "input", "Y": "output"}),
        },
        "netnames": {"intermediate_sum": {"bits": [7]}, "alias_sum": {"bits": [7]}},
    }, "half_adder": {"ports": {}, "cells": {}, "netnames": {}}}}


class ConnectivityTests(unittest.TestCase):
    def test_two_half_adders_and_or_connections(self):
        module = normalize(full_adder_fixture(), "full_adder")["modules"]["full_adder"]
        self.assertEqual(len(module["cells"]), 3)
        nets = {net["bit"]: net for net in module["nets"]}
        self.assertEqual(nets[7]["drivers"], [{"node": "add_operands", "port": "sum", "index": 0}])
        self.assertEqual(nets[7]["consumers"], [{"node": "add_carry_in", "port": "a", "index": 0}])
        self.assertEqual(set(nets[7]["aliases"]), {"intermediate_sum", "alias_sum"})
        self.assertEqual(nets[8]["consumers"][0]["node"], "carry_or")
        self.assertEqual(nets[9]["consumers"][0]["node"], "carry_or")
        self.assertEqual(nets[6]["consumers"][0]["node"], "$boundary")

    def test_fanout_constants_slices_and_concatenation_keep_bit_identity(self):
        data = full_adder_fixture()
        module = data["modules"]["full_adder"]
        module["cells"]["bus"] = {"type": "$unknown", "port_directions": {"A": "input"},
                                   "connections": {"A": [7, "0", 7, "1", 2]}}
        normalized = normalize(data, "full_adder")["modules"]["full_adder"]
        nets = {net["id"]: net for net in normalized["nets"]}
        self.assertEqual(len(nets["bit:7"]["consumers"]), 3)
        self.assertEqual(nets["const:0"]["consumers"][0]["index"], 1)
        self.assertNotIn("bit:0", nets)
        self.assertEqual(normalized["cells"][-1]["ports"][0]["bits"], [7, "0", 7, "1", 2])

    def test_feedback_is_not_dropped(self):
        data = full_adder_fixture()
        data["modules"]["full_adder"]["cells"]["reg"] = {
            "type": "$dff", "port_directions": {"D": "input", "Q": "output"},
            "connections": {"D": [10], "Q": [10]}}
        module = normalize(data, "full_adder")["modules"]["full_adder"]
        feedback = next(net for net in module["nets"] if net["bit"] == 10)
        self.assertEqual(feedback["drivers"][0]["port"], "Q")
        self.assertEqual(feedback["consumers"][0]["port"], "D")

    def test_ascending_and_offset_alias_indices(self):
        data = full_adder_fixture()
        data["modules"]["full_adder"]["netnames"]["ascending"] = {
            "bits": [2, 3], "offset": 4, "upto": 1}
        module = normalize(data, "full_adder")["modules"]["full_adder"]
        nets = {net["bit"]: net for net in module["nets"]}
        self.assertIn("ascending[5]", nets[2]["aliases"])
        self.assertIn("ascending[4]", nets[3]["aliases"])

    def test_inout_records_both_roles(self):
        data = full_adder_fixture()
        data["modules"]["full_adder"]["ports"]["io"] = {"direction": "inout", "bits": [20]}
        module = normalize(data, "full_adder")["modules"]["full_adder"]
        net = next(net for net in module["nets"] if net["bit"] == 20)
        self.assertTrue(net["drivers"] and net["consumers"])

    def test_unknown_direction_fails_instead_of_guessing(self):
        data = full_adder_fixture()
        data["modules"]["full_adder"]["cells"]["carry_or"]["port_directions"] = {}
        with self.assertRaises(BuildError):
            normalize(data, "full_adder")

    def test_invalid_top_and_missing_tool(self):
        with self.assertRaises(BuildError):
            build("full_adder; exec bad")
        with patch("visualizer.netlist.shutil.which", return_value=None):
            with self.assertRaisesRegex(BuildError, "unavailable"):
                build("full_adder")

    def test_missing_top_fails(self):
        with self.assertRaises(BuildError):
            normalize(full_adder_fixture(), "absent")

    def test_unlowered_memory_is_not_silently_omitted(self):
        data = full_adder_fixture()
        data["modules"]["full_adder"]["memories"] = {"ram": {"width": 8, "size": 16}}
        with self.assertRaisesRegex(BuildError, "memories"):
            normalize(data, "full_adder")


class ApiTests(unittest.TestCase):
    def setUp(self):
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = f"http://127.0.0.1:{self.server.server_port}/api/build"

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def post(self, value, headers=None):
        return urlopen(Request(self.url, data=json.dumps(value).encode(),
                               headers={"Content-Type": "application/json", **(headers or {})}))

    def test_build_success(self):
        with patch("visualizer.server.build", return_value={"top": "full_adder"}) as mocked:
            with self.post({"top": "full_adder"}) as response:
                self.assertEqual(json.load(response), {"top": "full_adder"})
            mocked.assert_called_once_with("full_adder")

    def test_failure_is_visible_and_malformed_json_shape_is_rejected(self):
        with patch("visualizer.server.build", side_effect=BuildError("Tool missing")):
            with self.assertRaises(HTTPError) as caught:
                self.post({"top": "full_adder"})
            self.assertEqual(caught.exception.code, 400)
            self.assertEqual(json.load(caught.exception)["error"], "Tool missing")
        with self.assertRaises(HTTPError) as caught:
            self.post([])
        self.assertEqual(caught.exception.code, 400)

    def test_cross_origin_build_rejected(self):
        with patch("visualizer.server.build") as mocked:
            with self.assertRaises(HTTPError) as caught:
                self.post({"top": "full_adder"}, {"Origin": "https://untrusted.example"})
            self.assertEqual(caught.exception.code, 403)
            mocked.assert_not_called()


TOOL = os.environ.get("YOSYS") or shutil.which("yosys") or shutil.which("yowasp-yosys")


@unittest.skipUnless(TOOL, "Yosys not installed; set YOSYS to run elaboration integration checks")
class ElaborationTests(unittest.TestCase):
    def test_real_full_adder_matches_rtl(self):
        graph = build("full_adder", executable=TOOL)
        module = graph["modules"]["full_adder"]
        cells = {cell["id"]: cell for cell in module["cells"]}
        self.assertEqual(cells["add_operands"]["module"], "half_adder")
        self.assertEqual(cells["add_carry_in"]["module"], "half_adder")
        or_cell = next(cell for cell in module["cells"] if cell["type"] == "$or")
        bits = lambda cell, port: next(item["bits"] for item in cell["ports"] if item["name"] == port)
        self.assertEqual(bits(cells["add_operands"], "sum"), bits(cells["add_carry_in"], "a"))
        self.assertEqual(bits(cells["add_operands"], "carry"), bits(or_cell, "A"))
        self.assertEqual(bits(cells["add_carry_in"], "carry"), bits(or_cell, "B"))
        primitives = {cell["type"] for cell in graph["modules"]["half_adder"]["cells"]}
        self.assertEqual(primitives, {"$xor", "$and"})
