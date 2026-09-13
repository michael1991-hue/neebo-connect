# Install and test Nivvi from Windows

1. Open this repository's **Actions** tab, then the latest successful **Build Nivvi for iPhone** run.
2. Download **Nivvi-unsigned**, unzip it and transfer **Nivvi-unsigned.ipa** to the iPhone's Files app.
3. Use [AltStore Classic's Windows instructions](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows). In AltStore Classic, open My Apps → + and select the IPA. Follow its signing, refresh and Developer Mode instructions.
4. Version 0.5 / Build 5 has a new bundle identifier and installs separately. Export history/events from the old installation first. Keep the old app until you have checked the exports; history does not automatically transfer.
5. Open Nivvi and set up the profile. Allow Bluetooth access. Disconnect other apps using the device, then Device → Scan for devices → select your monitor → Connect wearable.
6. Standard Heart Rate Service devices should show **Standard heart-rate device** and incoming heart rate. If not listed, enable **Show other nearby Bluetooth devices** and scan again. A listed device is not necessarily supported. The custom profile remains experimental and needs independent comparison.
7. Check live timestamps and let the session run beyond two minutes. Lock/unlock the phone; check history and whether the device supplies background notifications. Diagnostic capture ends after two minutes; the session continues.
8. Check reconnection after signal loss and Bluetooth off/on. Tap Disconnect and confirm automatic reconnection stops.
9. In Settings, try Test siren and Test notification. Configure both low/high test limits with a test peripheral. Equality does not trigger; low is strictly below and high is strictly above. Custom-format alerts require separate experimental opt-in. Device data has not been clinically validated.
10. Review History → Events and Readings; touch the heart-rate chart, select another day and export both CSVs. Edit profile gender/photo, cancel, save and relaunch.

This repository builds an iPhone IPA. Windows can download and sign it using the installation workflow; it cannot compile the SwiftUI app directly. There is no Android APK/AAB in this version. Notification sound and continuous operation remain subject to phone settings, device behaviour and iOS restrictions.
