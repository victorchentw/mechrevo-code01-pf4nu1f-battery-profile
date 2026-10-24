# MECHREVO S2 Air PF4NU1F Battery Profile

A manual, experimental switch between the OEM **Healthy** and **High Capacity** battery profiles on one specific laptop:

- MECHREVO S2 Air, board PF4NU1F
- BIOS N.1.07MRO05, EC 1.4
- Ubuntu kernel 7.0.0-38-generic with the existing ACPI debugger

This is not a general MECHREVO tool. The script checks the laptop, firmware, kernel, and ACPI table before it can write anything. If they do not match, it refuses to run.

## What the profiles mean

- **High Capacity** favors maximum available battery capacity.
- **Healthy** is the OEM battery-care profile intended for long-term use.

In the observed test, selecting Healthy made Ubuntu report the battery current as 0 µA.

## How it works

The script uses the laptop's existing ACPI debugger to communicate with the embedded controller (EC). It does not install a kernel module or start a background service.

To enable Healthy, it sets the OEM application-present (AP) flag, selects High Capacity, then selects Healthy. The AP flag remains set while Healthy is active. To return to High Capacity, run the `high` command; it selects High Capacity and clears the AP flag.

The AP flag is not a battery-only switch and may affect other firmware features. Keep the original DC-in adapter connected while using Healthy. The evidence covers the original DC-in adapter only; AC0 cannot distinguish DC-in from USB-C PD. Do not use this script with USB-C PD.

## Usage

Run these commands from the laptop's local terminal:

```bash
sudo ./pf4nu1f_battery_profile.sh healthy
```

When you finish, restore the original mode:

```bash
sudo ./pf4nu1f_battery_profile.sh high
```

The `healthy` command requires an active charging baseline. The `high` command restores High Capacity and clears AP-present. Keep DC-in connected until `high` finishes.

This script is a one-time manual Healthy-to-High cycle. It is not a daily-use controller, does not run at startup, and must not be used as a persistent service. It stores a root-only state marker under `/var/lib/pf4nu1f-battery-profile-test`; do not delete or reset that marker. If an ACPI call or readback is uncertain, the script stops and does not retry.

Use at your own risk.
