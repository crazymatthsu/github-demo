-- test-infra/seed/sqlserver/00-databases.sql: generic schema helper for the test-infra SQL Server (D8 §6.3).
--
-- Creates the source databases that the source-database instances read. The names follow D5's worked
-- example: positions-db-to-deephaven reads [positions], trades-db-to-amps reads [trades]. The cases
-- then create their tables inside them (test-infra/testdata/<connector>/<case>/input/schema.sql).
--
-- Idempotent, one batch, no GO separator. `stack.sh up` applies it through apply.sh as soon as SQL
-- Server is healthy, before the app under test starts. A test fixture can also run it over JDBC
-- against master.
IF DB_ID(N'positions') IS NULL CREATE DATABASE [positions];
IF DB_ID(N'trades') IS NULL CREATE DATABASE [trades];
