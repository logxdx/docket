# Source this file to put the Flutter toolchain on PATH:
#
#   source tool/env.sh
#
# The toolchain is .tooling/ in the repository (a folder or a link to one), or the folder
# NOTES_TOOLING names; nothing is installed into $HOME.

_notes_here="$(cd "$(dirname "${BASH_SOURCE[0]:-${(%):-%x}}")/.." && pwd)"
if [[ -n "${NOTES_TOOLING:-}" ]]; then
  export DOCKET_TOOLING="$NOTES_TOOLING"
else
  export DOCKET_TOOLING="$(cd "$_notes_here/.tooling" 2>/dev/null && pwd)"
fi
if [[ -z "$DOCKET_TOOLING" || ! -d "$DOCKET_TOOLING/flutter" ]]; then
  echo "No toolchain found: set NOTES_TOOLING to a folder holding flutter/, jdk/ and android-sdk/." >&2
else
  {
    export JAVA_HOME="$DOCKET_TOOLING/jdk" ANDROID_HOME="$DOCKET_TOOLING/android-sdk" ANDROID_SDK_ROOT="$DOCKET_TOOLING/android-sdk"
    export GRADLE_USER_HOME="$DOCKET_TOOLING/gradle-home" PUB_CACHE="$DOCKET_TOOLING/pub-cache" FLUTTER_ROOT="$DOCKET_TOOLING/flutter"
    export ANDROID_USER_HOME="$DOCKET_TOOLING/android-user" FLUTTER_SUPPRESS_ANALYTICS=true
    export PATH="$FLUTTER_ROOT/bin:$PUB_CACHE/bin:$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:$PATH"
  }
fi
unset _notes_here
