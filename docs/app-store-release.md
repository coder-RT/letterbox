# Publishing Letterbox on the App Store

Last updated: 2026-11-15. Plan: publish through a partner company's Apple Developer **organization** account, so the company is the seller shown on the App Store.

Rules and laws change; check each point against Apple's current documents before submitting. This is not legal advice.

## What the app already has

| App Review asks for | Letterbox | Where |
|---|---|---|
| Filter objectionable content (guideline 1.2) | Offensive words masked on the phone, on by default | Settings → Help and safety → Hide offensive words (`ContentFilter`) |
| Report objectionable content (1.2) | Touch and hold a message → **Report…**: blocks the sender (or hides the message if the sender can't be identified), and offers an email report to the support address | `ChatScreen`, `ReportText` |
| Block abusive users (1.2) | Report, or **Block** on a person's page | `ChatStore.block` |
| Published contact (1.2) | Help and safety → Email the Letterbox team, Website | `HelpView`; the address is set per build (below) |
| Privacy manifest | `PrivacyInfo.xcprivacy`: no tracking, no data collected | `Letterbox/PrivacyInfo.xcprivacy` |
| No accounts, no data collection | Nothing leaves the phone except Bluetooth traffic; no server | – |
| Release build without internet chat | Location channels are left out of Release builds | `LETTERBOX_LOCATION_CHANNELS` in `project.yml` |
| Original app icon | Yes; SF Symbols aren't used in it | `Assets.xcassets/AppIcon` |
| Accessibility | Apple's audit passes on every screen in the UI tests | `LetterboxUITests` |

## Steps

### 1. The company (partner)
1. Enrol in the Apple Developer Program as an **organization**: a D-U-N-S number, a website, and someone who can sign for the company. If the company already has an account, use it.
2. Invite the developer's own Apple ID to the team as **Admin** or **App Manager**.
3. Agree in writing: the developer owns the code and the app; the company publishes it on their behalf and transfers it to the developer's account on request; who pays the yearly fee.
4. Set up a support address on the company's domain (for example `letterbox@company-domain`). In India, the company should also publish a grievance contact as the IT Rules require. Check with the company's adviser.

### 2. The build (developer)
1. In `Makefile.local` (not in git):
   ```make
   DEVELOPMENT_TEAM := <the company's team ID>
   SUPPORT_EMAIL := <the support address>
   ```
   Then `make gen`. Without `SUPPORT_EMAIL`, Report still blocks but offers no email, and Help shows only the website.
2. **Pick a new name.** "Letterboxd" is a registered trademark for software and a well-known app; a confusingly similar name invites a complaint. Change `CFBundleDisplayName` and the store name together.
3. **Bundle ID.** `app.letterbox` was registered by a free personal team; if the company's team can't claim it, choose one under the company (without anyone's personal name).
4. Archive the **Release** configuration (location channels off) and upload it with Xcode.

### 3. App Store Connect
1. **Privacy policy URL** and **support URL**: [`privacy-policy.md`](privacy-policy.md) and [`support.md`](support.md), published with GitHub Pages at `https://coder-rt.github.io/letterbox/privacy-policy` and `/support`. The app links to both from Help and safety, as guideline 5.1.1 requires. The privacy label is "Data Not Collected". If the company wants its name and address in the policy, add them to "Who we are".
2. **Age rating:** answer the questionnaire honestly. It's chat with strangers, so expect a high rating. Check Apple's notice on apps distributed in Texas and the Declared Age Range API.
3. **Encryption:** answer **Yes** (Noise and ChaCha20-Poly1305, not only Apple's built-in encryption). For **France**, file the ANSSI declaration or leave France out until it's done.
4. **Availability:** leave out **China** (Apple removed bitchat there in 2026 at the government's request, and China needs an ICP filing).
5. **EU trader status:** the company declares it. If it's a trader, its D-U-N-S address, phone and email are shown on EU listings.
6. **Screenshots:** `make ui-test` saves light, dark and largest-text screenshots of every screen.
7. **Review notes:**
   - Letterbox is offline peer-to-peer chat over Bluetooth, with no server or accounts.
   - Reviewers with one device see an empty #nearby that explains itself. Attach a short video of two phones chatting.
   - **Safety:** an on-device word filter, Report (blocks immediately; optional email report), Block, and contact details in Help and safety. There's no server to moderate, and a report takes effect on the reporter's phone at once.
   - The Bluetooth background modes keep the mesh reachable with the phone locked.

### 4. TestFlight first
Invite friends through TestFlight before release. It also solves installing on phones you can't plug into the Mac.
