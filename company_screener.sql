-- =====================================================================
-- Company Fundamentals Screener  (SQLite)
-- Data: Kaggle "New York Stock Exchange" (dgawlik/nyse)
--   fundamentals.csv  - annual 10-K line items, ~450 S&P 500 companies, 2012-2016
--   securities.csv    - ticker, company name, sector
--   prices.csv        - daily share prices 2010-2016
-- Load the three CSVs into SQLite tables named fundamentals, securities, prices
-- (tick "Column names in first line" when importing), then run sections 1 to 3 in order.
-- Section 0 is an optional data-quality check and can be run at any time.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. DATA QUALITY CHECK (optional, read-only)
-- Finds different tickers whose reported financials are identical. Three of the
-- pairs are two share classes of one company (Under Armour, News Corp, Discovery).
-- PG/REGN is a genuine error: P&G's rows are a copy of Regeneron's financials.
-- ---------------------------------------------------------------------
SELECT a."Ticker Symbol" AS ticker_a,
       b."Ticker Symbol" AS ticker_b,
       COUNT(*) AS matching_periods
FROM fundamentals a
JOIN fundamentals b
  ON a."Period Ending" = b."Period Ending"
 AND a."Total Revenue" = b."Total Revenue"
 AND a."Net Income"    = b."Net Income"
 AND a."Total Assets"  = b."Total Assets"
 AND a."Ticker Symbol" < b."Ticker Symbol"
GROUP BY a."Ticker Symbol", b."Ticker Symbol";

-- ---------------------------------------------------------------------
-- 1. PREP: tidy copy of the price table
-- Some dates carry a time part ("2016-01-05 00:00:00"); keep the first 10
-- characters so they compare cleanly with the fundamentals dates. The index
-- makes the price lookups in section 2 fast (851k rows).
-- ---------------------------------------------------------------------
CREATE TABLE prices_clean AS
SELECT symbol, substr(date, 1, 10) AS trade_date, close
FROM prices;

CREATE INDEX idx_prices_clean ON prices_clean(symbol, trade_date);

-- ---------------------------------------------------------------------
-- 2. METRICS VIEW: one row per company per year
--   ratios     : net margin, ROE, debt-to-equity, P/E (share price on the last
--                trading day on or before each year-end, within 10 days)
--   LAG()      : year-on-year revenue growth, margin change, debt-to-equity change
--   Exclusions : PG (corrupt rows) and the duplicate share classes UA, NWS, DISCK
--   ROE and debt-to-equity are NULL when equity <= 0; P/E is NULL when EPS <= 0.
-- ---------------------------------------------------------------------
CREATE VIEW company_metrics AS
WITH base AS (
  SELECT f."Ticker Symbol" AS ticker,
         s.Security AS company,
         s."GICS Sector" AS sector,
         f."Period Ending" AS period_ending,
         f."Total Revenue" AS revenue,
         f."Net Income" AS net_income,
         f."Total Equity" AS equity,
         f."Long-Term Debt" + f."Short-Term Debt / Current Portion of Long-Term Debt" AS total_debt,
         f."Earnings Per Share" AS eps,
         (SELECT p.close FROM prices_clean p
           WHERE p.symbol = f."Ticker Symbol"
             AND p.trade_date <= f."Period Ending"
             AND p.trade_date >= date(f."Period Ending", '-10 days')
           ORDER BY p.trade_date DESC LIMIT 1) AS share_price
  FROM fundamentals f
  JOIN securities s ON f."Ticker Symbol" = s."Ticker symbol"
  WHERE f."Ticker Symbol" NOT IN ('PG', 'UA', 'NWS', 'DISCK')
),
ratios AS (
  SELECT ticker, company, sector, period_ending, revenue,
         net_income * 1.0 / revenue AS net_margin,
         CASE WHEN equity > 0 THEN net_income * 1.0 / equity END AS roe,
         CASE WHEN equity > 0 THEN total_debt * 1.0 / equity END AS debt_to_equity,
         CASE WHEN eps > 0 THEN share_price / eps END AS pe_ratio
  FROM base
)
SELECT ticker, company, sector, period_ending,
       pe_ratio, roe, debt_to_equity, net_margin,
       (revenue - LAG(revenue) OVER (PARTITION BY ticker ORDER BY period_ending)) * 1.0
         / LAG(revenue) OVER (PARTITION BY ticker ORDER BY period_ending) AS revenue_growth,
       net_margin - LAG(net_margin) OVER (PARTITION BY ticker ORDER BY period_ending) AS margin_change,
       debt_to_equity - LAG(debt_to_equity) OVER (PARTITION BY ticker ORDER BY period_ending) AS debt_to_equity_change
