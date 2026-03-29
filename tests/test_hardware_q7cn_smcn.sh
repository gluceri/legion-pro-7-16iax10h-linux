#!/bin/bash
# =============================================================================
# Comprehensive Hardware Test Script for Legion Pro 7
# 1) 16IAX10H (Q7CN, EC 0x5508)
# 2) 16AFR10H (SMCN, EC 0x5508)
# =============================================================================
#
# Tests: module build, upstream module handling, module load, hwmon sensors,
#        3-fan support, Extreme power mode, EC register verification, and more.
#
# Usage: sudo bash tests/test_hardware_q7cn_smcn.sh [OPTIONS]
#
# Options:
#   --skip-build       Skip kernel module build step
#   --skip-blacklist   Skip upstream module blacklist creation
#   --install-blacklist Actually write the blacklist file (otherwise dry-run)
#   --test-extreme     Test writing Extreme power mode (0xE0) to hardware
#   --wmi-dryrun       Load module with wmi_dryrun=1 and test write paths safely
#   --help             Show this help
#
# WARNING: This script requires root. Some tests modify hardware state.
#          --test-extreme will change your power mode.
#          --wmi-dryrun is safe: WMI writes are logged but not executed.
# =============================================================================

set -euo pipefail

# Clean up temp build dir on exit
KM_BUILD=""
cleanup() { [ -n "$KM_BUILD" ] && rm -rf "$KM_BUILD"; }
trap cleanup EXIT

# === Auto-tee to log file ===
LOG_FILE="$(mktemp /tmp/legion-test-XXXXXX.log)"
if [ -z "${LEGION_TEST_LOGGING:-}" ]; then
    export LEGION_TEST_LOGGING=1
    exec > >(tee "$LOG_FILE") 2>&1
fi

# === Configuration ===
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KM_SRC="${REPO_ROOT}/kernel_module"
KM_BUILD="$(mktemp -d /tmp/km_build.XXXXXX)"
MODULE_NAME="legion-laptop"
MODULE_KO="${KM_BUILD}/${MODULE_NAME}.ko"
BLACKLIST_FILE="/etc/modprobe.d/blacklist-lenovo-wmi.conf"
LEGION_CONF="/etc/modprobe.d/legion-laptop.conf"
SYSFS_BASE="/sys/bus/platform/drivers/legion/PNP0C09:00"

# Colors for output (disable when not on a terminal, e.g. piped or logged)
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' NC=''
fi

# Counters
PASS=0
FAIL=0
WARN=0
SKIP=0

# Options
SKIP_BUILD=false
SKIP_BLACKLIST=false
INSTALL_BLACKLIST=false
TEST_EXTREME=false
WMI_DRYRUN=false

# === Argument Parsing ===
for arg in "$@"; do
    case "$arg" in
        --skip-build)       SKIP_BUILD=true ;;
        --skip-blacklist)   SKIP_BLACKLIST=true ;;
        --install-blacklist) INSTALL_BLACKLIST=true ;;
        --test-extreme)     TEST_EXTREME=true ;;
        --wmi-dryrun)       WMI_DRYRUN=true ;;
        --help)
            head -20 "$0" | grep '^#' | sed 's/^# \?//'
            exit 0
            ;;
        *)
            echo "Unknown option: $arg"
            exit 1
            ;;
    esac
done

# === Helper Functions ===
section() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${BLUE}  $1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

pass() {
    echo -e "  ${GREEN}[PASS]${NC} $1"
    PASS=$((PASS + 1))
}

fail() {
    echo -e "  ${RED}[FAIL]${NC} $1"
    FAIL=$((FAIL + 1))
}

warn() {
    echo -e "  ${YELLOW}[WARN]${NC} $1"
    WARN=$((WARN + 1))
}

skip() {
    echo -e "  ${CYAN}[SKIP]${NC} $1"
    SKIP=$((SKIP + 1))
}

info() {
    echo -e "  ${CYAN}[INFO]${NC} $1"
}

value() {
    echo -e "  ${CYAN}       ${NC} $1 = ${BOLD}$2${NC}"
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}ERROR: This script must be run as root (sudo).${NC}"
        exit 1
    fi
}

# === Pre-flight ===
check_root
echo -e "${BOLD}Legion Pro 7 16IAX10H (Q7CN) and 16AFR10H (SMCN) — Comprehensive Hardware Test${NC}"
echo -e "Date: $(date)"
echo -e "Kernel: $(uname -r)"
echo -e "User: $(whoami)"

# =============================================================================
# SECTION 1: System Information
# =============================================================================
section "1. System Information"

DMI_PRODUCT=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo "unknown")
DMI_FAMILY=$(cat /sys/class/dmi/id/product_family 2>/dev/null || echo "unknown")
BIOS_VER=$(cat /sys/class/dmi/id/bios_version 2>/dev/null || echo "unknown")
KERNEL_VER=$(uname -r)

value "Product" "$DMI_PRODUCT"
value "Family" "$DMI_FAMILY"
value "BIOS" "$BIOS_VER"
value "Kernel" "$KERNEL_VER"

if echo "$BIOS_VER" | grep -qi "Q7CN" || echo "$BIOS_VER" | grep -qi "SMCN"; then
    pass "BIOS version matches Q7CN/SMCN"
else
    warn "BIOS version '$BIOS_VER' does not contain Q7CN/SMCN — this script is designed for Q7CN/SMCN"
