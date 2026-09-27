-- positions-basic: the source table of the reference case (D8 §5.2, §6.5).
-- Runs in database [positions] (manifest input.database), one batch without GO, so it works over JDBC
-- and with sqlcmd (test-infra/seed/sqlserver/apply.sh). Idempotent: the stack is shared by every test
-- class of a suite (D8 §5.6), so the case recreates its table.
DROP TABLE IF EXISTS dbo.positions;

CREATE TABLE dbo.positions (
    account     VARCHAR(32)    NOT NULL,
    instrument  VARCHAR(32)    NOT NULL,
    qty         DECIMAL(19, 4) NOT NULL,
    as_of       DATETIME2(3)   NOT NULL,  -- UTC, millisecond precision
    ingested_at DATETIME2(3)   NOT NULL   -- UTC; generated, so ignored by the comparison
        CONSTRAINT df_positions_ingested_at DEFAULT SYSUTCDATETIME(),
    CONSTRAINT pk_positions PRIMARY KEY (account, instrument)
);