FROM ratios;

-- ---------------------------------------------------------------------
-- 3. THE SCREENER
-- Takes each company's latest year and scores it 0-1 on five measures using
-- PERCENT_RANK (0 = worst of all companies, 1 = best; lower is better for P/E
-- and debt-to-equity, so those two are flipped):
--   valuation (P/E) | revenue growth | ROE | debt-to-equity | margin change
-- composite_score = average of the scores a company has. A company needs at
-- least 4 of the 5 to be ranked.
-- warning_flag = margin fell AND debt-to-equity rose in the latest year.
-- ---------------------------------------------------------------------
WITH latest AS (
  SELECT *, ROW_NUMBER() OVER (PARTITION BY ticker ORDER BY period_ending DESC) AS rn
  FROM company_metrics
),
cur AS (SELECT * FROM latest WHERE rn = 1),
scored AS (
  SELECT *,
    CASE WHEN pe_ratio IS NOT NULL THEN 1 - PERCENT_RANK() OVER (PARTITION BY pe_ratio IS NOT NULL ORDER BY pe_ratio) END AS pe_score,
    CASE WHEN revenue_growth IS NOT NULL THEN PERCENT_RANK() OVER (PARTITION BY revenue_growth IS NOT NULL ORDER BY revenue_growth) END AS growth_score,
    CASE WHEN roe IS NOT NULL THEN PERCENT_RANK() OVER (PARTITION BY roe IS NOT NULL ORDER BY roe) END AS roe_score,
    CASE WHEN debt_to_equity IS NOT NULL THEN 1 - PERCENT_RANK() OVER (PARTITION BY debt_to_equity IS NOT NULL ORDER BY debt_to_equity) END AS debt_score,
    CASE WHEN margin_change IS NOT NULL THEN PERCENT_RANK() OVER (PARTITION BY margin_change IS NOT NULL ORDER BY margin_change) END AS margin_score
  FROM cur
),
final AS (
  SELECT *,
    (pe_score IS NOT NULL) + (growth_score IS NOT NULL) + (roe_score IS NOT NULL) + (debt_score IS NOT NULL) + (margin_score IS NOT NULL) AS metrics_available,
    (COALESCE(pe_score,0) + COALESCE(growth_score,0) + COALESCE(roe_score,0) + COALESCE(debt_score,0) + COALESCE(margin_score,0)) * 1.0
      / NULLIF((pe_score IS NOT NULL) + (growth_score IS NOT NULL) + (roe_score IS NOT NULL) + (debt_score IS NOT NULL) + (margin_score IS NOT NULL), 0) AS composite_score,
    CASE WHEN margin_change < 0 AND debt_to_equity_change > 0 THEN 'WARNING' ELSE '' END AS warning_flag
  FROM scored
)
SELECT RANK() OVER (ORDER BY composite_score DESC) AS overall_rank,
       ticker, company, sector, period_ending,
       ROUND(composite_score, 3) AS composite_score,
       ROUND(pe_ratio, 1) AS pe_ratio,
       ROUND(revenue_growth * 100, 1) AS revenue_growth_pct,
       ROUND(roe * 100, 1) AS roe_pct,
       ROUND(debt_to_equity, 2) AS debt_to_equity,
       ROUND(margin_change * 100, 2) AS margin_change_pts,
       warning_flag
FROM final
WHERE metrics_available >= 4
ORDER BY overall_rank;