fi

# =============================================================================
# SECTION 2: Upstream Module Status
# =============================================================================
section "2. Upstream Lenovo WMI Module Status"

UPSTREAM_MODULES=(
    lenovo_wmi_gamezone
    lenovo_wmi_other
    lenovo_wmi_events
    lenovo_wmi_capdata01
    lenovo_wmi_helpers
    lenovo_wmi_hotkey_utilities
    lenovo_wmi_camera
)

CONFLICTING_MODULES=(
    lenovo_wmi_gamezone
    lenovo_wmi_other
    lenovo_wmi_events
)

info "Checking loaded upstream modules..."
LOADED_UPSTREAM=()
for mod in "${UPSTREAM_MODULES[@]}"; do
    if lsmod | grep -q "^${mod}"; then
        LOADED_UPSTREAM+=("$mod")
        if printf '%s\n' "${CONFLICTING_MODULES[@]}" | grep -qx "$mod"; then
            warn "CONFLICTING module loaded: $mod"
        else
            info "Non-conflicting module loaded: $mod"
        fi
    fi
done

if [ ${#LOADED_UPSTREAM[@]} -eq 0 ]; then
    pass "No upstream lenovo-wmi modules loaded"
else
    info "Loaded upstream modules: ${LOADED_UPSTREAM[*]}"
fi

# Check for existing blacklist
if [ -f "$BLACKLIST_FILE" ]; then
    pass "Blacklist file exists: $BLACKLIST_FILE"
    info "Contents:"
    sed 's/^/         /' "$BLACKLIST_FILE"
else
    warn "No blacklist file at $BLACKLIST_FILE"
fi

# =============================================================================
# SECTION 3: Blacklist Setup (optional)
# =============================================================================
section "3. Upstream Module Blacklist"

BLACKLIST_CONTENT="# Blacklist upstream lenovo-wmi modules that conflict with legion-laptop
# Generated by test_hardware_q7cn_smcn.sh on $(date)
#
# These modules bind to the same WMI GUIDs that legion-laptop uses:
#   lenovo_wmi_gamezone  - GameZone GUID, platform_profile
#   lenovo_wmi_other     - OtherMethod GUID, fan RPM/temps
#   lenovo_wmi_events    - Event GUID for power mode changes
#
# Non-conflicting modules are left alone:
#   lenovo_wmi_capdata01, lenovo_wmi_helpers,
#   lenovo_wmi_hotkey_utilities, lenovo_wmi_camera
blacklist lenovo_wmi_gamezone
blacklist lenovo_wmi_other
blacklist lenovo_wmi_events
"

if [ "$SKIP_BLACKLIST" = true ]; then
    skip "Blacklist setup (--skip-blacklist)"
elif [ "$INSTALL_BLACKLIST" = true ]; then
    echo "$BLACKLIST_CONTENT" > "$BLACKLIST_FILE"
    pass "Wrote blacklist to $BLACKLIST_FILE"
    info "Run 'sudo depmod -a' and reboot for full effect"
else
    info "Dry-run: would write to $BLACKLIST_FILE:"
    echo "$BLACKLIST_CONTENT" | sed 's/^/         /'
    info "Use --install-blacklist to actually write this file"
    skip "Blacklist install (dry-run mode)"
fi

# =============================================================================
# SECTION 4: Unload Conflicting Modules
# =============================================================================
section "4. Unloading Conflicting Modules"

# Unload upstream conflicting modules first (legion-laptop may depend on WMI bus)
for mod in "${CONFLICTING_MODULES[@]}"; do
    if lsmod | grep -q "^${mod}"; then
        info "Unloading $mod..."
        rmmod "$mod" 2>/dev/null && pass "Unloaded $mod" || warn "Failed to unload $mod (may have dependents)"
    fi
done

# Non-conflicting modules (capdata01, helpers, hotkey_utilities, camera)
# are left alone — they can coexist with legion-laptop.

# Unload legion-laptop (try both rmmod and modprobe -r)
if lsmod | grep -qE "^legion[_-]laptop" || [ -d "/sys/bus/platform/drivers/legion" ]; then
    info "Unloading existing legion-laptop..."
    rmmod legion_laptop 2>/dev/null \
        || rmmod legion-laptop 2>/dev/null \
        || modprobe -r legion_laptop 2>/dev/null \
        || modprobe -r legion-laptop 2>/dev/null \
        || true
    sleep 1
    if lsmod | grep -qE "^legion[_-]laptop"; then
        warn "legion-laptop still loaded after unload attempts"
    else
        pass "Unloaded legion-laptop"
    fi
else
    info "legion-laptop not currently loaded"
fi

# Verify conflicting modules
STILL_LOADED=false
for mod in "${CONFLICTING_MODULES[@]}"; do
    if lsmod | grep -q "^${mod}"; then
        fail "Module $mod still loaded after rmmod"
        STILL_LOADED=true
    fi
done
if [ "$STILL_LOADED" = false ]; then
    pass "All conflicting modules unloaded"
fi

# =============================================================================
# SECTION 5: Build Kernel Module
# =============================================================================
section "5. Building Kernel Module"

if [ "$SKIP_BUILD" = true ]; then
    skip "Build step (--skip-build)"
    if [ ! -f "$MODULE_KO" ]; then
        fail "Module not found at $MODULE_KO and build was skipped"
        echo -e "${RED}Cannot continue without a built module. Run without --skip-build.${NC}"
        exit 1
    fi
else
    info "Building kernel module..."
    rm -rf "${KM_BUILD:?}"
    cp -r "$KM_SRC" "$KM_BUILD"

    BUILD_OUTPUT=$(make -C "$KM_BUILD" 2>&1)
    BUILD_EXIT=$?

    if [ $BUILD_EXIT -eq 0 ]; then
        # Check for warnings from our code
        OUR_WARNINGS=$(echo "$BUILD_OUTPUT" | grep "legion-laptop.c" | grep -ci "warning" || true)
        OUR_ERRORS=$(echo "$BUILD_OUTPUT" | grep "legion-laptop.c" | grep -ci "error" || true)

        if [ "$OUR_ERRORS" -gt 0 ]; then
            fail "Build succeeded but had $OUR_ERRORS error(s) from our code"
            echo "$BUILD_OUTPUT" | grep "legion-laptop.c" | grep -i "error" | sed 's/^/         /'
        elif [ "$OUR_WARNINGS" -gt 0 ]; then
            warn "Build succeeded but had $OUR_WARNINGS warning(s) from our code"
            echo "$BUILD_OUTPUT" | grep "legion-laptop.c" | grep -i "warning" | sed 's/^/         /'
        else
            pass "Build successful: 0 errors, 0 warnings"
        fi
    else
        fail "Build failed (exit code $BUILD_EXIT)"
        echo "$BUILD_OUTPUT" | tail -20 | sed 's/^/         /'
        echo -e "${RED}Cannot continue without a successful build.${NC}"
        exit 1
    fi

    # Extra warnings build (check only; reuse the .ko from the first build)
    info "Running extra-warnings check..."
    WARN_OUTPUT=$(make -C "$KM_BUILD" allWarn 2>&1)
    EXTRA_WARNS=$(echo "$WARN_OUTPUT" | grep "legion-laptop.c" | grep -ci "warning" || true)
    if [ "$EXTRA_WARNS" -gt 0 ]; then
        warn "Extra-warnings build found $EXTRA_WARNS warning(s)"
        echo "$WARN_OUTPUT" | grep "legion-laptop.c" | grep -i "warning" | sed 's/^/         /'
    else
        pass "Extra-warnings build: 0 warnings from our code"
    fi
fi

value "Module" "$MODULE_KO"
value "Module size" "$(du -h "$MODULE_KO" | cut -f1)"

# =============================================================================
# SECTION 6: Load Module
# =============================================================================
section "6. Loading legion-laptop Module"

# Check modprobe config
if [ -f "$LEGION_CONF" ]; then
    info "Modprobe config ($LEGION_CONF):"
    sed 's/^/         /' "$LEGION_CONF"
fi

# Clear dmesg marker
DMESG_MARKER=$(dmesg --raw | tail -1 | cut -d' ' -f1 || true)

INSMOD_PARAMS="enable_platformprofile=false"
if [ "$WMI_DRYRUN" = true ]; then
    INSMOD_PARAMS="$INSMOD_PARAMS wmi_dryrun=1"
    info "Loading module with wmi_dryrun=1 (WMI writes will be logged but NOT executed)..."
else
    info "Loading module with enable_platformprofile=false..."
fi
INSMOD_OUT=$(insmod "$MODULE_KO" $INSMOD_PARAMS 2>&1) && INSMOD_RC=0 || INSMOD_RC=$?

if [ "$INSMOD_RC" -ne 0 ]; then
    # If "File exists", the old module is still loaded - force unload and retry
    if echo "$INSMOD_OUT" | grep -qi "file exists\|already loaded"; then
        warn "Module already loaded, forcing unload and retrying..."
        rmmod legion_laptop 2>/dev/null || rmmod legion-laptop 2>/dev/null || true
        sleep 1
        INSMOD_OUT=$(insmod "$MODULE_KO" $INSMOD_PARAMS 2>&1) && INSMOD_RC=0 || INSMOD_RC=$?
    fi
fi

if [ "$INSMOD_RC" -eq 0 ]; then
    pass "Module loaded successfully"
else
    fail "Module failed to load"
    echo "$INSMOD_OUT" | sed 's/^/         /'
    echo -e "  ${RED}       dmesg output:${NC}"
    dmesg --ctime | tail -20 | sed 's/^/         /'
    echo -e "${RED}Cannot continue without a loaded module.${NC}"
    exit 1
fi

# Show dmesg from our module
sleep 1
info "dmesg output from legion-laptop:"
dmesg --ctime | grep -i "legion" | tail -30 | sed 's/^/         /'

# Verify module is loaded (kernel normalizes hyphens to underscores)
if lsmod | grep -qE "^legion[_-]laptop"; then
    pass "Module confirmed in lsmod"
    MOD_INFO=$(modinfo "$MODULE_KO" 2>/dev/null | grep -E "^(version|description|license)" || true)
    echo "$MOD_INFO" | sed 's/^/         /'
else
    # Fallback: check if sysfs driver is present (more reliable than lsmod)
    if [ -d "/sys/bus/platform/drivers/legion" ]; then
        pass "Module confirmed via sysfs (lsmod pattern mismatch)"
    else
        fail "Module not found in lsmod or sysfs after insmod"
    fi
fi

# =============================================================================
# SECTION 7: Sysfs Attributes
# =============================================================================
section "7. Sysfs Attributes"

if [ -d "$SYSFS_BASE" ]; then
    pass "Sysfs directory exists: $SYSFS_BASE"
else
    # Try to find it
    SYSFS_BASE=$(find /sys/bus/platform/drivers/legion/ -name "PNP*" -type d 2>/dev/null | head -1 || true)
    if [ -n "$SYSFS_BASE" ]; then
        warn "Sysfs base at non-standard path: $SYSFS_BASE"
    else
        fail "Cannot find legion sysfs directory"
        SYSFS_BASE=""
    fi
fi

if [ -n "$SYSFS_BASE" ]; then
    # Attributes exposed by legion-laptop under its own sysfs
    LEGION_ATTRS=(powermode rapidcharge touchpad)
    for attr in "${LEGION_ATTRS[@]}"; do
        FILE="$SYSFS_BASE/$attr"
        if [ -f "$FILE" ]; then
            VAL=$(cat "$FILE" 2>/dev/null || echo "ERROR")
            pass "legion sysfs: $attr"
            value "$attr" "$VAL"
        else
            warn "legion sysfs: $attr not found"
        fi
    done
fi

# Attributes exposed by ideapad-laptop (separate driver)
IDEAPAD_BASE="/sys/bus/platform/drivers/ideapad_acpi/VPC2004:00"
if [ -d "$IDEAPAD_BASE" ]; then
    IDEAPAD_ATTRS=(conservation_mode fn_lock camera_power usb_charging)
    for attr in "${IDEAPAD_ATTRS[@]}"; do
        FILE="$IDEAPAD_BASE/$attr"
        if [ -f "$FILE" ]; then
            VAL=$(cat "$FILE" 2>/dev/null || echo "ERROR")
            pass "ideapad sysfs: $attr"
            value "$attr" "$VAL"
        else
            info "ideapad sysfs: $attr not present"
        fi
    done
else
    info "ideapad_acpi sysfs not found (conservation_mode, fn_lock provided by ideapad-laptop)"
fi

# =============================================================================
# SECTION 8: Hwmon Sensor Discovery
# =============================================================================
section "8. Hwmon Sensor Discovery"

# Find our hwmon directory
HWMON_DIR=""
for d in /sys/class/hwmon/hwmon*; do
    NAME=$(cat "$d/name" 2>/dev/null || true)
    if [ "$NAME" = "legion" ] || [ "$NAME" = "legion_hwmon" ]; then
        HWMON_DIR="$d"
        break
    fi
done

if [ -z "$HWMON_DIR" ]; then
    # Fallback: check via device link
    for d in /sys/class/hwmon/hwmon*; do
        if readlink -f "$d/device" 2>/dev/null | grep -q "legion"; then
            HWMON_DIR="$d"
            break
        fi
    done
fi

if [ -n "$HWMON_DIR" ]; then
    pass "Found legion hwmon at: $HWMON_DIR"
    HWMON_NAME=$(cat "$HWMON_DIR/name" 2>/dev/null || echo "unknown")
    value "hwmon name" "$HWMON_NAME"
else
    fail "Cannot find legion hwmon directory"
    info "Available hwmon devices:"
    for d in /sys/class/hwmon/hwmon*; do
        NAME=$(cat "$d/name" 2>/dev/null || echo "?")
        echo "         $d -> $NAME"
    done
fi

# =============================================================================
# SECTION 9: Temperature Sensors
# =============================================================================
section "9. Temperature Sensors"

if [ -n "$HWMON_DIR" ]; then
    for i in 1 2 3; do
        TEMP_FILE="$HWMON_DIR/temp${i}_input"
        LABEL_FILE="$HWMON_DIR/temp${i}_label"
        if [ -f "$TEMP_FILE" ]; then
            RAW=$(cat "$TEMP_FILE" 2>/dev/null || echo "ERROR")
            LABEL=$(cat "$LABEL_FILE" 2>/dev/null || echo "temp${i}")
            # hwmon temps are in millidegrees
            if [ "$RAW" != "ERROR" ] && [ "$RAW" -gt 0 ] 2>/dev/null; then
                TEMP_C=$((RAW / 1000))
                pass "temp${i} ($LABEL): ${TEMP_C}°C (raw: $RAW)"
                if [ "$TEMP_C" -gt 105 ]; then
                    warn "Temperature seems very high: ${TEMP_C}°C"
                fi
            else
                warn "temp${i} ($LABEL): raw=$RAW (may be unreadable or 0)"
            fi
        else
            info "temp${i}_input not present"
        fi
    done
else
    skip "Temperature sensors (no hwmon directory)"
fi

# =============================================================================
# SECTION 10: Fan Speed Sensors (CRITICAL — 3-fan test)
# =============================================================================
section "10. Fan Speed Sensors (3-Fan Support)"

if [ -n "$HWMON_DIR" ]; then
    FAN_COUNT=0
    for i in 1 2 3; do
        FAN_FILE="$HWMON_DIR/fan${i}_input"
        LABEL_FILE="$HWMON_DIR/fan${i}_label"
        if [ -f "$FAN_FILE" ]; then
            RPM=$(cat "$FAN_FILE" 2>/dev/null || echo "ERROR")
            LABEL=$(cat "$LABEL_FILE" 2>/dev/null || echo "fan${i}")
            if [ "$RPM" != "ERROR" ]; then
                FAN_COUNT=$((FAN_COUNT + 1))
                pass "fan${i} ($LABEL): ${RPM} RPM"
                if [ "$RPM" -eq 0 ]; then
                    info "Fan ${i} reports 0 RPM (may be stopped or idle)"
                elif [ "$RPM" -gt 7000 ]; then
                    warn "Fan ${i} RPM seems very high: ${RPM}"
                fi
            else
                fail "fan${i} ($LABEL): read error"
            fi
        else
            if [ "$i" -le 2 ]; then
                fail "fan${i}_input not present (expected for all models)"
            else
                warn "fan${i}_input not present (3rd fan may not be supported on this model)"
            fi
        fi
    done

    echo ""
    if [ "$FAN_COUNT" -eq 3 ]; then
        pass "*** ALL 3 FANS DETECTED — 3-fan support is working ***"
    elif [ "$FAN_COUNT" -eq 2 ]; then
        warn "Only 2 fans detected. If this is Q7CN/SMCN hardware, fan3 should be visible."
        info "Check dmesg for is_visible/num_fans messages"
    else
        fail "Only $FAN_COUNT fan(s) detected"
    fi

    # Also check fan targets
    echo ""
    info "Fan target RPMs:"
    for i in 1 2; do
        TARGET_FILE="$HWMON_DIR/fan${i}_target"
        if [ -f "$TARGET_FILE" ]; then
            TARGET=$(cat "$TARGET_FILE" 2>/dev/null || echo "N/A")
            value "fan${i}_target" "$TARGET RPM"
        fi
    done

    # Fan max RPMs
    echo ""
    info "Fan max RPMs:"
    for i in 1 2; do
        MAX_FILE="$HWMON_DIR/fan${i}_max"
        if [ -f "$MAX_FILE" ]; then
            MAX=$(cat "$MAX_FILE" 2>/dev/null || echo "N/A")
            value "fan${i}_max" "$MAX RPM"
        fi
    done
else
    skip "Fan sensors (no hwmon directory)"
fi

# =============================================================================
# SECTION 11: Fan Curve Attributes
# =============================================================================
section "11. Fan Curve Hwmon Attributes"

if [ -n "$HWMON_DIR" ]; then
    # Check a few representative fan curve files
    info "Fan curve point 1 (sample):"
    for attr in pwm1_auto_point1_pwm pwm2_auto_point1_pwm \
                pwm1_auto_point1_temp pwm1_auto_point1_temp_hyst \
                pwm2_auto_point1_temp pwm2_auto_point1_temp_hyst \
                pwm3_auto_point1_temp pwm3_auto_point1_temp_hyst \
                pwm1_auto_point1_accel pwm1_auto_point1_decel; do
        FILE="$HWMON_DIR/$attr"
        if [ -f "$FILE" ]; then
            VAL=$(cat "$FILE" 2>/dev/null || echo "ERROR")
            value "$attr" "$VAL"
        else
            warn "Missing: $attr"
        fi
    done

    # Count total fan curve files (use find to avoid glob expansion issues)
    PWM1_COUNT=$(find -L "$HWMON_DIR" -maxdepth 1 -name 'pwm1_auto_point*_pwm' 2>/dev/null | wc -l)
    PWM2_COUNT=$(find -L "$HWMON_DIR" -maxdepth 1 -name 'pwm2_auto_point*_pwm' 2>/dev/null | wc -l)
    PWM3_PWM_COUNT=$(find -L "$HWMON_DIR" -maxdepth 1 -name 'pwm3_auto_point*_pwm' 2>/dev/null | wc -l)

    pass "Fan curve points: pwm1=$PWM1_COUNT, pwm2=$PWM2_COUNT"
    if [ "$PWM3_PWM_COUNT" -gt 0 ]; then
        info "Note: pwm3 fan speed curve points found ($PWM3_PWM_COUNT) — unexpected"
    else
        pass "No pwm3 fan speed curve (correct: fan curve is unified, pwm3 is IC temp only)"
    fi

    # Minifancurve
    MINI_FILE="$HWMON_DIR/minifancurve"
    if [ -f "$MINI_FILE" ]; then
        MINI_VAL=$(cat "$MINI_FILE" 2>/dev/null || echo "ERROR")
        value "minifancurve" "$MINI_VAL"
    else
        info "minifancurve attribute not present"
    fi
else
    skip "Fan curve attributes (no hwmon directory)"
fi

# =============================================================================
# SECTION 12: Power Mode
# =============================================================================
section "12. Power Mode"

if [ -n "$SYSFS_BASE" ] && [ -f "$SYSFS_BASE/powermode" ]; then
    CURRENT_MODE=$(cat "$SYSFS_BASE/powermode" 2>/dev/null || echo "ERROR")
    pass "Current power mode read successfully"
    value "powermode" "$CURRENT_MODE"

    case "$CURRENT_MODE" in
        1)   info "Mode: Quiet" ;;
        2)   info "Mode: Balanced" ;;
        3)   info "Mode: Performance" ;;
        255) info "Mode: Custom" ;;
        224) info "Mode: Extreme" ;;
        *)   warn "Unknown power mode value: $CURRENT_MODE" ;;
    esac

    # Test Extreme mode write
    if [ "$TEST_EXTREME" = true ]; then
        echo ""
        info "Testing Extreme power mode write (0xE0 = 224)..."
        SAVED_MODE="$CURRENT_MODE"

        echo 224 > "$SYSFS_BASE/powermode" 2>&1 && {
            NEW_MODE=$(cat "$SYSFS_BASE/powermode" 2>/dev/null || echo "ERROR")
            if [ "$NEW_MODE" = "224" ]; then
                pass "*** Extreme mode (224) written and read back successfully ***"
            else
                fail "Wrote 224 but read back: $NEW_MODE"
            fi
        } || {
            fail "Failed to write Extreme mode (224)"
            info "Check dmesg for error details:"
            dmesg --ctime | tail -5 | sed 's/^/         /'
        }

        # Restore previous mode
        info "Restoring previous power mode ($SAVED_MODE)..."
        echo "$SAVED_MODE" > "$SYSFS_BASE/powermode" 2>/dev/null || \
            warn "Failed to restore power mode to $SAVED_MODE"

        RESTORED=$(cat "$SYSFS_BASE/powermode" 2>/dev/null || echo "?")
        if [ "$RESTORED" = "$SAVED_MODE" ]; then
            pass "Power mode restored to $SAVED_MODE"
        else
            warn "Power mode is $RESTORED after restore attempt (expected $SAVED_MODE)"
        fi
    else
        skip "Extreme mode write test (use --test-extreme to enable)"
    fi
