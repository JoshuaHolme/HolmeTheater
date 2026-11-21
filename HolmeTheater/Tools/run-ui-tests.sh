#!/bin/zsh
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# Runs the UI tests on every iPhone, iPad and Apple TV simulator installed for the newest OS, each in every orientation
# (ReleaseUITests.xctestplan runs every test once per orientation, skipping those a device doesn't support), and the
# iPhone Duo both unfolded and folded. Prints a table of the results, and keeps each device's result bundle.
#
#   Tools/run-ui-tests.sh                     every device, here in the terminal
#   Tools/run-ui-tests.sh "iPhone 17e" Duo    only the devices whose names contain one of these
#   Tools/run-ui-tests.sh --background [...]  the same, detached: returns at once, and posts a notification when done
#   Tools/run-ui-tests.sh --stop              stops a run that's going
#
# From Xcode: build the "UI Test Matrix" scheme (Product > Build), which starts a background run and finishes at once.
# Progress goes to .build/UITestResults/latest-run.log, and each run's results, with a summary.txt, to a dated folder
# beside it (.build/UITestResults/latest points at the newest). Open a device's .xcresult in Xcode to see its failures,
# with a screenshot of each.
#
# Nothing to set up: the tests run against canned data (-UseMockService), so they need no server. A whole run takes a
# couple of hours; the simulators it uses shouldn't be used for anything else meanwhile.
#
# Folding the Duo: no command-line tool or XCUITest API can fold a simulator, so this uses the Simulator app's Device
# menu, through System Events. That needs whatever started the script (Terminal, or Xcode) to be allowed to control the
# computer (System Settings > Privacy & Security > Accessibility). Without it, the script asks you to fold the Duo
# yourself: in the terminal, or with a dialog when running in the background.

set -u
cd "${0:A:h}/.."

typeset -r root=.build/UITestResults
typeset -r lock="$root/.running"
mkdir -p "$root"

# Posts a notification: the only way a background run can say it's done. $1: title, $2: message.
notify() {
    osascript -e 'on run arguments' -e 'display notification (item 2 of arguments) with title (item 1 of arguments)' \
        -e 'end run' "$1" "$2" > /dev/null 2>&1
}

# Whether a run is going already.
is_running() { [[ -f $lock ]] && kill -0 "$(<$lock)" 2> /dev/null }

case "${1:-}" in
--background)
    shift
    if is_running; then
        notify "UI tests are already running" "See $root/latest-run.log"
        print "Already running (process $(<$lock)). Progress: $PWD/$root/latest-run.log"
        exit 0
    fi
    # Detached, so Xcode's build finishes at once, and with a clean environment: a scheme's pre-action inherits the build
    # settings of the build that ran it, which would steer xcodebuild wrong.
    clean=(HOME="$HOME" USER="$USER" LOGNAME="${LOGNAME:-$USER}" TMPDIR="${TMPDIR:-/tmp}" PATH=/usr/bin:/bin:/usr/sbin:/sbin)
    [[ -n ${DEVELOPER_DIR:-} ]] && clean+=(DEVELOPER_DIR="$DEVELOPER_DIR")
    env -i "${clean[@]}" nohup /bin/zsh "${0:A}" "$@" > "$root/latest-run.log" 2>&1 < /dev/null &!
    print "UI tests started in the background. Progress: $PWD/$root/latest-run.log"
    exit 0
    ;;
--stop)
    if is_running; then
        pkill -P "$(<$lock)"
        kill "$(<$lock)"
        rm -f "$lock"
        print "Stopped."
    else
        print "Not running."
    fi
    exit 0
    ;;
esac

if is_running; then
    print -u2 "Already running (process $(<$lock)). Stop it with: $0 --stop"
    exit 1
fi
print $$ > "$lock"
trap 'rm -f "$lock"' EXIT

typeset -r project=HolmeTheater.xcodeproj
typeset -r scheme=HolmeTheater
typeset -r plan=ReleaseUITests
typeset -r derived=.build/DerivedData
typeset -r results="$root/$(date +%Y-%m-%d_%H-%M-%S)"
mkdir -p "$results"
ln -sfn "${results:t}" "$root/latest"

# MARK: Devices

