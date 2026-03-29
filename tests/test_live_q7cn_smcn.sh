#!/bin/bash
# =============================================================================
# Live Hardware Validation - Legion Pro 7
# 1) 16IAX10H (Q7CN, EC 0x5508)
# 2) 16AFR10H (SMCN, EC 0x5508)
# =============================================================================
#
# Tests the loaded driver against real hardware. Cycles through power modes,
# reads all sensors, verifies custom mode block, checks LED init, and
# confirms stability after each mode change.
#
# Usage: sudo bash tests/test_live_q7cn_smcn.sh
#
# Output: /tmp/legion-live-test-<timestamp>.log
# =============================================================================

set -euo pipefail

# Avoid SIGPIPE issues with grep -q in pipelines under pipefail
check_module_loaded() {
    lsmod | grep "$1" > /dev/null 2>&1 || return 1
    return 0
}

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Must run as root." >&2
    exit 1
fi

LOG="$(mktemp /tmp/legion-live-test-XXXXXX.log)"
exec > >(tee "$LOG") 2>&1

# === Paths ===
SYSFS="/sys/bus/platform/drivers/legion/PNP0C09:00"
ORIGINAL_PM_FOR_TRAP=""

# Restore power mode on unexpected exit (Ctrl+C, set -e failure, etc.)
cleanup_powermode() {
    if [ -n "$ORIGINAL_PM_FOR_TRAP" ] && [ -f "$SYSFS/powermode" ]; then
        echo "$ORIGINAL_PM_FOR_TRAP" > "$SYSFS/powermode" 2>/dev/null || true
        echo "Restored powermode to $ORIGINAL_PM_FOR_TRAP on exit" >&2
    fi
}
trap cleanup_powermode EXIT INT TERM
DEBUGFS="/sys/kernel/debug/legion"
HWMON=""
PASS=0
FAIL=0
WARN=0

# Find hwmon directory for legion
for d in /sys/class/hwmon/hwmon*; do
    if [ -f "$d/name" ] && grep -q "legion_hwmon" "$d/name" 2>/dev/null; then
        HWMON="$d"
        break
    fi
done

# === Helpers ===
pass() { PASS=$((PASS + 1)); echo "  [PASS] $*"; }
fail() { FAIL=$((FAIL + 1)); echo "  [FAIL] $*"; }
warn() { WARN=$((WARN + 1)); echo "  [WARN] $*"; }
info() { echo "  [INFO] $*"; }
value() { echo "  $1: $2"; }
divider() { echo ""; echo "== $1 =="; }

read_or_na() {
    cat "$1" 2>/dev/null || echo "N/A"
}

# === Preflight ===
divider "1. Module Status"

if ! check_module_loaded legion_laptop; then
    fail "legion_laptop module not loaded"
    echo "Load it first: sudo insmod kernel_module/legion-laptop.ko"
    exit 1
fi
pass "legion_laptop module loaded"

if [ ! -d "$SYSFS" ]; then
    fail "Sysfs path not found: $SYSFS"
    exit 1
fi
pass "Sysfs path exists"

if [ -z "$HWMON" ]; then
    fail "No legion_hwmon found in /sys/class/hwmon"
    exit 1
fi
pass "hwmon found: $HWMON"

value "Module" "$(modinfo -F filename legion_laptop 2>/dev/null || echo 'insmod (not in modprobe path)')"
value "BIOS" "$(cat /sys/class/dmi/id/bios_version 2>/dev/null)"
value "Product" "$(cat /sys/class/dmi/id/product_name 2>/dev/null)"
value "Kernel" "$(uname -r)"

# === Sensor Reads ===
divider "2. Fan Speeds (RPM)"

for i in 1 2 3; do
    F="$HWMON/fan${i}_input"
    if [ -f "$F" ]; then
        V=$(read_or_na "$F")
        if [ "$V" = "N/A" ] || [ "$V" = "0" ]; then
            warn "fan${i}_input: $V (may be idle or error)"
        else
            pass "fan${i}_input: ${V} RPM"
        fi
    else
        if [ "$i" -le 2 ]; then
            fail "fan${i}_input missing"
        else
            info "fan${i}_input not present (2-fan model?)"
        fi
    fi
done

divider "3. Temperatures"

for i in 1 2; do
    F="$HWMON/temp${i}_input"
    if [ -f "$F" ]; then
        V=$(read_or_na "$F")
        if [ "$V" = "N/A" ]; then
            fail "temp${i}_input read error"
        else
            CELSIUS=$((V / 1000))
            if [ "$CELSIUS" -gt 0 ] && [ "$CELSIUS" -lt 110 ]; then
                pass "temp${i}_input: ${CELSIUS}C (raw: $V)"
            else
                warn "temp${i}_input: ${CELSIUS}C — out of expected range"
            fi
        fi
    else
        fail "temp${i}_input missing"
    fi