else
    fail "Cannot read powermode from sysfs"
fi

# =============================================================================
# SECTION 13: Platform Profile
# =============================================================================
section "13. Platform Profile"

PP_FILE="/sys/firmware/acpi/platform_profile"
PP_CHOICES_FILE="/sys/firmware/acpi/platform_profile_choices"

if [ -f "$PP_FILE" ]; then
    PP_VAL=$(cat "$PP_FILE" 2>/dev/null || echo "ERROR")
    PP_CHOICES=$(cat "$PP_CHOICES_FILE" 2>/dev/null || echo "N/A")
    value "platform_profile" "$PP_VAL"
    value "choices" "$PP_CHOICES"

    # Check if this is from our module or upstream
    info "Note: enable_platformprofile=false was used, so this may be from another driver"
else
    info "platform_profile not available (expected with enable_platformprofile=false)"
fi

# =============================================================================
# SECTION 14: Additional Features
# =============================================================================
section "14. Additional Features"

if [ -n "$SYSFS_BASE" ]; then
    # Legion-specific features (already checked in section 7, show extras here)
    for attr in lockfancontroller fan_fullspeed fan_maxspeed overdrive gsync winkey igpumode; do
        FILE="$SYSFS_BASE/$attr"
        if [ -f "$FILE" ]; then
            VAL=$(cat "$FILE" 2>/dev/null || echo "ERROR")
            pass "legion: $attr = $VAL"
        fi
    done
