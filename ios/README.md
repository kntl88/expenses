# Receipts (iOS)

Native iPhone companion to the Expenses web app: scan a receipt, let Claude split it into
categories, review, and save the rows straight into `data/expenses.json` in the private data repo.

## Run
1. Open `ios/ReceiptScanner.xcodeproj` in Xcode 16+.
2. Target → Signing & Capabilities → pick your Team (bundle id `com.kntl88.ReceiptScanner`).
3. Run on your iPhone (the camera doesn't work in the simulator).

## First launch
- **Vault PIN**: the same PIN as the web app. The app fetches `data/vault.json` from this repo,
  decrypts it on-device (PBKDF2-SHA256 310k → AES-GCM, identical to `index.html`) and stores the
  GitHub token in the Keychain.
- **Anthropic API key**: stored in the Keychain.

## Week summary
The home screen shows the web app's **Consumption** card for the current week (Basic / Fun / Unnec /
Total, Gas, Purchases, with Saving and Forecast), computed from `expenses.json` + `accounts.json` by a
Swift port of `renderDailyRates` / `getBudgetBreakdown` (`WeekSummary.swift`). Tap combo cells to show
the per-day bar chart; pull down to refresh. Keep the two in sync if the web formula changes.

## Flow
Take a photo (used as-is, no auto-crop) → Claude (`claude-opus-5`) lists every line
item with a category (Basic by default) → items are grouped by category; tap an item's category to
move it → edit date, description, account → optionally pick an existing
expense with the same amount (±10 days) to replace/split it → save. Rows use the web app's exact
shape (`id`, negative `amount`, `category`/`subCategory` via the same token mapping, `account`,
`created`), and the file is re-serialized byte-compatible with `JSON.stringify(x, null, 2)`.
One expense row is written per category.

**Learning:** when a receipt is saved, every item you left in a non-Basic category is remembered
(name normalized, pack sizes ignored: "KOFF III 0,33L" ≈ "Koff III 0,5L"). Next time those items are
put in that category automatically (marked "learned"), and recent rules are also given to Claude so
similar items follow. Saving an item as Basic forgets its rule; Basic itself is never stored.
Rules live on the phone (Settings → Learned items, swipe to delete).

Conflicts with concurrent web edits are handled by re-fetching and re-applying.

Project is generated from `project.yml` with XcodeGen (`cd ios && xcodegen`), but the generated
`.xcodeproj` is committed so XcodeGen isn't required.

## Transactions, itemization and pending payments
`expenses.json` stays one row per category (so every web calculation keeps working), with optional
fields the web app ignores and preserves on edit:
- `txId` — rows from the same receipt/transaction share it; the phone shows them as one transaction.
- `items` — that row's receipt lines, `[{name, amount}]` (itemized transactions).
- `pending: true` — a card payment logged by the automation that still waits for a receipt or
  allocation. It already counts in its guessed category in the web app.

The home screen lists **Pending** payments (swipe right to confirm the guessed category, left to scan
the receipt or delete; tap for details/allocation) and recent **Transactions** (tap to see the
line items by category, rescan, or edit the split). Scanning a receipt for a pending payment replaces
its row with itemized category rows. Older receipt splits without a `txId` are grouped by their shared
`created` timestamp, date and base description.

## Card payments (Apple Pay automation)
The app exposes a **Log Card Payment** Shortcuts action (amount + merchant). It categorizes from your
own history for that merchant (weighted by euros), falls back to Claude for new merchants, applies
the "eating out < 5 € = basic" rule, and writes the expense as **pending** with today's date and the
default account. If the network is down it queues the entry and syncs next time the app opens.

Setup (once):
1. Run the app once after installing so iOS registers the action.
2. Shortcuts → Automation → **+** → **Transaction** → choose your card(s) in Wallet → Run Immediately → Next.
3. **New Blank Automation** → add action **Log Card Payment** (Receipts app).
4. Tap *Amount* → select the magic variable **Shortcut Input** → change it to **Amount**.
   Tap *Merchant* → **Shortcut Input** → **Merchant**. Done.

Only Apple Pay taps trigger it (not the physical card or online payments). Scanning the receipt
later still works: the review screen offers the card entry under "Replace existing" (same amount).
