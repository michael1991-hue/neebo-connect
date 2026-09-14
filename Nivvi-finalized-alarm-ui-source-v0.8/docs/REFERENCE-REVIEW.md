# Reference review and release gaps

Reviewed 13 September 2026. These sources informed structure and questions; their legal text, brand assets and clinical claims have not been copied into Nivvi.

- [TachyMon terms](https://www.whipdev.com/terms): app/platform licence structure and service limitations are relevant topics. The document uses Ontario law and broad liability exclusions; those are not a UK consumer contract template.
- [TachyMon privacy](https://www.whipdev.com/privacy): covers usage information, accounts and third parties, while saying the operator does not collect/store heart-rate data. Nivvi stores readings locally and supports child profiles, so its notice must distinguish local processing from operator receipt rather than repeat those statements.
- [TachyMon product page](https://www.whipdev.com/tachymon): a focused product page with legal/support access is a useful structural reference. It is not proof of another app's regulatory status or approval route.
- [BabySensor sales conditions](https://babysensor.co.uk/pages/salgsbetingelser): concerns goods/services, Norwegian rules and hardware returns. Its stated subscription arrangement ends unless extended; do not reuse it for a proposed auto-renewing mobile subscription.
- [BabySensor privacy](https://babysensor.co.uk/pages/privacy-policy): a purpose/data/retention table is useful. Its business activities, legal bases and retention periods are not Nivvi's.
- [ICO privacy-notice guidance](https://ico.org.uk/for-organisations/advice-for-small-organisations/privacy-notices-and-cookies/how-to-write-a-privacy-notice-and-what-goes-in-it/): identify controller/contact, actual data flows, purposes, lawful bases, recipients, retention and rights. Complete those decisions before publishing the draft.
- [CMA fair-contract guidance](https://www.gov.uk/guidance/writing-a-fair-contract-for-customers): consumer terms must be fair and transparent, rather than remove mandatory protections through disclaimers.
- [MHRA software guidance](https://www.gov.uk/government/publications/medical-devices-software-applications-apps): assess actual intended purpose. Renaming an app or describing it as general information does not establish medical-device exemption.

## Current implementation gaps relevant to privacy

The main history window is 30 calendar days; raw captures, export copies and retained migration backups are separate. Do not advertise that all information is automatically erased after 30 days. The app lacks a single delete-all-personal-data control. Profiles can be edited and photos removed, but complete local removal may require uninstalling, with backups handled separately.

No account, remote sharing, analytics, AI service or subscription code is installed. A website/email provider has not been configured. Operator identity, public contact information, special-category processing assessment and publication date remain missing. Legal drafts must stay marked as drafts until completed and reviewed.

## Scope of code review

Inspected the current Swift sources, regression suite, shell build, CI workflow, icon and sound generation scripts, icon asset and documentation. Renamed the app source and clean bundle identifier, removed embedded manufacturer references, corrected standard-service discovery, added standard frame/contact checks and retained the custom adapter with experimental labelling. The first version 0.5 build passed 88 regression checks and compiled successfully on macOS. A follow-up build pins the iPhone SDK for the linker as well as the Swift compiler. Final results are available from GitHub Actions. Physical-device and legal review remain separate release gates.