fi

# LED subsystem (legion LEDs may not contain "legion" in name)
info "LED subsystem:"
LED_FOUND=false
for led in /sys/class/leds/platform::*; do
    if [ -e "$led" ]; then
        LED_NAME=$(basename "$led")
        LED_BRIGHTNESS=$(cat "$led/brightness" 2>/dev/null || echo "N/A")
        LED_MAX=$(cat "$led/max_brightness" 2>/dev/null || echo "N/A")
        value "$LED_NAME" "brightness=$LED_BRIGHTNESS, max=$LED_MAX"
        LED_FOUND=true
    fi
done
if [ "$LED_FOUND" = false ]; then
    info "No platform:: LEDs found"
fi

# =============================================================================
# SECTION 14b: WMI Dry-Run Tests (fan control + extreme mode)
# =============================================================================
if [ "$WMI_DRYRUN" = true ]; then
    section "14b. WMI Dry-Run Tests (wmi_dryrun=1 - NO hardware writes)"

    info "wmi_dryrun=1: All WMI writes are logged in dmesg but NOT executed."
    info "This validates the full code path safely."
    echo ""

    # --- Fan fullspeed read ---
    if [ -n "$SYSFS_BASE" ] && [ -f "$SYSFS_BASE/fan_fullspeed" ]; then
        FS_VAL=$(cat "$SYSFS_BASE/fan_fullspeed" 2>/dev/null || echo "ERROR")
        pass "fan_fullspeed read: $FS_VAL (WMI GET_FULLSPEED method 1)"
    else
        warn "fan_fullspeed not available"
    fi

    # --- Fan maxspeed read ---
    if [ -n "$SYSFS_BASE" ] && [ -f "$SYSFS_BASE/fan_maxspeed" ]; then
        MS_VAL=$(cat "$SYSFS_BASE/fan_maxspeed" 2>/dev/null || echo "ERROR")
        pass "fan_maxspeed read: $MS_VAL (WMI GET_MAXSPEED method 3)"
    else
        warn "fan_maxspeed not available"
    fi

    # --- Fan curve read via debugfs ---
    FANCURVE_FILE="/sys/kernel/debug/legion/fancurve"
    if [ -f "$FANCURVE_FILE" ]; then
        info "Fan curve read (WMI GET_TABLE method 5):"
        cat "$FANCURVE_FILE" 2>/dev/null | head -15 | sed 's/^/         /'
        pass "Fan curve read successful"
    else
        info "Fan curve debugfs not available"
    fi

    # --- Fan curve read via hwmon ---
    if [ -n "$HWMON_DIR" ]; then
        info "Fan curve points via hwmon (all 10 speed points):"
        ALL_OK=true
        for i in 1 2 3 4 5 6 7 8 9 10; do
            F="$HWMON_DIR/pwm1_auto_point${i}_pwm"
            if [ -f "$F" ]; then
                V=$(cat "$F" 2>/dev/null || echo "ERR")
                echo -e "         point${i}: speed1=$V"
            else
                ALL_OK=false
            fi
        done
        if [ "$ALL_OK" = true ]; then
            pass "All 10 fan curve speed points readable"
        else
            warn "Some fan curve speed points missing"
        fi
    fi

    echo ""
    info "--- Dry-run WRITE tests (WMI calls logged, NOT executed) ---"
    echo ""

    # --- Dry-run: fan_fullspeed write ---
    if [ -n "$SYSFS_BASE" ] && [ -f "$SYSFS_BASE/fan_fullspeed" ]; then
        SAVED_FS=$(cat "$SYSFS_BASE/fan_fullspeed" 2>/dev/null || echo "0")
        echo "$SAVED_FS" > "$SYSFS_BASE/fan_fullspeed" 2>&1 && {
            pass "fan_fullspeed dry-run write: value=$SAVED_FS (wrote same value back)"
        } || {
            fail "fan_fullspeed dry-run write failed"
        }

        # Check dmesg for the dry-run log
        sleep 0.5
        DRYRUN_MSG=$(dmesg | grep "WMI dry run" | tail -1 || true)
        if echo "$DRYRUN_MSG" | grep -q "dry run"; then
            pass "dmesg confirms WMI write was intercepted:"
            echo "         $DRYRUN_MSG"
        else
            warn "No dry-run message in dmesg (write may not have reached wmi_exec_arg)"
        fi
    fi

    # --- Dry-run: fan_maxspeed write ---
    if [ -n "$SYSFS_BASE" ] && [ -f "$SYSFS_BASE/fan_maxspeed" ]; then
        SAVED_MS=$(cat "$SYSFS_BASE/fan_maxspeed" 2>/dev/null || echo "0")
        echo "$SAVED_MS" > "$SYSFS_BASE/fan_maxspeed" 2>&1 && {
            pass "fan_maxspeed dry-run write: value=$SAVED_MS (wrote same value back)"
        } || {
            fail "fan_maxspeed dry-run write failed"
        }
    fi

    # --- Dry-run: extreme mode write ---
    if [ -n "$SYSFS_BASE" ] && [ -f "$SYSFS_BASE/powermode" ]; then
        SAVED_PM=$(cat "$SYSFS_BASE/powermode" 2>/dev/null || echo "ERROR")
        info "Current power mode: $SAVED_PM"

        echo 224 > "$SYSFS_BASE/powermode" 2>&1 && {
            pass "Extreme mode (224) dry-run write: code path validated"
        } || {
            fail "Extreme mode (224) dry-run write: rejected by validation"
            dmesg | tail -3 | sed 's/^/         /'
        }

        # Verify the mode didn't actually change (dry run should skip WMI)
        sleep 0.5
        AFTER_PM=$(cat "$SYSFS_BASE/powermode" 2>/dev/null || echo "ERROR")
        if [ "$AFTER_PM" = "$SAVED_PM" ]; then
            pass "Power mode unchanged after dry-run write (was $SAVED_PM, still $AFTER_PM)"
        else
            warn "Power mode changed to $AFTER_PM (expected $SAVED_PM to be unchanged in dry-run)"
        fi

        # Check dmesg for dry-run log
        DRYRUN_PM=$(dmesg | grep "WMI dry run" | grep "method 44" | tail -1 || true)
        if [ -n "$DRYRUN_PM" ]; then
            pass "dmesg confirms extreme mode WMI write was intercepted:"
            echo "         $DRYRUN_PM"
        fi

        # Restore just in case (writes are dry-run anyway)
        echo "$SAVED_PM" > "$SYSFS_BASE/powermode" 2>/dev/null || true
    fi

    # --- Dry-run: fan curve write (write current values back) ---
    if [ -n "$HWMON_DIR" ] && [ -f "$HWMON_DIR/pwm1_auto_point1_pwm" ]; then
        CUR_SPEED=$(cat "$HWMON_DIR/pwm1_auto_point1_pwm" 2>/dev/null || echo "ERR")
        if [ "$CUR_SPEED" != "ERR" ]; then
            echo "$CUR_SPEED" > "$HWMON_DIR/pwm1_auto_point1_pwm" 2>&1 && {
                pass "Fan curve dry-run write: pwm1_auto_point1_pwm=$CUR_SPEED (wrote same value)"
            } || {
                fail "Fan curve dry-run write failed"
            }

            # Check for SET_TABLE dry-run message
            sleep 0.5
            DRYRUN_FC=$(dmesg | grep "WMI dry run" | grep "method 6" | tail -1 || true)
            if [ -n "$DRYRUN_FC" ]; then
                pass "dmesg confirms fan curve WMI SET_TABLE was intercepted:"
                echo "         $DRYRUN_FC"
            fi
        fi
    fi

    echo ""
    info "--- Dry-run dmesg summary ---"
    dmesg | grep "WMI dry run" | tail -10 | sed 's/^/         /'

