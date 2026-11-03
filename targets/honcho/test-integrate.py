#!/usr/bin/env python3
"""The MCP registration preserves existing Open WebUI connections and grants."""
import importlib.util
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "honcho_webui", Path(__file__).with_name("integrate-webui.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class Response(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


class IntegrationTest(unittest.TestCase):
    def test_add_then_update_without_losing_other_connections_or_grants(self):
        with tempfile.TemporaryDirectory() as directory:
            admin = Path(directory, "admin")
            key = Path(directory, "honcho")
            admin.write_text("webui-secret")
            key.write_text("honcho-secret")
            original = {"url": "http://other/mcp", "type": "mcp",
                        "info": {"id": "other"}, "path": "/mcp"}
            state = [original]
            calls = []

            def fake_urlopen(request, timeout):
                self.assertEqual(request.get_header("Authorization"),
                                 "Bearer webui-secret")
                self.assertEqual(timeout, 20)
                calls.append(request.get_method())
                if request.data is not None:
                    state[:] = json.loads(request.data)["TOOL_SERVER_CONNECTIONS"]
                return Response(json.dumps(
                    {"TOOL_SERVER_CONNECTIONS": state}).encode())

            argv = ["integrate-webui.py", "http://127.0.0.1:8080",
                    str(admin), str(key), "http://192.0.2.85:3000"]
            with patch.object(module, "urlopen", fake_urlopen), \
                 patch.object(sys, "argv", argv):
                module.main()
                self.assertEqual(["GET", "POST"], calls)
                self.assertEqual(original, state[0])
                self.assertEqual("http://192.0.2.85:3000/mcp", state[1]["url"])
                self.assertEqual("honcho-secret", state[1]["key"])
                self.assertEqual("/mcp", state[1]["path"])
                self.assertEqual("osr", state[1]["headers"]["X-Honcho-Workspace-ID"])
                state[1]["config"]["access_grants"] = [{"principal_id": "group-1"}]
                state[1]["info"]["name"] = "My Memory"
                key.write_text("rotated-secret")
                calls.clear()
                module.main()
                self.assertEqual(["GET", "POST"], calls)
                self.assertEqual("rotated-secret", state[1]["key"])
                self.assertEqual("My Memory", state[1]["info"]["name"])
                self.assertEqual([{"principal_id": "group-1"}],
                                 state[1]["config"]["access_grants"])
                calls.clear()
                module.main()
                self.assertEqual(["GET"], calls)


if __name__ == "__main__":
    unittest.main()
