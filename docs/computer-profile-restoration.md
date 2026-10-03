# Consolidated computer profiles restored

The October 3 APKs through versionCode 2026102304 were built from a committed
checkout that omitted the existing local computer-profile implementation.
This removed its UI from those APKs. The profiles implementation is now included
in the committed app alongside the ZeroTier recovery, local terminal review,
and visible recording/transcription error fixes.

Connect > Computers manages named computers. Selection in Connect, Builds, or
Terminal updates the build server, SSH identity, Agent URL and pair token together.
Terminal > Tools > sessions switches retained terminal sessions, with separate
scrollback and credentials. Editing a background session does not select it or
change another computer's credentials. Backup/restore includes profile metadata
and the existing secure-storage credentials.

Install the corrected APK as an in-place update using the same app/package and
signing key. There is no app-data clear or uninstall in this workflow. A regression
check confirms saved unified profiles, selected ID, passwords and Agent tokens
survive legacy settings changes by an intervening older build. This is synthetic
verification; the actual contents of the user's phone storage were not read.

Validation: 240 Flutter tests passed, including 17 focused profile/session tests;
Flutter analysis reported no issues. One native Android 36 emulator test passed,
restoring two saved profile fixtures and switching the visible computer selector
while checking the persisted build-server and SSH identity. The first UI harness
attempt could not match Flutter's combined accessibility label; its next attempt
read settings midway through asynchronous writes. Matching the combined label
and waiting for all expected settings made the final check pass.

The native fixture test must use the isolated application ID
io.github.chasekolozsy.devota.profilesverify. It skips on other package IDs, since
it seeds fixture preferences. To build the fixture and its instrumentation APK:

    cd app/android
    DEVOTA_APPLICATION_ID=io.github.chasekolozsy.devota.profilesverify ./gradlew :app:assembleDebug :app:assembleDebugAndroidTest

Install those APKs on a selected emulator, then run:

    adb -s emulator-5554 shell am instrument -w -e class io.github.chasekolozsy.devota.ComputerProfilesRecoveryTest io.github.chasekolozsy.devota.profilesverify.test/androidx.test.runner.AndroidJUnitRunner