else
    # Not in dry-run mode — skip this section
    :
fi

# =============================================================================
# SECTION 15: EC Register Mapping Verification
# =============================================================================
section "15. EC Register Mapping Notes"

info "Q7CN/SMCN uses ACCESS_METHOD_WMI3 for temps/fans/curves (not direct EC reads)"
info "EC address formula: ACPI_addr = 0xFE500000 + (EC_offset - 0xC000)"
info "See legion-laptop.c ec_register_offsets for full register map"

# =============================================================================
# SECTION 16: WMI GUID Presence Check
# =============================================================================
section "16. WMI GUID Presence on This Hardware"

WMI_BUS="/sys/bus/wmi/devices"
EXPECTED_GUIDS=(
    "887B54E3-DDDC-4B2C-8B88-68A26A8835D0:GameZone"
    "92549549-4BDE-4F06-AC04-CE8BF898DBAA:FanMethod"
    "DC2A8805-3A8C-41BA-A6F7-092E0089CD3B:OtherMethod"
    "8C5B9127-ECD4-4657-980F-851019F99CA5:Keyboard"
    "D320289E-8FEA-41E0-86F9-611D83151B5F:FanEvent"
    "BC72A435-E8C1-4275-B3E2-D8B8074ABA59:Fan2Event"
    "10AFC6D9-EA8B-4590-A2E7-1CD3C84BB4B1:KeyEvent"
)

