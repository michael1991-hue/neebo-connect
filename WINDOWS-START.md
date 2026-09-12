# iPhone testing from Windows

## 1. Build online
Create a PRIVATE GitHub repository named neebo-connect, initialized with a README.
Grant the ChatGPT GitHub connection access to it. Share its URL in the conversation.
The assistant can then add these prepared source and workflow files and inspect the build.

Alternatively, put all these files at the root of your repository, including
.github/workflows/iphone.yml. GitHub Actions runs build.sh on a macOS runner.
The workflow produces an unsigned IPA; the workflow itself contains no signing credentials.
Private repositories use your GitHub Actions allowance and may require Actions/billing to be enabled.
Do not upload NBO.txt or personal sensor logs to the repository.

## 2. Download the resulting app
After the workflow succeeds, open its Actions run and download NeeboConnect-unsigned.
Extract the downloaded ZIP to obtain NeeboConnect-unsigned.ipa.
This workflow has not run yet. Successful compilation is still required.

## 3. Sign and install from Windows
Use the official AltStore Classic Windows instructions:
https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows
Install AltServer and its required Apple components, connect the iPhone, and install AltStore Classic.
Transfer the IPA to Files on the iPhone; open AltStore Classic > My Apps > + and select the IPA.
Follow AltStore's own signing and Developer Mode steps. Enter credentials only in its official flow,
never in GitHub, the app source, workflow secrets, or this chat.
Free signing requires regular refreshes. This is a foreground research prototype, not a medical monitor.

## 4. Short test
Close LightBlue's connection. Test only when not relying on Neebo alerts.
Scan, select NB0, and run the two-minute capture with the prototype open.
If the original phone owns the connection, temporarily switch its Bluetooth off for the test.
Stop capture, share the JSONL file here, then restore the original phone and check readings resume.
Battery should be decoded; heart rate and oxygen must remain Not decoded.

Build source has been inspected locally but cannot be compiled in this Linux environment.
Hardware accuracy, iOS rendering, signing and actual BLE connection remain untested.
