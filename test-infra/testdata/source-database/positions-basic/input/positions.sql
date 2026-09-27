-- positions-basic: seed rows (D8 §6.5). ingested_at takes its default.
-- The quantities cover what the canonical form must handle (D8 §5.5): integers, fractions, negatives
-- and a large value, all exact in binary floating point so DECIMAL and double pipelines agree. as_of
-- values are UTC, one with a non-zero millisecond part.
INSERT INTO dbo.positions (account, instrument, qty, as_of) VALUES
    ('ACC-001', 'AAPL',        100,     '2026-09-25T20:00:00.000'),
    ('ACC-001', 'MSFT',        250.5,   '2026-09-25T20:00:00.000'),
    ('ACC-001', 'VOD.L',      -300,     '2026-09-25T15:30:00.000'),
    ('ACC-002', 'AAPL',    1000000,     '2026-09-25T20:00:00.000'),
    ('ACC-002', 'SAP.DE',        0.25,  '2026-09-25T15:30:00.000'),
    ('ACC-003', '7203.T',     1250.75,  '2026-09-25T06:00:00.000'),
    ('ACC-003', 'NESN.SW',     -42,     '2026-09-25T15:30:00.000'),
    ('ACC-004', 'MSFT',          0.125, '2026-09-25T20:00:00.123');