NOT_EXPECTED_GUIDS=(
    "BFD42481-AEE3-4502-A107-AFB68425C5F8:GPU_EVENT"
    "D062906B-12D4-4510-999D-4831EE80E985:OC_EVENT"
    "BFD42481-AEE3-4501-A107-AFB68425C5F8:TEMP_EVENT"
)

if [ -d "$WMI_BUS" ]; then
    for entry in "${EXPECTED_GUIDS[@]}"; do
        GUID="${entry%%:*}"
        NAME="${entry##*:}"
        # WMI devices may appear as GUID or GUID-N
        if ls "$WMI_BUS" 2>/dev/null | grep -qi "${GUID}"; then
            pass "WMI GUID present: $NAME ($GUID)"
        else
            warn "WMI GUID missing: $NAME ($GUID)"
        fi
    done

    echo ""
    info "GUIDs in legion_wmi_ids NOT expected on this hardware:"
    for entry in "${NOT_EXPECTED_GUIDS[@]}"; do
        GUID="${entry%%:*}"
        NAME="${entry##*:}"
        if ls "$WMI_BUS" 2>/dev/null | grep -qi "${GUID}"; then
            info "$NAME ($GUID) — PRESENT (unexpected!)"
        else
            pass "$NAME ($GUID) — correctly absent"
        fi
    done
