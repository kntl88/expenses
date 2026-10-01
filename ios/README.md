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
- `pending: true` — a card payment (logged by the former Apple Pay automation) that still waits for a receipt or
  allocation. It already counts in its guessed category in the web app.

The home screen lists **Pending** payments and recent **Transactions**. Tap a row to expand its line items by category in place, with buttons to
scan/rescan the receipt, allocate or edit the split, confirm a pending payment, or delete a transaction (swipe left also deletes; a receipt split into categories is deleted as a whole) (pending rows can
also be swiped: right to confirm, left to scan or delete). A photo with several receipts is reviewed
and saved one receipt at a time. Scanning a receipt for a pending payment replaces
its row with itemized category rows. Older receipt splits without a `txId` are grouped by their shared
`created` timestamp, date and base description.

### Automatic receipt matching
Receipts, Wallet imports and card taps carry a paid time (`time`, HH:MM — an extra row field the web
app ignores; card taps give the exact time). A scanned receipt is auto-assigned to the pending
payment with the same total, same day ±1, closest time when both are known (within 2 h). Failing
that, it fills in a card tap still waiting for details from within 30 min of the receipt's printed
time, and the tap is cleared. Either can be changed in the review's "Replace existing" picker.

Back on Home the Consumption numbers change first; ~1 s later the settled pending payment swells
green with a checkmark, flies off, and the list closes up (`-demo -settle` plays it in the simulator).

## Lock screen button
The `ReceiptControls` widget extension (iOS 18+) adds a **Scan Receipt** control: long-press the
lock screen → Customize → Lock Screen → tap a bottom button slot (or add it in Control Center) →
search "Receipts". It runs `ScanReceiptIntent` (Shared/), which opens the app straight into the
camera. The same action is available in Shortcuts / the Action button. For the lock screen widget
row there's also a circular **Scan Receipt** widget (opens `receipts://scan`, since lock screen widgets
can't run intents).

## Wallet screenshot import (Back Tap)
Card details reach Wallet 30–60 min after paying, too late for the Shortcuts Transaction trigger, so
payments are imported from a screenshot of Wallet's transaction list instead:
1. Shortcuts → new shortcut: **Take Screenshot** → **Import Wallet Screenshot** (Receipts), with
   Screenshot connected to the Take Screenshot result (automatic when it follows Take Screenshot).
2. Settings → Accessibility → Touch → Back Tap → **Triple Tap** → that shortcut.
3. In Wallet, open the card's transactions and triple-tap the back of the phone.

Receipts opens on the screenshot with **Cancel / Import** first, so an accidental Back Tap never
reaches Claude. After Import, Claude reads the rows (relative dates like "Yesterday" resolved to dates). Each row
gets a category from your past naming of that merchant in the app's transactions, else Claude's guess.
Rows matching a transaction already in the app (same amount within 5 days), declined ones and refunds
start unchecked. **Add** saves the checked ones as pending card payments.

### Card taps waiting for details
Shortcuts → Automation → **Transaction** (your payment card only, Run Immediately) → **Register Card
Tap** (Receipts), with Merchant and Amount set to the Shortcut Input's Merchant / Amount (both
optional; usually empty at the tap). The tap is kept on the phone and listed on Home under
**Waiting for details** (tap a row to open Wallet, swipe to dismiss; dropped after 14 days). The
Wallet import pairs taps with payments (same day ±1, same amount/merchant when the tap has them),
shows "card tap HH:MM" on the row, and clears the tap once its payment is added or already in Receipts.

## Widgets
**Consumption** (home screen small/medium, lock screen rectangular/inline/circular): this week's
Saving (Basic+Fun+Unnec row), today's net, Forecast and the pending-payment count; the medium size
also lists Basic/Fun/Unnec/Total and has a Scan button. The app caches `expenses.json` +
`accounts.json` in the App Group `group.com.kntl88.ReceiptScanner` whenever it loads data; the widget recomputes `WeekSummary` from that cache (also at
midnight), so it needs no network or credentials.

After saving, the app returns straight to Home; the Consumption card keeps the old numbers for about
two seconds, then animates to the new ones.
