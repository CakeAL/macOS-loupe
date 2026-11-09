#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
source_package="${1:-}"

if [[ -z "$source_package" ]]; then
    shopt -s nullglob
    for runtime in /private/var/run/com.apple.security.cryptexd/mnt/com.apple.iPhoneOS.SimulatorRuntime*/Library/Developer/CoreSimulator/Profiles/Runtimes/*.simruntime \
                   /Library/Developer/CoreSimulator/Volumes/*/Library/Developer/CoreSimulator/Profiles/Runtimes/*.simruntime; do
        package="$runtime/Contents/Resources/RuntimeRoot/Applications/Preview.app/LandingUI-Loupe.ca"
        if [[ -f "$package/main.caml" ]]; then
            source_package="$package"
            break
        fi
    done
fi

if [[ ! -f "$source_package/main.caml" ]]; then
    printf '%s\n' 'Install and mount an iOS 27 simulator runtime in Xcode, or pass the path to LandingUI-Loupe.ca.' >&2
    exit 1
fi

destination="$root/Resources/LandingUI-Loupe.ca"
if [[ ! -d "$destination" ]]; then
    mkdir -p "$root/Resources"
    ditto "$source_package" "$destination"
fi
chmod u+w "$destination/main.caml"
/usr/bin/perl -0pi -e 's{<(eventHandlers|states|stateTransitions)>.*?</\1>}{}gs' "$destination/main.caml"
printf 'Imported loupe to %s\n' "$destination"
