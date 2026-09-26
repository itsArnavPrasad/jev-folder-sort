#!/bin/bash
# (Re)create a messy demo playground inside the repo: examples/demo/
#   Inbox/        messy files to sort (the watched folder)
#   Sorted/       destination root with a folder tree and a few already-sorted files
#   Untouchable/  decoys outside the scope — must never change
# Everything stays inside the repo; nothing touches your real folders.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
DEMO="$REPO/examples/demo"
rm -rf "$DEMO"
mkdir -p "$DEMO"/{Inbox,Untouchable}
mkdir -p "$DEMO"/Sorted/{"Finance/Taxes","Finance/Bank","Finance/Receipts","School/Lectures","School/Assignments","Work/Contracts","Work/Invoices","Pictures/Screenshots","Pictures/Photos",Apps,Code,Books,Travel}
cd "$DEMO"

txt() { printf '%b\n' "$2" > "$1"; }
pdf() { # real PDF with extractable text
  local tmp; tmp="$(mktemp -t jevdemo).txt"
  printf '%b\n' "$2" > "$tmp"
  cupsfilter "$tmp" > "$1" 2>/dev/null || cp "$tmp" "$1"
  rm -f "$tmp"
}
docx() { local tmp; tmp="$(mktemp -t jevdemo).txt"; printf '%b\n' "$2" > "$tmp"; textutil -convert docx "$tmp" -output "$1"; rm -f "$tmp"; }
img() { # real PNG/JPEG from a system icon
  local src=/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericDocumentIcon.icns
  sips -s format "$2" "$src" --out "$1" >/dev/null 2>&1 || : > "$1"
}

# --- messy Inbox
pdf Inbox/2025_W2_Acme.pdf "Form W-2 Wage and Tax Statement 2025\nEmployer: Acme Corp\nWages, tips, other compensation 84,210.00\nFederal income tax withheld 12,400.00"
pdf Inbox/1099-NEC_Upwork_2025.pdf "Form 1099-NEC 2025\nPayer: Upwork Global Inc.\nNonemployee compensation 14,220.00"
pdf Inbox/Chase_Statement_Aug2025.pdf "Chase Total Checking\nStatement period August 1 - August 31, 2025\nBeginning balance \$2,412.10\nEnding balance \$1,988.64"
pdf Inbox/order-112-4432110.pdf "Your order has shipped.\nInstant Pot Duo 6qt\nOrder Total: \$89.99\nAmazon.com"
pdf Inbox/Uber_receipt.pdf "Thanks for riding, Alex.\nTotal \$18.42\nTrip fare \$14.10\nBooking fee \$2.10"
pdf Inbox/Lecture_07_Dynamic_Programming.pdf "CS 161 Design and Analysis of Algorithms\nLecture 7: Dynamic programming, memoization, knapsack"
docx Inbox/ECON_essay_final_v2.docx "The effect of minimum wage policy on youth employment.\nIntroduction. Literature review. Method."
pdf Inbox/problem_set_3.pdf "Problem Set 3. Due Friday.\n1. Show that T(n) = 2T(n/2) + n is O(n log n)."
pdf Inbox/MSA_Brightwave_signed.pdf "Master Services Agreement between Alex Doe Design and Brightwave Inc.\nSigned by both parties."
pdf Inbox/INV-0042_Brightwave.pdf "INVOICE #0042\nBill to: Brightwave Inc.\nLogo design, 3 revisions\nTotal EUR 2,400.00. Due in 14 days."
pdf Inbox/Lisbon_Airbnb_confirmation.pdf "Reservation confirmed. Alfama loft, Lisbon. 3 nights. Check-in Oct 12."
pdf Inbox/boarding_pass_TAP.pdf "TAP Air Portugal. Boarding pass. Lisbon (LIS) to Berlin (BER). Seat 21A."
txt Inbox/scraper.py "import requests\nfrom bs4 import BeautifulSoup\n\ndef main():\n    html = requests.get('https://example.com').text\n    print(BeautifulSoup(html, 'html.parser').title)"
txt Inbox/docker-compose.yml "services:\n  db:\n    image: postgres:16\n    ports: ['5432:5432']"
img "Inbox/Screenshot 2025-09-26 at 09.12.44.png" png
img "Inbox/Screenshot 2025-09-27 at 18.03.10.png" png
img Inbox/IMG_4471.jpg jpeg
img Inbox/PXL_20250713_184455123.jpg jpeg
: > Inbox/Raycast.dmg
: > Inbox/Docker.dmg
: > "Inbox/Atomic Habits - James Clear.epub"
: > Inbox/Unknown.bin
txt Inbox/notes.txt "buy milk, call mom"
: > Inbox/movie.mp4.crdownload          # in-progress download: must be skipped
mkdir -p Inbox/Old\ Stuff && txt "Inbox/Old Stuff/nested.pdf" "nested file: must not be touched"
txt Inbox/.hidden_config "hidden: must not be touched"

# --- a few files already sorted (used to bootstrap learning)
pdf Sorted/Finance/Taxes/2024_W2_Acme.pdf "Form W-2 Wage and Tax Statement 2024\nEmployer: Acme Corp"
pdf Sorted/Finance/Bank/Chase_Statement_Jul2025.pdf "Chase Total Checking\nStatement period July 2025"
pdf Sorted/Finance/Receipts/apple_store_receipt.pdf "Apple Store. AirPods Pro. Total \$249.00"
pdf Sorted/School/Lectures/Lecture_06_Greedy.pdf "CS 161 Lecture 6: Greedy algorithms"
pdf Sorted/Work/Invoices/INV-0041_Solace.pdf "INVOICE #0041\nBill to: Solace Coffee\nTotal EUR 1,200.00"
txt Sorted/Code/utils.py "def slugify(s):\n    return s.lower().replace(' ', '-')"

# --- decoys outside the scope
txt Untouchable/do_not_move_W2.txt "Form W-2 decoy outside the scope"
img Untouchable/decoy_screenshot.png png

echo "Demo ready at $DEMO"
echo "  watch:  $DEMO/Inbox"
echo "  root:   $DEMO/Sorted"
