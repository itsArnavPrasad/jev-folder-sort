"""Held-out eval: can the model follow plain-English folder descriptions?

Folder names here carry little or no meaning ("Box 1", a person's name, a
project code); the description is the only way to know what belongs where.
Descriptions are written the way a person would type them, not in the
generator's vocabulary. Never used for training or checkpoint selection.
"""

from __future__ import annotations

TREES: dict[str, list[tuple[str, str]]] = {
    "boxes": [
        ("Box 1", "anything to do with money I owe or paid: bills, receipts, bank stuff"),
        ("Box 2", "government and tax paperwork, IRS letters, tax forms"),
        ("Box 3", "stuff for my university courses: slides, homework, exams"),
        ("Box 4", "pictures I took with my phone"),
        ("Box 5", "screen grabs"),
        ("Box 6", "programs to install"),
        ("Box 7", "my job hunt: CVs, cover letters, offers"),
    ],
    "people": [
        ("Maya", "everything for my daughter Maya: school letters, report cards, her doctor visits"),
        ("Leo", "my son's football club, match schedules and his swimming lessons"),
        ("House", "the flat: rent, lease, electricity and water bills, repairs"),
        ("Car", "the car: insurance, servicing, parking fines"),
        ("Holidays", "trips we are planning: flights, hotels, tickets"),
        ("Kitchen", "recipes and meal plans"),
    ],
    "codes": [
        ("P-17", "client Brightwave — contracts, invoices and briefs for them"),
        ("P-22", "client Solace Coffee — everything about their rebrand"),
        ("ADM", "my own freelance admin: my taxes, my insurance, accounting"),
        ("LIB", "articles and books I want to read later"),
        ("SRC", "source code and scripts"),
    ],
}