# Every available iPhone, iPad and Apple TV on the newest iOS and tvOS runtimes, one per line: platform|udid|name.
devices=("${(@f)$(xcrun simctl list devices available --json | python3 -c '
import json, re, sys
runtimes = json.load(sys.stdin)["devices"]
def version(key):
    return [int(part) for part in re.findall(r"\d+", key)]
for platform, prefix in (("iOS", "com.apple.CoreSimulator.SimRuntime.iOS-"), ("tvOS", "com.apple.CoreSimulator.SimRuntime.tvOS-")):
    keys = [key for key in runtimes if key.startswith(prefix) and runtimes[key]]
    # The newest runtime that has the device, so a device type only installed with a newer point release is still found.
    newest = {}
    for key in sorted(keys, key=version):
        for device in runtimes[key]:
            if platform == "tvOS" or device["name"].startswith(("iPhone", "iPad")):
                newest[device["name"]] = device["udid"]
    for name, udid in sorted(newest.items()):
        print(f"{platform}|{udid}|{name}")
')}")

if (( $# > 0 )); then
    wanted=()
    for device in $devices; do
        for filter in "$@"; do
            [[ "${device##*|}" == *"$filter"* ]] && { wanted+=("$device"); break; }
        done
    done
    devices=($wanted)
fi

if (( ${#devices} == 0 )); then
    print -u2 "No simulators found. Install them in Xcode > Settings > Components."
    exit 1
fi

print "Testing on ${#devices} devices:"
for device in $devices; do print "  ${device##*|}"; done
print

# MARK: Building

# Once per platform, then each device runs what was built.
for platform in iOS tvOS; do
    (( ${devices[(I)$platform\|*]} )) || continue
    print "Building for $platform…"
    if ! xcodebuild build-for-testing -project "$project" -scheme "$scheme" -testPlan "$plan" \
        -destination "generic/platform=$platform Simulator" -derivedDataPath "$derived" -quiet \
        > "$results/build-$platform.log" 2>&1; then
        print -u2 "The $platform build failed; see $results/build-$platform.log"
        exit 1
    fi
done

# MARK: Running

summary=()
failed=0

# Runs the plan on one device and adds a line to the summary. $1: udid, $2: what to call the run.
run_tests() {
    local udid=$1 label=$2
    local bundle="$results/${label//[^A-Za-z0-9 ()._-]/_}.xcresult"
    print "Testing on $label…"
    xcodebuild test-without-building -project "$project" -scheme "$scheme" -testPlan "$plan" \
        -destination "id=$udid" -derivedDataPath "$derived" -resultBundlePath "$bundle" \
        -parallel-testing-enabled NO > "$bundle.log" 2>&1
    local code=$?
    local counts=$(xcrun xcresulttool get test-results summary --path "$bundle" 2>/dev/null | python3 -c '
import json, sys
try:
    s = json.load(sys.stdin)
    passed, failed, skipped = (s.get(key, 0) for key in ("passedTests", "failedTests", "skippedTests"))
    print(f"{passed} passed, {failed} failed, {skipped} skipped")
except Exception:
    print("no results")
')
    if (( code == 0 )); then
        summary+=("PASS  $label: $counts")
    else
        summary+=("FAIL  $label: $counts (see $bundle)")
        failed=1
    fi
}

# Whether the Duo is unfolded: its inner screen is the bigger of its two. $1: udid.
is_unfolded() {
    local shot="${TMPDIR:-/tmp}/duo-$$.png"
    xcrun simctl io "$1" screenshot "$shot" > /dev/null 2>&1 || return 2
    local width=$(sips -g pixelWidth "$shot" 2>/dev/null | awk '/pixelWidth/ { print $2 }')
    rm -f "$shot"
    (( width > 1600 ))
}

# Folds or unfolds the Duo with the Simulator app's Device menu, or asks for it to be done by hand. $1: udid,
# $2: "Fold" or "Unfold". Returns non-zero if it couldn't be done.
set_fold() {
    local udid=$1 action=$2
    open -a Simulator --args -CurrentDeviceUDID "$udid"
    sleep 3
    osascript > /dev/null 2>&1 <<EOF
tell application "Simulator" to activate
tell application "System Events" to tell process "Simulator"
    set chosen to missing value
    repeat with item_ in menu items of menu "Device" of menu bar 1
        set title_ to name of item_
        if title_ is not missing value and title_ starts with "$action" then set chosen to item_
    end repeat
    if chosen is missing value then error "No $action item in the Device menu"
    click chosen
end tell
EOF
    if (( $? != 0 )); then
        local request="Couldn't ${action:l} the iPhone Duo automatically. ${action} it in Simulator (Device menu), then continue."
        if [[ -t 0 ]]; then
            print "$request Press Return when it's done."
            read -r
        else
            # In the background, nobody is watching the terminal: ask with a dialog. "Skip" leaves that posture untested.
            osascript -e 'on run arguments' \
                -e 'display dialog (item 1 of arguments) with title "Holme Theater UI Tests" buttons {"Skip", "Continue"} default button "Continue" cancel button "Skip"' \
                -e 'end run' "$request" > /dev/null 2>&1 || return 1
        fi
    fi
    sleep 3
    if [[ $action == Unfold ]]; then is_unfolded "$udid"; else ! is_unfolded "$udid"; fi
}

for device in $devices; do
    platform=${device%%|*}
    rest=${device#*|}
    udid=${rest%%|*}
    name=${rest#*|}

    if [[ $name == *Duo* ]]; then
        # Both ways, ending as it started.
        xcrun simctl boot "$udid" > /dev/null 2>&1
        xcrun simctl bootstatus "$udid" > /dev/null 2>&1
        if is_unfolded "$udid"; then postures=(Unfold Fold); else postures=(Fold Unfold); fi
        for posture in $postures; do
            label="$name ($( [[ $posture == Fold ]] && print folded || print unfolded ))"
            if [[ $posture != ${postures[1]} ]] && ! set_fold "$udid" "$posture"; then
                summary+=("SKIP  $label: couldn't change the fold")
                failed=1
                continue
            fi
            run_tests "$udid" "$label"
        done
        set_fold "$udid" "${postures[1]}" > /dev/null 2>&1
    else
        run_tests "$udid" "$name"
    fi
done

print
print "Results ($PWD/$results):" | tee "$results/summary.txt"
for line in $summary; do print "  $line"; done | tee -a "$results/summary.txt"

passes=${#${(M)summary:#PASS*}}
if (( failed )); then
    notify "UI tests: $(( ${#summary} - passes )) of ${#summary} runs didn't pass" "See $results/summary.txt"
else
    notify "UI tests passed" "All ${#summary} runs passed, on every device and in every orientation."
fi
exit $failed
