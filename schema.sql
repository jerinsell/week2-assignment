-- schema.sql
-- Neighborhood library database (MSAI-5523, Module 2)
-- Build with:  sqlite3 library.db < schema.sql
-- Foreign keys are only enforced when a connection runs: PRAGMA foreign_keys = ON;

PRAGMA foreign_keys = ON;

------------------------------------------------------------------------
-- BOOKS AND THE PEOPLE WHO MADE THEM
------------------------------------------------------------------------

-- One row per title (a "work"), not per physical copy.
CREATE TABLE books (
    book_id           INTEGER PRIMARY KEY,          -- same id as books.csv
    goodreads_book_id INTEGER UNIQUE,
    isbn              TEXT,                         -- TEXT so leading zeros survive
    isbn13            TEXT,
    title             TEXT    NOT NULL,
    original_title    TEXT,
    publication_year  INTEGER,
    language_code     TEXT,
    msrp              NUMERIC NOT NULL CHECK (msrp > 0)  -- replacement fee if a copy is lost
);

-- One row per person, no matter how many books they worked on.
CREATE TABLE contributors (
    contributor_id INTEGER PRIMARY KEY,
    name           TEXT NOT NULL UNIQUE
);

-- Many-to-many: a book has many contributors, a contributor works on many books.
-- Illustrators, translators, etc. are kept, but with their role, so they are not
-- mistaken for authors.
CREATE TABLE book_contributors (
    book_id        INTEGER NOT NULL REFERENCES books(book_id),
    contributor_id INTEGER NOT NULL REFERENCES contributors(contributor_id),
    role           TEXT    NOT NULL CHECK (role IN
                     ('author','illustrator','translator','editor',
                      'introduction','afterword','narrator')),
    credit_order   INTEGER NOT NULL DEFAULT 1,      -- order as printed on the book
    PRIMARY KEY (book_id, contributor_id, role)
);

-- One row per physical copy on the shelf. A title can have 1 to 5 copies.
CREATE TABLE copies (
    copy_id        INTEGER PRIMARY KEY,
    book_id        INTEGER NOT NULL REFERENCES books(book_id),
    acquired_date  TEXT    NOT NULL,                -- ISO date, YYYY-MM-DD
    condition      TEXT    NOT NULL DEFAULT 'good'
                     CHECK (condition IN ('new','good','fair','poor')),
    lost_date      TEXT,                            -- set when a borrower loses it
    withdrawn_date TEXT                             -- set when the library retires it
);

------------------------------------------------------------------------
-- MEMBERS AND HOW THEY PAY
------------------------------------------------------------------------

CREATE TABLE members (
    member_id   INTEGER PRIMARY KEY,
    first_name  TEXT NOT NULL,
    last_name   TEXT NOT NULL,
    birth_date  TEXT NOT NULL,                      -- drives age group and birthday email
    email       TEXT NOT NULL UNIQUE,
    phone       TEXT,
    street      TEXT NOT NULL,
    city        TEXT NOT NULL,
    state       TEXT NOT NULL DEFAULT 'TN',
    zip         TEXT NOT NULL CHECK (length(zip) = 5), -- TEXT so 02134 stays 02134
    joined_date TEXT NOT NULL
);

-- The library never stores a full card or account number: only what is needed to
-- recognize the method, plus a token from the payment processor that charges it.
CREATE TABLE payment_methods (
    payment_method_id INTEGER PRIMARY KEY,
    member_id         INTEGER NOT NULL REFERENCES members(member_id),
    method_type       TEXT    NOT NULL CHECK (method_type IN ('credit_card','debit_card','bank_account')),
    brand             TEXT,                         -- Visa, Mastercard, bank name...
    last4             TEXT    NOT NULL CHECK (length(last4) = 4),
    processor_token   TEXT    NOT NULL UNIQUE,
    is_default        INTEGER NOT NULL DEFAULT 1 CHECK (is_default IN (0,1))
);

------------------------------------------------------------------------
-- BORROWING
------------------------------------------------------------------------

-- One row per checkout of one copy by one member.
-- Standard loans are 14 days; an extended loan (30 days) must be chosen at checkout,
-- so the due date is calculated by the database and the loan type cannot be changed.
CREATE TABLE loans (
    loan_id       INTEGER PRIMARY KEY,
    copy_id       INTEGER NOT NULL REFERENCES copies(copy_id),
    member_id     INTEGER NOT NULL REFERENCES members(member_id),
    checkout_date TEXT    NOT NULL,
    loan_type     TEXT    NOT NULL DEFAULT 'standard' CHECK (loan_type IN ('standard','extended')),
    due_date      TEXT GENERATED ALWAYS AS (
                    date(checkout_date, CASE loan_type WHEN 'extended' THEN '+30 days'
                                                       ELSE '+14 days' END)) STORED,
    returned_date TEXT,
    lost_date     TEXT,
    CHECK (returned_date IS NULL OR returned_date >= checkout_date),
    CHECK (lost_date IS NULL OR lost_date >= checkout_date),
    CHECK (returned_date IS NULL OR lost_date IS NULL)
);

