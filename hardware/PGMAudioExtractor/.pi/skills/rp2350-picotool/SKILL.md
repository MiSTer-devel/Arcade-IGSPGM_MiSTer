---
name: rp2350-picotool
description: "Use picotool to talk to the RP2350 device, check boot mode, query info, reboot between BOOTSEL and APPLICATION, and load UF2 firmware."
---

Use this skill whenever working with the RP2350-based device attached to this project.

## Device modes

The device has two important modes:

- `BOOTSEL` mode
  - firmware can be loaded
  - `picotool info` should work
  - `picotool load <file.uf2>` should work
- `APPLICATION` mode
  - normal firmware execution mode

## Mode switching

Reboot the device into `BOOTSEL` mode with:

```bash
picotool reboot -u -F
```

Reboot the device into `APPLICATION` mode with:

```bash
picotool reboot -a -F
```

Notes:
- `-F` forces the operation without interactive confirmation.
- The current firmware exposes the Pico USB reset interface, so `picotool reboot -u -F` should work from `APPLICATION` mode.
- After a mode switch, allow a short delay and retry once if `picotool info` or `picotool load` races device re-enumeration.
- If `picotool reboot -u -F` fails to put the device into `BOOTSEL` mode, the device may be in a bad state.
- In that case, stop and prompt the user with exactly:

```text
BOOTSEL PLZ?!
```

The user will then manually place the device into `BOOTSEL` mode.

## BOOTSEL-only commands

These commands require the device to already be in `BOOTSEL` mode and will error otherwise:

```bash
picotool info
picotool load <firmware.uf2>
```

`picotool load <firmware.uf2>` reboots the device into `APPLICATION` mode when the load completes successfully.

## Recommended workflows

### Check device status / inspect firmware

1. Try to enter `BOOTSEL` mode:

```bash
picotool reboot -u -F
```

2. Query device info:

```bash
picotool info
```

If `picotool info` fails immediately after rebooting into `BOOTSEL`, wait briefly and retry once.

3. If step 1 fails or step 2 indicates the device is not in `BOOTSEL`, ask the user:

```text
BOOTSEL PLZ?!
```

4. After the user intervenes, retry:

```bash
picotool info
```

### Load new firmware

1. Put device in `BOOTSEL` mode:

```bash
picotool reboot -u -F
```

2. Load firmware:

```bash
picotool load <path-to-firmware.uf2>
```

If `picotool load` fails immediately after entering `BOOTSEL`, wait briefly and retry once.

3. If entering `BOOTSEL` fails, ask the user exactly:

```text
BOOTSEL PLZ?!
```

Then retry the load.

## Operational guidance

- Prefer `picotool info` to confirm the device is reachable in `BOOTSEL` mode before loading firmware.
- Do not assume `picotool load` can succeed from `APPLICATION` mode.
- A successful `picotool load` returns the device to `APPLICATION` mode automatically, so no extra reboot command is needed afterward.
- If a BOOTSEL transition just occurred, allow a short re-enumeration delay before deciding the command failed.
- When reporting status, mention which mode the device is believed to be in.
- Include the exact `picotool` command used when summarizing actions.
