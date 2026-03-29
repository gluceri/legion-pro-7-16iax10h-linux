<h1 align="left">
  <a href="https://github.com/ChaoticSi1ence/legion-pro-7-16iax10h-linux" target="_blank">
    <picture>
      <source media="(prefers-color-scheme: light)" srcset="https://raw.githubusercontent.com/johnfanv2/LenovoLegionLinux/HEAD/doc/assets/legion_logo_dark.svg">
      <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/johnfanv2/LenovoLegionLinux/HEAD/doc/assets/legion_logo_light.svg">
      <img alt="LenovoLegionLinux" src="https://raw.githubusercontent.com/johnfanv2/LenovoLegionLinux/HEAD/doc/assets/legion_logo_dark.svg" height="50" style="max-width: 100%;">
    </picture>
  </a>
  <strong>Legion Pro 7 16IAX10H Linux Driver</strong>
</h1>

[![Build](https://github.com/ChaoticSi1ence/legion-pro-7-16iax10h-linux/actions/workflows/build.yml/badge.svg?branch=main)](https://github.com/ChaoticSi1ence/legion-pro-7-16iax10h-linux/actions/workflows/build.yml)

> Fork of [johnfanv2/LenovoLegionLinux](https://github.com/johnfanv2/LenovoLegionLinux),
> built for the **Legion Pro 7 16IAX10H** (Q7CN, EC 0x5508) and **Legion Pro 7 16AFR10H** (SMCN, EC 0x5508). Clone-and-build only.

**Not affiliated with Lenovo. Use at your own risk.**

---

## What's Changed

- **WMI3 access methods** for all hardware interfaces
- **3-fan support**: CPU, GPU, Auxiliary — non-sequential fan IDs correctly mapped
- **3 power modes**: Quiet / Balanced / Performance via PPD, Fn+Q, or sysfs.
  Extreme (0xE0) via direct sysfs only. Custom (255) blocked (causes hard shutdown).
- **22 broken sysfs attributes hidden** — non-functional IT5508 EC methods removed via `is_visible`
- **`wmi_dryrun` module parameter** — log WMI writes without executing them
- **Bug fixes**: NULL dereferences in WMI handlers, GUID copy-paste bugs, LED type mismatches, WMI notify race conditions

---

## Tested Hardware

### 16IAX10H

| Property | Value |
|----------|-------|
| Model | 83F5 |
| BIOS | Q7CN45WW |
| EC | ITE IT5508 (0x5508) |
| CPU | Intel Core Ultra 9 275HX |
| GPU | NVIDIA RTX 5090 Laptop |
| Test Results | **PASS 46/46** (live), **PASS 56/56** (dry-run) |

### 16AFR10H

| Property | Value |
|----------|-------|
| Model | 83RU |
| BIOS | SMCN19WW |
| EC | ITE IT5508 (0x5508) |
| CPU | Ryzen 9 9955HX |
| GPU | NVIDIA RTX 5070 Ti Laptop |
| Test Results | hardware dry-run: **46/0/3/2/51** (PASS/FAIL/WARN/SKIP/TOTAL)<br> hardware with extreme mode: **41/0/1/1/43** (PASS/FAIL/WARN/SKIP/TOTAL)<br> live **21/0/3/24** (PASS/FAIL/WARN/TOTAL) |


---

## Quick Start

```bash
# Install dependencies (Arch/CachyOS)
sudo pacman -S linux-headers base-devel lm_sensors

# Build and install
git clone https://github.com/ChaoticSi1ence/legion-pro-7-16iax10h-linux.git
cd legion-pro-7-16iax10h-linux
sudo bash kernel_module/build-legion-module.sh

# Verify
sudo dmesg | grep legion
sensors
```

The build script handles module installation, conflicting module blacklisting, PPD udev rule, and auto-load on boot. Rebuild after each kernel update.

<details>
<summary>Manual build</summary>

```bash
cd kernel_module
make && sudo make install && sudo depmod -a && sudo modprobe legion-laptop
```

On kernels 6.12+, blacklist the conflicting upstream module:

```bash
echo "blacklist lenovo_wmi_gamezone" | sudo tee /etc/modprobe.d/blacklist-lenovo-wmi.conf
```

</details>

---

## Usage

```bash
LEGION=/sys/bus/platform/drivers/legion/PNP0C09:00
```

### Power Mode

Use the **KDE/GNOME power slider** (recommended), **Fn+Q**, or the command line:

```bash
powerprofilesctl set performance    # Performance
powerprofilesctl set balanced       # Balanced
powerprofilesctl set power-saver    # Quiet

# Extreme mode (sysfs only)
echo 224 | sudo tee $LEGION/powermode
```

The driver integrates with [power-profiles-daemon](https://gitlab.freedesktop.org/upower/power-profiles-daemon) — the desktop power slider maps directly to firmware thermal modes. Fn+Q changes are reflected back to the slider.

### Battery

```bash
# Conservation mode (~55-60% cap) — provided by ideapad-laptop, not this module
IDEAPAD=/sys/bus/platform/drivers/ideapad_acpi/VPC2004:00
echo 1 | sudo tee $IDEAPAD/conservation_mode

# Rapid charge — provided by legion-laptop (disable conservation first)
echo 1 | sudo tee $LEGION/rapidcharge
```

### Other Controls

```bash
echo 0 | sudo tee $LEGION/winkey              # Disable Windows/Super key
echo 0 | sudo tee $LEGION/touchpad            # Disable touchpad (also Fn+F10)
echo 1 | sudo tee $LEGION/lockfancontroller   # Lock fans at current speed
```

---

## Testing

```bash
# Dry-run (safe — no hardware writes)
sudo bash tests/test_hardware_q7cn_smcn.sh --wmi-dryrun

# Full test with extreme mode
sudo bash tests/test_hardware_q7cn_smcn.sh --test-extreme
```

---

## Known Limitations

- **Custom power mode (255) causes hard shutdown** — blocked by default. Override with `allow_custom_mode=1` at your own risk.
- **22 sysfs attributes non-functional** on IT5508 EC (fan_fullspeed, gsync, overdrive, igpumode, power limits, OC controls) — automatically hidden.
- Keyboard backlight is firmware-loaded via USB — no WMI control available.
- Module must be rebuilt after each kernel update.

---

## FAQ

**Module doesn't load — "not in allowlist"**
Force-load with `sudo modprobe legion-laptop force=1` and open an issue.

**Sensors show 0 RPM or 0 temperature**
Check `sudo dmesg | grep legion`. GPU temp may read 0 when dGPU is in deep sleep.

**USB-C PD drops to trickle charge**
Blacklist `ucsi_acpi` — the Lenovo UCSI firmware is broken on Gen 10:
```bash
echo "blacklist ucsi_acpi" | sudo tee /etc/modprobe.d/blacklist-ucsi.conf && sudo reboot
```

---

## Credits

Fork of [LenovoLegionLinux](https://github.com/johnfanv2/LenovoLegionLinux) by [johnfanv2](https://github.com/johnfanv2).

Original contributors: [SmokelessCPU](https://github.com/SmokelessCPUv2), [Bartosz Cichecki](https://github.com/BartoszCichecki) ([LenovoLegionToolkit](https://github.com/BartoszCichecki/LenovoLegionToolkit)), [0x1F9F1](https://github.com/0x1F9F1) ([LegionFanControl](https://github.com/0x1F9F1/LegionFanControl)), [ViRb3](https://github.com/ViRb3), David Woodhouse ([ideapad-laptop](https://github.com/torvalds/linux/blob/master/drivers/platform/x86/ideapad-laptop.c)).

---

## Legal

Reference to any Lenovo products, services, processes, or other information and/or use of Lenovo Trademarks does not constitute or imply endorsement, sponsorship, or recommendation thereof by Lenovo.

License: [GPL-2.0](https://www.gnu.org/licenses/old-licenses/gpl-2.0.html)