-- A copy can only be out with one person at a time.
CREATE UNIQUE INDEX one_open_loan_per_copy
    ON loans(copy_id) WHERE returned_date IS NULL AND lost_date IS NULL;
CREATE INDEX loans_by_member ON loans(member_id);

-- A member asks for a title; when a copy comes back it is set aside for them
-- (copy_id + ready_date) and held for up to 7 days.
CREATE TABLE holds (
    hold_id      INTEGER PRIMARY KEY,
    book_id      INTEGER NOT NULL REFERENCES books(book_id),
    member_id    INTEGER NOT NULL REFERENCES members(member_id),
    placed_date  TEXT    NOT NULL,
    copy_id      INTEGER REFERENCES copies(copy_id),
    ready_date   TEXT,
    expires_date TEXT,
    status       TEXT    NOT NULL DEFAULT 'waiting'
                   CHECK (status IN ('waiting','ready','picked_up','expired','cancelled')),
    CHECK (expires_date IS NULL OR
           julianday(expires_date) - julianday(ready_date) BETWEEN 0 AND 7)
);

-- Late fees and lost-book replacement fees. Each fee belongs to one loan.
CREATE TABLE fees (
    fee_id            INTEGER PRIMARY KEY,
    member_id         INTEGER NOT NULL REFERENCES members(member_id),
    loan_id           INTEGER NOT NULL REFERENCES loans(loan_id),
    fee_type          TEXT    NOT NULL CHECK (fee_type IN ('late','lost')),
    amount            NUMERIC NOT NULL CHECK (amount > 0),
    assessed_date     TEXT    NOT NULL,
    paid_date         TEXT,
    payment_method_id INTEGER REFERENCES payment_methods(payment_method_id),
    CHECK (paid_date IS NULL OR payment_method_id IS NOT NULL)
);

------------------------------------------------------------------------
-- BUSINESS RULES (triggers)
------------------------------------------------------------------------

-- No more than 5 copies of one title.
CREATE TRIGGER max_five_copies
BEFORE INSERT ON copies
WHEN (SELECT COUNT(*) FROM copies WHERE book_id = NEW.book_id) >= 5
BEGIN
    SELECT RAISE(ABORT, 'The library keeps at most 5 copies of a title');
END;

-- No more than 5 books out at once per member.
CREATE TRIGGER max_five_loans
BEFORE INSERT ON loans
WHEN (SELECT COUNT(*) FROM loans
      WHERE member_id = NEW.member_id
        AND returned_date IS NULL AND lost_date IS NULL) >= 5
BEGIN
    SELECT RAISE(ABORT, 'A member may only have 5 books checked out at a time');
END;

-- A lost or withdrawn copy cannot be checked out.
CREATE TRIGGER no_loan_of_missing_copy
BEFORE INSERT ON loans
WHEN (SELECT lost_date IS NOT NULL OR withdrawn_date IS NOT NULL
      FROM copies WHERE copy_id = NEW.copy_id)
BEGIN
    SELECT RAISE(ABORT, 'That copy is lost or withdrawn');
END;

-- Extended loans must be chosen at checkout, not afterwards.
CREATE TRIGGER loan_type_is_fixed
BEFORE UPDATE OF loan_type ON loans
WHEN NEW.loan_type <> OLD.loan_type
BEGIN
    SELECT RAISE(ABORT, 'Loan type must be chosen at checkout and cannot be changed');
END;

-- When a late book comes back, charge the late fee automatically:
-- $0.25/day for days 1-7, $0.50/day for days 8-14, $1.00/day after that, max $75.
CREATE TRIGGER assess_late_fee
AFTER UPDATE OF returned_date ON loans
WHEN OLD.returned_date IS NULL AND NEW.returned_date > NEW.due_date
BEGIN
    INSERT INTO fees (member_id, loan_id, fee_type, amount, assessed_date)
    SELECT NEW.member_id, NEW.loan_id, 'late',
           MIN(75.0, 0.25 * MIN(d, 7)
                   + 0.50 * MAX(0, MIN(d, 14) - 7)
                   + 1.00 * MAX(0, d - 14)),
           NEW.returned_date
    FROM (SELECT CAST(julianday(NEW.returned_date) - julianday(NEW.due_date) AS INTEGER) AS d);
END;

-- When a borrower reports a book lost, mark the copy lost and charge its MSRP.
CREATE TRIGGER assess_lost_fee
AFTER UPDATE OF lost_date ON loans
WHEN OLD.lost_date IS NULL AND NEW.lost_date IS NOT NULL
BEGIN
    UPDATE copies SET lost_date = NEW.lost_date WHERE copy_id = NEW.copy_id;
    INSERT INTO fees (member_id, loan_id, fee_type, amount, assessed_date)
    SELECT NEW.member_id, NEW.loan_id, 'lost', b.msrp, NEW.lost_date
    FROM copies c JOIN books b ON b.book_id = c.book_id
    WHERE c.copy_id = NEW.copy_id;
