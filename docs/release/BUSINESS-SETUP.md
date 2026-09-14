# Operator, domain and support setup

Prepared configuration; no domain purchased, mailbox created or Apple enrolment performed.

## Information the owner must supply

Legal operator/entity name; service address; launch countries; owned/preferred domain; Apple Developer membership status and team. Do not paste passwords, recovery codes, private keys or payment details into chat.

Apple's [enrolment guidance](https://developer.apple.com/programs/enroll/) describes organisation verification, authority, D-U-N-S and domain email requirements. Confirm the appropriate legal-entity route for the app's sensitive health use under [review guideline 5.1.1](https://developer.apple.com/app-store/review/guidelines/). Paying for a developer membership does not approve the app or its medical claims.

## Proposed email configuration

On the domain the owner selects and owns, create a monitored `support@` mailbox and a `privacy@` alias routed to it. These are proposed addresses, not active addresses. Use MFA and restricted access; publish the actual response hours. Do not present support as emergency assistance.

After selecting an email provider, use its exact MX, SPF and DKIM values. Publish one valid SPF record; set DMARC according to the provider's guidance, verify delivery and authentication, and test inbound/outbound messages before publishing the address. DNS values cannot be completed until the provider and domain are known.

Proposed support policy for approval: avoid requesting identifiable health attachments by default; remove unnecessary sensitive attachments promptly; review routine resolved tickets for deletion after 90 days unless a documented legal/security reason requires longer. This is a proposed operating policy, not an existing guarantee. Confirm provider location, processors, transfer safeguards and actual retention settings before finalising the privacy notice.

## Website content plan

Publish `/support`, `/privacy`, `/terms` and `/compatibility` on an owned HTTPS domain, with an operator/contact footer and effective dates. The accompanying drafts provide the copy. Add the real provider/logging details and remove all placeholders before publication. No advertising or analytics is needed for the initial support website.

Use current app screenshots with fictional data. Preserve licences for every font, image, icon and sound. Check Nivvi as a trademark in target markets before treating the name as cleared. Do not use third-party logos or claim endorsement. Compatibility descriptions should be factual and tested.

## Before charging

No subscription exists in this build. A paid release needs an implemented and tested purchasing/restoration flow, actual pricing/trial/cancellation disclosures, Apple financial agreements and a support/refund process. Do not advertise £6.99 as a currently available service. Assess consumer and medical-device obligations for the intended product before taking payment.
