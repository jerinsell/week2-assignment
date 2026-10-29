"""Build library.db from schema.sql and books.csv, then add made-up members and loans.

Usage:  python3 load_library.py
Running it again rebuilds library.db from scratch with the same data (fixed random seed).
"""
import csv
import random
import sqlite3
from datetime import date, timedelta
from pathlib import Path

HERE = Path(__file__).resolve().parent
DB = HERE / "library.db"
TODAY = date(2026, 10, 28)          # the day the sample data was generated
OPENED = date(2026, 1, 5)           # the library's first day
random.seed(5523)

# --- Books ---------------------------------------------------------------------------
# 25 titles from books.csv (by book_id), picked for a neighborhood library with kids,
# teens and adults. books.csv has no prices, so MSRP (list price) is set here.
BOOKS = {  # book_id: (msrp, copies)
    1: (12.99, 5),  2: (10.99, 5),  4: (18.99, 4),  5: (17.00, 3),  7: (14.99, 4),
    13: (9.99, 3), 14: (9.99, 2), 15: (8.99, 2), 16: (17.95, 2), 18: (12.99, 3),
    26: (9.99, 3), 28: (11.00, 2), 32: (12.00, 2), 35: (17.99, 3), 36: (10.99, 4),
    37: (8.99, 3), 41: (9.99, 4), 43: (12.00, 1), 47: (14.99, 3), 48: (17.99, 2),
    50: (19.99, 2), 54: (9.99, 2), 58: (10.00, 1), 59: (9.99, 4), 70: (9.99, 2),
}

# books.csv lumps every name into "authors". These are the people on our 25 books who
# are NOT the author, with the role they actually played. Everyone else is an author.
ROLES = {
    (2, "Mary GrandPré"): "illustrator",
    (13, "Erich Fromm"): "afterword",
    (13, "Celâl Üster"): "translator",
    (15, "Eleanor Roosevelt"): "introduction",
    (15, "B.M. Mooyaart-Doubleday"): "translator",
    (16, "Reg Keeland"): "translator",
    (18, "Mary GrandPré"): "illustrator",
    (18, "Rufus Beck"): "narrator",
    (35, "Alan R. Clarke"): "translator",
    (43, "Michael Mason"): "editor",
    (58, "John Seelye"): "introduction",
    (58, "Guy Cardwell"): "editor",
    (59, "Garth Williams"): "illustrator",
    (59, "Rosemary Wells"): "illustrator",
}

# --- Members: 25 past and present Tennessee Titans ----------------------------------
# Names are real players; birthdays, addresses, emails, phones and payment details are
# made up for this exercise. Phone numbers use the fictional 555-01xx range.
PLAYERS = [
    "Eddie George", "Derrick Henry", "Frank Wycheck", "Kevin Dyson", "Jevon Kearse",
    "Bruce Matthews", "Keith Bulluck", "Samari Rolle", "Kevin Mawae", "Chris Johnson",
    "Vince Young", "Derrick Mason", "Michael Roos", "Cortland Finnegan", "Jurrell Casey",
    "Delanie Walker", "Marcus Mariota", "Ryan Tannehill", "Kevin Byard", "A.J. Brown",
    "Taylor Lewan", "Jeffery Simmons", "Will Levis", "Calvin Ridley", "Blaine Bishop",
]
NEVER_BORROWED = "Blaine Bishop"     # required: one member with no loans
BIRTHDAY_TODAY = "Derrick Henry"     # shows up in birthday_emails_today on TODAY
STREETS = ["Belmont Blvd", "Music Row", "Charlotte Ave", "Granny White Pike", "Shelby Ave",
           "Woodland St", "Hillsboro Pike", "Gallatin Ave", "Elliston Pl", "12th Ave S",
           "Fatherland St", "Acklen Ave", "Natchez Trace", "Lealand Ln", "Riverside Dr"]
PLACES = [("Nashville", "37203"), ("Nashville", "37204"), ("Nashville", "37206"),
          ("Nashville", "37209"), ("Nashville", "37212"), ("Nashville", "37215"),
          ("Brentwood", "37027"), ("Franklin", "37067"), ("Antioch", "37013")]
CARDS = [("credit_card", "Visa"), ("credit_card", "Mastercard"), ("debit_card", "Visa"),
         ("credit_card", "American Express"), ("bank_account", "Pinnacle Bank")]


def iso(d):
    return d.isoformat() if d else None


def isbn13_from_isbn10(isbn10):
    """books.csv stores isbn13 in scientific notation (9.78043902348e+12), which has lost
    its last digit, so rebuild it from the ISBN-10: '978' + first 9 digits + check digit."""
    core = "978" + isbn10[:9]
    total = sum(int(d) * (1 if i % 2 == 0 else 3) for i, d in enumerate(core))
    return core + str((10 - total % 10) % 10)


