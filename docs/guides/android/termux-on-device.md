# Inspect an Android device from Termux on that device

REA can run inside [Termux](https://termux.dev/) and inspect the phone or
tablet it runs on. `adb` in Termux connects to the device's own Wireless
debugging service over `localhost`, so no computer, USB cable or network
exposure is involved. The device operations are the ones the
[ADB guide](adb-device-analysis.md) owns; this guide covers only the on-device
setup and a script that collects a read-only device map.

## Verification status

- REA's Termux build (`npm run build:termux`) is exercised by the
  [Termux browser smoke test](../../development/testing.md#termux-android-browser-smoke-test).
- The ADB operations are verified with a desktop adb client. They have **not**
  been run from Termux against the same device. Treat the workflow below as
  unverified until you have run it, and report what you observe.
- `scripts/termux/rea-device-map.sh` and its collections were checked on Linux
  with stand-in adb binaries: option handling, trying every listed row,
  per-step failure handling, custom collections and both REA and raw adb
  modes. They have not been run in Termux or against a real device.

## Requirements

- Android 11 or later, which provides Wireless debugging with pairing.
- Termux installed from F-Droid or the Termux GitHub releases.
- A Wi-Fi connection. Android offers Wireless debugging only while Wi-Fi is
  connected, even though the adb traffic stays on the device.

REA and its scripts never install platform tools or a runtime. Install them
yourself in Termux:

```sh
pkg install android-tools nodejs-lts npm git termux-exec
```

## Connect adb to the device

1. In Android Settings, enable **Developer options**, then **Wireless
   debugging**.
2. Open Termux and the Wireless debugging screen in split view. The pairing
   code is valid only while its dialog stays visible.
3. Tap **Pair device with pairing code**. Use the port from that dialog:

   ```sh
   adb pair localhost:<pairing port>
   ```

4. Enter the six-digit code, then connect with the port shown on the main
   Wireless debugging screen (it differs from the pairing port):

   ```sh
   adb connect localhost:<connect port>
   adb devices
   ```

The device must be listed in state `device`. After pairing, adb may list the
same device a second time under an `adb-…._adb-tls-connect._tcp` name; either
serial works. Its serial is the
`localhost:<connect port>` value exactly as `adb devices` prints it. The connect
port changes whenever Wireless debugging restarts; pairing is kept.

## Build REA in Termux

Termux uses its own Node.js distribution, so use the Termux build script
instead of `build:cached`:

```sh
git clone https://github.com/morluto/rea.git
cd rea
npm ci
npm run build:termux
node scripts/rea.mjs inspect-adb-client
```

`inspect-adb-client` reports the resolved adb binary and version without
contacting a device. If `npm ci` or the build fails, the device map script can
still run with `--adb-only`.

## Collect a device map

```sh
bash scripts/termux/rea-device-map.sh
```

The script lists every row `adb devices` reports and tries each one, whatever
its state. The state column is adb's own label; a row that cannot answer fails
its steps and the run continues. `--serial`, which can be repeated, limits the
run to named serials, including one adb does not list.

Each run executes a set of collections. Every step is a read; nothing is
installed, pushed, started or stopped.

| Collection   | What it reads                                                                  | Source                                                                                     |
| ------------ | ------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------ |
| `device`     | Build, SDK, patch level, ABIs, display, features, binder services              | REA: `inspect_adb_device`, `inspect_adb_display`, `list_adb_features`, `list_adb_services` |
| `packages`   | Installed packages, third-party and system listed separately                   | REA: `list_adb_packages`                                                                   |
| `processes`  | Running processes and the focused window                                       | REA: `list_adb_processes`, `inspect_adb_window`                                            |
| `usage`      | Per-app usage history (`dumpsys usagestats`)                                   | Raw adb                                                                                    |
| `sqlite`     | Device `sqlite3` binary, `dumpsys dbinfo`, database files in shared storage    | Raw adb and Termux                                                                         |
| `postgresql` | PostgreSQL processes and packages on the device, tools and processes in Termux | Raw adb and Termux                                                                         |
| `kotlin`     | Kotlin marker entries in each third-party base APK, compilers in Termux        | Raw adb and Termux                                                                         |

The adb client and device list (`inspect_adb_client`, `list_adb_devices`) are
always recorded once. REA steps save the full Evidence JSON. Raw adb and Termux
steps save command output as text: they carry no provenance, limitations or
parsing and are not REA Evidence. With `--adb-only`, the first three
collections also use raw adb.

Every published byte is the output of a command that ran in that invocation.
The script writes no placeholder, default or remembered result, keeps no cache,
and refuses an output directory that already holds files.

How to read the raw collections:

- A probe file ends with one line, `rea-device-map-exit=<n>`: the real exit code
  of the probed command. For `command -v <tool>`, output plus `0` means the tool
  was found; no output and a non-zero code means it was not. A probe whose
  output lacks that line did not get an answer from the device and is recorded
  as failed.
- A `postgres-*` file holds the lines of the neighbouring `all-processes.txt` or
  `all-packages.txt` that name PostgreSQL. Exit code `1` in `SUMMARY.tsv` and an
  empty file mean no line matched; the complete source file is saved beside it.
  Listening ports are not checked, because Android does not let the adb shell
  user list other apps' sockets.
- `sqlite`: the adb shell user cannot read other apps' private databases.
  `dumpsys dbinfo` reports only what the system exposes for running apps.
- `kotlin`: for each third-party APK the file holds a header line, the archive
  entries under `kotlin/` or named `*.kotlin_module` exactly as `unzip` lists
  them, and `unzip-exit=<n>`. Listed entries show Kotlin was used. No entries do
  not show Kotlin is absent, because shrinkers can remove them, and a non-zero
  `unzip-exit` means the APK could not be listed.

### Results

```text
<output>/SUMMARY.tsv            one row per step: target, adb state, collection, step, source, exit code, file
<output>/adb-client/            adb client and device list
<output>/devices/<n>-<serial>/  one file per successful step for that row
<output>/termux/                steps that ran in Termux itself, once per run
<output>/failures/              output and stderr of failed steps, same layout
```

A failed step publishes nothing under `devices/`, `termux/` or `adb-client/`.
Its output, including REA's error result, and its stderr move to `failures/`.

The script exits `0` when every step succeeded, `1` when a prerequisite is
missing (adb, any listed device or an empty output directory), `2` for an
invalid option, and `3` when the collection ran but a step failed. Before the
first step it starts REA once. If REA is missing or cannot start, it prints the
reason and continues with raw adb output for every collection; the `source`
column of `SUMMARY.tsv` shows which was used.

### Options

- `--serial <serial>` tries only that serial. Repeatable.
- `--output <dir>` names a new or empty result directory.
- `--adb-only` skips REA and uses raw adb for every collection.
- `--only <a,b>` and `--skip <a,b>` select collections.
- `--list` prints the available collections.
- `--collections <dir>` loads more collections. Repeatable.

`REA_BIN` names one executable that starts REA, and `REA_ADB_PATH` selects the
adb binary as described in the [ADB guide](adb-device-analysis.md#supply-tools).

### Add a collection

A collection is a `.sh` file in `scripts/termux/collections/` or a directory
passed with `--collections`. The file name is the collection name and its
second line is the description `--list` prints. The script sources it once per
device with these helpers and variables:

- `rea_step <step> <rea command…>` runs one REA operation and saves its JSON.
- `adb_step <step> <shell words…>` runs one device shell command; a non-zero
  exit is a failure.
- `adb_probe_step <step> <shell string>` runs a device command whose non-zero
  exit is an answer, and appends the exit trailer.
- `match_step <step> <published file> <regex>` saves the matching lines of a
  file this device already published.
- `local_step`, `local_probe_step` and `local_match_step` do the same in Termux,
  once per run.
- `$serial` is the current row's serial; `$use_rea` is `1` unless `--adb-only`.

```sh
# shellcheck shell=bash
# Battery state.
adb_step dumpsys-battery dumpsys battery
```

Keep collections read-only, and never print a verdict the command did not
produce: save the command's own output and let its exit code speak.

To look closer at one app, continue with the ADB guide's package operations,
for example `inspect-adb-package` and `pull-adb-package`.

## Limitations

- The shell adb grants is the `shell` user, not root. Other apps' private data
  under `/data/data` is not readable, and some `dumpsys` sections are reduced.
- The result directory holds personal data: installed apps, running processes
  and usage history. The script creates it with owner-only
  permissions. Keep it out of shared storage and version control.
- Wireless debugging grants shell access to any paired client. Turn it off when
  you are done; revoke pairings from the same settings screen.
- Android may stop Termux in the background. Keep it in the foreground or hold
  a wake lock while a collection runs.
