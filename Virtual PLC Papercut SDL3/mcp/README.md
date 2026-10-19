# Virtual PLC MCP server (Claude Code)

`vplc_mcp.py` is an MCP server (stdio, Python standard library only) that lets Claude Code check and write the
program of the running Virtual PLC. It talks to the app through its IPC server, the named pipe
`\\.\pipe\VirtualPLC`, on this PC only (no network port).

## Setup

1. Start `VirtualPLC.exe`, open the **Ports** screen and switch **IPC server** on.
2. To let Claude Code change the program, switch **Claude Code may change the program** on (card
   *Claude Code (MCP)*). Off: it only reads.
3. Add the server to Claude Code once (the **Copy setup command** button copies this line):

   ```
   claude mcp add virtual-plc -- python "F:\Claude\Lazarus\UI04\Virtual PLC Papercut SDL3\mcp\vplc_mcp.py"
   ```

   Or start Claude Code in the Virtual PLC folder: its `.mcp.json` has the server (Claude Code asks once
   whether to use it).
4. In Claude Code: `/mcp` shows `virtual-plc` and its tools.

## Tools

| Tool | What it does | Needs the permission |
|---|---|---|
| `get_guide` | how to program the Virtual PLC with these tools (LAD cell format, SCL / STL) | no |
| `plc_state` | reachable?, the CPU, RUN / STOP | no |
| `get_project` | the CPU, the blocks, the DBs, the types, the tags | no |
| `get_block` | one block: its interface and every network | no |
| `compile` | every error and warning | no |
| `read_values` | live values (`wait_ms` waits first) | no |
| `get_diagnostics` | the mode, the stop cause, the diagnostic buffer | no |
| `write_network`, `delete_network` | a network of SCL, STL or LAD | yes |
| `create_block`, `set_interface` | an FC / FB, the interface of a block | yes |
| `add_db_variables`, `add_tags` | DB variables, PLC tags | yes |
| `set_inputs` | operate the simulated inputs | yes |
| `download_and_run` | compile, download, RUN | yes |

Every change can be undone in the app (**AI ▼**, undo of the assistant). The Ports screen counts the tool
calls and shows the last one.

## Test

`test\mcptest.py` starts the server and calls the tools while the app runs the script test
`VPLC_MCP_TEST` (no other Virtual PLC may own the pipe meanwhile):

```
python test\mcptest.py shots\mcp_client.txt   (in the background)
VPLC_NO_SHELL=1 VPLC_MCP_TEST=1 VirtualPLC.exe --shots shots
```
