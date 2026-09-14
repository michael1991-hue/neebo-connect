# Privacy disclosure audit — 0.9.4

Scope: the three Swift source files and current bundled-resource build. No third-party runtime SDK was found. This is a code audit, not a network trace of the signed release.

| Data/use | Current implementation | Disclosure implication |
| --- | --- | --- |
| Profile, photo, HR, oxygen, notes, events | Stored in the app container/preferences | Sensitive local information; explain retention and controls |
| Sleep state/time | Parent-entered preferences and event log | Include in privacy notice; not inferred from sensors |
| Bluetooth identifier and limits | UserDefaults | Required-reason API manifest declares CA92.1, own-app preferences |
| Manual diagnostic capture | Local packet/status log | Not automatically sent; separately retained and can be shared |
| Exports/share sheet | User selects recipient/service | Review disclosure if support starts receiving these routinely |
| Network backend / analytics / advertising / tracking | Not implemented in inspected app | No tracking domains or developer-collected types declared in this manifest |
| Website/email/Apple distribution | Separate services, not configured by this revision | Final disclosure depends on actual providers and practices |

`apple/PrivacyInfo.xcprivacy` covers the inspected app code. Verify the archive contains it. Re-audit any SDK, analytics, account, payment, remote sharing or diagnostic upload before adding it.

Apple defines collection in terms of data transmitted off-device and accessible to the developer or partners. Local storage alone is not collection for its label. Do not blindly choose “Data Not Collected”: check the final signed binary, support intake and each optional-disclosure condition before submitting the form. TestFlight/OS handling should be distinguished from app-operated collection.

Audit UserDefaults and AppStorage against [required-reason APIs](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api), and final disclosures against [App privacy details](https://developer.apple.com/app-store/app-privacy-details/). The App Store label and UK GDPR assessment are different obligations. Where the operator processes health information, document the applicable Article 6 basis and Article 9 condition; see [ICO guidance](https://ico.org.uk/for-organisations/uk-gdpr-guidance-and-resources/lawful-basis/special-category-data/what-are-the-rules-on-special-category-data/).