END;

------------------------------------------------------------------------
-- VIEWS (answers the library asks every day, computed from the tables)
------------------------------------------------------------------------

-- Age group comes from birth_date, so it updates itself as members grow up.
CREATE VIEW member_profiles AS
SELECT m.*,
       CAST((julianday('now', 'localtime') - julianday(m.birth_date)) / 365.2425 AS INTEGER) AS age,
       CASE
         WHEN (julianday('now', 'localtime') - julianday(m.birth_date)) / 365.2425 < 8  THEN 'child (under 8)'
         WHEN (julianday('now', 'localtime') - julianday(m.birth_date)) / 365.2425 < 13 THEN 'child (8-12)'
         WHEN (julianday('now', 'localtime') - julianday(m.birth_date)) / 365.2425 < 19 THEN 'teen (13-18)'
         ELSE 'adult'
       END AS age_group
FROM members m;

-- Who gets the free-book birthday email today.
CREATE VIEW birthday_emails_today AS
SELECT member_id, first_name, last_name, email, birth_date
FROM members
WHERE strftime('%m-%d', birth_date) = strftime('%m-%d', 'now', 'localtime');

-- Every loan with its due date, days late and the late fee owed so far.
CREATE VIEW loan_overview AS
SELECT l.loan_id, l.copy_id, b.book_id, b.title,
       l.member_id, m.first_name || ' ' || m.last_name AS member_name,
       l.loan_type, l.checkout_date, l.due_date, l.returned_date, l.lost_date,
       CASE
         WHEN l.lost_date IS NOT NULL         THEN 'lost'
         WHEN l.returned_date IS NOT NULL     THEN 'returned'
         WHEN l.due_date < date('now', 'localtime')        THEN 'overdue'
         ELSE 'checked out'
       END AS loan_status,
       x.days_late,
       MIN(75.0, 0.25 * MIN(x.days_late, 7)
               + 0.50 * MAX(0, MIN(x.days_late, 14) - 7)
               + 1.00 * MAX(0, x.days_late - 14)) AS late_fee
FROM loans l
JOIN copies  c ON c.copy_id   = l.copy_id
JOIN books   b ON b.book_id   = c.book_id
JOIN members m ON m.member_id = l.member_id
JOIN (SELECT loan_id,
             MAX(0, CAST(julianday(COALESCE(returned_date, lost_date, date('now', 'localtime')))
                       - julianday(due_date) AS INTEGER)) AS days_late
      FROM loans) x ON x.loan_id = l.loan_id;

-- Where every copy is right now. Status is derived, never typed in,
-- so it can't disagree with the loans and holds tables.
CREATE VIEW copy_status AS
SELECT c.copy_id, c.book_id, b.title, c.condition,
       CASE
         WHEN c.withdrawn_date IS NOT NULL THEN 'withdrawn'
         WHEN c.lost_date      IS NOT NULL THEN 'lost'
         WHEN EXISTS (SELECT 1 FROM loans l
                      WHERE l.copy_id = c.copy_id AND l.returned_date IS NULL
                        AND l.lost_date IS NULL AND l.due_date < date('now', 'localtime')) THEN 'overdue'
         WHEN EXISTS (SELECT 1 FROM loans l
                      WHERE l.copy_id = c.copy_id AND l.returned_date IS NULL
                        AND l.lost_date IS NULL) THEN 'checked out'
         WHEN EXISTS (SELECT 1 FROM holds h
                      WHERE h.copy_id = c.copy_id AND h.status = 'ready'
                        AND h.expires_date >= date('now', 'localtime')) THEN 'on hold'
         ELSE 'available'
       END AS status
FROM copies c JOIN books b ON b.book_id = c.book_id;

-- How each title circulates:
--   checkouts               how many times it has been borrowed
--   avg_days_checked_out    average length of a finished loan
--   avg_days_on_shelf       average wait on the shelf before the next checkout
--                           (from when the copy arrived or was last returned)
CREATE VIEW book_circulation AS
WITH gaps AS (
    SELECT l.copy_id, l.checkout_date, l.returned_date,
           julianday(l.returned_date) - julianday(l.checkout_date) AS days_out,
           julianday(l.checkout_date) - julianday(COALESCE(
               LAG(l.returned_date) OVER (PARTITION BY l.copy_id ORDER BY l.checkout_date),
               c.acquired_date)) AS days_on_shelf
    FROM loans l JOIN copies c ON c.copy_id = l.copy_id
)
SELECT b.book_id, b.title,
       (SELECT COUNT(*) FROM copies c WHERE c.book_id = b.book_id) AS copies,
       COUNT(g.copy_id)                 AS checkouts,
       ROUND(AVG(g.days_out), 1)        AS avg_days_checked_out,
       ROUND(AVG(g.days_on_shelf), 1)   AS avg_days_on_shelf
FROM books b
LEFT JOIN copies c ON c.book_id = b.book_id
LEFT JOIN gaps   g ON g.copy_id = c.copy_id
GROUP BY b.book_id, b.title;