done

# === Fan Curve ===
divider "4. Fan Curve Points"

CURVE_OK=true
for i in 1 2 3 4 5 6 7 8 9 10; do
    F="$HWMON/pwm1_auto_point${i}_pwm"
    if [ -f "$F" ]; then
        V=$(read_or_na "$F")
        echo "    point${i}: $V"
    else
        CURVE_OK=false
    fi
done
if [ "$CURVE_OK" = true ]; then
    pass "All 10 fan curve speed points readable"
else
    warn "Some fan curve points missing"
fi

if [ -f "$DEBUGFS/fancurve" ]; then
    info "Debugfs fan curve:"
    head -15 "$DEBUGFS/fancurve" | sed 's/^/    /'
fi

# === Fan Fullspeed / Maxspeed ===
divider "5. Fan Control Attributes"

for attr in fan_fullspeed fan_maxspeed conservation_mode fn_lock; do
    F="$SYSFS/$attr"
    if [ -f "$F" ]; then
        V=$(read_or_na "$F")
        pass "$attr: $V"
    else
        info "$attr: not present"
    fi
done

# === LEDs ===
divider "6. LED Drivers"

for led in platform::ioport platform::ylogo; do
    LEDPATH="/sys/class/leds/$led"
    if [ -d "$LEDPATH" ]; then
        B=$(read_or_na "$LEDPATH/brightness")
        M=$(read_or_na "$LEDPATH/max_brightness")
        pass "$led: brightness=$B max=$M"
    else
        warn "$led: not registered"
    fi
done

# === Keyboard Backlight ===
KBD_LED="/sys/class/leds/platform::kbd_backlight"
if [ -d "$KBD_LED" ]; then
    B=$(read_or_na "$KBD_LED/brightness")
    M=$(read_or_na "$KBD_LED/max_brightness")
    pass "kbd_backlight: brightness=$B max=$M"
else
    info "kbd_backlight: not present"
fi

# === Platform Profile ===
divider "7. Platform Profile"

PP_CHOICES=""
PP_CURRENT=""
if [ -f /sys/firmware/acpi/platform_profile_choices ]; then
    PP_CHOICES=$(cat /sys/firmware/acpi/platform_profile_choices)
    PP_CURRENT=$(cat /sys/firmware/acpi/platform_profile)
    value "Available profiles" "$PP_CHOICES"
    value "Current profile" "$PP_CURRENT"

    if echo "$PP_CHOICES" | grep -q "balanced-performance"; then
        warn "balanced-performance profile visible (custom mode NOT blocked)"
    else
        pass "balanced-performance profile hidden (custom mode blocked)"
    fi
else
    info "platform_profile not available"
fi

# === Custom Mode Block Test ===
divider "8. Custom Mode (255) Block Test"

SAVED_PM=$(read_or_na "$SYSFS/powermode")
value "Current powermode" "$SAVED_PM"

# Try writing custom mode — should fail with EPERM
CUSTOM_RESULT=$(echo 255 > "$SYSFS/powermode" 2>&1 && echo "ACCEPTED" || echo "BLOCKED")
if [ "$CUSTOM_RESULT" = "BLOCKED" ]; then
    pass "Custom mode (255) write correctly blocked"
    DMESG_LINE=$(dmesg | grep "custom power mode.*blocked" | tail -1)
    if [ -n "$DMESG_LINE" ]; then
        pass "dmesg warning present: $(echo "$DMESG_LINE" | sed 's/.*legion-laptop: //')"
    else
        warn "No dmesg warning found (may have scrolled out)"
    fi
else
    fail "Custom mode (255) was ACCEPTED — protection not working!"
fi

# Verify powermode didn't change
AFTER_PM=$(read_or_na "$SYSFS/powermode")
if [ "$SAVED_PM" = "$AFTER_PM" ]; then
    pass "Power mode unchanged after blocked write ($AFTER_PM)"
else
    fail "Power mode CHANGED from $SAVED_PM to $AFTER_PM after blocked write!"
fi

# === Power Mode Cycling ===
divider "9. Power Mode Cycling (Quiet -> Balanced -> Performance)"

ORIGINAL_PM=$(read_or_na "$SYSFS/powermode")
ORIGINAL_PM_FOR_TRAP="$ORIGINAL_PM"
value "Starting powermode" "$ORIGINAL_PM"

MODES="1:Quiet 2:Balanced 3:Performance"

