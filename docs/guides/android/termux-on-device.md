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
- `scripts/termux/rea-device-map.sh` was checked on Linux with a stand-in adb
  binary: argument handling, device selection, per-step failure recording and
  both collection modes. It has not been run in Termux.

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

The script selects the single connected device, or the one named with
`--serial`, and writes one file per step into a new directory:

| Step                                                         | REA operation                            |
| ------------------------------------------------------------ | ---------------------------------------- |
| adb client and attached devices                              | `inspect_adb_client`, `list_adb_devices` |
| Build, SDK, patch level, product, ABIs                       | `inspect_adb_device`                     |
| Display size and density                                     | `inspect_adb_display`                    |
| Hardware and software features                               | `list_adb_features`                      |
| Binder services                                              | `list_adb_services`                      |
| Installed packages, third-party and system listed separately | `list_adb_packages`                      |
| Running processes                                            | `list_adb_processes`                     |
| Focused window and app                                       | `inspect_adb_window`                     |

Every step is a read-kind operation; nothing is installed, pushed, started or
stopped. Each REA step saves the full Evidence JSON. `SUMMARY.tsv` records each
step's source, exit code and file, and a failed step keeps its reason in its own file or a `.stderr` file beside it,
while the remaining steps still run.

Options:

- `--serial <serial>` selects a device when several are connected.
- `--output <dir>` names a new or empty result directory.
- `--adb-only` skips REA and saves the raw output of the underlying device
  commands. Those files are not REA Evidence: they carry no provenance,
  limitations or parsing.
- `--usage-stats` also saves raw `dumpsys usagestats`, the per-app usage
  history. REA has no operation for it, so this file is raw adb output in
  either mode.

The script exits `0` when every step succeeded, `1` when a prerequisite is
missing (adb, REA, a ready device or an empty output directory), `2` for an
invalid option, and `3` when the collection ran but a step failed. Before the
first step it starts REA once and stops with REA's own message if that fails.

`REA_BIN` names one executable that starts REA, and `REA_ADB_PATH` selects the adb binary
as described in the [ADB guide](adb-device-analysis.md#supply-tools).

To look closer at one app, continue with the ADB guide's package operations,
for example `inspect-adb-package` and `pull-adb-package`.

## Limitations

- The shell adb grants is the `shell` user, not root. Other apps' private data
  under `/data/data` is not readable, and some `dumpsys` sections are reduced.
- The result directory holds personal data: installed apps, running processes
  and, with `--usage-stats`, usage history. The script creates it with owner-only
  permissions. Keep it out of shared storage and version control.
- Wireless debugging grants shell access to any paired client. Turn it off when
  you are done; revoke pairings from the same settings screen.
- Android may stop Termux in the background. Keep it in the foreground or hold
  a wake lock while a collection runs.
