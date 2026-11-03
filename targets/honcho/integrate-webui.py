#!/usr/bin/env python3
"""Register Honcho's MCP endpoint in the router's Open WebUI, idempotently."""
import json
import sys
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


def request(url, token, payload=None):
    headers = {"Authorization": "Bearer " + token}
    if payload is not None:
        headers["Content-Type"] = "application/json"
    req = Request(url, data=payload, headers=headers,
                  method="POST" if payload is not None else "GET")
    with urlopen(req, timeout=20) as response:
        return json.load(response)


def main():
    base, admin_file, honcho_file, mcp_url = sys.argv[1:]
    admin = Path(admin_file).read_text(encoding="utf-8").strip()
    honcho = Path(honcho_file).read_text(encoding="utf-8").strip()
    if not admin or not honcho:
        raise ValueError("missing Open WebUI admin token or Honcho API token")
    endpoint = base.rstrip("/") + "/api/v1/configs/tool_servers"
    response = request(endpoint, admin)
    connections = response.get("TOOL_SERVER_CONNECTIONS", [])
    if not isinstance(connections, list):
        raise ValueError("Open WebUI returned an invalid tool server list")
    connection = {
        "type": "mcp", "url": mcp_url.rstrip("/") + "/mcp", "path": "/mcp",
        "auth_type": "bearer", "key": honcho,
        "headers": {"X-Honcho-Workspace-ID": "osr"},
        "config": {"enable": True},
        "info": {"id": "honcho", "name": "Honcho Memory",
                 "description": "Shared memory tools for agents"},
    }
    existing = [item for item in connections if isinstance(item, dict) and
                (item.get("info") or {}).get("id") == "honcho"]
    if existing:
        previous = existing[0]
        updated = dict(previous)
        updated.update({key: connection[key] for key in
                        ("type", "url", "path", "auth_type", "key")})
        updated["config"] = dict(previous.get("config") or connection["config"])
        updated["info"] = dict(previous.get("info") or connection["info"])
        updated["headers"] = dict(connection["headers"])
        if isinstance(previous.get("headers"), dict):
            updated["headers"].update(previous["headers"])
        connection = updated
    if len(existing) == 1 and existing[0] == connection:
        print("Honcho MCP is already registered in Open WebUI")
        return
    next_connections = [item for item in connections
                        if isinstance(item, dict) and
                        (item.get("info") or {}).get("id") != "honcho"]
    next_connections.append(connection)
    if next_connections != connections:
        request(endpoint, admin, json.dumps(
            {"TOOL_SERVER_CONNECTIONS": next_connections}).encode())
    print("Honcho MCP registered in Open WebUI")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, HTTPError, URLError, OSError, KeyError) as exc:
        print(f"Honcho Open WebUI integration failed: {exc}", file=sys.stderr)
        sys.exit(1)
