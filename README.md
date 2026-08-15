# Awake

A raycast extension that keeps your Mac running when its lid is closed, since existing menu bar apps and extensions like coffee in raycast don't actually do this properly and will let your computer go to system sleep. 

You can keep the Mac awake indefinitely or choose a time from 10 minutes to 12 hours. normal sleep is restored when the time ends, when you choose ```bed```, or when the battery reaches 20% while the Mac is unplugged.

`Keep Display On` optionally prevents the display from sleeping while Awake is active, and closing the lid still turns off the internal display.

## Install

Build and install the helper:

```bash
git clone https://github.com/cx18121/awake.git
cd awake
swift build -c release
scripts/install-helper.sh
```

The helper install asks for your Mac password once. It installs a small background service and a narrow permission rule that lets the Raycast extension start and stop Awake.

Then load the Raycast extension:

```bash
cd raycast
npm install
npm run dev
```

Raycast adds three commands. Run `Awake Menu Bar` to show the menu bar control. `Awake` starts an indefinite session. `Bed` restores normal sleep.

## Remove

Run:

```bash
scripts/uninstall.sh
```

The script restores normal sleep before it removes the helper.
