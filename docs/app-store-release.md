# Publishing HelloLetter on the App Store

Last updated: 15 November 2026. Plan: an **individual** Apple Developer account, a **free** app with no purchases, **iPhone only** for version 1. The listing text is in [app-store-listing.md](app-store-listing.md).

Rules and laws change; check each point against Apple's current documents before submitting. This is not legal advice.

## Decisions

| | Choice | Why |
|---|---|---|
| Account | Individual ($99 a year) | Simplest. The App Store shows the developer's **legal name** as seller; the code and repository stay name-free. The app can move to a company account later with an App Store app transfer. |
| Price | Free, no in-app purchases | A mesh only works if everyone in a group installs it. Free also means **non-trader** under the EU Digital Services Act, so no address, phone or email is shown. |
| Platforms | iPhone first | One listing and one review. The Mac app ships as a zip (`make mac-zip`) until a Mac App Store release. |
| Name | HelloLetter | Friendly and non-technical. No App Store app or trademark found in web checks; passes a spoken "radio check". "Letterbox" was dropped because of the Letterboxd trademark. |

## What the app already has

| App Review asks for | HelloLetter |
|---|---|
| Filter objectionable content (guideline 1.2) | Offensive words masked on the phone, on by default |
| Report objectionable content (1.2) | Touch and hold → Report… blocks at once and offers an email report |
| Block abusive users (1.2) | Report, or Block on a person's page |
| Published contact (1.2) | Settings → Help and safety, and the support page |
| Privacy policy in the app (5.1.1) | Help and safety → Privacy policy |
| Privacy manifest | `PrivacyInfo.xcprivacy`: no tracking, no data collected |
| No internet chat in the store build | Location channels are left out of Release builds |
| Original icon, no transparency | `Assets.xcassets/AppIcon` |
| Accessibility | Apple's audit passes on every screen in the UI tests |

## Steps

### 1. Accounts (you)
1. Enrol in the [Apple Developer Program](https://developer.apple.com/programs/enroll/) as an **individual** with your Apple ID. Apple verifies your identity; allow 1–2 days.
2. Create a **support mailbox** just for the app (for example on Proton). Don't use your personal address, and not a gmail.com one either: the repository's privacy hook blocks those, and this address is published.
3. In [App Store Connect](https://appstoreconnect.apple.com):
   - **Apps → + → New App**: name **HelloLetter**, bundle ID `app.helloletter`, language English, SKU `helloletter`. This reserves the name and is the definitive check that it's free.
   - **Business**: set the trader status to **not a trader**.
4. Optional but wise: search [USPTO](https://tmsearch.uspto.gov), [EUIPO](https://euipo.europa.eu/eSearch/) and the Polish patent office (UPRP) for HELLOLETTER before investing in the brand.

### 2. Build settings (developer machine)
1. In `Makefile.local` (never committed):
   ```make
   DEVELOPMENT_TEAM := <your paid team ID>
   SUPPORT_EMAIL := <the support mailbox>
   ```
2. Put the support address on the support page (`docs/support.md`, Contact) so it's on the public support URL.
3. Once the name is reserved: rename the repository to `helloletter` and update the links in `SupportContact` and `ShareText.inviteLink`, and the URLs in [app-store-listing.md](app-store-listing.md).

### 3. TestFlight
1. `make archive-ios` archives the Release build and uploads it with `Config/ExportOptions.plist`. Xcode Organizer (Product → Archive) works too.
2. In App Store Connect → TestFlight, test it on your iPhone (internal testing).
3. Add an **external** group with a public link, so friends install without a cable. The first external build needs a short beta review.
4. Real-device checks from the [release checklist](gap-analysis.md#release-checklist): two phones chatting, lock-screen alerts, Bluetooth off and on, background relaunch, and, if possible, an envelope across three phones.

### 4. Store listing and submission
1. Paste the text from [app-store-listing.md](app-store-listing.md).
2. Upload screenshots from `build/screenshots/` (6.9-inch, 1320×2868).
3. **App privacy:** Data Not Collected.
4. **Age rating:** answer the questionnaire honestly (chat with strangers, so expect a teen or higher rating). Check Apple's notice on apps distributed in Texas first.
5. **Encryption:** Yes, standard algorithms. Leave **France** out until the ANSSI declaration is filed.
6. **Availability:** everywhere except **China mainland**.
7. **Review notes and a demo video** (two phones, airplane mode): text in the listing doc.
8. Submit; review usually takes 1–3 days. Choose **manual release**, so you publish when ready.

## After launch
- Keep the support mailbox answered: App Review expects reports handled promptly.
- Every update needs a higher build number; `ExportOptions.plist` lets Xcode manage it.
- A tip jar can be added later with in-app purchases. It makes you a trader in the EU (contact details shown; a P.O. box works) and needs the paid-apps agreement.