else
    warn "WMI bus directory not found at $WMI_BUS"
fi

# =============================================================================
# SECTION 17: Debugfs
# =============================================================================
section "17. Debugfs"

DEBUGFS="/sys/kernel/debug/legion"
if [ -d "$DEBUGFS" ]; then
    pass "Legion debugfs directory exists"
    info "Contents:"
    ls -la "$DEBUGFS" 2>/dev/null | sed 's/^/         /'

    # Read EC dump summary if available
    EC_DUMP="$DEBUGFS/ecmemoryio"
    if [ -f "$EC_DUMP" ]; then
        DUMP_SIZE=$(wc -c < "$EC_DUMP" 2>/dev/null || echo 0)
        value "EC memory dump size" "$DUMP_SIZE bytes"
    fi

    FANCURVE_FILE="$DEBUGFS/fancurve"
    if [ -f "$FANCURVE_FILE" ]; then
        info "Fan curve from debugfs:"
        cat "$FANCURVE_FILE" 2>/dev/null | head -15 | sed 's/^/         /'
    fi
else
    info "Legion debugfs not available (mount debugfs or check module options)"
fi

# =============================================================================
# SECTION 18: dmesg Summary
# =============================================================================
section "18. Final dmesg Summary"

info "All legion-related dmesg entries:"
dmesg --ctime | grep -iE "legion|wmi.*lenovo|lenovo.*wmi" | tail -40 | sed 's/^/         /'

