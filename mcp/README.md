# PocketCtrl Host MCP

`pocketctrl-host-server.mjs` exposes hosting controls for the running Mac app over MCP.
It talks to the app's authenticated, loopback-only control API at `http://127.0.0.1:47777`.

Start the Mac app and provide its private host-control token through the environment:

```sh
POCKETCTRL_CONTROL_TOKEN='your-control-token' node mcp/pocketctrl-host-server.mjs
```

Codex or another MCP client can register that command as a stdio MCP server.

Available tools:

- `pocketctrl_host_status`
- `pocketctrl_host_pairing_info`
- `pocketctrl_host_start`
- `pocketctrl_host_stop`
- `pocketctrl_host_restart`
- `pocketctrl_host_regenerate_pairing`
- `pocketctrl_host_set_settings`

The same authenticated local API is available from the Swift CLI:

```sh
POCKETCTRL_CONTROL_TOKEN='your-control-token' swift run pocketctrl status
POCKETCTRL_CONTROL_TOKEN='your-control-token' swift run pocketctrl start
POCKETCTRL_CONTROL_TOKEN='your-control-token' swift run pocketctrl stop
POCKETCTRL_CONTROL_TOKEN='your-control-token' swift run pocketctrl set fps 60 bitrate 12 remote-input on
```

For safety, both clients reject non-loopback `POCKETCTRL_HOST_URL` values.