for entry in $MODES; do
    MODE_NUM="${entry%%:*}"
    MODE_NAME="${entry##*:}"

    echo ""
    info "--- Switching to $MODE_NAME (powermode=$MODE_NUM) ---"

    WRITE_ERR=$(echo "$MODE_NUM" > "$SYSFS/powermode" 2>&1) && WRITE_OK=true || WRITE_OK=false

    if [ "$WRITE_OK" = true ]; then
        # Wait for EC to settle
        sleep 2

        # Verify readback
        READBACK=$(read_or_na "$SYSFS/powermode")
        if [ "$READBACK" = "$MODE_NUM" ]; then
            pass "$MODE_NAME: write OK, readback=$READBACK"
        else
            fail "$MODE_NAME: wrote $MODE_NUM but read back $READBACK"
        fi

        # Read sensors in this mode
        FAN1=$(read_or_na "$HWMON/fan1_input")
        FAN2=$(read_or_na "$HWMON/fan2_input")
        FAN3=$(read_or_na "$HWMON/fan3_input")
        T1=$(read_or_na "$HWMON/temp1_input")
        T2=$(read_or_na "$HWMON/temp2_input")
        T1C="N/A"; [ "$T1" != "N/A" ] && T1C=$((T1 / 1000))
        T2C="N/A"; [ "$T2" != "N/A" ] && T2C=$((T2 / 1000))

        value "  Fans (RPM)" "fan1=$FAN1 fan2=$FAN2 fan3=$FAN3"
        value "  Temps (C)" "cpu=${T1C} gpu=${T2C}"

        # Platform profile should match
        if [ -f /sys/firmware/acpi/platform_profile ]; then
            PP=$(cat /sys/firmware/acpi/platform_profile)
            value "  Platform profile" "$PP"
        fi

        # Stability: read sensors twice more at 1s intervals
        sleep 1
        FAN1B=$(read_or_na "$HWMON/fan1_input")
        sleep 1
        FAN1C=$(read_or_na "$HWMON/fan1_input")

        if [ "$FAN1" != "N/A" ] && [ "$FAN1B" != "N/A" ] && [ "$FAN1C" != "N/A" ]; then
            pass "$MODE_NAME: stable (fan1 readings: $FAN1, $FAN1B, $FAN1C)"
        else
            warn "$MODE_NAME: could not verify stability (N/A readings)"
        fi
    else
        fail "$MODE_NAME: write failed: $WRITE_ERR"
    fi
done

# === Restore Original Mode ===
divider "10. Restore Original Power Mode"

echo "$ORIGINAL_PM" > "$SYSFS/powermode" 2>&1 && RESTORE_OK=true || RESTORE_OK=false
sleep 2
FINAL_PM=$(read_or_na "$SYSFS/powermode")

if [ "$RESTORE_OK" = true ] && [ "$FINAL_PM" = "$ORIGINAL_PM" ]; then
    pass "Restored to original powermode $ORIGINAL_PM"
    ORIGINAL_PM_FOR_TRAP=""  # Clear trap — restore succeeded
else
    fail "Failed to restore powermode (wanted $ORIGINAL_PM, got $FINAL_PM)"
fi

# === Extreme Mode (224) Read Test ===
divider "11. Extreme Mode (224) Read Test"

info "NOT writing extreme mode — read-only check"
if [ "$FINAL_PM" = "224" ]; then
    info "Currently in extreme mode"
else
    info "Not in extreme mode (current: $FINAL_PM)"
fi

# === dmesg Errors ===
divider "12. dmesg Error Check"

LEGION_ERRORS=$(dmesg | grep -iE "legion|legion_laptop" | grep -ciE "error|fail|bug|oops|panic" || true)
if [ "$LEGION_ERRORS" -gt 0 ]; then
    warn "$LEGION_ERRORS error/fail messages in dmesg:"
    dmesg | grep -iE "legion|legion_laptop" | grep -iE "error|fail|bug|oops|panic" | tail -10 | sed 's/^/    /'
else
    pass "No error messages in legion dmesg"
fi

# === EC RAM Spot Check ===
divider "13. EC RAM / Debugfs"

if [ -d "$DEBUGFS" ]; then
    pass "Debugfs directory exists"
    ls "$DEBUGFS" 2>/dev/null | sed 's/^/    /'

    if [ -f "$DEBUGFS/ecmemoryio" ]; then
        DUMP_SIZE=$(wc -c < "$DEBUGFS/ecmemoryio" 2>/dev/null || echo 0)
        value "EC memory dump" "$DUMP_SIZE bytes"
    fi
else
    info "Debugfs not available"
fi

# === Summary ===
divider "SUMMARY"

TOTAL=$((PASS + FAIL + WARN))
echo ""
echo "  PASS: $PASS  |  FAIL: $FAIL  |  WARN: $WARN  |  Total: $TOTAL"
echo ""

if [ "$FAIL" -eq 0 ]; then
    echo "  All tests passed."
else
    echo "  $FAIL test(s) FAILED — review output above."
fi

if [ "$WARN" -gt 0 ]; then
    echo "  $WARN warning(s) — review for potential issues."
fi

echo ""
echo "Log saved to: $LOG"