def build():
    if DB.exists():
        DB.unlink()
    con = sqlite3.connect(DB)
    con.execute("PRAGMA foreign_keys = ON")
    con.executescript((HERE / "schema.sql").read_text())

    # Books and contributors
    rows = {int(r["book_id"]): r for r in csv.DictReader(open(HERE / "books.csv", encoding="utf-8"))}
    contributor_ids = {}
    for book_id, (msrp, _) in BOOKS.items():
        r = rows[book_id]
        year = r["original_publication_year"]
        isbn10 = r["isbn"].zfill(10)                                # restore leading zeros
        con.execute(
            "INSERT INTO books VALUES (?,?,?,?,?,?,?,?,?)",
            (book_id, int(r["goodreads_book_id"]), isbn10, isbn13_from_isbn10(isbn10),
             r["title"], r["original_title"] or None,
             int(float(year)) if year else None, r["language_code"] or None, msrp))
        for order, name in enumerate(n.strip() for n in r["authors"].split(",")):
            name = " ".join(name.split())                           # "Robert    Jackson"
            if name not in contributor_ids:
                contributor_ids[name] = con.execute(
                    "INSERT INTO contributors (name) VALUES (?)", (name,)).lastrowid
            con.execute("INSERT INTO book_contributors VALUES (?,?,?,?)",
                        (book_id, contributor_ids[name], ROLES.get((book_id, name), "author"), order + 1))

    # Copies, bought in the library's first two months (a few added later)
    copies = []  # (copy_id, book_id, acquired)
    for book_id, (_, n) in BOOKS.items():
        for i in range(n):
            acquired = OPENED + timedelta(days=random.randint(0, 55) if i < 3 else random.randint(60, 150))
            cond = random.choice(["new", "new", "good", "good", "fair"])
            cid = con.execute("INSERT INTO copies (book_id, acquired_date, condition) VALUES (?,?,?)",
                              (book_id, iso(acquired), cond)).lastrowid
            copies.append((cid, book_id, acquired))

    # Members and payment methods
    members = {}
    for i, full in enumerate(PLAYERS):
        first, last = full.split(" ", 1)
        if full == BIRTHDAY_TODAY:
            born = date(1994, TODAY.month, TODAY.day)
        else:
            born = date(random.randint(1970, 2000), random.randint(1, 12), random.randint(1, 28))
        city, zip_code = random.choice(PLACES)
        mid = con.execute(
            "INSERT INTO members (first_name,last_name,birth_date,email,phone,street,city,state,zip,joined_date)"
            " VALUES (?,?,?,?,?,?,?,?,?,?)",
            (first, last, iso(born),
             f"{first.lower().replace('.', '')}.{last.lower()}@example.com",
             f"615-555-01{i:02d}",
             f"{random.randint(100, 4999)} {random.choice(STREETS)}", city, "TN", zip_code,
             iso(OPENED + timedelta(days=random.randint(0, 40))))).lastrowid
        mtype, brand = random.choice(CARDS)
        con.execute(
            "INSERT INTO payment_methods (member_id,method_type,brand,last4,processor_token)"
            " VALUES (?,?,?,?,?)",
            (mid, mtype, brand, f"{random.randint(0, 9999):04d}", f"tok_demo_{mid:03d}_{random.getrandbits(32):08x}"))
        members[full] = mid

    # --- Borrowing history -----------------------------------------------------------
    # Walk each copy forward in time: sit on the shelf, get borrowed, come back
    # (usually on time, sometimes late), repeat. Popular titles sit on the shelf less.
    planned = []  # dicts: copy_id, out, type, back, lost
    lost_copy = next(c for c in copies if c[1] == 37)[0]   # one copy of Narnia gets lost
    for cid, book_id, acquired in copies:
        popularity = BOOKS[book_id][1]                       # more copies = more demand
        t = acquired
        n = 0
        while True:
            t += timedelta(days=random.randint(1, 60 - popularity * 8))
            if t >= TODAY:
                break
            ltype = "extended" if random.random() < 0.2 else "standard"
            due = t + timedelta(days=30 if ltype == "extended" else 14)
            if random.random() < 0.15:
                back = due + timedelta(days=random.randint(1, 25))        # late
            else:
                back = t + timedelta(days=random.randint(3, (due - t).days))
            n += 1
            if cid == lost_copy and n == 2:
                planned.append(dict(copy_id=cid, out=t, type="standard", back=None,
                                    lost=t + timedelta(days=35)))
                break
            planned.append(dict(copy_id=cid, out=t, type=ltype,
                                back=back if back < TODAY else None, lost=None))
            if back >= TODAY:
                break
            t = back

    # Guarantee one loan that is still out but not yet due, and one that is overdue.
    planned.sort(key=lambda l: l["out"])
    open_loans = [l for l in planned if l["back"] is None and l["lost"] is None]
    due = lambda l: l["out"] + timedelta(days=30 if l["type"] == "extended" else 14)
    if not any(due(l) < TODAY for l in open_loans):
        open_loans[0]["out"] = TODAY - timedelta(days=24)
    if not any(due(l) >= TODAY for l in open_loans):
        open_loans[-1]["out"] = TODAY - timedelta(days=3)

    # Hand each checkout to a member who has fewer than 5 books out on that day.
    borrowers = [m for name, m in members.items() if name != NEVER_BORROWED]
    for l in planned:
        end = lambda x: x["back"] or x["lost"] or date.max
        busy = {}
        for o in planned:
            if "member" in o and o["out"] <= l["out"] < end(o):
                busy[o["member"]] = busy.get(o["member"], 0) + 1
        l["member"] = random.choice([m for m in borrowers if busy.get(m, 0) < 5])

    # Replay events in date order (returns before checkouts on the same day) so the
    # database's own triggers enforce the rules and assess the fees.
    events = []
    for l in planned:
        events.append((l["out"], 1, "out", l))
        if l["back"]:
            events.append((l["back"], 0, "back", l))
        if l["lost"]:
            events.append((l["lost"], 0, "lost", l))
    for when, _, kind, l in sorted(events, key=lambda e: (e[0], e[1])):
        if kind == "out":
            l["id"] = con.execute(
                "INSERT INTO loans (copy_id, member_id, checkout_date, loan_type) VALUES (?,?,?,?)",
                (l["copy_id"], l["member"], iso(when), l["type"])).lastrowid
        elif kind == "back":
            con.execute("UPDATE loans SET returned_date = ? WHERE loan_id = ?", (iso(when), l["id"]))
        else:
            con.execute("UPDATE loans SET lost_date = ? WHERE loan_id = ?", (iso(when), l["id"]))

    # Most older fees have been paid with the member's card on file.
    for fee_id, member_id, assessed in con.execute(
            "SELECT fee_id, member_id, assessed_date FROM fees").fetchall():
        assessed = date.fromisoformat(assessed)
        if assessed < TODAY - timedelta(days=10) and random.random() < 0.8:
            pm = con.execute("SELECT payment_method_id FROM payment_methods WHERE member_id = ?",
                             (member_id,)).fetchone()[0]
            con.execute("UPDATE fees SET paid_date = ?, payment_method_id = ? WHERE fee_id = ?",
                        (iso(assessed + timedelta(days=random.randint(0, 7))), pm, fee_id))

    # Holds: one copy set aside and waiting for pickup, one member waiting in line,
    # one past hold that was picked up and one that expired.
    on_shelf = con.execute("SELECT copy_id, book_id FROM copy_status WHERE status = 'available'"
                           " ORDER BY copy_id").fetchall()
    hold_members = [members["Kevin Byard"], members["Will Levis"], members["Eddie George"],
                    members["Vince Young"]]
    cid, bid = on_shelf[0]
    con.execute("INSERT INTO holds (book_id,member_id,placed_date,copy_id,ready_date,expires_date,status)"
                " VALUES (?,?,?,?,?,?, 'ready')",
                (bid, hold_members[0], iso(TODAY - timedelta(days=6)), cid,
                 iso(TODAY - timedelta(days=2)), iso(TODAY + timedelta(days=5))))
    busy_title = con.execute("SELECT book_id FROM copy_status GROUP BY book_id"
                             " HAVING SUM(status = 'available') = 0 LIMIT 1").fetchone()
    if busy_title:
        con.execute("INSERT INTO holds (book_id,member_id,placed_date,status) VALUES (?,?,?, 'waiting')",
                    (busy_title[0], hold_members[1], iso(TODAY - timedelta(days=1))))
    con.execute("INSERT INTO holds (book_id,member_id,placed_date,copy_id,ready_date,expires_date,status)"
                " VALUES (1,?,'2026-05-02',1,'2026-05-06','2026-05-13','picked_up')", (hold_members[2],))
    con.execute("INSERT INTO holds (book_id,member_id,placed_date,copy_id,ready_date,expires_date,status)"
                " VALUES (7,?,'2026-08-10',?, '2026-08-12','2026-08-19','expired')",
                (hold_members[3], next(c[0] for c in copies if c[1] == 7)))

    con.commit()
    con.close()


if __name__ == "__main__":
    build()
    print(f"Built {DB.name}")