# =============================================================================
# Summary
# =============================================================================
section "SUMMARY"

TOTAL=$((PASS + FAIL + WARN + SKIP))
echo -e "  ${GREEN}PASS: $PASS${NC}  |  ${RED}FAIL: $FAIL${NC}  |  ${YELLOW}WARN: $WARN${NC}  |  ${CYAN}SKIP: $SKIP${NC}  |  Total: $TOTAL"
echo ""

if [ "$FAIL" -eq 0 ]; then
    echo -e "  ${GREEN}${BOLD}All critical tests passed!${NC}"
else
    echo -e "  ${RED}${BOLD}$FAIL test(s) failed — review output above.${NC}"
fi

if [ "$WARN" -gt 0 ]; then
    echo -e "  ${YELLOW}$WARN warning(s) — review for potential issues.${NC}"
fi

echo ""
echo -e "${BOLD}Next steps:${NC}"
echo "  1. If fan3 was detected, 3-fan support is confirmed working"
echo "  2. Run with --wmi-dryrun to safely test fan control and extreme mode writes"
echo "  3. Run with --test-extreme to actually write Extreme power mode to hardware"
echo "  4. Run with --install-blacklist to persist upstream module blacklist"
echo "  5. After blacklist: reboot, then re-run this script to verify clean state"
echo ""
echo -e "Log saved to: ${BOLD}${LOG_FILE}${NC}"
