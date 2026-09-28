# Receipts (iOS)

Native iPhone companion to the Expenses web app: scan a receipt, let Claude split it into
categories, review, and save the rows straight into `data/expenses.json` in the private data repo.

## Run
1. Open `ios/ReceiptScanner.xcodeproj` in Xcode 16+.
2. Target → Signing & Capabilities → pick your Team (bundle id `com.kntl88.ReceiptScanner`).
3. Run on your iPhone (the document camera doesn't work in the simulator; "Choose from Photos" does).

## First launch
- **Vault PIN**: the same PIN as the web app. The app fetches `data/vault.json` from this repo,
  decrypts it on-device (PBKDF2-SHA256 310k → AES-GCM, identical to `index.html`) and stores the
  GitHub token in the Keychain.
- **Anthropic API key**: stored in the Keychain.

## Flow
Scan (VisionKit, multi-page OK) or pick a photo → Claude (`claude-opus-5`, same prompt/schema as the
web app's receipt scan) → edit parts, date, description, account → optionally pick an existing
expense with the same amount (±10 days) to replace/split it → save. Rows use the web app's exact
shape (`id`, negative `amount`, `category`/`subCategory` via the same token mapping, `account`,
`created`), and the file is re-serialized byte-compatible with `JSON.stringify(x, null, 2)`.
Conflicts with concurrent web edits are handled by re-fetching and re-applying.

Project is generated from `project.yml` with XcodeGen (`cd ios && xcodegen`), but the generated
`.xcodeproj` is committed so XcodeGen isn't required.

## Card payments (Apple Pay automation)
The app exposes a **Log Card Payment** Shortcuts action (amount + merchant). It categorizes from your
own history for that merchant (weighted by euros), falls back to Claude for new merchants, applies
the "eating out < 5 € = basic" rule, and writes the expense with today's date and the default
account. If the network is down it queues the entry and syncs next time the app opens.

Setup (once):
1. Run the app once after installing so iOS registers the action.
2. Shortcuts → Automation → **+** → **Transaction** → choose your card(s) in Wallet → Run Immediately → Next.
3. **New Blank Automation** → add action **Log Card Payment** (Receipts app).
4. Tap *Amount* → select the magic variable **Shortcut Input** → change it to **Amount**.
   Tap *Merchant* → **Shortcut Input** → **Merchant**. Done.

Only Apple Pay taps trigger it (not the physical card or online payments). Scanning the receipt
later still works: the review screen offers the card entry under "Replace existing" (same amount).
