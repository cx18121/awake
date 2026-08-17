# Awake

Awake controls whether your Mac and its display can sleep. It can also keep agents running while the lid is closed.

The menu has four modes:

- `Sleep Normally` lets the display and Mac sleep normally.
- `Keep Screen On` keeps the display on while the lid is open. The Mac sleeps when you close the lid.
- `Keep Agents Running` lets the display turn off, but keeps the Mac running when you close the lid.
- `Keep Everything On` keeps the display on while the lid is open and keeps the Mac running when you close the lid.

The three awake modes can run indefinitely or for a set time from 10 minutes to 12 hours. The selected mode continues after a restart. Awake returns to normal sleep when the time ends, when you choose `Sleep Normally`, or when the battery reaches 20% while the Mac is unplugged.

## Install

Build and install the helper:

```bash
git clone https://github.com/cx18121/awake.git
cd awake
swift build -c release
scripts/install-helper.sh
```

The helper install asks for your Mac password once. It installs a small background service and a narrow permission rule that lets the Raycast extension control sleep.

Then load the Raycast extension:

```bash
cd raycast
npm install
npm run dev
```

Raycast adds three commands. Run `Awake Menu Bar` to show the menu bar control. `Keep Agents Running` starts that mode indefinitely. `Sleep Normally` ends the active mode.

## Remove

Run:

```bash
scripts/uninstall.sh
```

The script restores normal sleep before it removes the helper.