FILES: dict[str, list[tuple[str, str, str, list[str]]]] = {
    "boxes": [
        ("Verizon_bill_Aug.pdf", "Verizon Wireless. Your bill for August. Amount due $84.12.", "", ["Box 1"]),
        ("Target receipt.pdf", "Target. Thank you for shopping. Total $42.17. VISA ending 1123.", "", ["Box 1"]),
        ("Wells_Fargo_Sept.pdf", "Wells Fargo Everyday Checking. Statement period Sep 1-30.", "", ["Box 1"]),
        ("IRS_CP2000_notice.pdf", "Department of the Treasury Internal Revenue Service. Notice CP2000. Proposed changes to your tax return.", "", ["Box 2"]),
        ("fw4_2026.pdf", "Form W-4 Employee's Withholding Certificate 2026.", "", ["Box 2"]),
        ("1098-T_2025.pdf", "Form 1098-T Tuition Statement 2025. Payments received for qualified tuition.", "", ["Box 2", "Box 3"]),
        ("ORGO_lecture14.pdf", "Organic Chemistry Lecture 14: Aldehydes and ketones. Nucleophilic addition.", "", ["Box 3"]),
        ("hw5_linear_algebra.pdf", "Math 54 Homework 5. Due Wednesday. Find the eigenvalues.", "", ["Box 3"]),
        ("midterm2_review.pdf", "Midterm 2 review sheet. Topics covered. Practice problems.", "", ["Box 3"]),
        ("IMG_9031.HEIC", "", "", ["Box 4"]),
        ("PXL_20260402_171203344.jpg", "", "", ["Box 4"]),
        ("Screenshot 2026-04-02 at 10.11.12 AM.png", "", "", ["Box 5"]),
        ("CleanShot 2026-03-30 at 22.01.44.png", "", "", ["Box 5"]),
        ("VLC-3.0.21-arm64.dmg", "", "https://get.videolan.org", ["Box 6"]),
        ("NordVPN.pkg", "", "", ["Box 6"]),
        ("Resume_Jordan_Lee_2026.pdf", "Jordan Lee. Data Analyst. Experience. SQL, Tableau, Python.", "", ["Box 7"]),
        ("cover_letter_spotify.docx", "Dear hiring team at Spotify, I would love to join as a Data Analyst.", "", ["Box 7"]),
        ("offer_letter_final.pdf", "We are delighted to offer you the role of Analyst. Start date. Base salary.", "", ["Box 7"]),
        ("random_notes.txt", "remember to water plants", "", ["NONE"]),
        ("tmp.bin", "", "", ["NONE"]),
    ],
    "people": [
        ("Maya_report_card_T1.pdf", "Oakwood Primary. Maya Patel. Term 1 report. Reading: excellent.", "", ["Maya"]),
        ("school_trip_consent.pdf", "Year 3 trip to the Science Museum. Please sign and return for Maya.", "", ["Maya"]),
        ("GP_letter_Maya.pdf", "Dr. Ahmed. Maya's asthma review. Continue inhaler twice daily.", "", ["Maya"]),
        ("U10_fixtures_spring.pdf", "Under-10s spring fixtures. Saturday home match 10am. Leo Patel squad list.", "", ["Leo"]),
        ("swim_lessons_invoice.pdf", "Aquatics centre. Swimming lessons for Leo. Term fee £96.", "", ["Leo"]),
        ("tenancy_agreement_2026.pdf", "Assured shorthold tenancy agreement. Monthly rent £1,450. Flat 4.", "", ["House"]),
        ("octopus_energy_march.pdf", "Octopus Energy. Your electricity statement for March. £61.20.", "", ["House"]),
        ("thames_water_bill.pdf", "Thames Water. Water and sewerage charges. Amount due.", "", ["House"]),
        ("boiler_repair_quote.pdf", "Quote for boiler repair. Replace diverter valve. £240 incl. VAT.", "", ["House"]),
        ("car_insurance_2026.pdf", "Admiral. Your car insurance schedule. Ford Fiesta. Annual premium £512.", "", ["Car"]),
        ("MOT_certificate.pdf", "MOT test certificate. Vehicle passed. Odometer reading 48,211.", "", ["Car"]),
        ("PCN_notice.pdf", "Penalty Charge Notice. Parking contravention. Pay £35 within 14 days.", "", ["Car"]),
        ("easyJet_booking_LGW_NCE.pdf", "easyJet booking confirmation. London Gatwick to Nice. 4 passengers.", "", ["Holidays"]),
        ("Airbnb_Nice_house.pdf", "Your trip to Nice. Villa with pool. Check-in 12 August.", "", ["Holidays"]),
        ("louvre_tickets.pdf", "Musée du Louvre. E-tickets. Timed entry 10:30.", "", ["Holidays"]),
        ("weekly_meal_plan.xlsx", "Monday,Tuesday,Wednesday\nPasta,Tacos,Curry", "", ["Kitchen"]),
        ("shakshuka.txt", "Shakshuka: 6 eggs, tomatoes, peppers, cumin. Simmer 10 minutes.", "", ["Kitchen"]),
        ("IMG_2210.HEIC", "", "", ["NONE"]),
        ("mystery_download.zip", "", "", ["NONE"]),
    ],
    "codes": [
        ("Brightwave_SOW_v2.pdf", "Statement of Work. Brightwave Inc. Website redesign. Fees.", "", ["P-17"]),
        ("INV-0107_Brightwave.pdf", "Invoice 0107. Bill to Brightwave Inc. Amount due €3,200.", "", ["P-17"]),
        ("brightwave_brief_q3.docx", "Brief: Brightwave Q3 landing pages. Audience. Tone.", "", ["P-17"]),
        ("Solace_rebrand_moodboard.pdf", "Solace Coffee rebrand. Moodboard. Warm earthy palette.", "", ["P-22"]),
        ("solace_logo_v4.svg", "", "", ["P-22"]),
        ("INV-0108_Solace.pdf", "Invoice 0108. Bill to Solace Coffee. Brand identity phase 2.", "", ["P-22"]),
        ("quarterly_estimated_tax.pdf", "Estimated tax payment voucher. Quarter 2. Self-employed.", "", ["ADM"]),
        ("PI_insurance_renewal.pdf", "Professional indemnity insurance renewal for freelancers.", "", ["ADM"]),
        ("bookkeeping_2026.xlsx", "Date,Description,Income,Expense\n2026-01-03,Brightwave,3200,", "", ["ADM"]),
        ("The_Mom_Test.epub", "", "", ["LIB"]),
        ("longread_attention_economy.pdf", "The attention economy. A long read on how apps compete for our time.", "", ["LIB"]),
        ("deploy.sh", "#!/bin/bash\nset -e\nrsync -av dist/ server:/var/www", "", ["SRC"]),
        ("api.ts", "import express from 'express'\nconst router = express.Router()", "", ["SRC"]),
        ("vacation_photo.jpg", "", "", ["NONE"]),
    ],
}
